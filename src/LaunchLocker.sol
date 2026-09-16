// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";

import {ERC20Settler} from "./libraries/ERC20Settler.sol";

/// @notice Permanently holds every launch position. No withdraw, collect, or rescue.
contract LaunchLocker is IUnlockCallback {
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;

    bytes32 internal constant SALT = bytes32(uint256(1));

    IPoolManager public immutable poolManager;
    address public immutable installer;
    address public factory;
    address public distributor;

    struct Position {
        bool locked;
        bool tokenIsCurrency0;
        int24 tickLower;
        int24 tickUpper;
        address token;
        address pairAsset;
        PoolKey key;
    }

    mapping(address token => Position) public positions;

    error AlreadySet();
    error NotFactory();
    error NotInstaller();
    error NotDistributor();
    error NotPoolManager();
    error AlreadyLocked();
    error UnknownToken();
    error ZeroAddress();
    error ZeroLiquidity();
    error FeeOnTransfer();

    event FactorySet(address factory);
    event DistributorSet(address distributor);
    event PositionLocked(address indexed token, int24 tickLower, int24 tickUpper, uint128 liquidity);
    event LiquidityIncreased(address indexed token, uint128 liquidity);

    modifier onlyFactory() {
        if (msg.sender != factory) revert NotFactory();
        _;
    }

    constructor(IPoolManager poolManager_) {
        if (address(poolManager_) == address(0)) revert ZeroAddress();
        poolManager = poolManager_;
        installer = msg.sender;
    }

    function setFactory(address factory_) external {
        if (factory != address(0)) revert AlreadySet();
        if (factory_ == address(0)) revert ZeroAddress();
        if (msg.sender != installer) revert NotInstaller();
        factory = factory_;
        emit FactorySet(factory_);
    }

    function setDistributor(address distributor_) external {
        if (distributor != address(0)) revert AlreadySet();
        if (distributor_ == address(0)) revert ZeroAddress();
        if (msg.sender != factory) revert NotDistributor();
        distributor = distributor_;
        emit DistributorSet(distributor_);
    }

    function seed(PoolKey calldata key, address token, uint256 tokenAmount, int24 tickLower, int24 tickUpper)
        external
        onlyFactory
    {
        if (positions[token].locked) revert AlreadyLocked();
        bool tokenIsCurrency0 = Currency.unwrap(key.currency0) == token;
        address pairAsset = tokenIsCurrency0 ? Currency.unwrap(key.currency1) : Currency.unwrap(key.currency0);

        positions[token] = Position({
            locked: true,
            tokenIsCurrency0: tokenIsCurrency0,
            tickLower: tickLower,
            tickUpper: tickUpper,
            token: token,
            pairAsset: pairAsset,
            key: key
        });

        _pullExact(token, msg.sender, tokenAmount);
        bytes memory raw = poolManager.unlock(abi.encode(token, tokenAmount, uint128(0), false));
        uint128 liquidity = abi.decode(raw, (uint128));
        _refundIdle(token, pairAsset, msg.sender);
        emit PositionLocked(token, tickLower, tickUpper, liquidity);
    }

    function increaseLiquidity(address token, uint256 amount0, uint256 amount1) external returns (uint128 liquidity) {
        if (msg.sender != distributor) revert NotDistributor();
        Position storage pos = positions[token];
        if (!pos.locked) revert UnknownToken();
        _pullExact(Currency.unwrap(pos.key.currency0), msg.sender, amount0);
        _pullExact(Currency.unwrap(pos.key.currency1), msg.sender, amount1);
        bytes memory raw = poolManager.unlock(abi.encode(token, amount0, amount1, true));
        liquidity = abi.decode(raw, (uint128));
        _refundIdle(Currency.unwrap(pos.key.currency0), Currency.unwrap(pos.key.currency1), msg.sender);
        emit LiquidityIncreased(token, liquidity);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (address token, uint256 amount0OrToken, uint256 amount1, bool isIncrease) =
            abi.decode(data, (address, uint256, uint256, bool));
        Position memory pos = positions[token];

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(pos.key.toId());
        uint160 sqrtA = TickMath.getSqrtPriceAtTick(pos.tickLower);
        uint160 sqrtB = TickMath.getSqrtPriceAtTick(pos.tickUpper);

        uint256 amount0;
        uint256 amount1Used;
        if (isIncrease) {
            amount0 = amount0OrToken;
            amount1Used = amount1;
        } else if (pos.tokenIsCurrency0) {
            amount0 = amount0OrToken;
        } else {
            amount1Used = amount0OrToken;
        }

        uint128 liquidity =
            LiquidityAmounts.getLiquidityForAmounts(sqrtPriceX96, sqrtA, sqrtB, amount0, amount1Used);
        if (liquidity == 0) revert ZeroLiquidity();

        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            pos.key,
            ModifyLiquidityParams({
                tickLower: pos.tickLower,
                tickUpper: pos.tickUpper,
                liquidityDelta: int256(uint256(liquidity)),
                salt: SALT
            }),
            ""
        );
        ERC20Settler.settleDelta(poolManager, pos.key.currency0, pos.key.currency1, delta);
        return abi.encode(liquidity);
    }

    function isLocked(address token) external view returns (bool) {
        return positions[token].locked;
    }

    function _pullExact(address asset, address from, uint256 amount) private {
        if (amount == 0) return;
        uint256 before = IERC20(asset).balanceOf(address(this));
        IERC20(asset).safeTransferFrom(from, address(this), amount);
        if (IERC20(asset).balanceOf(address(this)) - before != amount) revert FeeOnTransfer();
    }

    function _refundIdle(address asset0, address asset1, address to) private {
        uint256 leftover0 = IERC20(asset0).balanceOf(address(this));
        uint256 leftover1 = IERC20(asset1).balanceOf(address(this));
        if (leftover0 != 0) IERC20(asset0).safeTransfer(to, leftover0);
        if (leftover1 != 0) IERC20(asset1).safeTransfer(to, leftover1);
    }
}

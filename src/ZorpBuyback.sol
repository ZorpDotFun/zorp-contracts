// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {FeeConfigLib} from "./libraries/ZorpTypes.sol";
import {QuoteSide} from "./libraries/QuoteSide.sol";
import {ERC20Settler} from "./libraries/ERC20Settler.sol";

interface IZorpLaunchView {
    function hook() external view returns (address);
    function POOL_FEE() external view returns (uint24);
    function TICK_SPACING() external view returns (int24);
    function launches(address token)
        external
        view
        returns (
            address token_,
            address creator,
            address pairAsset,
            address tributeRecipient,
            uint256 supply,
            uint256 openingPrice,
            uint256 launchedAt,
            int24 tickLower,
            int24 tickUpper,
            bool tokenIsCurrency0,
            bool exists
        );
}

/// @notice Admin-only sink for the protocol fee (starts at 0.5%, owner-settable).
///         Holds quote until the admin sets official $ZORP and calls buybackAndBurn.
contract ZorpBuyback is Ownable2Step, ReentrancyGuard, IUnlockCallback {
    using SafeERC20 for IERC20;

    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    IPoolManager public immutable poolManager;
    address public immutable installer;
    IZorpLaunchView public factory;
    address public zorpToken;
    uint16 public protocolFeeBps = FeeConfigLib.DEFAULT_PROTOCOL_FEE_BPS;

    error AlreadySet();
    error NotAuthorized();
    error ZeroAddress();
    error ZorpNotSet();
    error UnknownLaunch();
    error NotPoolManager();
    error Slippage();
    error InvalidFee();
    error OwnershipCannotBeRenounced();

    event FactorySet(address factory);
    event ProtocolFeeUpdated(uint16 previous, uint16 next);
    event ZorpTokenUpdated(address indexed previous, address indexed next);
    event BuybackBurned(address indexed zorp, uint256 quoteSpent, uint256 tokensBurned);
    event Withdrawn(address indexed token, address indexed to, uint256 amount);

    constructor(IPoolManager poolManager_, address admin) Ownable(admin) {
        if (address(poolManager_) == address(0) || admin == address(0)) revert ZeroAddress();
        poolManager = poolManager_;
        installer = msg.sender;
    }

    receive() external payable {}

    function renounceOwnership() public pure override {
        revert OwnershipCannotBeRenounced();
    }

    function setFactory(address factory_) external {
        if (address(factory) != address(0)) revert AlreadySet();
        if (factory_ == address(0)) revert ZeroAddress();
        if (msg.sender != installer) revert NotAuthorized();
        factory = IZorpLaunchView(factory_);
        emit FactorySet(factory_);
    }

    function setProtocolFeeBps(uint16 bps) external onlyOwner {
        if (bps > FeeConfigLib.MAX_PROTOCOL_FEE_BPS) revert InvalidFee();
        emit ProtocolFeeUpdated(protocolFeeBps, bps);
        protocolFeeBps = bps;
    }

    /// @notice Point at the official $ZORP once it is live on the launchpad.
    function setZorpToken(address token) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        emit ZorpTokenUpdated(zorpToken, token);
        zorpToken = token;
    }

    function buybackAndBurn(uint256 quoteAmount, uint256 minZorpOut) external onlyOwner nonReentrant {
        if (zorpToken == address(0)) revert ZorpNotSet();
        if (quoteAmount == 0) revert Slippage();
        uint256 burned = abi.decode(poolManager.unlock(abi.encode(quoteAmount)), (uint256));
        if (burned < minZorpOut) revert Slippage();
        emit BuybackBurned(zorpToken, quoteAmount, burned);
    }

    function withdraw(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        if (token == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert Slippage();
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
        emit Withdrawn(token, to, amount);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        uint256 quoteAmount = abi.decode(data, (uint256));
        address token = zorpToken;
        (
            ,
            ,
            address pairAsset,
            ,
            ,
            ,
            ,
            ,
            ,
            bool tokenIsCurrency0,
            bool exists
        ) = factory.launches(token);
        if (!exists || pairAsset == address(0)) revert UnknownLaunch();

        PoolKey memory key = PoolKey({
            currency0: tokenIsCurrency0 ? Currency.wrap(token) : Currency.wrap(pairAsset),
            currency1: tokenIsCurrency0 ? Currency.wrap(pairAsset) : Currency.wrap(token),
            fee: factory.POOL_FEE(),
            tickSpacing: factory.TICK_SPACING(),
            hooks: IHooks(factory.hook())
        });

        bool zeroForOne = QuoteSide.buyZeroForOne(tokenIsCurrency0);
        BalanceDelta delta = poolManager.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(quoteAmount),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );

        uint256 tokensOut = QuoteSide.abs(QuoteSide.launchAmount(tokenIsCurrency0, delta));
        uint256 spent = QuoteSide.abs(QuoteSide.quoteAmount(tokenIsCurrency0, delta));
        ERC20Settler.settle(poolManager, QuoteSide.quote(key, tokenIsCurrency0), spent);
        ERC20Settler.take(poolManager, QuoteSide.launch(key, tokenIsCurrency0), address(this), tokensOut);
        _burnZorp(token, tokensOut);
        return abi.encode(tokensOut);
    }

    function _burnZorp(address token, uint256 amount) private {
        if (amount == 0) return;
        try ERC20Burnable(token).burn(amount) {}
        catch {
            IERC20(token).safeTransfer(DEAD, amount);
        }
    }
}

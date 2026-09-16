// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BaseHook} from "@uniswap/v4-hooks-public/src/base/BaseHook.sol";

import {IFeeDistributor} from "./interfaces/IFeeDistributor.sol";
import {FeeConfig, FeeConfigLib} from "./libraries/ZorpTypes.sol";
import {QuoteSide} from "./libraries/QuoteSide.sol";
import {SnipeTax} from "./libraries/SnipeTax.sol";
import {ZorpBuyback} from "./ZorpBuyback.sol";

/// @notice Singleton hook on every Zorp pool. Snipe tax + quote-denominated fee split.
///         Owner is ZorpTimelock (2-of-3 proposer). Pair-asset allowlist lives on the factory.
contract LaunchHook is BaseHook, Ownable2Step {
    uint256 internal constant BPS = 10_000;

    address public immutable installer;
    address public factory;
    IFeeDistributor public distributor;
    address public locker;
    address public buyback;
    bool public swapsPaused;

    struct PoolInfo {
        bool registered;
        bool tokenIsCurrency0;
        address token;
        address pairAsset;
        address creator;
        uint256 launchedAt;
        FeeConfig fees;
    }

    mapping(PoolId id => PoolInfo) public pools;
    mapping(PoolId id => PoolKey) private _keys;

    error AlreadySet();
    error NotFactory();
    error NotInstaller();
    error ZeroAddress();
    error AlreadyRegistered();
    error UnknownPool();
    error LiquidityLocked();
    error SwapsPaused();
    error AmountOverflow();
    error OwnershipCannotBeRenounced();

    event FactorySet(address factory);
    event DistributorSet(address distributor);
    event LockerSet(address locker);
    event BuybackSet(address buyback);
    event SwapsPausedUpdated(bool paused);
    event PoolRegistered(PoolId indexed id, address token, address pairAsset, address creator);

    modifier onlyFactory() {
        if (msg.sender != factory) revert NotFactory();
        _;
    }

    constructor(IPoolManager poolManager_, address owner_, address installer_)
        BaseHook(poolManager_)
        Ownable(owner_)
    {
        if (installer_ == address(0)) revert ZeroAddress();
        installer = installer_;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function setFactory(address factory_) external {
        if (factory != address(0)) revert AlreadySet();
        if (factory_ == address(0)) revert ZeroAddress();
        if (msg.sender != installer) revert NotInstaller();
        factory = factory_;
        emit FactorySet(factory_);
    }

    function setDistributor(address distributor_) external onlyFactory {
        if (address(distributor) != address(0)) revert AlreadySet();
        if (distributor_ == address(0)) revert ZeroAddress();
        distributor = IFeeDistributor(distributor_);
        emit DistributorSet(distributor_);
    }

    function setLocker(address locker_) external onlyFactory {
        if (locker != address(0)) revert AlreadySet();
        if (locker_ == address(0)) revert ZeroAddress();
        locker = locker_;
        emit LockerSet(locker_);
    }

    function setBuyback(address buyback_) external onlyFactory {
        if (buyback != address(0)) revert AlreadySet();
        if (buyback_ == address(0)) revert ZeroAddress();
        buyback = buyback_;
        emit BuybackSet(buyback_);
    }

    function setSwapsPaused(bool paused) external onlyFactory {
        swapsPaused = paused;
        emit SwapsPausedUpdated(paused);
    }

    function renounceOwnership() public pure override {
        revert OwnershipCannotBeRenounced();
    }

    function registerPool(
        PoolKey calldata key,
        address token,
        address pairAsset,
        address creator,
        FeeConfig calldata fees
    ) external onlyFactory {
        PoolId id = key.toId();
        if (pools[id].registered) revert AlreadyRegistered();
        bool tokenIsCurrency0 = Currency.unwrap(key.currency0) == token;
        if (Currency.unwrap(QuoteSide.quote(key, tokenIsCurrency0)) != pairAsset) revert UnknownPool();
        pools[id] = PoolInfo({
            registered: true,
            tokenIsCurrency0: tokenIsCurrency0,
            token: token,
            pairAsset: pairAsset,
            creator: creator,
            launchedAt: block.timestamp,
            fees: fees
        });
        _keys[id] = key;
        emit PoolRegistered(id, token, pairAsset, creator);
    }

    function _beforeInitialize(address sender, PoolKey calldata, uint160) internal view override returns (bytes4) {
        if (sender != factory) revert NotFactory();
        return IHooks.beforeInitialize.selector;
    }

    /// @dev Only the locker may add or remove protocol liquidity. No third-party LP.
    function _beforeAddLiquidity(address sender, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        view
        override
        returns (bytes4)
    {
        if (sender != locker) revert LiquidityLocked();
        return IHooks.beforeAddLiquidity.selector;
    }

    function _beforeRemoveLiquidity(address sender, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        view
        override
        returns (bytes4)
    {
        if (sender == locker || sender == factory || sender == address(distributor)) revert LiquidityLocked();
        return IHooks.beforeRemoveLiquidity.selector;
    }

    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolInfo memory info = pools[key.toId()];
        if (!info.registered) {
            return (IHooks.beforeSwap.selector, toBeforeSwapDelta(0, 0), 0);
        }
        if (swapsPaused && !_isInternal(sender)) revert SwapsPaused();
        if (_isInternal(sender)) {
            return (IHooks.beforeSwap.selector, toBeforeSwapDelta(0, 0), 0);
        }

        bool exactInput = params.amountSpecified < 0;
        if (!QuoteSide.quoteIsSpecified(info.tokenIsCurrency0, params.zeroForOne, exactInput)) {
            return (IHooks.beforeSwap.selector, toBeforeSwapDelta(0, 0), 0);
        }

        uint256 specified =
            exactInput ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        (uint256 splitTax, uint256 protocolFee, uint256 total) =
            _quoteCuts(info, QuoteSide.isBuy(info.tokenIsCurrency0, params.zeroForOne), specified);
        if (total == 0) return (IHooks.beforeSwap.selector, toBeforeSwapDelta(0, 0), 0);

        Currency pair = QuoteSide.quote(key, info.tokenIsCurrency0);
        poolManager.take(pair, address(distributor), total);
        distributor.accrue(info.token, splitTax, protocolFee);
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(int128(uint128(total)), 0), 0);
    }

    function _afterSwap(address sender, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        PoolInfo memory info = pools[key.toId()];
        if (!info.registered || _isInternal(sender)) return (IHooks.afterSwap.selector, 0);

        bool exactInput = params.amountSpecified < 0;
        if (QuoteSide.quoteIsSpecified(info.tokenIsCurrency0, params.zeroForOne, exactInput)) {
            return (IHooks.afterSwap.selector, 0);
        }

        bool buying = QuoteSide.isBuy(info.tokenIsCurrency0, params.zeroForOne);
        int128 quoteDelta = QuoteSide.quoteAmount(info.tokenIsCurrency0, delta);
        // Buy pays quote (negative); sell receives quote (positive).
        if (buying ? quoteDelta >= 0 : quoteDelta <= 0) return (IHooks.afterSwap.selector, 0);

        (uint256 splitTax, uint256 protocolFee, uint256 total) =
            _quoteCuts(info, buying, QuoteSide.abs(quoteDelta));
        if (total == 0) return (IHooks.afterSwap.selector, 0);

        Currency pair = QuoteSide.quote(key, info.tokenIsCurrency0);
        poolManager.take(pair, address(distributor), total);
        distributor.accrue(info.token, splitTax, protocolFee);
        return (IHooks.afterSwap.selector, int128(uint128(total)));
    }

    function _quoteCuts(PoolInfo memory info, bool buying, uint256 quoteAmount)
        private
        view
        returns (uint256 splitTax, uint256 protocolFee, uint256 total)
    {
        uint256 protoBps = _protocolFeeBps();
        uint256 userBps = buying
            ? uint256(info.fees.buyTaxBps) + SnipeTax.buyBps(info.launchedAt)
            : uint256(info.fees.sellTaxBps);
        if (userBps + protoBps >= BPS) {
            userBps = BPS - protoBps - 1;
        }
        splitTax = (quoteAmount * userBps) / BPS;
        protocolFee = (quoteAmount * protoBps) / BPS;
        total = splitTax + protocolFee;
        if (total > uint256(uint128(type(int128).max))) revert AmountOverflow();
    }

    function _protocolFeeBps() private view returns (uint256) {
        if (buyback == address(0)) return FeeConfigLib.DEFAULT_PROTOCOL_FEE_BPS;
        return ZorpBuyback(payable(buyback)).protocolFeeBps();
    }

    function _isInternal(address sender) private view returns (bool) {
        return sender == factory || sender == locker || sender == address(distributor) || sender == buyback;
    }
}

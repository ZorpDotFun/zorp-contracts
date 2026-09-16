// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {LaunchToken} from "./LaunchToken.sol";
import {LaunchHook} from "./LaunchHook.sol";
import {LaunchLocker} from "./LaunchLocker.sol";
import {FeeDistributor} from "./FeeDistributor.sol";
import {ZorpBuyback} from "./ZorpBuyback.sol";
import {Arc} from "./constants/Arc.sol";
import {LaunchConfig, LaunchParams, FeeConfigLib, TokenMetadataLib} from "./libraries/ZorpTypes.sol";
import {OpeningPrice} from "./libraries/OpeningPrice.sol";
import {LaunchPrep} from "./libraries/LaunchPrep.sol";
import {QuoteSide} from "./libraries/QuoteSide.sol";
import {ERC20Settler} from "./libraries/ERC20Settler.sol";

/// @notice Atomic CREATE2 deploy + v4 pool init + one-sided seed + permanent lock + optional first buy.
contract LaunchFactory is Ownable2Step, ReentrancyGuard, IUnlockCallback {
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;

    uint24 public constant POOL_FEE = 0;
    int24 public constant TICK_SPACING = 60;
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000e18;
    uint256 public constant TARGET_FDV = OpeningPrice.TARGET_FDV;
    uint8 public constant MIN_PAIR_DECIMALS = OpeningPrice.MIN_DECIMALS;
    uint8 public constant MAX_PAIR_DECIMALS = OpeningPrice.MAX_DECIMALS;
    uint256 public constant MAX_FIRST_BUY = type(uint128).max;
    uint256 public constant MAX_NAME_LENGTH = TokenMetadataLib.MAX_NAME_LENGTH;
    uint256 public constant MAX_SYMBOL_LENGTH = TokenMetadataLib.MAX_SYMBOL_LENGTH;
    uint256 public constant MAX_IMAGE_LENGTH = TokenMetadataLib.MAX_IMAGE_LENGTH;
    uint256 public constant MAX_DESCRIPTION_LENGTH = TokenMetadataLib.MAX_DESCRIPTION_LENGTH;
    uint256 public constant MAX_SOCIAL_LENGTH = TokenMetadataLib.MAX_SOCIAL_LENGTH;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    IPoolManager public immutable poolManager;
    LaunchHook public immutable hook;
    FeeDistributor public immutable distributor;
    LaunchLocker public immutable locker;
    ZorpBuyback public immutable buyback;
    address public immutable installer;

    bool public wired;
    bool public launchEnabled = true;
    mapping(address asset => bool) public approvedPairAssets;
    /// @notice Pricing decimals for a pair. `0` means read `decimals()` on the token.
    mapping(address asset => uint8) public pairDecimals;
    address public usdQuote;
    mapping(address asset => PoolKey) public pricePools;

    struct Launch {
        address token;
        address creator;
        address pairAsset;
        address tributeRecipient;
        uint256 supply;
        uint256 openingPrice;
        uint256 launchedAt;
        int24 tickLower;
        int24 tickUpper;
        bool tokenIsCurrency0;
        bool exists;
    }

    mapping(address token => Launch) public launches;
    address[] public allTokens;

    error LaunchDisabled();
    error PairNotApproved();
    error InvalidPairAsset();
    error InvalidCreator();
    error InvalidTokenParams();
    error InvalidFirstBuy();
    error TokenDeployFailed();
    error NotPoolManager();
    error NotInstaller();
    error NotWired();
    error AlreadyWired();
    error UnknownLaunch();
    error ZeroAddress();
    error FeeOnTransfer();
    error PriceUnavailable();
    error InvalidPricePool();
    error UsdQuoteUnset();
    error NotTimelock();

    event Wired();
    event PairAssetUpdated(address indexed asset, bool approved);
    event PairDecimalsUpdated(address indexed asset, uint8 decimals);
    event UsdQuoteUpdated(address quote);
    event PricePoolUpdated(address indexed asset, Currency currency0, Currency currency1);
    event LaunchEnabledUpdated(bool enabled);
    event SwapsPausedUpdated(bool paused);
    event TreasuryUpdated(address treasury);
    event TokenLaunched(
        address indexed token,
        address indexed creator,
        address indexed pairAsset,
        uint256 supply,
        uint256 openingPrice,
        uint256 firstBuySpent,
        uint256 firstBuyTokens
    );
    event TokenMetadataSet(
        address indexed token,
        string name,
        string symbol,
        string image,
        string description,
        string twitter,
        string telegram,
        string website
    );

    constructor(
        address owner_,
        IPoolManager poolManager_,
        LaunchHook hook_,
        FeeDistributor distributor_,
        LaunchLocker locker_,
        ZorpBuyback buyback_
    ) Ownable(owner_) {
        if (
            owner_ == address(0) || address(poolManager_) == address(0) || address(hook_) == address(0)
                || address(distributor_) == address(0) || address(locker_) == address(0)
                || address(buyback_) == address(0)
        ) {
            revert ZeroAddress();
        }
        poolManager = poolManager_;
        hook = hook_;
        distributor = distributor_;
        locker = locker_;
        buyback = buyback_;
        installer = msg.sender;
        if (Arc.USDC != address(0) && Arc.USDC.code.length != 0) {
            LaunchPrep.enablePair(Arc.USDC, MIN_PAIR_DECIMALS, MAX_PAIR_DECIMALS);
            approvedPairAssets[Arc.USDC] = true;
            usdQuote = Arc.USDC;
            emit PairAssetUpdated(Arc.USDC, true);
            emit UsdQuoteUpdated(Arc.USDC);
        }
    }

    /// @notice Installer-only one-shot wiring after each child `setFactory(this)`.
    function wire() external {
        if (msg.sender != installer) revert NotInstaller();
        if (wired) revert AlreadyWired();
        if (hook.factory() != address(this) || distributor.factory() != address(this) || locker.factory() != address(this))
        {
            revert NotWired();
        }
        if (address(buyback.factory()) != address(this)) revert NotWired();
        wired = true;
        hook.setDistributor(address(distributor));
        hook.setLocker(address(locker));
        hook.setBuyback(address(buyback));
        distributor.setHook(address(hook));
        distributor.setLocker(address(locker));
        locker.setDistributor(address(distributor));
        emit Wired();
    }

    function setPairAsset(address asset, bool approved) external onlyOwner {
        if (asset == address(0)) revert ZeroAddress();
        if (approved) LaunchPrep.enablePair(asset, MIN_PAIR_DECIMALS, MAX_PAIR_DECIMALS);
        approvedPairAssets[asset] = approved;
        emit PairAssetUpdated(asset, approved);
    }

    /// @notice Override pricing decimals only when the token has no `decimals()`.
    ///         If `decimals()` exists, `decimals_` must match it (or be `0` to clear).
    function setPairDecimals(address asset, uint8 decimals_) external onlyOwner {
        if (asset == address(0)) revert ZeroAddress();
        if (decimals_ != 0 && (decimals_ < MIN_PAIR_DECIMALS || decimals_ > MAX_PAIR_DECIMALS)) {
            revert InvalidPairAsset();
        }
        if (decimals_ != 0) {
            try IERC20Metadata(asset).decimals() returns (uint8 actual) {
                if (actual != decimals_) revert InvalidPairAsset();
            } catch {}
        }
        pairDecimals[asset] = decimals_;
        emit PairDecimalsUpdated(asset, decimals_);
    }

    function setUsdQuote(address quote) external onlyOwner {
        if (quote == address(0)) revert ZeroAddress();
        _pairDecimals(quote);
        usdQuote = quote;
        emit UsdQuoteUpdated(quote);
    }

    /// @notice Uniswap v4 pool used to read the live USDC price of a pairing asset.
    function setPricePool(address asset, PoolKey calldata key) external onlyOwner {
        if (asset == address(0) || usdQuote == address(0)) revert ZeroAddress();
        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);
        if (c0 >= c1) revert InvalidPricePool();
        if (!((c0 == asset && c1 == usdQuote) || (c1 == asset && c0 == usdQuote))) revert InvalidPricePool();
        LaunchPrep.requireLivePool(poolManager, key);
        pricePools[asset] = key;
        emit PricePoolUpdated(asset, key.currency0, key.currency1);
    }

    function setLaunchEnabled(bool enabled) external onlyOwner {
        launchEnabled = enabled;
        emit LaunchEnabledUpdated(enabled);
    }

    function setSwapsPaused(bool paused) external onlyOwner {
        hook.setSwapsPaused(paused);
        emit SwapsPausedUpdated(paused);
    }

    function setProtocolTreasury(address treasury) external {
        if (msg.sender != hook.owner()) revert NotTimelock();
        distributor.setProtocolTreasury(treasury);
        emit TreasuryUpdated(treasury);
    }

    function launchCount() external view returns (uint256) {
        return allTokens.length;
    }

    function predictTokenAddress(LaunchParams calldata params) external view returns (address) {
        return _computeCreate2(params.salt, _tokenCreationCode(params));
    }

    function launchToken(LaunchParams calldata params)
        external
        nonReentrant
        returns (address token, uint256 firstBuyTokens)
    {
        if (!wired) revert NotWired();
        if (!launchEnabled) revert LaunchDisabled();
        if (params.creator != msg.sender) revert InvalidCreator();
        if (bytes(params.name).length == 0 || bytes(params.symbol).length == 0) revert InvalidTokenParams();
        TokenMetadataLib.validate(params.name, params.symbol, params.metadata);
        LaunchConfig calldata config = params.config;
        if (!approvedPairAssets[config.pairAsset]) revert PairNotApproved();
        if (config.firstBuyCap > MAX_FIRST_BUY) revert InvalidFirstBuy();
        FeeConfigLib.validate(config.fees);
        uint8 pricingDecimals =
            LaunchPrep.pairDecimals(config.pairAsset, pairDecimals[config.pairAsset], MIN_PAIR_DECIMALS, MAX_PAIR_DECIMALS);
        uint256 openingPrice = OpeningPrice.rawPriceUsd(
            pricingDecimals,
            LaunchPrep.spotUsdPrice(
                poolManager,
                config.pairAsset,
                pricingDecimals,
                usdQuote,
                pricePools[config.pairAsset],
                pairDecimals[usdQuote],
                MIN_PAIR_DECIMALS,
                MAX_PAIR_DECIMALS
            )
        );

        token = _deployToken(params);
        LaunchToken(token).setMetadata(params.metadata);
        if (token == config.pairAsset) revert InvalidPairAsset();
        (PoolKey memory key, bool tokenIsCurrency0, uint160 sqrtPrice, int24 tickLower, int24 tickUpper) =
            LaunchPrep.poolGeometry(token, config.pairAsset, address(hook), POOL_FEE, TICK_SPACING, openingPrice);

        hook.registerPool(key, token, config.pairAsset, params.creator, config.fees);
        distributor.registerLaunch(token, config.pairAsset, params.creator, params.tributeRecipient, config.fees);
        distributor.setPoolKey(token, key);

        _exclude(token, address(this), true);
        _exclude(token, address(hook), true);
        _exclude(token, address(locker), true);
        _exclude(token, address(distributor), true);
        _exclude(token, address(poolManager), true);
        _exclude(token, address(buyback), true);
        _exclude(token, DEAD, true);

        poolManager.initialize(key, sqrtPrice);

        IERC20(token).forceApprove(address(locker), TOTAL_SUPPLY);
        locker.seed(key, token, TOTAL_SUPPLY, tickLower, tickUpper);
        uint256 unusedSeed = IERC20(token).balanceOf(address(this));
        if (unusedSeed != 0) LaunchToken(token).burn(unusedSeed);
        uint256 lockedSupply = TOTAL_SUPPLY - unusedSeed;

        launches[token] = Launch({
            token: token,
            creator: params.creator,
            pairAsset: config.pairAsset,
            tributeRecipient: params.tributeRecipient,
            supply: lockedSupply,
            openingPrice: openingPrice,
            launchedAt: block.timestamp,
            tickLower: tickLower,
            tickUpper: tickUpper,
            tokenIsCurrency0: tokenIsCurrency0,
            exists: true
        });
        allTokens.push(token);

        uint256 spent;
        if (config.firstBuyCap != 0) {
            _pullExact(config.pairAsset, msg.sender, config.firstBuyCap);
            uint256 feeBps = buyback.protocolFeeBps();
            uint256 reservedFee = (config.firstBuyCap * feeBps) / FeeConfigLib.BPS;
            uint256 swapBudget = config.firstBuyCap - reservedFee;
            if (swapBudget != 0) {
                uint160 limit = OpeningPrice.fourXLimit(sqrtPrice, tokenIsCurrency0);
                (spent, firstBuyTokens) = abi.decode(
                    poolManager.unlock(abi.encode(token, msg.sender, swapBudget, limit)),
                    (uint256, uint256)
                );
            }
            uint256 protocolFee = (spent * feeBps) / FeeConfigLib.BPS;
            address treasury = distributor.protocolTreasury();
            if (protocolFee != 0) IERC20(config.pairAsset).safeTransfer(treasury, protocolFee);
            uint256 refund = config.firstBuyCap - spent - protocolFee;
            if (refund != 0) IERC20(config.pairAsset).safeTransfer(msg.sender, refund);
        }

        emit TokenLaunched(token, params.creator, config.pairAsset, lockedSupply, openingPrice, spent, firstBuyTokens);
        emit TokenMetadataSet(
            token,
            params.name,
            params.symbol,
            params.metadata.image,
            params.metadata.description,
            params.metadata.twitter,
            params.metadata.telegram,
            params.metadata.website
        );
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (address token, address buyer, uint256 maxSpend, uint160 sqrtPriceLimit) =
            abi.decode(data, (address, address, uint256, uint160));
        Launch memory launch = launches[token];
        if (!launch.exists) revert UnknownLaunch();

        bool zeroForOne = QuoteSide.buyZeroForOne(launch.tokenIsCurrency0);
        PoolKey memory key = PoolKey({
            currency0: launch.tokenIsCurrency0 ? Currency.wrap(token) : Currency.wrap(launch.pairAsset),
            currency1: launch.tokenIsCurrency0 ? Currency.wrap(launch.pairAsset) : Currency.wrap(token),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });

        BalanceDelta delta = poolManager.swap(
            key,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: -int256(maxSpend), sqrtPriceLimitX96: sqrtPriceLimit}),
            ""
        );

        uint256 tokensOut = QuoteSide.abs(QuoteSide.launchAmount(launch.tokenIsCurrency0, delta));
        uint256 spent = QuoteSide.abs(QuoteSide.quoteAmount(launch.tokenIsCurrency0, delta));
        ERC20Settler.settle(poolManager, QuoteSide.quote(key, launch.tokenIsCurrency0), spent);
        ERC20Settler.take(poolManager, QuoteSide.launch(key, launch.tokenIsCurrency0), buyer, tokensOut);
        return abi.encode(spent, tokensOut);
    }

    function _deployToken(LaunchParams calldata params) private returns (address token) {
        bytes memory bytecode = _tokenCreationCode(params);
        bytes32 salt = params.salt;
        assembly ("memory-safe") {
            token := create2(0, add(bytecode, 0x20), mload(bytecode), salt)
        }
        if (token == address(0)) revert TokenDeployFailed();
    }

    function _tokenCreationCode(LaunchParams calldata params) private view returns (bytes memory) {
        return LaunchPrep.tokenCreationCode(params, address(this), address(distributor));
    }

    function _computeCreate2(bytes32 salt, bytes memory bytecode) private view returns (address) {
        return LaunchPrep.computeCreate2(address(this), salt, bytecode);
    }

    function _pairDecimals(address asset) private view returns (uint8) {
        return LaunchPrep.pairDecimals(asset, pairDecimals[asset], MIN_PAIR_DECIMALS, MAX_PAIR_DECIMALS);
    }

    function _pullExact(address asset, address from, uint256 amount) private {
        uint256 before = IERC20(asset).balanceOf(address(this));
        IERC20(asset).safeTransferFrom(from, address(this), amount);
        if (IERC20(asset).balanceOf(address(this)) - before != amount) revert FeeOnTransfer();
    }

    function _exclude(address token, address account, bool value) private {
        LaunchToken(token).setExcluded(account, value);
    }
}

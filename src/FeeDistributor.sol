// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {IFeeDistributor} from "./interfaces/IFeeDistributor.sol";
import {ILaunchToken} from "./interfaces/ILaunchToken.sol";
import {FeeConfig} from "./libraries/ZorpTypes.sol";
import {QuoteSide} from "./libraries/QuoteSide.sol";
import {ERC20Settler} from "./libraries/ERC20Settler.sol";
import {LaunchLocker} from "./LaunchLocker.sol";
import {LaunchToken} from "./LaunchToken.sol";

/// @notice Pull claims for creator / tribute / protocol / dividends.
///         Permissionless `distribute()` runs buyback-and-burn and auto-LP.
contract FeeDistributor is IFeeDistributor, IUnlockCallback, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 internal constant BPS = 10_000;

    IPoolManager public immutable poolManager;
    address public immutable installer;
    address public factory;
    address public hook;
    address public locker;
    address public protocolTreasury;

    struct Launch {
        bool registered;
        address pairAsset;
        address creator;
        address tributeRecipient;
        FeeConfig fees;
        PoolKey key;
        bool tokenIsCurrency0;
        uint256 pendingBuyback;
        uint256 pendingAutoLp;
    }

    mapping(address token => Launch) public launches;
    mapping(address account => mapping(address asset => uint256)) public claimable;
    mapping(address token => uint256) public reservedDividends;
    mapping(address token => uint256) public pendingDividends;

    error AlreadySet();
    error NotFactory();
    error NotInstaller();
    error NotHook();
    error NotPoolManager();
    error UnknownLaunch();
    error ZeroAddress();
    error NothingToDistribute();
    error Slippage();
    error FeeOnTransfer();

    event FactorySet(address factory);
    event HookSet(address hook);
    event LockerSet(address locker);
    event TreasurySet(address treasury);
    event LaunchRegistered(address indexed token, address pairAsset, address creator);
    event Accrued(address indexed token, uint256 splitQuote, uint256 protocolQuote);
    event Claimed(address indexed account, address indexed asset, uint256 amount);
    event Distributed(address indexed token, uint256 boughtBack, uint256 autoLpQuote);

    modifier onlyFactory() {
        if (msg.sender != factory) revert NotFactory();
        _;
    }

    constructor(IPoolManager poolManager_, address protocolTreasury_) {
        if (address(poolManager_) == address(0) || protocolTreasury_ == address(0)) revert ZeroAddress();
        poolManager = poolManager_;
        protocolTreasury = protocolTreasury_;
        installer = msg.sender;
    }

    function setFactory(address factory_) external {
        if (factory != address(0)) revert AlreadySet();
        if (factory_ == address(0)) revert ZeroAddress();
        if (msg.sender != installer) revert NotInstaller();
        factory = factory_;
        emit FactorySet(factory_);
    }

    function setHook(address hook_) external onlyFactory {
        if (hook != address(0)) revert AlreadySet();
        if (hook_ == address(0)) revert ZeroAddress();
        hook = hook_;
        emit HookSet(hook_);
    }

    function setLocker(address locker_) external onlyFactory {
        if (locker != address(0)) revert AlreadySet();
        if (locker_ == address(0)) revert ZeroAddress();
        locker = locker_;
        emit LockerSet(locker_);
    }

    function setProtocolTreasury(address treasury) external onlyFactory {
        if (treasury == address(0)) revert ZeroAddress();
        protocolTreasury = treasury;
        emit TreasurySet(treasury);
    }

    function registerLaunch(
        address token,
        address pairAsset,
        address creator,
        address tributeRecipient,
        FeeConfig calldata fees
    ) external onlyFactory {
        Launch storage launch = launches[token];
        if (launch.registered) revert AlreadySet();
        launch.registered = true;
        launch.pairAsset = pairAsset;
        launch.creator = creator;
        launch.tributeRecipient = tributeRecipient;
        launch.fees = fees;
        emit LaunchRegistered(token, pairAsset, creator);
    }

    function setPoolKey(address token, PoolKey calldata key) external onlyFactory {
        Launch storage launch = launches[token];
        if (!launch.registered) revert UnknownLaunch();
        launch.key = key;
        launch.tokenIsCurrency0 = Currency.unwrap(key.currency0) == token;
    }

    function accrue(address token, uint256 splitQuote, uint256 protocolQuote) external nonReentrant {
        if (msg.sender != hook) revert NotHook();
        Launch storage launch = launches[token];
        if (!launch.registered) revert UnknownLaunch();
        if (splitQuote == 0 && protocolQuote == 0) return;

        address pair = launch.pairAsset;
        if (protocolQuote != 0) _pushExact(pair, protocolTreasury, protocolQuote);

        if (splitQuote != 0) {
            FeeConfig memory fees = launch.fees;
            uint256 creatorAmt = (splitQuote * fees.creatorBps) / BPS;
            uint256 dividendAmt = (splitQuote * fees.dividendBps) / BPS;
            uint256 buybackAmt = (splitQuote * fees.buybackBps) / BPS;
            uint256 autoLpAmt = (splitQuote * fees.autoLpBps) / BPS;
            uint256 tributeAmt = (splitQuote * fees.tributeBps) / BPS;
            uint256 extraProtocol = splitQuote - creatorAmt - dividendAmt - buybackAmt - autoLpAmt - tributeAmt;

            if (creatorAmt != 0) claimable[launch.creator][pair] += creatorAmt;
            if (tributeAmt != 0 && launch.tributeRecipient != address(0)) {
                claimable[launch.tributeRecipient][pair] += tributeAmt;
            } else if (tributeAmt != 0) {
                claimable[launch.creator][pair] += tributeAmt;
            }
            if (extraProtocol != 0) _pushExact(pair, protocolTreasury, extraProtocol);
            if (dividendAmt != 0) pendingDividends[token] += dividendAmt;
            _flushDividends(token);
            launch.pendingBuyback += buybackAmt;
            launch.pendingAutoLp += autoLpAmt;
        }

        emit Accrued(token, splitQuote, protocolQuote);
    }

    function claim(address token) external nonReentrant returns (uint256 amount) {
        address pair = launches[token].pairAsset;
        if (pair == address(0)) revert UnknownLaunch();
        _flushDividends(token);
        amount = _claimAsset(msg.sender, pair);
        uint256 dividends = LaunchToken(token).claimRewards(msg.sender);
        if (dividends != 0) {
            reservedDividends[token] -= dividends;
            _pushExact(pair, msg.sender, dividends);
            amount += dividends;
        }
        emit Claimed(msg.sender, pair, amount);
    }

    function claimToken(address asset) external nonReentrant returns (uint256 amount) {
        amount = _claimAsset(msg.sender, asset);
        emit Claimed(msg.sender, asset, amount);
    }

    function distribute(address token, uint256 minBuybackOut, uint256 minAutoLpOut) external nonReentrant {
        Launch storage launch = launches[token];
        if (!launch.registered) revert UnknownLaunch();
        _flushDividends(token);

        uint256 buybackQuote = launch.pendingBuyback;
        uint256 autoLpQuote = launch.pendingAutoLp;
        if (buybackQuote == 0 && autoLpQuote == 0) revert NothingToDistribute();
        launch.pendingBuyback = 0;
        launch.pendingAutoLp = 0;

        uint256 bought;
        if (buybackQuote != 0) {
            uint256 leftoverBuyback;
            (bought, leftoverBuyback) =
                abi.decode(poolManager.unlock(abi.encode(token, buybackQuote, true)), (uint256, uint256));
            if (leftoverBuyback != 0) launch.pendingBuyback += leftoverBuyback;
            if (bought < minBuybackOut) revert Slippage();
            if (bought != 0) LaunchToken(token).burn(bought);
        }

        if (autoLpQuote != 0) {
            uint256 half = autoLpQuote / 2;
            uint256 rest = autoLpQuote - half;
            uint256 tokensBought;
            if (half != 0) {
                uint256 leftoverHalf;
                (tokensBought, leftoverHalf) =
                    abi.decode(poolManager.unlock(abi.encode(token, half, true)), (uint256, uint256));
                if (leftoverHalf != 0) launch.pendingAutoLp += leftoverHalf;
            }
            if (tokensBought < minAutoLpOut) revert Slippage();
            (uint256 amount0, uint256 amount1) = launch.tokenIsCurrency0 ? (tokensBought, rest) : (rest, tokensBought);
            address pair = launch.pairAsset;
            uint256 pairBefore = IERC20(pair).balanceOf(address(this));
            uint256 tokBefore = IERC20(token).balanceOf(address(this));
            if (amount0 != 0) IERC20(Currency.unwrap(launch.key.currency0)).forceApprove(locker, amount0);
            if (amount1 != 0) IERC20(Currency.unwrap(launch.key.currency1)).forceApprove(locker, amount1);
            if (amount0 != 0 || amount1 != 0) {
                LaunchLocker(locker).increaseLiquidity(token, amount0, amount1);
            }
            uint256 pairAfter = IERC20(pair).balanceOf(address(this));
            if (pairAfter + rest > pairBefore) launch.pendingAutoLp += pairAfter + rest - pairBefore;
            uint256 tokAfter = IERC20(token).balanceOf(address(this));
            if (tokAfter + tokensBought > tokBefore) {
                LaunchToken(token).burn(tokAfter + tokensBought - tokBefore);
            }
        }

        emit Distributed(token, bought, autoLpQuote);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (address token, uint256 quoteAmount, bool buyTokens) = abi.decode(data, (address, uint256, bool));
        if (!buyTokens) return abi.encode(uint256(0), uint256(0));

        Launch memory launch = launches[token];
        bool zeroForOne = QuoteSide.buyZeroForOne(launch.tokenIsCurrency0);
        BalanceDelta delta = poolManager.swap(
            launch.key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(quoteAmount),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );

        uint256 tokensOut = QuoteSide.abs(QuoteSide.launchAmount(launch.tokenIsCurrency0, delta));
        uint256 spent = QuoteSide.abs(QuoteSide.quoteAmount(launch.tokenIsCurrency0, delta));
        ERC20Settler.settle(poolManager, QuoteSide.quote(launch.key, launch.tokenIsCurrency0), spent);
        ERC20Settler.take(poolManager, QuoteSide.launch(launch.key, launch.tokenIsCurrency0), address(this), tokensOut);
        uint256 leftover = quoteAmount > spent ? quoteAmount - spent : 0;
        return abi.encode(tokensOut, leftover);
    }

    function _flushDividends(address token) private {
        uint256 pending = pendingDividends[token];
        if (pending == 0) return;
        uint256 applied = ILaunchToken(token).notifyReward(pending);
        pendingDividends[token] = pending - applied;
        if (applied != 0) reservedDividends[token] += applied;
    }

    function _claimAsset(address account, address asset) private returns (uint256 amount) {
        amount = claimable[account][asset];
        if (amount == 0) return 0;
        claimable[account][asset] = 0;
        _pushExact(asset, account, amount);
    }

    function _pushExact(address asset, address to, uint256 amount) private {
        if (amount == 0) return;
        uint256 before = IERC20(asset).balanceOf(to);
        IERC20(asset).safeTransfer(to, amount);
        if (IERC20(asset).balanceOf(to) - before != amount) revert FeeOnTransfer();
    }
}

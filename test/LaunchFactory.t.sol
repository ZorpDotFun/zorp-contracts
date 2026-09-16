// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {LaunchFactory} from "../src/LaunchFactory.sol";
import {LaunchHook} from "../src/LaunchHook.sol";
import {LaunchLocker} from "../src/LaunchLocker.sol";
import {FeeDistributor} from "../src/FeeDistributor.sol";
import {ZorpBuyback} from "../src/ZorpBuyback.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {LaunchParams, TokenMetadata} from "../src/libraries/ZorpTypes.sol";
import {FeePresets} from "../src/libraries/FeePresets.sol";
import {OpeningPrice} from "../src/libraries/OpeningPrice.sol";
import {LaunchPrep} from "../src/libraries/LaunchPrep.sol";

import {MockERC20} from "./mocks/MockERC20.sol";
import {MockFeeOnTransfer} from "./mocks/MockFeeOnTransfer.sol";
import {MockPoolManager} from "./mocks/MockPoolManager.sol";
import {TestLaunchHook} from "./mocks/TestLaunchHook.sol";

contract LaunchFactoryTest is Test {
    MockPoolManager internal manager;
    TestLaunchHook internal hook;
    ZorpBuyback internal buyback;
    FeeDistributor internal distributor;
    LaunchLocker internal locker;
    LaunchFactory internal factory;
    MockERC20 internal usdc;

    function setUp() public {
        manager = new MockPoolManager();
        IPoolManager pm = IPoolManager(address(manager));
        hook = new TestLaunchHook(pm, address(this));
        buyback = new ZorpBuyback(pm, address(this));
        distributor = new FeeDistributor(pm, address(buyback));
        locker = new LaunchLocker(pm);
        factory = new LaunchFactory(address(this), pm, hook, distributor, locker, buyback);

        hook.setFactory(address(factory));
        distributor.setFactory(address(factory));
        locker.setFactory(address(factory));
        buyback.setFactory(address(factory));
        factory.wire();

        usdc = new MockERC20("USD Coin", "USDC", 6);
        factory.setPairAsset(address(usdc), true);
        factory.setUsdQuote(address(usdc));
    }

    function test_strangerCannotSetFactory() public {
        TestLaunchHook other = new TestLaunchHook(IPoolManager(address(manager)), address(this));
        vm.prank(address(0xB0B));
        vm.expectRevert(LaunchHook.NotInstaller.selector);
        other.setFactory(address(0xB0B));
    }

    function test_strangerCannotWire() public {
        vm.prank(address(0xB0B));
        vm.expectRevert(LaunchFactory.NotInstaller.selector);
        factory.wire();
    }

    function test_wireOnlyOnce() public {
        vm.expectRevert(LaunchFactory.AlreadyWired.selector);
        factory.wire();
    }

    function test_launchRequiresWire() public {
        IPoolManager pm = IPoolManager(address(manager));
        TestLaunchHook h2 = new TestLaunchHook(pm, address(this));
        ZorpBuyback b2 = new ZorpBuyback(pm, address(this));
        FeeDistributor d2 = new FeeDistributor(pm, address(b2));
        LaunchLocker l2 = new LaunchLocker(pm);
        LaunchFactory f2 = new LaunchFactory(address(this), pm, h2, d2, l2, b2);
        f2.setPairAsset(address(usdc), true);
        vm.expectRevert(LaunchFactory.NotWired.selector);
        f2.launchToken(_params(address(usdc), 0, bytes32(uint256(1))));
    }

    function test_creatorMustBeSender() public {
        LaunchParams memory params = _params(address(usdc), 0, bytes32(uint256(2)));
        params.creator = address(0xC1);
        vm.expectRevert(LaunchFactory.InvalidCreator.selector);
        factory.launchToken(params);
    }

    function test_launchStoresMetadataAndSixDecimalPrice() public {
        LaunchParams memory params = _params(address(usdc), 0, bytes32(uint256(3)));
        params.metadata = TokenMetadata({
            image: "ipfs://img",
            description: "hello",
            twitter: "x.com/zorp",
            telegram: "t.me/zorp",
            website: "https://zorpdotfun.com"
        });
        (address token,) = factory.launchToken(params);
        LaunchToken launched = LaunchToken(token);
        assertEq(launched.image(), "ipfs://img");
        assertEq(launched.twitter(), "x.com/zorp");
        assertEq(launched.telegram(), "t.me/zorp");
        assertEq(launched.website(), "https://zorpdotfun.com");
        (,,,,, uint256 openingPrice,,,,,) = factory.launches(token);
        assertEq(openingPrice, OpeningPrice.rawPrice(6));
        assertEq(openingPrice, 3);
    }

    function test_eighteenDecimalPairReadsLiveUsdcPrice() public {
        MockERC20 weth = new MockERC20("Wrapped Ether", "WETH", 18);
        factory.setPairAsset(address(weth), true);
        _setLivePrice(address(weth), 3_000e6);
        (address token,) = factory.launchToken(_params(address(weth), 0, bytes32(uint256(4))));
        (,,,,, uint256 openingPrice,,,,,) = factory.launches(token);
        assertEq(openingPrice, OpeningPrice.rawPriceUsd(18, 3_000e6));
        assertEq(openingPrice, 1e9);
    }

    function test_stockPairReadsLivePriceFor3kDollars() public {
        MockERC20 stock = new MockERC20("NVIDIA", "NVDA", 18);
        factory.setPairAsset(address(stock), true);
        _setLivePrice(address(stock), 100e6);
        (address token,) = factory.launchToken(_params(address(stock), 0, bytes32(uint256(9))));
        (,,,,, uint256 openingPrice,,,,,) = factory.launches(token);
        assertEq(openingPrice, OpeningPrice.rawPriceUsd(18, 100e6));
        assertEq(openingPrice, 30e9);
    }

    function test_stockWithoutPricePoolReverts() public {
        MockERC20 stock = new MockERC20("NVIDIA", "NVDA", 18);
        factory.setPairAsset(address(stock), true);
        vm.expectRevert(LaunchPrep.PriceUnavailable.selector);
        factory.launchToken(_params(address(stock), 0, bytes32(uint256(10))));
    }

    function test_usdcLaunchRequiresUsdQuote() public {
        IPoolManager pm = IPoolManager(address(manager));
        TestLaunchHook h2 = new TestLaunchHook(pm, address(this));
        ZorpBuyback b2 = new ZorpBuyback(pm, address(this));
        FeeDistributor d2 = new FeeDistributor(pm, address(b2));
        LaunchLocker l2 = new LaunchLocker(pm);
        LaunchFactory f2 = new LaunchFactory(address(this), pm, h2, d2, l2, b2);
        h2.setFactory(address(f2));
        d2.setFactory(address(f2));
        l2.setFactory(address(f2));
        b2.setFactory(address(f2));
        f2.wire();
        f2.setPairAsset(address(usdc), true);
        vm.expectRevert(LaunchPrep.UsdQuoteUnset.selector);
        f2.launchToken(_params(address(usdc), 0, bytes32(uint256(11))));
    }

    function test_mismatchedPairDecimalsReverts() public {
        vm.expectRevert(LaunchFactory.InvalidPairAsset.selector);
        factory.setPairDecimals(address(usdc), 18);
    }

    function test_strangerCannotSetPricePool() public {
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(usdc)),
            currency1: Currency.wrap(address(0xBEEF)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        vm.prank(address(0xB0B));
        vm.expectRevert();
        factory.setPricePool(address(0xBEEF), key);
    }

    function test_unsortedPricePoolReverts() public {
        MockERC20 weth = new MockERC20("Wrapped Ether", "WETH", 18);
        factory.setPairAsset(address(weth), true);
        bool wethIs0 = address(weth) < address(usdc);
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(wethIs0 ? address(usdc) : address(weth)),
            currency1: Currency.wrap(wethIs0 ? address(weth) : address(usdc)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        vm.expectRevert(LaunchFactory.InvalidPricePool.selector);
        factory.setPricePool(address(weth), key);
    }

    function test_uninitializedPricePoolReverts() public {
        MockERC20 weth = new MockERC20("Wrapped Ether", "WETH", 18);
        factory.setPairAsset(address(weth), true);
        bool wethIs0 = address(weth) < address(usdc);
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(wethIs0 ? address(weth) : address(usdc)),
            currency1: Currency.wrap(wethIs0 ? address(usdc) : address(weth)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        vm.expectRevert(LaunchPrep.PriceUnavailable.selector);
        factory.setPricePool(address(weth), key);
    }

    function test_strangerCannotSetPairDecimals() public {
        vm.prank(address(0xB0B));
        vm.expectRevert();
        factory.setPairDecimals(address(usdc), 6);
    }

    function test_strangerCannotSetTreasury() public {
        vm.prank(address(0xB0B));
        vm.expectRevert(LaunchFactory.NotTimelock.selector);
        factory.setProtocolTreasury(address(0xB0B));
    }

    function test_thirdPartyCannotAddLiquidity() public {
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(usdc)),
            currency1: Currency.wrap(address(0xBEEF)),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        ModifyLiquidityParams memory params =
            ModifyLiquidityParams({tickLower: 0, tickUpper: 60, liquidityDelta: 1, salt: bytes32(0)});
        vm.prank(address(manager));
        vm.expectRevert(LaunchHook.LiquidityLocked.selector);
        hook.beforeAddLiquidity(address(0xB0B), key, params, "");

        vm.prank(address(manager));
        bytes4 sel = hook.beforeAddLiquidity(address(locker), key, params, "");
        assertEq(sel, IHooks.beforeAddLiquidity.selector);
    }

    function test_firstBuyFeeChargedOnSpentAndSentToTreasury() public {
        manager.setSwapFillBps(1_000);
        usdc.mint(address(this), 1_000e6);
        usdc.approve(address(factory), 1_000e6);

        uint256 beforeTreasury = usdc.balanceOf(address(buyback));
        uint256 beforeUser = usdc.balanceOf(address(this));
        factory.launchToken(_params(address(usdc), 1_000e6, bytes32(uint256(5))));

        uint256 swapBudget = 1_000e6 - (1_000e6 * 50) / 10_000;
        uint256 spent = (swapBudget * 1_000) / 10_000;
        uint256 fee = (spent * 50) / 10_000;
        assertEq(usdc.balanceOf(address(buyback)) - beforeTreasury, fee);
        assertEq(beforeUser - usdc.balanceOf(address(this)), spent + fee);
        assertLt(fee, (1_000e6 * 50) / 10_000);
    }

    function test_feeOnTransferPairReverts() public {
        MockFeeOnTransfer fot = new MockFeeOnTransfer();
        factory.setPairAsset(address(fot), true);
        _setLivePrice(address(fot), 1e6);
        fot.mint(address(this), 1_000e6);
        fot.approve(address(factory), 1_000e6);
        vm.expectRevert(LaunchFactory.FeeOnTransfer.selector);
        factory.launchToken(_params(address(fot), 1_000e6, bytes32(uint256(6))));
    }

    function _setLivePrice(address asset, uint256 usdcPerWhole) private {
        bool assetIs0 = asset < address(usdc);
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(assetIs0 ? asset : address(usdc)),
            currency1: Currency.wrap(assetIs0 ? address(usdc) : asset),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        uint8 dec = IERC20Metadata(asset).decimals();
        uint256 raw = usdcPerWhole * (10 ** (18 - dec));
        manager.setSqrtPrice(key, OpeningPrice.sqrtPriceX96(asset, address(usdc), raw));
        factory.setPricePool(asset, key);
    }

    function _params(address pair, uint256 firstBuy, bytes32 salt) private view returns (LaunchParams memory params) {
        params.name = "Test Coin";
        params.symbol = "TEST";
        params.creator = address(this);
        params.salt = salt;
        params.config.pairAsset = pair;
        params.config.fees = FeePresets.creatorBacked();
        params.config.firstBuyCap = firstBuy;
    }
}

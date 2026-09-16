// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {FeeConfigLib, FeeConfig, TokenMetadata, TokenMetadataLib} from "../src/libraries/ZorpTypes.sol";
import {FeePresets} from "../src/libraries/FeePresets.sol";
import {SnipeTax} from "../src/libraries/SnipeTax.sol";
import {OpeningPrice} from "../src/libraries/OpeningPrice.sol";
import {OneSidedRange} from "../src/libraries/OneSidedRange.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TwoOfThree} from "../src/governance/TwoOfThree.sol";
import {ZorpTimelock} from "../src/governance/ZorpTimelock.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract Target {
    uint256 public value;

    function set(uint256 v) external {
        value = v;
    }
}

contract LaunchTokenTest is Test {
    LaunchToken internal token;
    address internal factory = address(this);
    address internal distributor = address(0xD1);
    address internal creator = address(0xC1);
    address internal alice = address(0xA1);
    address internal bob = address(0xB1);
    MockERC20 internal usdc;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        token = new LaunchToken("Zorp Coin", "ZORP", factory, distributor, creator, address(usdc));
        token.transfer(alice, 100_000e18);
        token.transfer(bob, 100_000e18);
    }

    function test_mintedToFactoryThenDistributed() public view {
        assertEq(token.totalSupply(), 1_000_000_000e18);
        assertEq(token.TOTAL_SUPPLY(), 1_000_000_000e18);
        assertEq(token.balanceOf(address(this)), 1_000_000_000e18 - 200_000e18);
        assertEq(token.creator(), creator);
        assertEq(token.pairAsset(), address(usdc));
    }

    function test_setMetadataStoresLaunchDetails() public {
        TokenMetadata memory meta = TokenMetadata({
            image: "ipfs://bafybeigdyrzt",
            description: "The first coin on Zorp",
            twitter: "x.com/zorpdotfun",
            telegram: "t.me/zorpdotfun",
            website: "https://zorpdotfun.com"
        });
        token.setMetadata(meta);

        (
            address tokenCreator,
            string memory tokenName,
            string memory tokenSymbol,
            string memory tokenImage,
            string memory tokenDescription,
            string memory tokenTwitter,
            string memory tokenTelegram,
            string memory tokenWebsite
        ) = token.getTokenInfo();

        assertEq(tokenCreator, creator);
        assertEq(tokenName, "Zorp Coin");
        assertEq(tokenSymbol, "ZORP");
        assertEq(tokenImage, meta.image);
        assertEq(tokenDescription, meta.description);
        assertEq(tokenTwitter, meta.twitter);
        assertEq(tokenTelegram, meta.telegram);
        assertEq(tokenWebsite, meta.website);
        assertEq(token.image(), meta.image);
        assertEq(token.imageUri(), meta.image);
        assertTrue(token.metadataFrozen());
    }

    function test_setMetadataOnlyOnce() public {
        TokenMetadata memory meta;
        token.setMetadata(meta);
        vm.expectRevert(LaunchToken.MetadataFrozen.selector);
        token.setMetadata(meta);
    }

    function test_setMetadataOnlyFactory() public {
        TokenMetadata memory meta;
        vm.prank(alice);
        vm.expectRevert(LaunchToken.NotFactory.selector);
        token.setMetadata(meta);
    }

    function test_metadataLengthCaps() public {
        TokenMetadata memory meta;
        TokenMetadataLib.validate("Zorp Coin", "ZORP", meta);

        string memory longName = _repeat("n", 65);
        vm.expectRevert(TokenMetadataLib.MetadataTooLong.selector);
        this.externalValidateMetadata(longName, "ZORP", meta);

        string memory longTicker = _repeat("T", 17);
        vm.expectRevert(TokenMetadataLib.MetadataTooLong.selector);
        this.externalValidateMetadata("Zorp Coin", longTicker, meta);

        meta.image = _repeat("i", 513);
        vm.expectRevert(TokenMetadataLib.MetadataTooLong.selector);
        this.externalValidateMetadata("Zorp Coin", "ZORP", meta);
    }

    function externalValidateMetadata(string calldata name, string calldata symbol, TokenMetadata calldata metadata)
        external
        pure
    {
        TokenMetadataLib.validate(name, symbol, metadata);
    }

    function _repeat(string memory ch, uint256 n) private pure returns (string memory out) {
        bytes memory raw = new bytes(n);
        bytes memory src = bytes(ch);
        for (uint256 i; i < n; ++i) {
            raw[i] = src[0];
        }
        out = string(raw);
    }

    function test_noOwnerMint() public {
        vm.expectRevert();
        (bool ok,) = address(token).call(abi.encodeWithSignature("mint(address,uint256)", alice, 1));
        ok;
    }

    function test_dividendAccountingOnTransfer() public {
        vm.prank(distributor);
        token.notifyReward(1_000e6);

        uint256 aliceBefore = token.pendingRewards(alice);
        uint256 factoryPending = token.pendingRewards(address(this));
        assertGt(aliceBefore, 0);
        assertGt(factoryPending, 0);

        vm.prank(alice);
        token.transfer(bob, 50_000e18);

        assertEq(token.pendingRewards(alice), aliceBefore);
        assertGt(token.pendingRewards(bob), 0);
    }

    function test_excludedSkipped() public {
        token.setExcluded(address(this), true);
        vm.prank(distributor);
        token.notifyReward(1_000e6);
        assertEq(token.pendingRewards(address(this)), 0);
        assertGt(token.pendingRewards(alice), 0);
    }

    function test_claimZerosPending() public {
        vm.prank(distributor);
        token.notifyReward(500e6);
        uint256 pending = token.pendingRewards(alice);
        vm.prank(distributor);
        uint256 claimed = token.claimRewards(alice);
        assertEq(claimed, pending);
        assertEq(token.pendingRewards(alice), 0);
    }

    function test_notifyRewardReturnsZeroWhenNoEligibleSupply() public {
        token.setExcluded(address(this), true);
        token.setExcluded(alice, true);
        token.setExcluded(bob, true);
        vm.prank(distributor);
        uint256 applied = token.notifyReward(1_000e6);
        assertEq(applied, 0);
        assertEq(token.pendingRewards(alice), 0);
    }

    function test_feeConfigAllowsZeroToTenPercent() public view {
        FeeConfig memory fees = FeePresets.creatorBacked();
        fees.buyTaxBps = 0;
        fees.sellTaxBps = 0;
        this.externalValidate(fees);
        fees.buyTaxBps = 1_000;
        fees.sellTaxBps = 1_000;
        this.externalValidate(fees);
    }

    function test_feeConfigRejectsBadTax() public {
        FeeConfig memory fees = FeePresets.creatorBacked();
        fees.buyTaxBps = 1_001;
        vm.expectRevert(FeeConfigLib.InvalidTax.selector);
        this.externalValidate(fees);
    }

    function test_feeConfigRejectsBadSplit() public {
        FeeConfig memory fees = FeePresets.creatorBacked();
        fees.creatorBps = 9_000;
        vm.expectRevert(FeeConfigLib.InvalidSplit.selector);
        this.externalValidate(fees);
    }

    function test_presetsSumTo10000() public pure {
        FeeConfigLib.validate(FeePresets.creatorBacked());
        FeeConfigLib.validate(FeePresets.diamondHands());
        FeeConfigLib.validate(FeePresets.deflationary());
        FeeConfigLib.validate(FeePresets.autoLp());
        FeeConfigLib.validate(FeePresets.tribute(100));
    }

    function externalValidate(FeeConfig calldata fees) external pure {
        FeeConfigLib.validate(fees);
    }

    function test_snipeTaxDecays() public {
        uint256 t0 = 1_000_000;
        vm.warp(t0);
        assertEq(SnipeTax.buyBps(t0), 9900);
        vm.warp(t0 + 3);
        assertEq(SnipeTax.buyBps(t0), 0);
        vm.warp(t0 + 1);
        assertGt(SnipeTax.buyBps(t0), 0);
        assertLt(SnipeTax.buyBps(t0), 9900);
    }

    function test_openingPriceInRange() public view {
        address pair = address(usdc);
        address tok = address(uint160(uint256(keccak256("token"))));
        uint160 sqrtP = OpeningPrice.sqrtPriceX96(tok, pair);
        assertGe(sqrtP, TickMath.MIN_SQRT_PRICE);
        assertLt(sqrtP, TickMath.MAX_SQRT_PRICE);
        int24 tick = TickMath.getTickAtSqrtPrice(sqrtP);
        (int24 lo, int24 hi) = OneSidedRange.ticks(tok < pair, tick, 60);
        assertLt(lo, hi);
        assertEq(lo % 60, 0);
        assertEq(hi % 60, 0);
    }

    function test_fixedOpeningPriceIsThree() public pure {
        assertEq(OpeningPrice.PRICE, 3);
        assertEq(OpeningPrice.rawPrice(6), 3);
        assertEq(OpeningPrice.rawPriceUsd(18, 3_000e6), 1e9);
        assertEq(OpeningPrice.rawPriceUsd(18, 100e6), 30e9);
        address weth = address(uint160(uint256(keccak256("weth"))));
        address usd = address(uint160(uint256(keccak256("usd"))));
        uint160 sqrtP = OpeningPrice.sqrtPriceX96(weth, usd, 3_000e6);
        uint256 spot = OpeningPrice.usdPrice6FromSqrt(sqrtP, weth < usd, 18, 6);
        assertGt(spot, 2_990e6);
        assertLt(spot, 3_010e6);
        assertEq(OpeningPrice.TARGET_FDV, 3_000);
    }

    function test_snappedFdvNearThreeThousandUsdc() public view {
        address pair = address(usdc);
        _assertNear3k(address(uint160(uint256(keccak256("token-low")))), pair, 6);
        _assertNear3k(address(uint160(uint256(keccak256("token-high")) | (uint256(type(uint160).max) << 8))), pair, 6);
    }

    function test_snappedFdvNearThreeThousandEighteenDecimals() public view {
        address pair = address(uint160(uint256(keccak256("weth-pair"))));
        _assertNear3k(address(uint160(uint256(keccak256("token-low-18")))), pair, 18);
        _assertNear3k(
            address(uint160(uint256(keccak256("token-high-18")) | (uint256(type(uint160).max) << 8))), pair, 18
        );
    }

    function _assertNear3k(address tok, address pair, uint8 decimals_) private view {
        uint256 raw = OpeningPrice.rawPrice(decimals_);
        uint160 sqrtP = OpeningPrice.sqrtPriceX96(tok, pair, raw);
        int24 tick = TickMath.getTickAtSqrtPrice(sqrtP);
        (int24 lo, int24 hi) = OneSidedRange.ticks(tok < pair, tick, 60);
        uint160 snapped = TickMath.getSqrtPriceAtTick(tok < pair ? lo : hi);
        uint256 pairPerToken = tok < pair
            ? FullMath.mulDiv(FullMath.mulDiv(snapped, snapped, 1 << 96), 1e18, 1 << 96)
            : FullMath.mulDiv(uint256(1) << 96, 1e18, FullMath.mulDiv(snapped, snapped, 1 << 96));
        uint256 fdvHuman = (1_000_000_000 * pairPerToken) / (10 ** decimals_);
        assertGt(fdvHuman, 2_900);
        assertLt(fdvHuman, 3_100);
    }

    function test_twoOfThreeAndTimelock() public {
        address a = address(0x1);
        address b = address(0x2);
        address c = address(0x3);
        TwoOfThree council = new TwoOfThree(a, b, c);
        ZorpTimelock lock = new ZorpTimelock(address(council));
        Target target = new Target();

        bytes memory data = abi.encodeCall(Target.set, (42));
        vm.prank(a);
        bytes32 hash = council.propose(address(lock), abi.encodeCall(ZorpTimelock.queue, (address(target), data)));
        vm.prank(b);
        council.approve(hash);
        vm.prank(a);
        council.execute(address(lock), abi.encodeCall(ZorpTimelock.queue, (address(target), data)), 0);

        vm.expectRevert(ZorpTimelock.NotReady.selector);
        vm.prank(address(council));
        lock.execute(address(target), data);

        vm.warp(block.timestamp + 4 hours);
        vm.prank(address(council));
        lock.execute(address(target), data);
        assertEq(target.value(), 42);

        vm.prank(a);
        bytes32 replay = council.propose(address(target), data);
        vm.prank(b);
        council.approve(replay);
        vm.prank(a);
        council.execute(address(target), data, 1);
        vm.expectRevert(TwoOfThree.AlreadyExecuted.selector);
        council.execute(address(target), data, 1);

        vm.prank(a);
        bytes32 delayHash = council.propose(address(lock), abi.encodeCall(ZorpTimelock.extendDelay, (1 days)));
        vm.prank(b);
        council.approve(delayHash);
        vm.prank(a);
        council.execute(address(lock), abi.encodeCall(ZorpTimelock.extendDelay, (1 days)), 2);

        bytes memory data2 = abi.encodeCall(Target.set, (7));
        vm.prank(a);
        bytes32 q2 = council.propose(address(lock), abi.encodeCall(ZorpTimelock.queue, (address(target), data2)));
        vm.prank(b);
        council.approve(q2);
        vm.prank(a);
        council.execute(address(lock), abi.encodeCall(ZorpTimelock.queue, (address(target), data2)), 3);

        vm.prank(address(council));
        lock.extendDelay(2 days);

        vm.warp(block.timestamp + 1 days);
        vm.prank(address(council));
        lock.execute(address(target), data2);
        assertEq(target.value(), 7);

        vm.prank(address(council));
        vm.expectRevert(ZorpTimelock.DelayTooLow.selector);
        lock.extendDelay(1 hours);
    }

    function test_twoOfThreeCancelRequiresTwoSigners() public {
        address a = address(0x1);
        address b = address(0x2);
        address c = address(0x3);
        TwoOfThree council = new TwoOfThree(a, b, c);
        Target target = new Target();
        bytes memory data = abi.encodeCall(Target.set, (99));

        vm.prank(a);
        bytes32 hash = council.propose(address(target), data);
        vm.prank(b);
        council.approve(hash);
        vm.prank(a);
        council.cancel(hash);
        assertFalse(council.cancelled(hash));
        vm.prank(c);
        council.cancel(hash);
        assertTrue(council.cancelled(hash));
        vm.expectRevert(TwoOfThree.AlreadyCancelled.selector);
        council.execute(address(target), data, 0);
    }

    function test_twoOfThreeReplaceSigner() public {
        address a = address(0x1);
        address b = address(0x2);
        address c = address(0x3);
        address d = address(0x4);
        TwoOfThree council = new TwoOfThree(a, b, c);
        bytes memory data = abi.encodeCall(TwoOfThree.replaceSigner, (c, d));
        vm.prank(a);
        bytes32 hash = council.propose(address(council), data);
        vm.prank(b);
        council.approve(hash);
        council.execute(address(council), data, 0);
        assertFalse(council.isSigner(c));
        assertTrue(council.isSigner(d));
        assertEq(council.signers(2), d);
    }
}

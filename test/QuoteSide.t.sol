// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {QuoteSide} from "../src/libraries/QuoteSide.sol";
import {FeePresets} from "../src/libraries/FeePresets.sol";
import {TestLaunchHook} from "./mocks/TestLaunchHook.sol";

contract TakeRecorder {
    address public currency;
    uint256 public amount;

    function take(Currency c, address, uint256 amt) external {
        currency = Currency.unwrap(c);
        amount = amt;
    }
}

contract AccrueSink {
    address public token;
    uint256 public amount;
    uint256 public protocolAmount;

    function accrue(address t, uint256 a, uint256 p) external {
        token = t;
        amount = a;
        protocolAmount = p;
    }
}

contract QuoteSideTest is Test {
    address internal constant QUOTE = address(0xBEEF);
    address internal constant TOKEN0 = address(0x1111);
    address internal constant TOKEN1 = address(0xF000000000000000000000000000000000000001);
    address internal constant TRADER = address(0xA11CE);

    TakeRecorder internal manager;
    AccrueSink internal distributor;
    TestLaunchHook internal hook;

    function setUp() public {
        assertLt(uint160(TOKEN0), uint160(QUOTE));
        assertGt(uint160(TOKEN1), uint160(QUOTE));

        manager = new TakeRecorder();
        distributor = new AccrueSink();
        hook = new TestLaunchHook(IPoolManager(address(manager)), address(this));
        hook.setFactory(address(this));
        hook.setDistributor(address(distributor));

        vm.warp(1_000_000);
    }

    function test_tokenAsCurrency0_quoteIsUsdc() public pure {
        PoolKey memory key = _key(TOKEN0, QUOTE);
        bool tokenIsC0 = true;

        assertEq(Currency.unwrap(QuoteSide.quote(key, tokenIsC0)), QUOTE);
        assertEq(Currency.unwrap(QuoteSide.launch(key, tokenIsC0)), TOKEN0);
        assertFalse(QuoteSide.buyZeroForOne(tokenIsC0));

        // Sell QUOTE (c1) → buy token (c0): not zeroForOne.
        assertTrue(QuoteSide.isBuy(tokenIsC0, false));
        assertTrue(QuoteSide.isSell(tokenIsC0, true));
        assertTrue(QuoteSide.quoteIsSpecified(tokenIsC0, false, true));
        assertFalse(QuoteSide.quoteIsSpecified(tokenIsC0, true, true));

        BalanceDelta sell = toBalanceDelta(-100, 50);
        assertEq(QuoteSide.quoteAmount(tokenIsC0, sell), 50);
        assertEq(QuoteSide.launchAmount(tokenIsC0, sell), -100);
    }

    function test_tokenAsCurrency1_quoteIsUsdc() public pure {
        PoolKey memory key = _key(QUOTE, TOKEN1);
        bool tokenIsC0 = false;

        assertEq(Currency.unwrap(QuoteSide.quote(key, tokenIsC0)), QUOTE);
        assertEq(Currency.unwrap(QuoteSide.launch(key, tokenIsC0)), TOKEN1);
        assertTrue(QuoteSide.buyZeroForOne(tokenIsC0));

        // Sell QUOTE (c0) → buy token (c1): zeroForOne.
        assertTrue(QuoteSide.isBuy(tokenIsC0, true));
        assertTrue(QuoteSide.isSell(tokenIsC0, false));
        assertTrue(QuoteSide.quoteIsSpecified(tokenIsC0, true, true));
        assertFalse(QuoteSide.quoteIsSpecified(tokenIsC0, false, true));

        BalanceDelta sell = toBalanceDelta(50, -100);
        assertEq(QuoteSide.quoteAmount(tokenIsC0, sell), 50);
        assertEq(QuoteSide.launchAmount(tokenIsC0, sell), -100);
    }

    function test_hookBuyExactIn_takesQuote_token0() public {
        _register(TOKEN0, QUOTE);
        _buyExactIn(_key(TOKEN0, QUOTE), false, 1_000e6);
        _assertQuoteTake(QUOTE, 15e6, 10e6, 5e6, TOKEN0);
    }

    function test_hookBuyExactIn_takesQuote_token1() public {
        _register(TOKEN1, QUOTE);
        _buyExactIn(_key(QUOTE, TOKEN1), true, 1_000e6);
        _assertQuoteTake(QUOTE, 15e6, 10e6, 5e6, TOKEN1);
    }

    function test_hookSellExactIn_takesQuote_token0() public {
        _register(TOKEN0, QUOTE);
        _sellExactIn(_key(TOKEN0, QUOTE), true, toBalanceDelta(-5_000e18, 1_000e6));
        _assertQuoteTake(QUOTE, 15e6, 10e6, 5e6, TOKEN0);
    }

    function test_hookSellExactIn_takesQuote_token1() public {
        _register(TOKEN1, QUOTE);
        _sellExactIn(_key(QUOTE, TOKEN1), false, toBalanceDelta(1_000e6, -5_000e18));
        _assertQuoteTake(QUOTE, 15e6, 10e6, 5e6, TOKEN1);
    }

    function test_hookNeverTakesLaunchToken_eitherOrdering() public {
        _register(TOKEN0, QUOTE);
        _buyExactIn(_key(TOKEN0, QUOTE), false, 500e6);
        assertEq(manager.currency(), QUOTE);

        _register(TOKEN1, QUOTE);
        _buyExactIn(_key(QUOTE, TOKEN1), true, 500e6);
        assertEq(manager.currency(), QUOTE);
        assertNotEq(manager.currency(), TOKEN0);
        assertNotEq(manager.currency(), TOKEN1);
    }

    function _register(address token, address pair) private {
        bool tokenIsC0 = token < pair;
        PoolKey memory key = tokenIsC0 ? _key(token, pair) : _key(pair, token);
        hook.registerPool(key, token, pair, address(0xC1), FeePresets.creatorBacked());
        vm.warp(block.timestamp + 3);
    }

    function _buyExactIn(PoolKey memory key, bool zeroForOne, uint256 quoteIn) private {
        vm.prank(address(manager));
        hook.beforeSwap(
            TRADER,
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(quoteIn),
                sqrtPriceLimitX96: 0
            }),
            ""
        );
    }

    function _sellExactIn(PoolKey memory key, bool zeroForOne, BalanceDelta delta) private {
        vm.prank(address(manager));
        hook.afterSwap(
            TRADER,
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(1e18),
                sqrtPriceLimitX96: 0
            }),
            delta,
            ""
        );
    }

    function _assertQuoteTake(
        address quote,
        uint256 total,
        uint256 splitTax,
        uint256 protocolFee,
        address token
    ) private view {
        assertEq(manager.currency(), quote);
        assertEq(manager.amount(), total);
        assertEq(distributor.token(), token);
        assertEq(distributor.amount(), splitTax);
        assertEq(distributor.protocolAmount(), protocolFee);
    }

    function _key(address c0, address c1) private pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
    }
}

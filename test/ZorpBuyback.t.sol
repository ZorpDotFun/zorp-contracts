// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {ZorpBuyback} from "../src/ZorpBuyback.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract ZorpBuybackTest is Test {
    ZorpBuyback internal buyback;
    MockERC20 internal usdc;
    address internal admin = address(this);
    address internal stranger = address(0xB0B);

    function setUp() public {
        buyback = new ZorpBuyback(IPoolManager(address(0xBEEF)), admin);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        usdc.mint(address(buyback), 1_000e6);
    }

    function test_defaultProtocolFeeIsHalfPercent() public view {
        assertEq(buyback.protocolFeeBps(), 50);
    }

    function test_adminSetsProtocolFee() public {
        buyback.setProtocolFeeBps(100);
        assertEq(buyback.protocolFeeBps(), 100);
        buyback.setProtocolFeeBps(0);
        assertEq(buyback.protocolFeeBps(), 0);
    }

    function test_protocolFeeCannotExceedTenPercent() public {
        vm.expectRevert(ZorpBuyback.InvalidFee.selector);
        buyback.setProtocolFeeBps(1_001);
    }

    function test_strangerCannotSetProtocolFee() public {
        vm.prank(stranger);
        vm.expectRevert();
        buyback.setProtocolFeeBps(200);
    }

    function test_adminSetsZorpToken() public {
        address zorp = address(0x1111);
        buyback.setZorpToken(zorp);
        assertEq(buyback.zorpToken(), zorp);
    }

    function test_strangerCannotSetZorpToken() public {
        vm.prank(stranger);
        vm.expectRevert();
        buyback.setZorpToken(address(0x1111));
    }

    function test_buybackRevertsUntilZorpSet() public {
        vm.expectRevert(ZorpBuyback.ZorpNotSet.selector);
        buyback.buybackAndBurn(100e6, 0);
    }

    function test_adminWithdrawsAnyToken() public {
        buyback.withdraw(address(usdc), stranger, 250e6);
        assertEq(usdc.balanceOf(stranger), 250e6);
        assertEq(usdc.balanceOf(address(buyback)), 750e6);
    }

    function test_strangerCannotWithdraw() public {
        vm.prank(stranger);
        vm.expectRevert();
        buyback.withdraw(address(usdc), stranger, 1);
    }

    function test_adminWithdrawsNative() public {
        vm.deal(address(buyback), 1 ether);
        uint256 before = stranger.balance;
        buyback.withdraw(address(0), stranger, 0.4 ether);
        assertEq(stranger.balance - before, 0.4 ether);
    }
}

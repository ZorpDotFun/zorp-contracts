// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

/// @notice Minimal PoolManager stand-in for factory launch + first-buy tests.
contract MockPoolManager {
    mapping(bytes32 slot => bytes32 value) public slots;
    uint256 public swapFillBps = 10_000;

    function setSwapFillBps(uint256 bps) external {
        swapFillBps = bps;
    }

    function setSqrtPrice(PoolKey calldata key, uint160 sqrtPriceX96) external {
        bytes32 stateSlot = keccak256(abi.encodePacked(PoolId.unwrap(key.toId()), StateLibrary.POOLS_SLOT));
        slots[stateSlot] = bytes32(uint256(sqrtPriceX96));
        slots[bytes32(uint256(stateSlot) + StateLibrary.LIQUIDITY_OFFSET)] = bytes32(uint256(1));
    }

    function initialize(PoolKey calldata key, uint160 sqrtPriceX96) external returns (int24) {
        IHooks(address(key.hooks)).beforeInitialize(msg.sender, key, sqrtPriceX96);
        bytes32 slot = keccak256(abi.encodePacked(PoolId.unwrap(key.toId()), StateLibrary.POOLS_SLOT));
        slots[slot] = bytes32(uint256(sqrtPriceX96));
        return 0;
    }

    function unlock(bytes calldata data) external returns (bytes memory) {
        return IUnlockCallback(msg.sender).unlockCallback(data);
    }

    function extsload(bytes32 slot) external view returns (bytes32) {
        return slots[slot];
    }

    function modifyLiquidity(PoolKey memory key, ModifyLiquidityParams memory, bytes calldata)
        external
        view
        returns (BalanceDelta, BalanceDelta)
    {
        uint256 b0 = IERC20(Currency.unwrap(key.currency0)).balanceOf(msg.sender);
        uint256 b1 = IERC20(Currency.unwrap(key.currency1)).balanceOf(msg.sender);
        int128 d0 = b0 == 0 ? int128(0) : -int128(uint128(b0));
        int128 d1 = b1 == 0 ? int128(0) : -int128(uint128(b1));
        return (toBalanceDelta(d0, d1), toBalanceDelta(0, 0));
    }

    function swap(PoolKey memory key, SwapParams memory params, bytes calldata) external view returns (BalanceDelta) {
        uint256 spent = (uint256(-params.amountSpecified) * swapFillBps) / 10_000;
        address out = params.zeroForOne ? Currency.unwrap(key.currency1) : Currency.unwrap(key.currency0);
        uint256 tokensOut = IERC20(out).balanceOf(address(this)) / 10;
        int128 inAmt = -int128(uint128(spent));
        int128 outAmt = int128(uint128(tokensOut));
        if (params.zeroForOne) return toBalanceDelta(inAmt, outAmt);
        return toBalanceDelta(outAmt, inAmt);
    }

    function sync(Currency) external {}

    function settle() external payable returns (uint256) {
        return 0;
    }

    function take(Currency currency, address to, uint256 amount) external {
        IERC20(Currency.unwrap(currency)).transfer(to, amount);
    }
}

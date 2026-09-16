// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

/// @notice Quote (pair asset) vs launch token. v4 `currency0`/`currency1` is
///         address sort order only — USDC can sit on either side.
library QuoteSide {
    /// @dev Buy = spend quote, receive launch token. `zeroForOne` sells currency0,
    ///      so that is a buy iff quote is currency0 (`!tokenIsCurrency0`).
    function isBuy(bool tokenIsCurrency0, bool zeroForOne) internal pure returns (bool) {
        return zeroForOne != tokenIsCurrency0;
    }

    function isSell(bool tokenIsCurrency0, bool zeroForOne) internal pure returns (bool) {
        return zeroForOne == tokenIsCurrency0;
    }

    /// @dev Swap direction that pays quote for launch tokens.
    function buyZeroForOne(bool tokenIsCurrency0) internal pure returns (bool) {
        return !tokenIsCurrency0;
    }

    /// @dev Specified is input on exact-in and output on exact-out. Quote is that
    ///      currency iff the swap is a buy xor an exact-out (buy == exactIn).
    function quoteIsSpecified(bool tokenIsCurrency0, bool zeroForOne, bool exactInput)
        internal
        pure
        returns (bool)
    {
        return isBuy(tokenIsCurrency0, zeroForOne) == exactInput;
    }

    function quote(PoolKey memory key, bool tokenIsCurrency0) internal pure returns (Currency) {
        return tokenIsCurrency0 ? key.currency1 : key.currency0;
    }

    function launch(PoolKey memory key, bool tokenIsCurrency0) internal pure returns (Currency) {
        return tokenIsCurrency0 ? key.currency0 : key.currency1;
    }

    function quoteAmount(bool tokenIsCurrency0, BalanceDelta delta) internal pure returns (int128) {
        return tokenIsCurrency0 ? delta.amount1() : delta.amount0();
    }

    function launchAmount(bool tokenIsCurrency0, BalanceDelta delta) internal pure returns (int128) {
        return tokenIsCurrency0 ? delta.amount0() : delta.amount1();
    }

    function abs(int128 value) internal pure returns (uint256) {
        return value >= 0 ? uint256(uint128(value)) : uint256(uint128(-value));
    }
}

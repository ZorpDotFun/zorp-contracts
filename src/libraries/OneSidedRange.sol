// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @notice Places the full launch-token supply entirely on the token side of the opening price.
library OneSidedRange {
    function ticks(bool tokenIsCurrency0, int24 openingTick, int24 tickSpacing)
        internal
        pure
        returns (int24 tickLower, int24 tickUpper)
    {
        int24 minUsable = TickMath.minUsableTick(tickSpacing);
        int24 maxUsable = TickMath.maxUsableTick(tickSpacing);
        int24 aligned = _align(openingTick, tickSpacing);

        if (tokenIsCurrency0) {
            return (aligned, maxUsable);
        }
        return (minUsable, aligned);
    }

    function _align(int24 tick, int24 spacing) private pure returns (int24) {
        int24 compressed = tick / spacing;
        if (tick < 0 && tick % spacing != 0) compressed--;
        return compressed * spacing;
    }
}

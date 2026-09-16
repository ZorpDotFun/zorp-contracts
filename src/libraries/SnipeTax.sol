// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Decaying launch-window buy tax: `9900 >> (elapsed_seconds * 14 / 3)`.
///         99% at t=0, ~0% by 3 seconds.
library SnipeTax {
    uint16 internal constant START_BPS = 9900;

    function buyBps(uint256 launchedAt) internal view returns (uint16) {
        if (block.timestamp <= launchedAt) return START_BPS;
        uint256 shift = ((block.timestamp - launchedAt) * 14) / 3;
        if (shift >= 16) return 0;
        return uint16(uint256(START_BPS) >> shift);
    }
}

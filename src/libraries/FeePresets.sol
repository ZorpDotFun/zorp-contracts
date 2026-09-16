// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FeeConfig} from "./ZorpTypes.sol";

/// @notice UI presets are just pre-filled FeeConfig values. The contract only sees the struct.
library FeePresets {
    function creatorBacked() internal pure returns (FeeConfig memory) {
        return FeeConfig({
            buyTaxBps: 100,
            sellTaxBps: 100,
            creatorBps: 10_000,
            dividendBps: 0,
            buybackBps: 0,
            autoLpBps: 0,
            tributeBps: 0,
            protocolBps: 0
        });
    }

    function diamondHands() internal pure returns (FeeConfig memory) {
        return FeeConfig({
            buyTaxBps: 300,
            sellTaxBps: 300,
            creatorBps: 0,
            dividendBps: 10_000,
            buybackBps: 0,
            autoLpBps: 0,
            tributeBps: 0,
            protocolBps: 0
        });
    }

    function deflationary() internal pure returns (FeeConfig memory) {
        return FeeConfig({
            buyTaxBps: 300,
            sellTaxBps: 300,
            creatorBps: 0,
            dividendBps: 0,
            buybackBps: 10_000,
            autoLpBps: 0,
            tributeBps: 0,
            protocolBps: 0
        });
    }

    function autoLp() internal pure returns (FeeConfig memory) {
        return FeeConfig({
            buyTaxBps: 300,
            sellTaxBps: 300,
            creatorBps: 0,
            dividendBps: 0,
            buybackBps: 0,
            autoLpBps: 10_000,
            tributeBps: 0,
            protocolBps: 0
        });
    }

    function tribute(uint16 taxBps) internal pure returns (FeeConfig memory) {
        return FeeConfig({
            buyTaxBps: taxBps,
            sellTaxBps: taxBps,
            creatorBps: 0,
            dividendBps: 0,
            buybackBps: 0,
            autoLpBps: 0,
            tributeBps: 10_000,
            protocolBps: 0
        });
    }
}

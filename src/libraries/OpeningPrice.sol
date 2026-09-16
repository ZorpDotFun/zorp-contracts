// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @notice Every launch opens at a hardcoded $3,000 implied FDV.
///         `usdPrice6` is the pair's USD price with 6 decimals ($1 = 1e6).
///         USDC $1 / 6dp → raw 3. WETH $3,000 / 18dp → raw 1e9 (1 WETH).
library OpeningPrice {
    error ZeroPrice();
    error UnsupportedPrice();
    error UnsupportedDecimals();

    uint256 internal constant TARGET_FDV = 3_000;
    uint256 internal constant USD_UNIT = 1e6;
    uint256 internal constant PRICE = 3;
    uint256 internal constant TOKEN_UNIT = 1e18;
    uint8 internal constant MIN_DECIMALS = 6;
    uint8 internal constant MAX_DECIMALS = 18;

    function rawPrice(uint8 pairDecimals) internal pure returns (uint256) {
        return rawPriceUsd(pairDecimals, USD_UNIT);
    }

    function rawPriceUsd(uint8 pairDecimals, uint256 usdPrice6) internal pure returns (uint256 price) {
        if (pairDecimals < MIN_DECIMALS || pairDecimals > MAX_DECIMALS) revert UnsupportedDecimals();
        if (usdPrice6 == 0) revert ZeroPrice();
        price = FullMath.mulDiv(TARGET_FDV, 10 ** pairDecimals, FullMath.mulDiv(usdPrice6, 1_000, 1));
        if (price == 0) revert ZeroPrice();
    }

    /// @notice Quote-token wei per 1 whole asset, scaled to 6 decimals (USDC).
    function usdPrice6FromSqrt(uint160 sqrtP, bool assetIsToken0, uint8 assetDecimals, uint8 quoteDecimals)
        internal
        pure
        returns (uint256 usdPrice6)
    {
        if (sqrtP == 0) revert ZeroPrice();
        uint256 quoteWei;
        if (assetIsToken0) {
            quoteWei = FullMath.mulDiv(uint256(sqrtP), uint256(sqrtP), uint256(1) << 96);
            quoteWei = FullMath.mulDiv(quoteWei, 10 ** assetDecimals, uint256(1) << 96);
        } else {
            uint256 num = FullMath.mulDiv(uint256(sqrtP), uint256(sqrtP), uint256(1) << 96);
            quoteWei = FullMath.mulDiv(uint256(1) << 96, 10 ** assetDecimals, num);
        }
        if (quoteDecimals == 6) return quoteWei;
        if (quoteDecimals > 6) return quoteWei / (10 ** (quoteDecimals - 6));
        return quoteWei * (10 ** (6 - quoteDecimals));
    }

    function sqrtPriceX96(address token, address pairAsset) internal pure returns (uint160) {
        return sqrtPriceX96(token, pairAsset, PRICE);
    }

    function sqrtPriceX96(address token, address pairAsset, uint256 openingPrice) internal pure returns (uint160) {
        if (openingPrice == 0) revert ZeroPrice();
        if (token < pairAsset) {
            return _sqrtRatioX96(openingPrice, TOKEN_UNIT);
        }
        return _sqrtRatioX96(TOKEN_UNIT, openingPrice);
    }

    /// @notice Price-limit sqrt for a 4x first-buy cap.
    function fourXLimit(uint160 openingSqrt, bool tokenIsCurrency0) internal pure returns (uint160) {
        if (tokenIsCurrency0) {
            uint256 doubled = uint256(openingSqrt) * 2;
            if (doubled >= TickMath.MAX_SQRT_PRICE) return TickMath.MAX_SQRT_PRICE - 1;
            return uint160(doubled);
        }
        uint256 halved = uint256(openingSqrt) / 2;
        if (halved <= TickMath.MIN_SQRT_PRICE) return TickMath.MIN_SQRT_PRICE + 1;
        return uint160(halved);
    }

    function _sqrtRatioX96(uint256 amount1, uint256 amount0) private pure returns (uint160) {
        if (amount0 > type(uint192).max || amount1 < (amount0 << 64)) {
            uint256 ratioX192 = FullMath.mulDiv(amount1, 1 << 192, amount0);
            uint256 root = Math.sqrt(ratioX192);
            if (root > type(uint160).max) revert UnsupportedPrice();
            if (root < TickMath.MIN_SQRT_PRICE || root >= TickMath.MAX_SQRT_PRICE) revert UnsupportedPrice();
            return uint160(root);
        }
        if (amount0 > type(uint128).max || amount1 < (amount0 << 128)) {
            uint256 ratioX128 = FullMath.mulDiv(amount1, 1 << 128, amount0);
            uint256 sqrtPriceX64 = Math.sqrt(ratioX128);
            uint256 shifted = sqrtPriceX64 << 32;
            if (shifted > type(uint160).max) revert UnsupportedPrice();
            if (shifted < TickMath.MIN_SQRT_PRICE || shifted >= TickMath.MAX_SQRT_PRICE) revert UnsupportedPrice();
            return uint160(shifted);
        }
        revert UnsupportedPrice();
    }
}

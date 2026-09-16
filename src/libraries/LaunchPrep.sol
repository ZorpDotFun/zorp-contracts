// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {LaunchToken} from "../LaunchToken.sol";
import {LaunchParams} from "./ZorpTypes.sol";
import {OpeningPrice} from "./OpeningPrice.sol";
import {OneSidedRange} from "./OneSidedRange.sol";

/// @notice External library — keeps LaunchFactory under the 24,576-byte cap.
library LaunchPrep {
    using StateLibrary for IPoolManager;

    error InvalidPairAsset();
    error PriceUnavailable();
    error UsdQuoteUnset();

    function enablePair(address asset, uint8 minDecimals, uint8 maxDecimals) external view {
        if (asset.code.length == 0) revert InvalidPairAsset();
        try IERC20Metadata(asset).decimals() returns (uint8 decimals_) {
            if (decimals_ < minDecimals || decimals_ > maxDecimals) revert InvalidPairAsset();
        } catch {
            revert InvalidPairAsset();
        }
    }

    function pairDecimals(address asset, uint8 override_, uint8 minDecimals, uint8 maxDecimals)
        external
        view
        returns (uint8)
    {
        return _pairDecimals(asset, override_, minDecimals, maxDecimals);
    }

    function _pairDecimals(address asset, uint8 override_, uint8 minDecimals, uint8 maxDecimals)
        private
        view
        returns (uint8 decimals_)
    {
        decimals_ = override_;
        try IERC20Metadata(asset).decimals() returns (uint8 value) {
            if (decimals_ != 0 && decimals_ != value) revert InvalidPairAsset();
            decimals_ = value;
        } catch {
            if (decimals_ == 0) revert InvalidPairAsset();
        }
        if (decimals_ < minDecimals || decimals_ > maxDecimals) revert InvalidPairAsset();
    }

    function requireLivePool(IPoolManager manager, PoolKey memory key) public view returns (uint160 sqrtP) {
        (sqrtP,,,) = manager.getSlot0(key.toId());
        if (sqrtP == 0 || manager.getLiquidity(key.toId()) == 0) revert PriceUnavailable();
    }

    function spotUsdPrice(
        IPoolManager manager,
        address asset,
        uint8 assetDecimals,
        address usdQuote,
        PoolKey memory pricePool,
        uint8 quoteOverride,
        uint8 minDecimals,
        uint8 maxDecimals
    ) external view returns (uint256) {
        if (usdQuote == address(0)) revert UsdQuoteUnset();
        if (asset == usdQuote) return OpeningPrice.USD_UNIT;
        address c0 = Currency.unwrap(pricePool.currency0);
        address c1 = Currency.unwrap(pricePool.currency1);
        if (c0 == address(0) && c1 == address(0)) revert PriceUnavailable();
        uint160 sqrtP = requireLivePool(manager, pricePool);
        uint8 quoteDecimals = _pairDecimals(usdQuote, quoteOverride, minDecimals, maxDecimals);
        return OpeningPrice.usdPrice6FromSqrt(sqrtP, c0 == asset, assetDecimals, quoteDecimals);
    }

    function tokenCreationCode(LaunchParams calldata params, address factory, address distributor)
        external
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(
            type(LaunchToken).creationCode,
            abi.encode(
                params.name,
                params.symbol,
                factory,
                distributor,
                params.creator,
                params.config.pairAsset
            )
        );
    }

    function computeCreate2(address factory, bytes32 salt, bytes memory bytecode) external pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), factory, salt, keccak256(bytecode))))));
    }

    function poolGeometry(address token, address pairAsset, address hook, uint24 fee, int24 spacing, uint256 openingPrice)
        external
        pure
        returns (PoolKey memory key, bool tokenIsCurrency0, uint160 sqrtPrice, int24 tickLower, int24 tickUpper)
    {
        tokenIsCurrency0 = token < pairAsset;
        key = PoolKey({
            currency0: tokenIsCurrency0 ? Currency.wrap(token) : Currency.wrap(pairAsset),
            currency1: tokenIsCurrency0 ? Currency.wrap(pairAsset) : Currency.wrap(token),
            fee: fee,
            tickSpacing: spacing,
            hooks: IHooks(hook)
        });
        sqrtPrice = OpeningPrice.sqrtPriceX96(token, pairAsset, openingPrice);
        int24 openingTick = TickMath.getTickAtSqrtPrice(sqrtPrice);
        (tickLower, tickUpper) = OneSidedRange.ticks(tokenIsCurrency0, openingTick, spacing);
        sqrtPrice = TickMath.getSqrtPriceAtTick(tokenIsCurrency0 ? tickLower : tickUpper);
    }
}

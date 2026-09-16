// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

library ERC20Settler {
    using SafeERC20 for IERC20;

    function settle(IPoolManager manager, Currency currency, uint256 amount) internal {
        if (amount == 0) return;
        manager.sync(currency);
        IERC20(Currency.unwrap(currency)).safeTransfer(address(manager), amount);
        manager.settle();
    }

    function take(IPoolManager manager, Currency currency, address to, uint256 amount) internal {
        if (amount == 0) return;
        manager.take(currency, to, amount);
    }

    function settleDelta(IPoolManager manager, Currency currency0, Currency currency1, BalanceDelta delta) internal {
        int128 d0 = delta.amount0();
        int128 d1 = delta.amount1();
        if (d0 < 0) settle(manager, currency0, uint256(uint128(-d0)));
        if (d1 < 0) settle(manager, currency1, uint256(uint128(-d1)));
        if (d0 > 0) take(manager, currency0, address(this), uint256(uint128(d0)));
        if (d1 > 0) take(manager, currency1, address(this), uint256(uint128(d1)));
    }
}

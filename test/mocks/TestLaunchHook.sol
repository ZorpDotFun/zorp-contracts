// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BaseHook} from "@uniswap/v4-hooks-public/src/base/BaseHook.sol";

import {LaunchHook} from "../../src/LaunchHook.sol";

contract TestLaunchHook is LaunchHook {
    constructor(IPoolManager manager_, address owner_) LaunchHook(manager_, owner_, msg.sender) {}

    function validateHookAddress(BaseHook) internal pure override {}
}

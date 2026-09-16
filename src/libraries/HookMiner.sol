// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

library HookMiner {
    uint160 internal constant FLAG_MASK = Hooks.ALL_HOOK_MASK;
    uint160 internal constant ZORP_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
            | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
            | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );

    error SeedNotFound();

    function find(address deployer, uint160 flags, bytes memory creationCode, bytes memory constructorArgs)
        internal
        pure
        returns (address hook, bytes32 salt)
    {
        bytes32 initCodeHash = keccak256(abi.encodePacked(creationCode, constructorArgs));
        for (uint256 i; i < 200_000; ++i) {
            salt = bytes32(i);
            hook = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash))))
            );
            if (uint160(hook) & FLAG_MASK == flags) return (hook, salt);
        }
        revert SeedNotFound();
    }
}

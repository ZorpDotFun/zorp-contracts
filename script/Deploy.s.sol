// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {Arc} from "../src/constants/Arc.sol";
import {LaunchHook} from "../src/LaunchHook.sol";
import {LaunchLocker} from "../src/LaunchLocker.sol";
import {LaunchFactory} from "../src/LaunchFactory.sol";
import {FeeDistributor} from "../src/FeeDistributor.sol";
import {ZorpBuyback} from "../src/ZorpBuyback.sol";
import {TwoOfThree} from "../src/governance/TwoOfThree.sol";
import {ZorpTimelock} from "../src/governance/ZorpTimelock.sol";
import {HookMiner} from "../src/libraries/HookMiner.sol";

contract DeployScript is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address signerA = vm.envAddress("SIGNER_A");
        address signerB = vm.envAddress("SIGNER_B");
        address signerC = vm.envAddress("SIGNER_C");
        address deployer = vm.addr(pk);

        require(Arc.V4_POOL_MANAGER != address(0), "Arc.sol empty");
        require(Arc.USDC != address(0), "Arc.USDC empty");
        require(Arc.V4_POOL_MANAGER.code.length != 0, "PoolManager has no code on this chain");
        require(Arc.USDC.code.length != 0, "USDC has no code on this chain");
        IPoolManager manager = IPoolManager(Arc.V4_POOL_MANAGER);

        vm.startBroadcast(pk);

        TwoOfThree council = new TwoOfThree(signerA, signerB, signerC);
        ZorpTimelock timelock = new ZorpTimelock(address(council));

        // Foundry salted `new` goes through the canonical CREATE2 factory, not the EOA.
        address create2 = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
        bytes memory hookCtor = abi.encode(manager, address(timelock), deployer);
        (address hookAddr, bytes32 salt) =
            HookMiner.find(create2, HookMiner.ZORP_FLAGS, type(LaunchHook).creationCode, hookCtor);
        LaunchHook hook = new LaunchHook{salt: salt}(manager, address(timelock), deployer);
        require(address(hook) == hookAddr, "hook salt mismatch");

        ZorpBuyback buyback = new ZorpBuyback(manager, address(timelock));
        FeeDistributor distributor = new FeeDistributor(manager, address(buyback));
        LaunchLocker locker = new LaunchLocker(manager);
        LaunchFactory factory = new LaunchFactory(address(council), manager, hook, distributor, locker, buyback);

        hook.setFactory(address(factory));
        distributor.setFactory(address(factory));
        locker.setFactory(address(factory));
        buyback.setFactory(address(factory));
        factory.wire();

        vm.stopBroadcast();

        require(factory.wired(), "wire failed");
        require(factory.usdQuote() == Arc.USDC, "USDC quote not bootstrapped");
        require(factory.approvedPairAssets(Arc.USDC), "USDC pair not approved");
        require(factory.owner() == address(council), "factory owner != council");
        require(hook.owner() == address(timelock), "hook owner != timelock");
        require(buyback.owner() == address(timelock), "buyback owner != timelock");

        console2.log("chainId", block.chainid);
        console2.log("deployer", deployer);
        console2.log("council", address(council));
        console2.log("timelock", address(timelock));
        console2.log("hook", address(hook));
        console2.log("buyback", address(buyback));
        console2.log("distributor", address(distributor));
        console2.log("locker", address(locker));
        console2.log("factory", address(factory));
        console2.log("usdQuote", factory.usdQuote());
        console2.log("poolManager", address(manager));
        console2.log("usdc", Arc.USDC);
    }
}

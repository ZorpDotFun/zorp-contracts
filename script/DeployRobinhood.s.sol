// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {Robinhood} from "../src/constants/Robinhood.sol";
import {LaunchHook} from "../src/LaunchHook.sol";
import {LaunchLocker} from "../src/LaunchLocker.sol";
import {LaunchFactory} from "../src/LaunchFactory.sol";
import {FeeDistributor} from "../src/FeeDistributor.sol";
import {ZorpBuyback} from "../src/ZorpBuyback.sol";
import {TwoOfThree} from "../src/governance/TwoOfThree.sol";
import {ZorpTimelock} from "../src/governance/ZorpTimelock.sol";
import {HookMiner} from "../src/libraries/HookMiner.sol";

/// @notice Deploy the Arc Zorp stack onto Robinhood Chain (4663).
///         Pair is official WETH. You broadcast — this script never prints keys.
///
///         forge script script/DeployRobinhood.s.sol:DeployRobinhoodScript \
///           --rpc-url robinhood --broadcast
contract DeployRobinhoodScript is Script {
    function run() external {
        require(block.chainid == Robinhood.CHAIN_ID, "not Robinhood 4663");

        uint256 pk = vm.envUint("PRIVATE_KEY");
        address signerA = vm.envAddress("SIGNER_A");
        address signerB = vm.envAddress("SIGNER_B");
        address signerC = vm.envAddress("SIGNER_C");
        uint256 ethUsd6 = vm.envOr("ETH_USD_6", Robinhood.WETH_USD_6);
        address deployer = vm.addr(pk);

        require(ethUsd6 != 0, "ETH_USD_6 empty");
        require(Robinhood.V4_POOL_MANAGER != address(0), "Robinhood.sol empty");
        require(Robinhood.WETH != address(0), "Robinhood.WETH empty");
        require(Robinhood.V4_POOL_MANAGER.code.length != 0, "PoolManager has no code on this chain");
        require(Robinhood.WETH.code.length != 0, "WETH has no code on this chain");
        IPoolManager manager = IPoolManager(Robinhood.V4_POOL_MANAGER);

        vm.startBroadcast(pk);

        TwoOfThree council = new TwoOfThree(signerA, signerB, signerC);
        ZorpTimelock timelock = new ZorpTimelock(address(council));

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

        if (ethUsd6 != Robinhood.WETH_USD_6) {
            factory.setPairUsdPrice6(Robinhood.WETH, ethUsd6);
        }

        hook.setFactory(address(factory));
        distributor.setFactory(address(factory));
        locker.setFactory(address(factory));
        buyback.setFactory(address(factory));
        factory.wire();

        vm.stopBroadcast();

        require(factory.wired(), "wire failed");
        require(factory.approvedPairAssets(Robinhood.WETH), "WETH pair not approved");
        require(factory.pairUsdPrice6(Robinhood.WETH) == ethUsd6, "WETH USD mark mismatch");
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
        console2.log("pairUsdPrice6", factory.pairUsdPrice6(Robinhood.WETH));
        console2.log("poolManager", address(manager));
        console2.log("weth", Robinhood.WETH);
    }
}

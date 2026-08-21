// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

import {IDeepStatePlanner} from "../src/aggregator-hooks/implementations/DeepState/interfaces/IDeepStatePlanner.sol";

import {DeepStateAggregator} from "../src/aggregator-hooks/implementations/DeepState/DeepStateAggregator.sol";
import {AggregatorHookMiner} from "./utils/AggregatorHookMiner.sol";
import {DeepStateDeploymentConstants} from "./utils/DeepStateDeploymentConstants.sol";

/// @title MineDeepStateAggregator
/// @notice Mines a production CREATE2 salt for the DeepState V1 aggregator hook.
contract MineDeepStateAggregator is Script {
    function run() external view {
        require(block.chainid == DeepStateDeploymentConstants.robinhoodChainId(), "wrong chain");

        address poolManager = DeepStateDeploymentConstants.robinhoodPoolManager();
        address planner = vm.envAddress("PLANNER");
        address routingFeeRecipient = vm.envAddress("ROUTING_FEE_RECIPIENT");
        address deployer = DeepStateDeploymentConstants.create2Deployer();

        require(poolManager.code.length != 0, "PoolManager has no code");
        require(planner.code.length != 0, "Planner has no code");
        require(routingFeeRecipient != address(0), "zero routing fee recipient");
        require(deployer.code.length != 0, "CREATE2 deployer has no code");
        require(address(IDeepStatePlanner(planner).deepstate()).code.length != 0, "Planner DeepState has no code");
        uint256 saltOffset = vm.envOr("SALT_OFFSET", uint256(0));

        bytes memory constructorArgs = abi.encode(poolManager, planner, routingFeeRecipient);

        (address hookAddress, bytes32 salt) = AggregatorHookMiner.find(
            deployer,
            DeepStateDeploymentConstants.hookFlags(),
            DeepStateDeploymentConstants.proposedDeepStateV1Id(),
            type(DeepStateAggregator).creationCode,
            constructorArgs,
            saltOffset
        );

        // Explicit post-mining sanity checks so deployment inputs cannot silently produce a wrong class of address.
        require(
            uint8(uint160(hookAddress) >> 152) == DeepStateDeploymentConstants.proposedDeepStateV1Id(),
            "wrong aggregator ID"
        );
        require(
            uint160(hookAddress) & Hooks.ALL_HOOK_MASK == DeepStateDeploymentConstants.hookFlags(),
            "wrong hook flags"
        );

        console2.log("=== DeepState Aggregator Hook Mining Result ===");
        console2.log("Hook address:", hookAddress);
        console2.log("Salt (bytes32):");
        console2.logBytes32(salt);
        console2.log("Salt (uint256):", uint256(salt));
        console2.log("CREATE2 deployer:", deployer);
        console2.log("PoolManager:", poolManager);
        console2.log("Planner:", planner);
        console2.log("Routing fee recipient:", routingFeeRecipient);
        console2.log("First-byte ID: 0xD1");
        console2.log("Hook flags:", DeepStateDeploymentConstants.hookFlags());
    }
}

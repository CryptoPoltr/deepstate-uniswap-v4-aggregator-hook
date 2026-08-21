// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

import {DeepStateAggregator} from "../src/aggregator-hooks/implementations/DeepState/DeepStateAggregator.sol";
import {IDeepStatePlanner} from "../src/aggregator-hooks/implementations/DeepState/interfaces/IDeepStatePlanner.sol";
import {DeepStateDeploymentConstants} from "./utils/DeepStateDeploymentConstants.sol";

/// @title VerifyDeepStateDeployment
/// @notice Read-only post-deployment verification for the Robinhood DeepState aggregator deployment.
contract VerifyDeepStateDeployment is Script {
    error WrongChain(uint256 actual, uint256 expected);
    error MissingCode(address target);
    error WrongAggregatorId(uint8 actual, uint8 expected);
    error WrongHookFlags(uint160 actual, uint160 expected);
    error BindingMismatch(string field, address actual, address expected);

    function run() external view {
        uint256 expectedChainId = DeepStateDeploymentConstants.robinhoodChainId();
        if (block.chainid != expectedChainId) revert WrongChain(block.chainid, expectedChainId);

        address hookAddress = vm.envAddress("HOOK");
        address plannerAddress = vm.envAddress("PLANNER");
        address deepstateAddress = vm.envAddress("DEEPSTATE");
        address routingFeeRecipient = vm.envAddress("ROUTING_FEE_RECIPIENT");
        address poolManager = DeepStateDeploymentConstants.robinhoodPoolManager();

        if (hookAddress.code.length == 0) revert MissingCode(hookAddress);
        if (plannerAddress.code.length == 0) revert MissingCode(plannerAddress);
        if (deepstateAddress.code.length == 0) revert MissingCode(deepstateAddress);
        if (poolManager.code.length == 0) revert MissingCode(poolManager);

        uint8 firstByte = uint8(uint160(hookAddress) >> 152);
        if (firstByte != DeepStateDeploymentConstants.proposedDeepStateV1Id()) {
            revert WrongAggregatorId(firstByte, DeepStateDeploymentConstants.proposedDeepStateV1Id());
        }

        uint160 flags = uint160(hookAddress) & Hooks.ALL_HOOK_MASK;
        if (flags != DeepStateDeploymentConstants.hookFlags()) {
            revert WrongHookFlags(flags, DeepStateDeploymentConstants.hookFlags());
        }

        IDeepStatePlanner planner = IDeepStatePlanner(plannerAddress);
        if (address(planner.deepstate()) != deepstateAddress) {
            revert BindingMismatch("planner.deepstate", address(planner.deepstate()), deepstateAddress);
        }

        DeepStateAggregator hook = DeepStateAggregator(payable(hookAddress));
        if (address(hook.poolManager()) != poolManager) {
            revert BindingMismatch("hook.poolManager", address(hook.poolManager()), poolManager);
        }
        if (address(hook.planner()) != plannerAddress) {
            revert BindingMismatch("hook.planner", address(hook.planner()), plannerAddress);
        }
        if (address(hook.deepstate()) != deepstateAddress) {
            revert BindingMismatch("hook.deepstate", address(hook.deepstate()), deepstateAddress);
        }
        if (hook.routingFeeRecipient() != routingFeeRecipient) {
            revert BindingMismatch("hook.routingFeeRecipient", hook.routingFeeRecipient(), routingFeeRecipient);
        }

        console2.log("=== DeepState Deployment Verification: PASS ===");
        console2.log("Chain ID:", block.chainid);
        console2.log("PoolManager:", poolManager);
        console2.log("DeepState:", deepstateAddress);
        console2.log("Planner:", plannerAddress);
        console2.log("Hook:", hookAddress);
        console2.log("Routing fee recipient:", routingFeeRecipient);
        console2.log("First-byte ID: 0xD1 (proposed)");
        console2.log("Hook flags:", flags);
    }
}

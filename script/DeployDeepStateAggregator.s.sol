// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {DeepStateAggregator} from "../src/aggregator-hooks/implementations/DeepState/DeepStateAggregator.sol";
import {IDeepStatePlanner} from "../src/aggregator-hooks/implementations/DeepState/interfaces/IDeepStatePlanner.sol";
import {AggregatorHookMiner} from "./utils/AggregatorHookMiner.sol";
import {DeepStateDeploymentConstants} from "./utils/DeepStateDeploymentConstants.sol";

/// @title DeployDeepStateAggregator
/// @notice Fail-closed deterministic deployment of the DeepState V1 aggregator hook on Robinhood Chain.
/// @dev Mine the salt against the exact same checkout/compiler/settings before running this script.
contract DeployDeepStateAggregator is Script {
    error WrongChain(uint256 actual, uint256 expected);
    error InvalidPoolManager(address manager);
    error InvalidPlanner(address planner);
    error InvalidRoutingFeeRecipient(address recipient);
    error ProposedIdNotConfirmed();
    error InvalidCreate2Deployer(address deployer);
    error PlannerDeepStateUnavailable(address deepstate);
    error ExpectedHookAlreadyDeployed(address hook);
    error PredictedHookMismatch(address expected, address predicted);
    error WrongAggregatorId(address hook, uint8 expectedId);
    error WrongHookFlags(address hook, uint160 expectedFlags, uint160 actualFlags);
    error Create2DeploymentFailed(bytes revertData);
    error DeploymentMissing(address hook);
    error PoolManagerBindingMismatch(address expected, address actual);
    error PlannerBindingMismatch(address expected, address actual);
    error DeepStateBindingMismatch(address expected, address actual);
    error RoutingFeeRecipientMismatch(address expected, address actual);

    function run() external returns (DeepStateAggregator hook) {
        uint256 expectedChainId = DeepStateDeploymentConstants.robinhoodChainId();
        if (block.chainid != expectedChainId) revert WrongChain(block.chainid, expectedChainId);
        if (!vm.envOr("CONFIRM_D1", false)) revert ProposedIdNotConfirmed();

        address poolManager = DeepStateDeploymentConstants.robinhoodPoolManager();
        address plannerAddress = vm.envAddress("PLANNER");
        address routingFeeRecipient = vm.envAddress("ROUTING_FEE_RECIPIENT");
        bytes32 salt = vm.envBytes32("HOOK_SALT");
        address expectedHook = vm.envAddress("EXPECTED_HOOK");
        address create2Deployer = DeepStateDeploymentConstants.create2Deployer();

        if (poolManager == address(0) || poolManager.code.length == 0) revert InvalidPoolManager(poolManager);
        if (plannerAddress == address(0) || plannerAddress.code.length == 0) revert InvalidPlanner(plannerAddress);
        if (routingFeeRecipient == address(0)) revert InvalidRoutingFeeRecipient(routingFeeRecipient);
        if (create2Deployer.code.length == 0) revert InvalidCreate2Deployer(create2Deployer);

        IDeepStatePlanner planner = IDeepStatePlanner(plannerAddress);
        address deepstate = address(planner.deepstate());
        if (deepstate == address(0) || deepstate.code.length == 0) revert PlannerDeepStateUnavailable(deepstate);

        bytes memory constructorArgs = abi.encode(poolManager, plannerAddress, routingFeeRecipient);
        bytes memory initCode = abi.encodePacked(type(DeepStateAggregator).creationCode, constructorArgs);
        address predicted = AggregatorHookMiner.computeAddress(create2Deployer, uint256(salt), keccak256(initCode));

        if (predicted != expectedHook) revert PredictedHookMismatch(expectedHook, predicted);
        if (routingFeeRecipient == expectedHook) revert InvalidRoutingFeeRecipient(routingFeeRecipient);
        _validateAddressBits(predicted);
        if (expectedHook.code.length != 0) revert ExpectedHookAlreadyDeployed(expectedHook);

        console2.log("=== Deploy DeepStateAggregator ===");
        console2.log("Chain ID:", block.chainid);
        console2.log("CREATE2 deployer:", create2Deployer);
        console2.log("PoolManager:", poolManager);
        console2.log("Planner:", plannerAddress);
        console2.log("DeepState:", deepstate);
        console2.log("Routing fee recipient:", routingFeeRecipient);
        console2.log("Expected hook:", expectedHook);
        console2.logBytes32(salt);
        console2.log("Init code hash:");
        console2.logBytes32(keccak256(initCode));

        // Explicitly call the same canonical deterministic deployment proxy used to mine the address.
        vm.startBroadcast();
        (bool success, bytes memory returndata) = create2Deployer.call(abi.encodePacked(salt, initCode));
        vm.stopBroadcast();
        if (!success) revert Create2DeploymentFailed(returndata);

        if (expectedHook.code.length == 0) revert DeploymentMissing(expectedHook);
        hook = DeepStateAggregator(payable(expectedHook));

        _validateAddressBits(expectedHook);
        _validateBindings(hook, poolManager, plannerAddress, deepstate, routingFeeRecipient);

        console2.log("Deployment verified:", expectedHook);
    }

    function _validateAddressBits(address hook) private pure {
        uint8 firstByte = uint8(uint160(hook) >> 152);
        if (firstByte != DeepStateDeploymentConstants.proposedDeepStateV1Id()) {
            revert WrongAggregatorId(hook, DeepStateDeploymentConstants.proposedDeepStateV1Id());
        }

        uint160 actualFlags = uint160(hook) & Hooks.ALL_HOOK_MASK;
        if (actualFlags != DeepStateDeploymentConstants.hookFlags()) {
            revert WrongHookFlags(hook, DeepStateDeploymentConstants.hookFlags(), actualFlags);
        }
    }

    function _validateBindings(
        DeepStateAggregator hook,
        address expectedPoolManager,
        address expectedPlanner,
        address expectedDeepState,
        address expectedRoutingFeeRecipient
    ) private view {
        address actualPoolManager = address(hook.poolManager());
        if (actualPoolManager != expectedPoolManager) {
            revert PoolManagerBindingMismatch(expectedPoolManager, actualPoolManager);
        }

        address actualPlanner = address(hook.planner());
        if (actualPlanner != expectedPlanner) revert PlannerBindingMismatch(expectedPlanner, actualPlanner);

        address actualDeepState = address(hook.deepstate());
        if (actualDeepState != expectedDeepState) revert DeepStateBindingMismatch(expectedDeepState, actualDeepState);

        address actualRecipient = hook.routingFeeRecipient();
        if (actualRecipient != expectedRoutingFeeRecipient) {
            revert RoutingFeeRecipientMismatch(expectedRoutingFeeRecipient, actualRecipient);
        }
    }
}

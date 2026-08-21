// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {DeepStatePlanner} from "../src/aggregator-hooks/implementations/DeepState/DeepStatePlanner.sol";
import {IDeepStateV1} from "../src/aggregator-hooks/implementations/DeepState/interfaces/IDeepStateV1.sol";
import {DeepStateDeploymentConstants} from "./utils/DeepStateDeploymentConstants.sol";

/// @title DeployDeepStatePlanner
/// @notice Deploys the immutable DeepState V1 read-only planner on Robinhood Chain.
contract DeployDeepStatePlanner is Script {
    error WrongChain(uint256 actual, uint256 expected);
    error InvalidDeepState(address deepstate);
    error DeepStateBindingMismatch(address expected, address actual);

    function run() external returns (DeepStatePlanner planner) {
        uint256 expectedChainId = DeepStateDeploymentConstants.robinhoodChainId();
        if (block.chainid != expectedChainId) revert WrongChain(block.chainid, expectedChainId);

        address deepstate = vm.envAddress("DEEPSTATE");
        if (deepstate == address(0) || deepstate.code.length == 0) revert InvalidDeepState(deepstate);

        console2.log("=== Deploy DeepStatePlanner ===");
        console2.log("Chain ID:", block.chainid);
        console2.log("DeepState:", deepstate);

        vm.startBroadcast();
        planner = new DeepStatePlanner(IDeepStateV1(deepstate));
        vm.stopBroadcast();

        address boundDeepState = address(planner.deepstate());
        if (boundDeepState != deepstate) revert DeepStateBindingMismatch(deepstate, boundDeepState);

        console2.log("Planner:", address(planner));
        console2.log("Verified DeepState binding:", boundDeepState);
    }
}

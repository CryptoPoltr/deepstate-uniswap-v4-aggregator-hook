// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

/// @title DeepStateDeploymentConstants
/// @notice Deployment-only constants for the DeepState V1 aggregator on Robinhood Chain.
library DeepStateDeploymentConstants {
    function robinhoodChainId() internal pure returns (uint256) {
        return 4663;
    }

    /// @notice Canonical Uniswap v4 PoolManager on Robinhood Chain.
    function robinhoodPoolManager() internal pure returns (address) {
        return 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    }

    /// @notice Arachnid/Foundry deterministic CREATE2 deployer used by Uniswap hook tooling.
    function create2Deployer() internal pure returns (address) {
        return 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    }

    /// @notice Proposed first-byte ID used by the current DeepState V1 aggregator deployment; upstream integration is separate.
    function proposedDeepStateV1Id() internal pure returns (uint8) {
        return 0xD1;
    }

    /// @notice Permission bits inherited from BaseAggregatorHook.
    function hookFlags() internal pure returns (uint160) {
        return uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );
    }
}

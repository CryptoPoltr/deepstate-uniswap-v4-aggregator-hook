// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IDeepStateV1} from "./IDeepStateV1.sol";

/// @title IDeepStatePlanner
/// @notice Read-only DeepState execution-planning interface used by the aggregator hook.
interface IDeepStatePlanner {
    struct Plan {
        uint256 epoch;
        uint256 amountTake; // debited from PoolManager
        uint256 deepStateInput; // actually pulled by DeepState
        uint256 amountOut; // net taker output after DeepState protocol + fixed routing fee
        uint160 baseQuantity; // DeepState quantity domain is always token0/base
        int32 limitTick; // worst tick required for this FOK fill
    }

    function deepstate() external view returns (IDeepStateV1);
    function plan(address token0, address token1, bool zeroToOne, int256 amountSpecified)
        external
        view
        returns (Plan memory result);

    function pseudoTotalValueLocked(address token0, address token1)
        external
        view
        returns (uint256 amount0, uint256 amount1);
}

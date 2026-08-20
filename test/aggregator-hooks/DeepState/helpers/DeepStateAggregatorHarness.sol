// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {DeepStateAggregator} from "../../../../src/aggregator-hooks/implementations/DeepState/DeepStateAggregator.sol";
import {
    IDeepStatePlanner
} from "../../../../src/aggregator-hooks/implementations/DeepState/interfaces/IDeepStatePlanner.sol";

contract DeepStateAggregatorHarness is DeepStateAggregator {
    constructor(IPoolManager manager, IDeepStatePlanner planner_, address routingFeeRecipient_)
        DeepStateAggregator(manager, planner_, routingFeeRecipient_)
    {}

    function conductSwapForCoverage(
        Currency settleCurrency,
        Currency takeCurrency,
        SwapParams calldata params,
        PoolId poolId
    ) external returns (uint256 amountSettle, uint256 amountTake, bool hasSettled) {
        return _conductSwap(settleCurrency, takeCurrency, params, poolId);
    }
}

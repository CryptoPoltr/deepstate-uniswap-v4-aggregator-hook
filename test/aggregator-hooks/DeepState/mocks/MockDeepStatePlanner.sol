// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {
    IDeepStatePlanner
} from "../../../../src/aggregator-hooks/implementations/DeepState/interfaces/IDeepStatePlanner.sol";
import {IDeepStateV1} from "../../../../src/aggregator-hooks/implementations/DeepState/interfaces/IDeepStateV1.sol";

contract MockDeepStatePlanner is IDeepStatePlanner {
    IDeepStateV1 public immutable override deepstate;

    Plan internal _plan;
    uint256 internal _tvl0;
    uint256 internal _tvl1;

    address public expectedToken0;
    address public expectedToken1;
    bool public expectedZeroToOne;
    int256 public expectedAmountSpecified;
    bool public enforceExpectedPlanCall;

    constructor(IDeepStateV1 deepstate_) {
        deepstate = deepstate_;
    }

    function setPlan(Plan memory plan_) external {
        _plan = plan_;
    }

    function setExpectedPlanCall(address token0, address token1, bool zeroToOne, int256 amountSpecified) external {
        expectedToken0 = token0;
        expectedToken1 = token1;
        expectedZeroToOne = zeroToOne;
        expectedAmountSpecified = amountSpecified;
        enforceExpectedPlanCall = true;
    }

    function clearExpectedPlanCall() external {
        enforceExpectedPlanCall = false;
    }

    function setTVL(uint256 amount0, uint256 amount1) external {
        _tvl0 = amount0;
        _tvl1 = amount1;
    }

    function plan(address token0, address token1, bool zeroToOne, int256 amountSpecified)
        external
        view
        override
        returns (Plan memory result)
    {
        if (enforceExpectedPlanCall) {
            require(token0 == expectedToken0, "token0");
            require(token1 == expectedToken1, "token1");
            require(zeroToOne == expectedZeroToOne, "direction");
            require(amountSpecified == expectedAmountSpecified, "amountSpecified");
        }
        return _plan;
    }

    function pseudoTotalValueLocked(address token0, address token1)
        external
        view
        override
        returns (uint256 amount0, uint256 amount1)
    {
        if (expectedToken0 != address(0)) {
            require(token0 == expectedToken0, "tvl token0");
            require(token1 == expectedToken1, "tvl token1");
        }
        return (_tvl0, _tvl1);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IDeepStateV1} from "../../../src/aggregator-hooks/implementations/DeepState/interfaces/IDeepStateV1.sol";
import {
    IDeepStatePlanner
} from "../../../src/aggregator-hooks/implementations/DeepState/interfaces/IDeepStatePlanner.sol";
import {DeepStatePlanner} from "../../../src/aggregator-hooks/implementations/DeepState/DeepStatePlanner.sol";
import {DeepStateFuzzBase} from "./helpers/DeepStateFuzzBase.sol";

/// @notice Differential fuzzing of DeepStatePlanner against the canonical local DeepstateV1 matcher.
/// @dev The planner is never compared with a duplicated reference implementation. Instead each planned
///      FOK order is executed by the real engine and its actual ERC-20 balance deltas must equal the plan.
contract DeepStatePlannerFuzz is DeepStateFuzzBase {
    DeepStatePlanner internal planner;

    function setUp() public {
        _setUpRealDeepState();
        planner = new DeepStatePlanner(IDeepStateV1(address(engine)));
    }

    function testFuzz_planExactInput_zeroForOne_matchesRealDeepState(
        uint256 bookSeed,
        uint128 amountSeed,
        uint8 feeSeed
    ) public {
        uint16 feeBps = uint16(bound(uint256(feeSeed), 0, 100));
        engine.setFeeConfig(protocolFeeRecipient, feeBps);
        uint160 totalBase = _buildRandomBook(true, bookSeed);

        uint256 amountIn = bound(uint256(amountSeed), 1e6, uint256(totalBase));
        IDeepStatePlanner.Plan memory p = planner.plan(address(token0), address(token1), true, -int256(amountIn));

        assertEq(p.amountTake, amountIn);
        _assertPlanExecutes(p, true);
    }

    function testFuzz_planExactOutput_zeroForOne_matchesRealDeepState(
        uint256 bookSeed,
        uint128 outputSeed,
        uint8 feeSeed
    ) public {
        uint16 feeBps = uint16(bound(uint256(feeSeed), 0, 100));
        engine.setFeeConfig(protocolFeeRecipient, feeBps);
        uint160 totalBase = _buildRandomBook(true, bookSeed);

        IDeepStatePlanner.Plan memory full =
            planner.plan(address(token0), address(token1), true, -int256(uint256(totalBase)));
        uint256 requestedOut = bound(uint256(outputSeed), 1, full.amountOut);

        IDeepStatePlanner.Plan memory p = planner.plan(address(token0), address(token1), true, int256(requestedOut));
        assertGe(p.amountOut, requestedOut);
        _assertPlanExecutes(p, true);
    }

    function testFuzz_planExactInput_oneForZero_matchesRealDeepState(
        uint256 bookSeed,
        uint128 budgetSeed,
        uint8 feeSeed
    ) public {
        uint16 feeBps = uint16(bound(uint256(feeSeed), 0, 100));
        engine.setFeeConfig(protocolFeeRecipient, feeBps);
        uint160 totalBase = _buildRandomBook(false, bookSeed);

        uint256 maxNetBase = _netAfterDeepStateFees(totalBase, feeBps);
        IDeepStatePlanner.Plan memory full = planner.plan(address(token0), address(token1), false, int256(maxNetBase));
        uint256 budget = bound(uint256(budgetSeed), 1e6, full.amountTake);

        IDeepStatePlanner.Plan memory p = planner.plan(address(token0), address(token1), false, -int256(budget));
        assertEq(p.amountTake, budget);
        assertLe(p.deepStateInput, budget);
        _assertPlanExecutes(p, false);
    }

    function testFuzz_planExactOutput_oneForZero_matchesRealDeepState(
        uint256 bookSeed,
        uint128 outputSeed,
        uint8 feeSeed
    ) public {
        uint16 feeBps = uint16(bound(uint256(feeSeed), 0, 100));
        engine.setFeeConfig(protocolFeeRecipient, feeBps);
        uint160 totalBase = _buildRandomBook(false, bookSeed);

        uint256 maxNetBase = _netAfterDeepStateFees(totalBase, feeBps);
        uint256 requestedOut = bound(uint256(outputSeed), 1, maxNetBase);
        IDeepStatePlanner.Plan memory p = planner.plan(address(token0), address(token1), false, int256(requestedOut));

        assertGe(p.amountOut, requestedOut);
        _assertPlanExecutes(p, false);
    }

    function _assertPlanExecutes(IDeepStatePlanner.Plan memory p, bool zeroToOne) internal {
        uint256 inputBefore = zeroToOne ? token0.balanceOf(taker) : token1.balanceOf(taker);
        uint256 outputBefore = zeroToOne ? token1.balanceOf(taker) : token0.balanceOf(taker);

        vm.prank(taker);
        bytes32 restingOrder = engine.fillWithIntegratorFee(
            _fill(p.epoch, _order(p.limitTick, p.baseQuantity), !zeroToOne, true, true), _integratorFee()
        );
        assertEq(restingOrder, bytes32(0));

        uint256 inputAfter = zeroToOne ? token0.balanceOf(taker) : token1.balanceOf(taker);
        uint256 outputAfter = zeroToOne ? token1.balanceOf(taker) : token0.balanceOf(taker);
        assertEq(inputBefore - inputAfter, p.deepStateInput, "planner input != DeepState debit");
        assertEq(outputAfter - outputBefore, p.amountOut, "planner output != DeepState credit");
    }
}

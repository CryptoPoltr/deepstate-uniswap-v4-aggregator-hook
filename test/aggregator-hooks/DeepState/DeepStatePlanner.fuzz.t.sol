// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TickMath32} from "deepstate-contracts/src/libraries/TickMath32.sol";

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

    /// @dev Regression for V12 #244822. Canonical DeepState can accept each resting BID independently
    ///      while the aggregate quote of a later FOK ASK exceeds its signed int256 settlement domain.
    function test_regression_zeroForOneExactInput_rejectsAggregateQuoteOutsideSignedSettlementDomain() public {
        _buildOverSignedDomainBidBook();

        uint256 amountIn = _overSignedDomainBaseQuantity();
        vm.expectRevert(DeepStatePlanner.AmountTooLarge.selector);
        planner.plan(address(token0), address(token1), true, -int256(amountIn));
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

    function _buildOverSignedDomainBidBook() internal {
        // Give the maker enough token1 collateral for two individually valid near-max signed quote orders.
        token1.mint(maker, type(uint256).max - token1.totalSupply());

        uint160 firstQuantity = _maxQuantityWhoseBidQuoteFitsInt256(type(int32).max);
        uint160 secondQuantity = _maxQuantityWhoseBidQuoteFitsInt256(type(int32).max - 1);
        if (uint256(firstQuantity) + uint256(secondQuantity) > type(uint160).max) {
            secondQuantity = type(uint160).max - firstQuantity;
            while (_bidQuote(type(int32).max - 1, secondQuantity) > uint256(type(int256).max)) {
                --secondQuantity;
            }
        }

        uint256 firstQuote = _bidQuote(type(int32).max, firstQuantity);
        uint256 secondQuote = _bidQuote(type(int32).max - 1, secondQuantity);
        assertLe(firstQuote, uint256(type(int256).max));
        assertLe(secondQuote, uint256(type(int256).max));
        assertGt(firstQuote + secondQuote, uint256(type(int256).max));

        _rest(type(int32).max, firstQuantity, true);
        _rest(type(int32).max - 1, secondQuantity, true);
    }

    function _overSignedDomainBaseQuantity() internal pure returns (uint256 amountIn) {
        uint160 firstQuantity = _maxQuantityWhoseBidQuoteFitsInt256(type(int32).max);
        uint160 secondQuantity = _maxQuantityWhoseBidQuoteFitsInt256(type(int32).max - 1);
        if (uint256(firstQuantity) + uint256(secondQuantity) > type(uint160).max) {
            secondQuantity = type(uint160).max - firstQuantity;
            while (_bidQuote(type(int32).max - 1, secondQuantity) > uint256(type(int256).max)) {
                --secondQuantity;
            }
        }
        amountIn = uint256(firstQuantity) + uint256(secondQuantity);
    }

    function _maxQuantityWhoseBidQuoteFitsInt256(int32 tick) internal pure returns (uint160 quantity) {
        (uint256 factor, uint16 shift) = TickMath32.getPriceFactorAtTick(tick);
        uint256 denominator = uint256(1) << shift;
        uint256 candidate = Math.mulDiv(uint256(type(int256).max), denominator, factor);
        if (candidate > type(uint160).max) candidate = type(uint160).max;
        quantity = uint160(candidate);
        while (_bidQuote(tick, quantity) > uint256(type(int256).max)) {
            --quantity;
        }
    }

    function _bidQuote(int32 tick, uint160 quantity) internal pure returns (uint256 quoteAmount) {
        if (quantity == 0) return 0;
        if (tick == 0) return quantity;
        (uint256 factor, uint16 shift) = TickMath32.getPriceFactorAtTick(tick);
        uint256 denominator = uint256(1) << shift;
        quoteAmount = Math.mulDiv(uint256(quantity), factor, denominator);
        if (mulmod(uint256(quantity), factor, denominator) != 0) ++quoteAmount;
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

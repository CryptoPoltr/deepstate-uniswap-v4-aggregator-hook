// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {DeepStatePlanner} from "../../../src/aggregator-hooks/implementations/DeepState/DeepStatePlanner.sol";
import {
    IDeepStatePlanner
} from "../../../src/aggregator-hooks/implementations/DeepState/interfaces/IDeepStatePlanner.sol";
import {
    DeepStateConstants
} from "../../../src/aggregator-hooks/implementations/DeepState/libraries/DeepStateConstants.sol";
import {MockDeepStateV1} from "./mocks/MockDeepStateV1.sol";
import {SyntheticBidTreeDeepStateV1} from "./mocks/SyntheticBidTreeDeepStateV1.sol";
import {DeepStatePlannerHarness} from "./helpers/DeepStatePlannerHarness.sol";

contract DeepStatePlannerUnitTest is Test {
    MockDeepStateV1 internal deepstate;
    DeepStatePlannerHarness internal planner;

    address internal token0 = address(0x1000);
    address internal token1 = address(0x2000);
    uint256 internal constant EPOCH = 7;
    bytes32 internal book;

    function setUp() public {
        deepstate = new MockDeepStateV1();
        planner = new DeepStatePlannerHarness(deepstate);
        deepstate.setPoolEpoch(token0, token1, EPOCH);
        book = planner.bookId(token0, token1, EPOCH);
    }

    function test_constructor() public view {
        assertEq(address(planner.deepstate()), address(deepstate));
        assertEq(planner.MAX_SCAN_NODES(), 4_096);
    }

    function test_plan_invalidPairs_revert() public {
        vm.expectRevert(DeepStatePlanner.InvalidPair.selector);
        planner.plan(address(0), token1, true, -1);
        vm.expectRevert(DeepStatePlanner.InvalidPair.selector);
        planner.plan(token0, token0, true, -1);
        vm.expectRevert(DeepStatePlanner.InvalidPair.selector);
        planner.plan(token1, token0, true, -1);
    }

    function test_pseudoTVL_invalidPair_reverts() public {
        vm.expectRevert(DeepStatePlanner.InvalidPair.selector);
        planner.pseudoTotalValueLocked(address(0), token1);
    }

    function test_plan_invalidAmounts_revert() public {
        vm.expectRevert(DeepStatePlanner.InvalidAmount.selector);
        planner.plan(token0, token1, true, 0);
        vm.expectRevert(DeepStatePlanner.InvalidAmount.selector);
        planner.plan(token0, token1, true, type(int256).min);
    }

    function test_plan_amountOutsideUint160_reverts() public {
        uint256 tooLarge = uint256(type(uint160).max) + 1;
        vm.expectRevert(DeepStatePlanner.AmountTooLarge.selector);
        planner.plan(token0, token1, true, -int256(tooLarge));
        vm.expectRevert(DeepStatePlanner.AmountTooLarge.selector);
        planner.plan(token0, token1, true, int256(tooLarge));
    }

    function test_plan_zeroToOneExactInput_singleLeaf() public {
        deepstate.setFeeConfig(address(0), 100);
        bytes32 bid = _node(0, 200_000, 0, 1);
        deepstate.setRoots(token0, token1, EPOCH, bytes32(0), bid);

        IDeepStatePlanner.Plan memory p = planner.plan(token0, token1, true, -int256(100_000));
        assertEq(p.epoch, EPOCH);
        assertEq(p.amountTake, 100_000);
        assertEq(p.deepStateInput, 100_000);
        assertEq(p.amountOut, 98_900);
        assertEq(p.baseQuantity, 100_000);
        assertEq(p.limitTick, 0);
    }

    function test_plan_zeroToOneExactOutput_singleLeaf() public {
        deepstate.setFeeConfig(address(0), 100);
        bytes32 bid = _node(0, 200_000, 0, 1);
        deepstate.setRoots(token0, token1, EPOCH, bytes32(0), bid);

        IDeepStatePlanner.Plan memory p = planner.plan(token0, token1, true, int256(98_900));
        assertEq(p.amountTake, 99_998);
        assertEq(p.deepStateInput, 99_998);
        assertEq(p.amountOut, 98_900);
        assertEq(p.baseQuantity, 99_998);
        assertEq(p.limitTick, 0);
    }

    function test_plan_oneForZeroExactInput_singleLeaf() public {
        deepstate.setFeeConfig(address(0), 100);
        bytes32 ask = _node(0, 200_000, 0, 1);
        deepstate.setRoots(token0, token1, EPOCH, ask, bytes32(0));

        IDeepStatePlanner.Plan memory p = planner.plan(token0, token1, false, -int256(100_000));
        assertEq(p.amountTake, 100_000);
        assertEq(p.deepStateInput, 100_000);
        assertEq(p.amountOut, 98_900);
        assertEq(p.baseQuantity, 100_000);
        assertEq(p.limitTick, 0);
    }

    function test_plan_oneForZeroExactInput_returnsMaxBookWhenBudgetExceedsBook() public {
        bytes32 ask = _node(0, 100_000, 0, 1);
        deepstate.setRoots(token0, token1, EPOCH, ask, bytes32(0));
        IDeepStatePlanner.Plan memory p = planner.plan(token0, token1, false, -int256(100_001));
        assertEq(p.amountTake, 100_001);
        assertEq(p.deepStateInput, 100_000);
        assertEq(p.baseQuantity, 100_000);
        assertEq(p.amountOut, 99_900); // fixed 10 bps routing fee
    }

    function test_plan_oneForZeroExactOutput_singleLeaf() public {
        deepstate.setFeeConfig(address(0), 100);
        bytes32 ask = _node(0, 200_000, 0, 1);
        deepstate.setRoots(token0, token1, EPOCH, ask, bytes32(0));

        IDeepStatePlanner.Plan memory p = planner.plan(token0, token1, false, int256(98_900));
        assertEq(p.amountTake, 99_998);
        assertEq(p.deepStateInput, 99_998);
        assertEq(p.amountOut, 98_900);
        assertEq(p.baseQuantity, 99_998);
        assertEq(p.limitTick, 0);
    }

    function test_plan_emptyRelevantBook_reverts() public {
        deepstate.setRoots(token0, token1, EPOCH, bytes32(0), bytes32(0));
        vm.expectRevert(DeepStatePlanner.InsufficientLiquidity.selector);
        planner.plan(token0, token1, true, -1);
        vm.expectRevert(DeepStatePlanner.InsufficientLiquidity.selector);
        planner.plan(token0, token1, false, -1);
    }

    function test_quoteExactBase_consumesRightFirstThenSafeAggregate() public {
        (bytes32 root, bytes32 leftAggregate,) = _twoLevelBook(true);
        (uint256 quoteAmount, int32 lastTick) = planner.quoteExactBase(book, root, 10, true);
        assertEq(quoteAmount, 10);
        assertEq(lastTick, _tick(leftAggregate));
    }

    function test_quoteExactBase_partiallyExpandsSafeAggregate() public {
        bytes32 root = _node(0, 10, 0, 100);
        bytes32 right = _node(0, 5, 0, 101);
        bytes32 leftAggregate = _node(0, 5, 1, 102);
        bytes32 leftLeft = _node(0, 3, 0, 103);
        bytes32 leftRight = _node(0, 2, 0, 104);
        deepstate.setTree(book, root, leftAggregate, right);
        deepstate.setTree(book, leftAggregate, leftLeft, leftRight);

        (uint256 quoteAmount, int32 lastTick) = planner.quoteExactBase(book, root, 7, true);
        assertEq(quoteAmount, 7);
        assertEq(lastTick, 0);
    }

    function test_quoteExactBase_insufficientLiquidity_reverts() public {
        bytes32 leaf = _node(0, 5, 0, 1);
        vm.expectRevert(DeepStatePlanner.InsufficientLiquidity.selector);
        planner.quoteExactBase(book, leaf, 6, true);
    }

    function test_quoteExactBase_invalidLeafAndBranch_revert() public {
        bytes32 badLeaf = _node(0, 1, 0, 1);
        deepstate.setTree(book, badLeaf, bytes32(0), _node(0, 1, 0, 2));
        vm.expectRevert(DeepStatePlanner.InvalidTree.selector);
        planner.quoteExactBase(book, badLeaf, 1, true);

        bytes32 zeroLeaf = _node(0, 0, 0, 3);
        vm.expectRevert(DeepStatePlanner.InvalidTree.selector);
        planner.quoteExactBase(book, zeroLeaf, 1, true);

        bytes32 badBranch = _node(0, 2, 0, 4);
        deepstate.setTree(book, badBranch, _node(0, 1, 0, 5), bytes32(0));
        vm.expectRevert(DeepStatePlanner.InvalidTree.selector);
        planner.quoteExactBase(book, badBranch, 1, true);
    }

    function test_baseForQuoteBudget_fullPartialAndZeroCostPaths() public {
        bytes32 ask = _node(0, 10, 0, 1);
        (uint160 base, uint256 spent, int32 tick) = planner.baseForQuoteBudget(book, ask, 7);
        assertEq(base, 7);
        assertEq(spent, 7);
        assertEq(tick, 0);

        // Negative-price ASK can have a zero-cost raw unit; a zero budget is rejected at the entry boundary.
        vm.expectRevert(DeepStatePlanner.InsufficientLiquidity.selector);
        planner.baseForQuoteBudget(book, ask, 0);
    }

    function test_baseForQuoteBudget_safeAggregate_fullAndPartial() public {
        (bytes32 root,,) = _twoLevelBook(false);
        (uint160 fullBase, uint256 fullSpent,) = planner.baseForQuoteBudget(book, root, 10);
        assertEq(fullBase, 10);
        assertEq(fullSpent, 10);

        (uint160 partialBase, uint256 partialSpent,) = planner.baseForQuoteBudget(book, root, 7);
        assertEq(partialBase, 7);
        assertEq(partialSpent, 7);
    }

    function test_baseForNetQuoteOutput_reachesTarget() public {
        bytes32 bid = _node(0, 20_000, 0, 1);
        (uint160 base, uint256 gross, int32 tick) = planner.baseForNetQuoteOutput(book, bid, 9_990, 0);
        assertEq(base, 9_999);
        assertEq(gross, 9_999);
        assertEq(tick, 0);
        assertEq(planner.netAfterFees(gross, 0), 9_990);
    }

    function test_baseForNetQuoteOutput_safeAggregate_fullAndPartial() public {
        bytes32 root = _node(0, 20_000, 0, 100);
        bytes32 right = _node(0, 10_000, 0, 101);
        bytes32 leftAggregate = _node(0, 10_000, 1, 102);
        bytes32 leftLeft = _node(0, 5_000, 0, 103);
        bytes32 leftRight = _node(0, 5_000, 0, 104);
        deepstate.setTree(book, root, leftAggregate, right);
        deepstate.setTree(book, leftAggregate, leftLeft, leftRight);

        (uint160 base, uint256 gross,) = planner.baseForNetQuoteOutput(book, root, 14_985, 0);
        assertEq(base, 14_999);
        assertEq(gross, 14_999);
    }

    function test_baseForQuoteBudget_returnsPriorFillWhenNextLeafCannotSpendOneRawUnit() public {
        bytes32 root = _node(0, 2, 0, 100);
        bytes32 cheapRight = _node(0, 1, 0, 101);
        bytes32 expensiveLeft = _node(type(int32).max, 1, 0, 102);
        deepstate.setTree(book, root, expensiveLeft, cheapRight);

        (uint160 base, uint256 spent, int32 lastTick) = planner.baseForQuoteBudget(book, root, 2);
        assertEq(base, 1);
        assertEq(spent, 1);
        assertEq(lastTick, 0);
    }

    function test_baseForQuoteBudget_noExecutableUnit_reverts() public {
        bytes32 expensive = _node(type(int32).max, 1, 0, 1);
        vm.expectRevert(DeepStatePlanner.InsufficientLiquidity.selector);
        planner.baseForQuoteBudget(book, expensive, 1);
    }

    function test_baseForNetQuoteOutput_feeDipContinuesToSafeGrossAcrossLeaves() public {
        (int32 tick, uint160 quantity) = _findDipLeaf();
        bytes32 root = _node(0, quantity + 10, 0, 200);
        bytes32 rightDip = _node(tick, quantity, 0, 201);
        bytes32 left = _node(0, 10, 0, 202);
        deepstate.setTree(book, root, left, rightDip);

        (uint160 base, uint256 gross,) = planner.baseForNetQuoteOutput(book, root, 9_990, 1);
        assertEq(gross, 10_001);
        assertEq(planner.netAfterFees(gross, 1), 9_990);
        assertGt(base, quantity);
    }

    function test_baseForNetQuoteOutput_feeDipRepairsWithinSameLeaf() public {
        (int32 tick, uint160 quantity) = _findDipWithinLargerLeaf();
        bytes32 leaf = _node(tick, quantity, 0, 1);

        (uint160 base, uint256 gross,) = planner.baseForNetQuoteOutput(book, leaf, 9_990, 1);
        assertGe(gross, 10_001);
        assertGe(planner.netAfterFees(gross, 1), 9_990);
        assertLe(base, quantity);
    }

    function test_baseForNetQuoteOutput_insufficientBook_reverts() public {
        bytes32 leaf = _node(0, 5, 0, 1);
        vm.expectRevert(DeepStatePlanner.InsufficientLiquidity.selector);
        planner.baseForNetQuoteOutput(book, leaf, 100, 0);
    }

    function test_pseudoTVL_emptyBooks() public view {
        (uint256 amount0, uint256 amount1) = planner.pseudoTotalValueLocked(token0, token1);
        assertEq(amount0, 0);
        assertEq(amount1, 0);
    }

    function test_pseudoTVL_collapsesSafeSubtrees() public {
        bytes32 root = _node(0, 10, 0, 100);
        bytes32 right = _node(0, 5, 0, 101);
        bytes32 leftAggregate = _node(0, 5, 1, 102);
        deepstate.setTree(book, root, leftAggregate, right);
        deepstate.setRoots(token0, token1, EPOCH, root, root);

        (uint256 amount0, uint256 amount1) = planner.pseudoTotalValueLocked(token0, token1);
        assertEq(amount0, 10);
        assertEq(amount1, 10);
    }

    function test_tvl_invalidTrees_revert() public {
        bytes32 bad = _node(0, 2, 0, 1);
        deepstate.setTree(book, bad, bytes32(0), _node(0, 1, 0, 2));
        deepstate.setRoots(token0, token1, EPOCH, bad, bytes32(0));
        vm.expectRevert(DeepStatePlanner.InvalidTree.selector);
        planner.pseudoTotalValueLocked(token0, token1);

        bytes32 badBranch = _node(0, 2, 0, 3);
        deepstate.setTree(book, badBranch, _node(0, 1, 0, 4), bytes32(0));
        deepstate.setRoots(token0, token1, EPOCH, bytes32(0), badBranch);
        vm.expectRevert(DeepStatePlanner.InvalidTree.selector);
        planner.pseudoTotalValueLocked(token0, token1);
    }

    function test_bidTVL_zeroQuantityLeaf_isZero() public {
        bytes32 zeroLeaf = _node(123, 0, 0, 1);
        assertEq(planner.bidQuoteTVL(book, zeroLeaf), 0);
    }

    function test_bidQuoteTVL_stopsAtScanLimit() public {
        SyntheticBidTreeDeepStateV1 synthetic = new SyntheticBidTreeDeepStateV1();
        DeepStatePlannerHarness scanPlanner = new DeepStatePlannerHarness(synthetic);

        uint256 amount1 = scanPlanner.bidQuoteTVL(bytes32(uint256(1)), synthetic.root());

        // A full traversal would quote all 4096 unit leaves. With right-first DFS, the first
        // 4096 tree reads visit exactly 2048 leaves before the non-strict scan bound stops traversal.
        assertEq(amount1, 2_048);
    }

    function test_maxPartialAskFill_boundariesAndInverseProperty() public view {
        assertEq(planner.maxPartialAskFill(1, 0, 10), 0);
        assertEq(planner.maxPartialAskFill(0, 100, 30), 30);

        int32 tick = 1_000_000;
        uint160 quantity = 1_000_000;
        uint256 full = planner.quoteValue(tick, quantity, false);
        assertEq(planner.maxPartialAskFill(tick, quantity, full), quantity);

        uint256 budget = full / 2;
        uint160 fill = planner.maxPartialAskFill(tick, quantity, budget);
        assertLe(planner.partialLeafQuote(tick, quantity, fill, false), budget);
        if (fill < quantity) assertGt(planner.partialLeafQuote(tick, quantity, fill + 1, false), budget);
    }

    function test_minPartialBidFill_boundariesAndInverseProperty() public view {
        assertEq(planner.minPartialBidFill(1, 0, 10), 0);
        assertEq(planner.minPartialBidFill(1, 10, 0), 0);
        assertEq(planner.minPartialBidFill(0, 100, 30), 30);

        int32 tick = -1_000_000;
        uint160 quantity = 1_000_000;
        uint256 full = planner.quoteValue(tick, quantity, true);
        uint256 need = full / 2;
        uint160 fill = planner.minPartialBidFill(tick, quantity, need);
        assertGe(planner.partialLeafQuote(tick, quantity, fill, true), need);
        if (fill > 1) assertLt(planner.partialLeafQuote(tick, quantity, fill - 1, true), need);
    }

    function test_minPartialBidFill_tickZeroInsufficient_reverts() public {
        vm.expectRevert(DeepStatePlanner.InsufficientLiquidity.selector);
        planner.minPartialBidFill(0, 10, 11);
    }

    function test_minPartialBidFill_nonZeroTickInsufficient_reverts() public {
        int32 tick = 1_000_000;
        uint160 quantity = 1000;
        uint256 full = planner.quoteValue(tick, quantity, true);
        vm.expectRevert(DeepStatePlanner.InsufficientLiquidity.selector);
        planner.minPartialBidFill(tick, quantity, full + 1);
    }

    function test_uniformBranchQuote_appliesCorrectionDirectionally() public view {
        bytes32 node = _node(0, 100, 3, 1); // correction amount = 2
        assertEq(planner.uniformBranchQuote(node, true), 102);
        assertEq(planner.uniformBranchQuote(node, false), 98);
    }

    function test_partialLeafQuote_fullAndPartial() public view {
        assertEq(planner.partialLeafQuote(0, 100, 100, false), 100);
        assertEq(planner.partialLeafQuote(0, 100, 25, false), 25);
        assertEq(planner.partialLeafQuote(0, 100, 25, true), 25);
    }

    function test_quoteValue_zeroTickZeroQuantityAndRounding() public view {
        assertEq(planner.quoteValue(123, 0, false), 0);
        assertEq(planner.quoteValue(0, 123, false), 123);
        uint256 down = planner.quoteValue(1_000_000, 123_456, false);
        uint256 up = planner.quoteValue(1_000_000, 123_456, true);
        assertGe(up, down);
        assertLe(up - down, 1);
    }

    function test_feeMath() public view {
        assertEq(planner.feeAmount(100_000, 0), 0);
        assertEq(planner.feeAmount(0, 100), 0);
        assertEq(planner.feeAmount(100_000, 100), 1_000);
        assertEq(planner.netAfterFees(100_000, 100), 98_900);
        assertEq(planner.netAfterFees(100_000, 0), 99_900);
    }

    function test_safeAndMinimalGross() public {
        vm.expectRevert(DeepStatePlanner.InvalidAmount.selector);
        planner.safeGrossForNet(0, 0);

        assertEq(planner.minimalGrossForNet(9_990, 1), 9_999); // safe target minus two
        assertEq(planner.minimalGrossForNet(910, 1), 910); // safe target minus one
        assertEq(planner.minimalGrossForNet(1, 0), 1); // safe target itself
    }

    function test_mulDivUp() public view {
        assertEq(planner.mulDivUp(10, 5, 2), 25);
        assertEq(planner.mulDivUp(10, 5, 3), 17);
    }

    function test_toUint160() public {
        assertEq(planner.toUint160(type(uint160).max), type(uint160).max);
        vm.expectRevert(DeepStatePlanner.AmountTooLarge.selector);
        planner.toUint160(uint256(type(uint160).max) + 1);
    }

    function test_nodeDecodingAndIds() public view {
        bytes32 node = _node(-123, 456, 7, 99);
        (int32 tick, uint160 quantity, uint32 correction) = planner.decodeNode(node);
        assertEq(tick, -123);
        assertEq(quantity, 456);
        assertEq(correction, 7);
        assertEq(planner.poolId(token0, token1), keccak256(abi.encode(token0, token1)));
        assertEq(planner.bookId(token0, token1, EPOCH), keccak256(abi.encode(token0, token1, EPOCH)));
    }

    function test_walkerPushPopTracksSafety() public view {
        bytes32 node = _node(0, 1, 0, 1);
        (bytes32 popped, bool safe) = planner.pushPop(node, true);
        assertEq(popped, node);
        assertTrue(safe);
        (popped, safe) = planner.pushPop(node, false);
        assertEq(popped, node);
        assertFalse(safe);
    }

    function test_treeStrictScanLimit_reverts() public {
        vm.expectRevert(DeepStatePlanner.ScanLimit.selector);
        planner.strictTreeAtLimit(book, _node(0, 1, 0, 1));
    }

    function test_expand_requiresTwoChildren() public {
        bytes32 node = _node(0, 2, 1, 1);
        deepstate.setTree(book, node, _node(0, 1, 0, 2), bytes32(0));
        vm.expectRevert(DeepStatePlanner.InvalidTree.selector);
        planner.expand(book, node, true);

        deepstate.setTree(book, node, _node(0, 1, 0, 2), _node(0, 1, 0, 3));
        assertEq(planner.expand(book, node, true), 2);
    }

    function test_pushChildrenStackOverflow_reverts() public {
        vm.expectRevert(DeepStatePlanner.InvalidTree.selector);
        planner.pushChildrenOverflow();
    }

    function test_quoteExactBase_safeAggregateFullButStillInsufficient_continues() public {
        bytes32 root = _node(0, 2, 0, 100);
        bytes32 right = _node(0, 1, 0, 101);
        bytes32 leftAggregate = _node(0, 1, 1, 102);
        deepstate.setTree(book, root, leftAggregate, right);

        vm.expectRevert(DeepStatePlanner.InsufficientLiquidity.selector);
        planner.quoteExactBase(book, root, 3, true);
    }

    function test_baseForQuoteBudget_invalidLeafAndBranch_revert() public {
        bytes32 badLeaf = _node(0, 1, 0, 300);
        deepstate.setTree(book, badLeaf, bytes32(0), _node(0, 1, 0, 301));
        vm.expectRevert(DeepStatePlanner.InvalidTree.selector);
        planner.baseForQuoteBudget(book, badLeaf, 1);

        bytes32 zeroLeaf = _node(0, 0, 0, 302);
        vm.expectRevert(DeepStatePlanner.InvalidTree.selector);
        planner.baseForQuoteBudget(book, zeroLeaf, 1);

        bytes32 badBranch = _node(0, 2, 0, 303);
        deepstate.setTree(book, badBranch, _node(0, 1, 0, 304), bytes32(0));
        vm.expectRevert(DeepStatePlanner.InvalidTree.selector);
        planner.baseForQuoteBudget(book, badBranch, 1);
    }

    function test_baseForQuoteBudget_safeAggregateOverflow_reverts() public {
        bytes32 root = _node(0, 1, 0, 310);
        bytes32 right = _node(0, 1, 0, 311);
        bytes32 leftAggregate = _node(0, type(uint160).max, 1, 312);
        deepstate.setTree(book, root, leftAggregate, right);

        vm.expectRevert(DeepStatePlanner.AmountTooLarge.selector);
        planner.baseForQuoteBudget(book, root, uint256(type(uint160).max) + 2);
    }

    function test_baseForQuoteBudget_fullLeafOverflow_reverts() public {
        bytes32 root = _node(0, 1, 0, 320);
        bytes32 right = _node(0, type(uint160).max, 0, 321);
        bytes32 left = _node(0, 1, 0, 322);
        deepstate.setTree(book, root, left, right);

        vm.expectRevert(DeepStatePlanner.AmountTooLarge.selector);
        planner.baseForQuoteBudget(book, root, uint256(type(uint160).max) + 1);
    }

    function test_baseForQuoteBudget_partialLeafOverflow_reverts() public {
        bytes32 root = _node(0, 1, 0, 330);
        bytes32 right = _node(0, type(uint160).max, 0, 331);
        bytes32 left = _node(0, 2, 0, 332);
        deepstate.setTree(book, root, left, right);

        vm.expectRevert(DeepStatePlanner.AmountTooLarge.selector);
        planner.baseForQuoteBudget(book, root, uint256(type(uint160).max) + 1);
    }

    function test_baseForNetQuoteOutput_zeroRootOrTarget_reverts() public {
        vm.expectRevert(DeepStatePlanner.InsufficientLiquidity.selector);
        planner.baseForNetQuoteOutput(book, bytes32(0), 1, 0);

        vm.expectRevert(DeepStatePlanner.InsufficientLiquidity.selector);
        planner.baseForNetQuoteOutput(book, _node(0, 1, 0, 340), 0, 0);
    }

    function test_baseForNetQuoteOutput_consumesWholeSafeAggregateThenContinues() public {
        bytes32 root = _node(0, 10, 0, 350);
        bytes32 right = _node(0, 5, 0, 351);
        bytes32 leftAggregate = _node(0, 5, 1, 352);
        deepstate.setTree(book, root, leftAggregate, right);

        vm.expectRevert(DeepStatePlanner.InsufficientLiquidity.selector);
        planner.baseForNetQuoteOutput(book, root, 20, 0);
    }

    function test_baseForNetQuoteOutput_safeAggregateOverflow_reverts() public {
        bytes32 root = _node(0, 1, 0, 360);
        bytes32 right = _node(0, 1, 0, 361);
        bytes32 leftAggregate = _node(0, type(uint160).max, 1, 362);
        deepstate.setTree(book, root, leftAggregate, right);

        vm.expectRevert(DeepStatePlanner.AmountTooLarge.selector);
        planner.baseForNetQuoteOutput(book, root, uint256(type(uint160).max) + 1_000_000, 0);
    }

    function test_baseForNetQuoteOutput_invalidLeafAndBranch_revert() public {
        bytes32 badLeaf = _node(0, 1, 0, 370);
        deepstate.setTree(book, badLeaf, bytes32(0), _node(0, 1, 0, 371));
        vm.expectRevert(DeepStatePlanner.InvalidTree.selector);
        planner.baseForNetQuoteOutput(book, badLeaf, 1, 0);

        bytes32 badBranch = _node(0, 2, 0, 372);
        deepstate.setTree(book, badBranch, _node(0, 1, 0, 373), bytes32(0));
        vm.expectRevert(DeepStatePlanner.InvalidTree.selector);
        planner.baseForNetQuoteOutput(book, badBranch, 1, 0);
    }

    function test_consumeNetQuoteLeaf_zeroQuantity_reverts() public {
        vm.expectRevert(DeepStatePlanner.InvalidTree.selector);
        planner.consumeNetQuoteLeaf(_netQuoteInput(10, 10, 0, 0, 0), _node(0, 0, 0, 380), 1, 0);
    }

    function test_consumeNetQuoteLeaf_fullLeafBaseOverflow_reverts() public {
        vm.expectRevert(DeepStatePlanner.AmountTooLarge.selector);
        planner.consumeNetQuoteLeaf(
            _netQuoteInput(1_000, 1_000, uint256(type(uint160).max), 0, 0), _node(0, 1, 0, 381), 1, 0
        );
    }

    function test_consumeNetQuoteLeaf_candidateBaseOverflow_reverts() public {
        vm.expectRevert(DeepStatePlanner.AmountTooLarge.selector);
        planner.consumeNetQuoteLeaf(_netQuoteInput(1, 1, uint256(type(uint160).max), 0, 0), _node(0, 1, 0, 382), 1, 0);
    }

    function test_consumeNetQuoteLeaf_feeDipWholeLeafOverflow_reverts() public {
        vm.expectRevert(DeepStatePlanner.AmountTooLarge.selector);
        planner.consumeNetQuoteLeaf(
            _netQuoteInput(1_000, 1, uint256(type(uint160).max) - 1, 0, 0), _node(0, 2, 0, 383), 2, 0
        );
    }

    function test_consumeNetQuoteLeaf_safeTargetBaseOverflow_reverts() public {
        vm.expectRevert(DeepStatePlanner.AmountTooLarge.selector);
        planner.consumeNetQuoteLeaf(
            _netQuoteInput(2, 1, uint256(type(uint160).max) - 1, 0, 0), _node(0, 2, 0, 384), 2, 0
        );
    }

    function test_consumeNetQuoteLeaf_inconsistentSafeTargetUnderDelivers_reverts() public {
        vm.expectRevert(DeepStatePlanner.InsufficientLiquidity.selector);
        planner.consumeNetQuoteLeaf(_netQuoteInput(2, 1, 0, 0, 0), _node(0, 2, 0, 385), 3, 0);
    }

    function test_tvl_additionalMalformedBranches_revert() public {
        bytes32 badAskBranch = _node(0, 2, 0, 390);
        deepstate.setTree(book, badAskBranch, _node(0, 1, 0, 391), bytes32(0));
        vm.expectRevert(DeepStatePlanner.InvalidTree.selector);
        planner.askBaseTVL(book, badAskBranch);

        bytes32 badBidLeaf = _node(0, 1, 0, 392);
        deepstate.setTree(book, badBidLeaf, bytes32(0), _node(0, 1, 0, 393));
        vm.expectRevert(DeepStatePlanner.InvalidTree.selector);
        planner.bidQuoteTVL(book, badBidLeaf);
    }

    function _netQuoteInput(
        uint256 safeGrossTarget,
        uint256 grossTarget,
        uint256 baseTotal,
        uint256 grossQuote,
        int32 lastTick
    ) internal pure returns (DeepStatePlannerHarness.NetQuoteInput memory input) {
        input.safeGrossTarget = safeGrossTarget;
        input.grossTarget = grossTarget;
        input.baseTotal = baseTotal;
        input.grossQuote = grossQuote;
        input.lastTick = lastTick;
    }

    function _findDipLeaf() internal view returns (int32 foundTick, uint160 foundQuantity) {
        // protocol=1 bp + routing=10 bps has net(9_999)=9_990 but net(10_000)=9_989.
        // Find a real TickMath32 price whose BID rounding skips raw gross 9_999 and lands on 10_000.
        for (uint256 i = 1; i <= 200; ++i) {
            int32 tick = int32(int256(i * 100_000));
            uint160 lo = 1;
            uint160 hi = 20_000;
            while (lo < hi) {
                uint160 mid = uint160((uint256(lo) + uint256(hi)) >> 1);
                if (planner.quoteValue(tick, mid, true) < 10_000) lo = mid + 1;
                else hi = mid;
            }
            if (planner.quoteValue(tick, lo, true) != 10_000) continue;
            uint160 fill = planner.minPartialBidFill(tick, lo, 9_999);
            if (planner.partialLeafQuote(tick, lo, fill, true) == 10_000) return (tick, lo);
        }
        revert("no fee-dip leaf found");
    }

    function _findDipWithinLargerLeaf() internal view returns (int32 foundTick, uint160 foundQuantity) {
        (int32 tick, uint160 baseQuantity) = _findDipLeaf();
        for (uint256 q = uint256(baseQuantity) + 1; q <= uint256(baseQuantity) + 500; ++q) {
            uint160 quantity = uint160(q);
            uint256 full = planner.quoteValue(tick, quantity, true);
            if (full <= 10_000) continue;
            uint160 fill = planner.minPartialBidFill(tick, quantity, 9_999);
            if (planner.partialLeafQuote(tick, quantity, fill, true) == 10_000) return (tick, quantity);
        }
        revert("no larger fee-dip leaf found");
    }

    function _twoLevelBook(bool bid) internal returns (bytes32 root, bytes32 leftAggregate, bytes32 right) {
        root = _node(0, 10, 0, 100);
        right = _node(0, 5, 0, 101);
        leftAggregate = _node(0, 5, 1, 102);
        bytes32 leftLeft = _node(0, 3, 0, 103);
        bytes32 leftRight = _node(0, 2, 0, 104);
        deepstate.setTree(book, root, leftAggregate, right);
        deepstate.setTree(book, leftAggregate, leftLeft, leftRight);
        if (bid) deepstate.setRoots(token0, token1, EPOCH, bytes32(0), root);
        else deepstate.setRoots(token0, token1, EPOCH, root, bytes32(0));
    }

    function _node(int32 tick, uint160 quantity, uint32 correctionCode, uint32 nonce) internal pure returns (bytes32) {
        return bytes32(
            (uint256(uint32(tick)) << 224) | (uint256(quantity) << 64) | (uint256(correctionCode) << 32)
                | uint256(nonce)
        );
    }

    function _tick(bytes32 node) internal pure returns (int32) {
        return int32(uint32(uint256(node) >> 224));
    }
}

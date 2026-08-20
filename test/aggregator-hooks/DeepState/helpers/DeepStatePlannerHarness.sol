// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DeepStatePlanner} from "../../../../src/aggregator-hooks/implementations/DeepState/DeepStatePlanner.sol";
import {IDeepStateV1} from "../../../../src/aggregator-hooks/implementations/DeepState/interfaces/IDeepStateV1.sol";

contract DeepStatePlannerHarness is DeepStatePlanner {
    constructor(IDeepStateV1 deepstate_) DeepStatePlanner(deepstate_) {}

    function quoteExactBase(bytes32 book, bytes32 root, uint160 baseNeeded, bool restingIsBid)
        external
        view
        returns (uint256, int32)
    {
        return _quoteExactBase(book, root, baseNeeded, restingIsBid);
    }

    function baseForQuoteBudget(bytes32 book, bytes32 root, uint256 budget)
        external
        view
        returns (uint160, uint256, int32)
    {
        return _baseForQuoteBudget(book, root, budget);
    }

    function baseForNetQuoteOutput(bytes32 book, bytes32 root, uint256 target, uint16 feeBps)
        external
        view
        returns (uint160, uint256, int32)
    {
        return _baseForNetQuoteOutput(book, root, target, feeBps);
    }

    function askBaseTVL(bytes32 book, bytes32 root) external view returns (uint256) {
        return _askBaseTVL(book, root);
    }

    function bidQuoteTVL(bytes32 book, bytes32 root) external view returns (uint256) {
        return _bidQuoteTVL(book, root);
    }

    function maxPartialAskFill(int32 tick, uint160 quantity, uint256 budget) external pure returns (uint160) {
        return _maxPartialAskFill(tick, quantity, budget);
    }

    function minPartialBidFill(int32 tick, uint160 quantity, uint256 grossNeed) external pure returns (uint160) {
        return _minPartialBidFill(tick, quantity, grossNeed);
    }

    function uniformBranchQuote(bytes32 node, bool isBid) external pure returns (uint256) {
        return _uniformBranchQuote(node, isBid);
    }

    function partialLeafQuote(int32 tick, uint160 quantity, uint160 fill, bool roundUp)
        external
        pure
        returns (uint256)
    {
        return _partialLeafQuote(tick, quantity, fill, roundUp);
    }

    function quoteValue(int32 tick, uint160 quantity, bool roundUp) external pure returns (uint256) {
        return _quoteValue(tick, quantity, roundUp);
    }

    function safeGrossForNet(uint256 target, uint16 feeBps) external pure returns (uint256) {
        return _safeGrossForNet(target, feeBps);
    }

    function minimalGrossForNet(uint256 target, uint16 feeBps) external pure returns (uint256) {
        return _minimalGrossForNet(target, feeBps);
    }

    function feeAmount(uint256 gross, uint16 feeBps) external pure returns (uint256) {
        return _feeAmount(gross, feeBps);
    }

    function netAfterFees(uint256 gross, uint16 feeBps) external pure returns (uint256) {
        return _netAfterFees(gross, feeBps);
    }

    function mulDivUp(uint256 x, uint256 y, uint256 denominator) external pure returns (uint256) {
        return _mulDivUp(x, y, denominator);
    }

    function toUint160(uint256 value) external pure returns (uint160) {
        return _toUint160(value);
    }

    function decodeNode(bytes32 node) external pure returns (int32 tick, uint160 quantity, uint32 correction) {
        return (_price(node), _quantity(node), _correctionCode(node));
    }

    function poolId(address token0, address token1) external pure returns (bytes32) {
        return _poolId(token0, token1);
    }

    function bookId(address token0, address token1, uint256 epoch) external pure returns (bytes32) {
        return _bookId(token0, token1, epoch);
    }

    function strictTreeAtLimit(bytes32 book, bytes32 node) external view returns (bytes32, bytes32) {
        Walker memory walker;
        walker.book = book;
        walker.scanned = MAX_SCAN_NODES;
        return _tree(walker, node, true);
    }

    function expand(bytes32 book, bytes32 node, bool safe) external view returns (uint256 sp) {
        Walker memory walker;
        walker.book = book;
        _expand(walker, node, safe);
        return walker.sp;
    }

    function pushChildrenOverflow() external pure {
        Walker memory walker;
        walker.sp = 64;
        _pushChildren(walker, bytes32(uint256(1)), bytes32(uint256(2)), false);
    }

    function pushPop(bytes32 node, bool safe) external pure returns (bytes32 popped, bool poppedSafe) {
        Walker memory walker;
        _push(walker, node, safe);
        return _pop(walker);
    }

    struct NetQuoteInput {
        uint256 safeGrossTarget;
        uint256 grossTarget;
        uint256 baseTotal;
        uint256 grossQuote;
        int32 lastTick;
    }

    struct NetQuoteResult {
        uint256 safeGrossTarget;
        uint256 grossTarget;
        uint256 baseTotal;
        uint256 grossQuote;
        int32 lastTick;
        bool done;
    }

    function consumeNetQuoteLeaf(NetQuoteInput calldata input, bytes32 node, uint256 targetNetQuote, uint16 feeBps)
        external
        pure
        returns (NetQuoteResult memory result)
    {
        NetQuoteState memory state;
        state.safeGrossTarget = input.safeGrossTarget;
        state.grossTarget = input.grossTarget;
        state.baseTotal = input.baseTotal;
        state.grossQuote = input.grossQuote;
        state.lastTick = input.lastTick;

        result.done = _consumeNetQuoteLeaf(state, node, targetNetQuote, feeBps);
        result.safeGrossTarget = state.safeGrossTarget;
        result.grossTarget = state.grossTarget;
        result.baseTotal = state.baseTotal;
        result.grossQuote = state.grossQuote;
        result.lastTick = state.lastTick;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TickMath32} from "deepstate-contracts/src/libraries/TickMath32.sol";

import {IDeepStateV1} from "./interfaces/IDeepStateV1.sol";
import {IDeepStatePlanner} from "./interfaces/IDeepStatePlanner.sol";
import {DeepStateConstants} from "./libraries/DeepStateConstants.sol";

/// @title DeepStatePlanner
/// @notice Immutable read-only execution planner for DeepState V1 order-book liquidity.
/// @dev Reproduces the read-only matching and rounding semantics needed to build an executable FOK plan.
///      Pool and book IDs are derived locally from DeepState's canonical keccak identifiers. Exact-input
///      and exact-output inversion use closed-form rounding math. Uniform off-right-spine branches consume
///      DeepState's packed aggregate quantity and correction code in O(1); the potentially dirty global
///      right spine is traversed through live child pointers with a fixed execution scan cap.
contract DeepStatePlanner is IDeepStatePlanner {
    /// @dev Maximum DFS frontier for DeepState's 64-bit radix key.
    uint256 private constant MAX_STACK = 65;
    /// @notice Fixed traversal cap. Keeping it in bytecode removes deploy-time gas-grief misconfiguration.
    uint32 public constant MAX_SCAN_NODES = 4_096;

    IDeepStateV1 public immutable override deepstate;

    /// @dev A node is aggregateSafe iff it is known to be outside the global dirty right spine.
    ///      safeMask stores one bit per stack slot to avoid a second fixed bool array.
    struct Walker {
        bytes32[MAX_STACK] stack;
        uint256 safeMask;
        uint256 sp;
        uint256 scanned;
        bytes32 book;
    }

    struct NetQuoteState {
        uint256 safeGrossTarget;
        uint256 grossTarget;
        uint256 baseTotal;
        uint256 grossQuote;
        int32 lastTick;
    }

    error InvalidPair();
    error InvalidAmount();
    error AmountTooLarge();
    error InsufficientLiquidity();
    error ScanLimit();
    error InvalidTree();

    constructor(IDeepStateV1 deepstate_) {
        deepstate = deepstate_;
    }

    function plan(address token0, address token1, bool zeroToOne, int256 amountSpecified)
        external
        view
        override
        returns (Plan memory result)
    {
        if (token0 == address(0) || token0 >= token1) revert InvalidPair();
        if (amountSpecified == 0 || amountSpecified == type(int256).min) revert InvalidAmount();

        uint256 specified = amountSpecified < 0 ? uint256(-amountSpecified) : uint256(amountSpecified);
        if (specified > type(uint160).max) revert AmountTooLarge();

        uint256 epoch = deepstate.poolEpoch(_poolId(token0, token1));
        (bytes32 askRoot, bytes32 bidRoot) = deepstate.roots(token0, token1, epoch);
        (, uint16 feeBps) = deepstate.feeConfig();

        result.epoch = epoch;
        bool exactInput = amountSpecified < 0;
        bytes32 book = _bookId(token0, token1, epoch);

        if (zeroToOne) {
            // token0 -> token1: incoming DeepState ASK consumes resting BIDs.
            if (exactInput) {
                (uint256 grossQuote, int32 bidExactInputLastTick) =
                    _quoteExactBase(book, bidRoot, uint160(specified), true);

                // Canonical DeepState credits aggregate quote settlement through a signed int256 delta.
                // Multiple individually valid resting BIDs can therefore still be unexecutable in aggregate.
                if (grossQuote > uint256(type(int256).max)) revert AmountTooLarge();

                result.amountTake = specified;
                result.deepStateInput = specified;
                result.amountOut = _netAfterFees(grossQuote, feeBps);
                result.baseQuantity = uint160(specified);
                result.limitTick = bidExactInputLastTick;
                return result;
            }

            // Exact token1 output. DeepState takes protocol + routing fees from taker output, therefore we find the
            // minimum token0 quantity whose gross bid quote reaches the exact gross-up target.
            (uint160 baseIn, uint256 grossQuoteOut, int32 bidExactOutputLastTick) =
                _baseForNetQuoteOutput(book, bidRoot, specified, feeBps);

            // Keep the signed settlement invariant local to every returned zero-to-one plan. Under the
            // current uint160 specified-amount bound this is defensive for exact-output, and protects any
            // future widening of that public input domain.
            if (grossQuoteOut > uint256(type(int256).max)) revert AmountTooLarge();

            result.amountTake = baseIn;
            result.deepStateInput = baseIn;
            result.amountOut = _netAfterFees(grossQuoteOut, feeBps);
            result.baseQuantity = baseIn;
            result.limitTick = bidExactOutputLastTick;
            return result;
        }

        // token1 -> token0: incoming DeepState BID consumes resting ASKs.
        if (exactInput) {
            // The input domain is quote/token1 but DeepState's order quantity is token0/base.
            // Choose the maximum base quantity whose exact FIFO quote cost is <= specified input.
            (uint160 baseOutGross, uint256 quoteSpent, int32 askExactInputLastTick) =
                _baseForQuoteBudget(book, askRoot, specified);

            result.amountTake = specified;
            result.deepStateInput = quoteSpent;
            result.amountOut = _netAfterFees(baseOutGross, feeBps);
            result.baseQuantity = baseOutGross;
            result.limitTick = askExactInputLastTick;
            return result;
        }

        // Exact token0 output. Gross-up for DeepState's protocol + routing output fees, then price that exact base amount.
        uint160 grossBaseOut = _toUint160(_minimalGrossForNet(specified, feeBps));
        (uint256 quoteIn, int32 askExactOutputLastTick) = _quoteExactBase(book, askRoot, grossBaseOut, false);

        result.amountTake = quoteIn;
        result.deepStateInput = quoteIn;
        result.amountOut = _netAfterFees(grossBaseOut, feeBps);
        result.baseQuantity = grossBaseOut;
        result.limitTick = askExactOutputLastTick;
    }

    /// @notice External-liquidity proxy for Uniswap routing.
    /// @dev
    ///  amount0 (resting asks) is exact in O(radix depth): every off-right-spine subtree has an exact
    ///  packed aggregate base quantity. amount1 (resting bids) also collapses same-tick uniform
    ///  branches using DeepState's correction code; if MAX_SCAN_NODES is reached across many distinct
    ///  ticks, the returned amount1 is a conservative lower bound rather than reverting.
    function pseudoTotalValueLocked(address token0, address token1)
        external
        view
        override
        returns (uint256 amount0, uint256 amount1)
    {
        if (token0 == address(0) || token0 >= token1) revert InvalidPair();

        uint256 epoch = deepstate.poolEpoch(_poolId(token0, token1));
        (bytes32 askRoot, bytes32 bidRoot) = deepstate.roots(token0, token1, epoch);
        bytes32 book = _bookId(token0, token1, epoch);

        amount0 = _askBaseTVL(book, askRoot);
        amount1 = _bidQuoteTVL(book, bidRoot);
    }

    function _quoteExactBase(bytes32 book, bytes32 root, uint160 baseNeeded, bool restingIsBid)
        internal
        view
        returns (uint256 quoteAmount, int32 lastTick)
    {
        if (root == bytes32(0) || baseNeeded == 0) revert InsufficientLiquidity();
        Walker memory walker = _walker(book, root);
        uint160 remaining = baseNeeded;

        while (walker.sp != 0) {
            (bytes32 node, bool safe) = _pop(walker);
            uint32 correction = _correctionCode(node);

            if (safe && correction != 0) {
                uint160 quantity = _quantity(node);
                if (quantity <= remaining) {
                    quoteAmount += _uniformBranchQuote(node, restingIsBid);
                    remaining -= quantity;
                    lastTick = _price(node);
                    if (remaining == 0) return (quoteAmount, lastTick);
                    continue;
                }
                // The aggregate correction is exact only for the whole subtree. For a partial FIFO
                // fill, descend; descendants remain aggregate-safe.
                _expand(walker, node, true);
                continue;
            }

            (bytes32 left, bytes32 right) = _tree(walker, node, true);
            if (left == bytes32(0)) {
                if (right != bytes32(0)) revert InvalidTree();
                uint160 quantity = _quantity(node);
                if (quantity == 0) revert InvalidTree();
                uint160 fill = remaining < quantity ? remaining : quantity;
                quoteAmount += _partialLeafQuote(_price(node), quantity, fill, restingIsBid);
                remaining -= fill;
                lastTick = _price(node);
                if (remaining == 0) return (quoteAmount, lastTick);
                continue;
            }

            if (right == bytes32(0)) revert InvalidTree();
            _pushChildren(walker, left, right, safe);
        }

        revert InsufficientLiquidity();
    }

    function _baseForQuoteBudget(bytes32 book, bytes32 root, uint256 budget)
        internal
        view
        returns (uint160 baseQuantity, uint256 quoteSpent, int32 lastTick)
    {
        if (root == bytes32(0) || budget == 0) revert InsufficientLiquidity();
        Walker memory walker = _walker(book, root);
        uint256 baseTotal;
        uint256 remainingBudget = budget;

        while (walker.sp != 0) {
            (bytes32 node, bool safe) = _pop(walker);
            uint32 correction = _correctionCode(node);

            if (safe && correction != 0) {
                uint256 fullCost = _uniformBranchQuote(node, false);
                if (fullCost <= remainingBudget) {
                    uint160 quantity = _quantity(node);
                    baseTotal += quantity;
                    if (baseTotal > type(uint160).max) revert AmountTooLarge();
                    quoteSpent += fullCost;
                    remainingBudget -= fullCost;
                    lastTick = _price(node);
                    // Keep walking even at zero remaining budget: later FIFO asks can still have
                    // zero raw quote cost because ASK notionals round down in DeepState.
                    continue;
                }
                _expand(walker, node, true);
                continue;
            }

            (bytes32 left, bytes32 right) = _tree(walker, node, true);
            if (left == bytes32(0)) {
                if (right != bytes32(0)) revert InvalidTree();
                uint160 quantity = _quantity(node);
                if (quantity == 0) revert InvalidTree();
                int32 tick = _price(node);
                uint256 fullCost = _quoteValue(tick, quantity, false);

                if (fullCost <= remainingBudget) {
                    baseTotal += quantity;
                    if (baseTotal > type(uint160).max) revert AmountTooLarge();
                    quoteSpent += fullCost;
                    remainingBudget -= fullCost;
                    lastTick = tick;
                    // Zero-cost leaves after an exactly exhausted budget are still executable.
                    continue;
                }

                uint160 partialFill = _maxPartialAskFill(tick, quantity, remainingBudget);
                if (partialFill == 0) {
                    if (baseTotal == 0) revert InsufficientLiquidity();
                    return (uint160(baseTotal), quoteSpent, lastTick);
                }

                uint256 partialCost = _partialLeafQuote(tick, quantity, partialFill, false);
                baseTotal += partialFill;
                if (baseTotal > type(uint160).max) revert AmountTooLarge();
                quoteSpent += partialCost;
                lastTick = tick;
                return (uint160(baseTotal), quoteSpent, lastTick);
            }

            if (right == bytes32(0)) revert InvalidTree();
            _pushChildren(walker, left, right, safe);
        }

        // The quote-input domain is not the DeepState quantity domain. If the entire ASK book is
        // exhausted first, return the maximal executable base quantity and let the hook's dust
        // tolerance decide whether the unspent quote remainder is acceptable.
        return (uint160(baseTotal), quoteSpent, lastTick);
    }

    function _baseForNetQuoteOutput(bytes32 book, bytes32 root, uint256 targetNetQuote, uint16 feeBps)
        internal
        view
        returns (uint160 baseQuantity, uint256 grossQuote, int32 lastTick)
    {
        if (root == bytes32(0) || targetNetQuote == 0) revert InsufficientLiquidity();
        Walker memory walker = _walker(book, root);
        NetQuoteState memory state;
        state.safeGrossTarget = _safeGrossForNet(targetNetQuote, feeBps);
        state.grossTarget = _minimalGrossForNet(targetNetQuote, feeBps);

        while (walker.sp != 0) {
            (bytes32 node, bool safe) = _pop(walker);
            uint32 correction = _correctionCode(node);

            if (safe && correction != 0) {
                uint256 fullQuote = _uniformBranchQuote(node, true);
                if (state.grossQuote + fullQuote < state.grossTarget) {
                    uint160 quantity = _quantity(node);
                    state.grossQuote += fullQuote;
                    state.baseTotal += quantity;
                    if (state.baseTotal > type(uint160).max) revert AmountTooLarge();
                    state.lastTick = _price(node);
                    continue;
                }
                _expand(walker, node, true);
                continue;
            }

            (bytes32 left, bytes32 right) = _tree(walker, node, true);
            if (left == bytes32(0)) {
                if (right != bytes32(0)) revert InvalidTree();
                if (_consumeNetQuoteLeaf(state, node, targetNetQuote, feeBps)) {
                    return (uint160(state.baseTotal), state.grossQuote, state.lastTick);
                }
                continue;
            }

            if (right == bytes32(0)) revert InvalidTree();
            _pushChildren(walker, left, right, safe);
        }

        revert InsufficientLiquidity();
    }

    function _consumeNetQuoteLeaf(NetQuoteState memory state, bytes32 node, uint256 targetNetQuote, uint16 feeBps)
        internal
        pure
        returns (bool done)
    {
        uint160 quantity = _quantity(node);
        if (quantity == 0) revert InvalidTree();

        int32 tick = _price(node);
        uint256 fullQuote = _quoteValue(tick, quantity, true);
        uint256 fullGross = state.grossQuote + fullQuote;

        if (fullGross < state.grossTarget) {
            state.grossQuote = fullGross;
            state.baseTotal += quantity;
            if (state.baseTotal > type(uint160).max) revert AmountTooLarge();
            state.lastTick = tick;
            return false;
        }

        uint160 partialFill = _minPartialBidFill(tick, quantity, state.grossTarget - state.grossQuote);
        uint256 candidateGross = state.grossQuote + _partialLeafQuote(tick, quantity, partialFill, true);
        uint256 candidateBase = state.baseTotal + partialFill;
        if (candidateBase == 0 || candidateBase > type(uint160).max) revert AmountTooLarge();

        // Independent fee floors can make net(gross) dip by one raw unit. The globally minimal
        // gross target can therefore be executable while the next raw gross value under-delivers.
        // If the first reachable quote lands on that dip, continue to the monotone-safe combined
        // threshold instead of returning an under-delivering exact-output plan.
        if (_netAfterFees(candidateGross, feeBps) >= targetNetQuote) {
            state.grossQuote = candidateGross;
            state.baseTotal = candidateBase;
            state.lastTick = tick;
            return true;
        }

        if (fullGross < state.safeGrossTarget) {
            state.grossQuote = fullGross;
            state.baseTotal += quantity;
            if (state.baseTotal > type(uint160).max) revert AmountTooLarge();
            state.lastTick = tick;
            // The minimal exact target has already been crossed, but the first reachable
            // gross landed on an independent-floor fee dip. From this point onward only
            // the monotone-safe target is meaningful.
            state.grossTarget = state.safeGrossTarget;
            return false;
        }

        partialFill = _minPartialBidFill(tick, quantity, state.safeGrossTarget - state.grossQuote);
        state.grossQuote += _partialLeafQuote(tick, quantity, partialFill, true);
        state.baseTotal += partialFill;
        if (state.baseTotal == 0 || state.baseTotal > type(uint160).max) revert AmountTooLarge();
        if (_netAfterFees(state.grossQuote, feeBps) < targetNetQuote) revert InsufficientLiquidity();
        state.lastTick = tick;
        return true;
    }

    /// @dev Maximum base fill from one resting ASK leaf with exact DeepState partial-fill rounding.
    function _maxPartialAskFill(int32 tick, uint160 quantity, uint256 budget) internal pure returns (uint160 fill) {
        if (quantity == 0) return 0;
        if (tick == 0) return uint160(budget < quantity ? budget : quantity);

        (uint256 factor, uint16 shift) = TickMath32.getPriceFactorAtTick(tick);
        uint256 denominator = uint256(1) << shift;
        uint256 fullQuote = Math.mulDiv(uint256(quantity), factor, denominator); // ASK rounds down
        if (fullQuote <= budget) return quantity;

        // partial(f) = floor(Q*p/d) - floor((Q-f)*p/d) <= budget
        // => floor((Q-f)*p/d) >= fullQuote-budget
        // => remainder >= ceil((fullQuote-budget)*d/p)
        uint256 minRemainderQuote = fullQuote - budget;
        uint256 remainder = _mulDivUp(minRemainderQuote, denominator, factor);
        fill = uint160(uint256(quantity) - remainder);
    }

    /// @dev Minimum base fill from one resting BID leaf whose gross token1 quote reaches grossNeed.
    function _minPartialBidFill(int32 tick, uint160 quantity, uint256 grossNeed) internal pure returns (uint160 fill) {
        if (quantity == 0 || grossNeed == 0) return 0;
        if (tick == 0) {
            if (grossNeed > quantity) revert InsufficientLiquidity();
            return uint160(grossNeed);
        }

        (uint256 factor, uint16 shift) = TickMath32.getPriceFactorAtTick(tick);
        uint256 denominator = uint256(1) << shift;
        uint256 fullQuote = _mulDivUp(uint256(quantity), factor, denominator); // BID rounds up
        if (grossNeed > fullQuote) revert InsufficientLiquidity();

        // partial(f) = ceil(Q*p/d) - ceil((Q-f)*p/d) >= grossNeed
        // Let C = fullQuote-grossNeed. ceil(r*p/d) <= C iff r*p/d <= C.
        // Max remainder is floor(C*d/p), therefore min fill is Q-remainder.
        uint256 maxRemainderQuote = fullQuote - grossNeed;
        uint256 remainder = Math.mulDiv(maxRemainderQuote, denominator, factor);
        fill = uint160(uint256(quantity) - remainder);
    }

    function _askBaseTVL(bytes32 book, bytes32 root) internal view returns (uint256 amount0) {
        if (root == bytes32(0)) return 0;
        Walker memory walker = _walker(book, root);

        while (walker.sp != 0) {
            (bytes32 node, bool safe) = _pop(walker);

            // Every off-right-spine node has exact aggregate quantity even when it spans many ticks.
            if (safe) {
                amount0 += _quantity(node);
                continue;
            }

            (bytes32 left, bytes32 right) = _tree(walker, node, false);
            if (left == bytes32(0)) {
                if (right != bytes32(0)) revert InvalidTree();
                amount0 += _quantity(node);
                continue;
            }
            if (right == bytes32(0)) revert InvalidTree();
            _pushChildren(walker, left, right, false);
        }
    }

    function _bidQuoteTVL(bytes32 book, bytes32 root) internal view returns (uint256 amount1) {
        if (root == bytes32(0)) return 0;
        Walker memory walker = _walker(book, root);

        while (walker.sp != 0) {
            (bytes32 node, bool safe) = _pop(walker);
            uint32 correction = _correctionCode(node);

            if (safe && correction != 0) {
                amount1 += _uniformBranchQuote(node, true);
                continue;
            }

            if (walker.scanned >= MAX_SCAN_NODES) break;
            (bytes32 left, bytes32 right) = _tree(walker, node, false);
            if (left == bytes32(0)) {
                if (right != bytes32(0)) revert InvalidTree();
                amount1 += _quoteValue(_price(node), _quantity(node), true);
                continue;
            }
            if (right == bytes32(0)) revert InvalidTree();
            _pushChildren(walker, left, right, safe);
        }
    }

    function _walker(bytes32 book, bytes32 root) internal pure returns (Walker memory walker) {
        walker.book = book;
        walker.stack[0] = root;
        walker.sp = 1;
        // Root is deliberately unsafe: only the global right spine may contain stale aggregate words.
    }

    function _pop(Walker memory walker) internal pure returns (bytes32 node, bool safe) {
        uint256 index = --walker.sp;
        node = walker.stack[index];
        safe = ((walker.safeMask >> index) & 1) != 0;
    }

    function _tree(Walker memory walker, bytes32 node, bool strict)
        internal
        view
        returns (bytes32 left, bytes32 right)
    {
        ++walker.scanned;
        if (strict && walker.scanned > MAX_SCAN_NODES) revert ScanLimit();
        return deepstate.tree(walker.book, node);
    }

    function _expand(Walker memory walker, bytes32 node, bool safe) internal view {
        (bytes32 left, bytes32 right) = _tree(walker, node, true);
        if (left == bytes32(0) || right == bytes32(0)) revert InvalidTree();
        _pushChildren(walker, left, right, safe);
    }

    function _pushChildren(Walker memory walker, bytes32 left, bytes32 right, bool parentSafe) internal pure {
        if (walker.sp + 2 > MAX_STACK) revert InvalidTree();

        // Push left then right so right is popped/executed first. If the parent is on the potentially
        // dirty global right spine, only its right child remains unsafe; the left subtree is exact.
        _push(walker, left, true);
        _push(walker, right, parentSafe);
    }

    function _push(Walker memory walker, bytes32 node, bool safe) internal pure {
        uint256 index = walker.sp++;
        walker.stack[index] = node;
        uint256 bit = uint256(1) << index;
        if (safe) walker.safeMask |= bit;
        else walker.safeMask &= ~bit;
    }

    function _uniformBranchQuote(bytes32 node, bool isBid) internal pure returns (uint256 quoteAmount) {
        uint32 correctionCode = _correctionCode(node);
        quoteAmount = _quoteValue(_price(node), _quantity(node), isBid);
        uint256 correction = uint256(correctionCode) - 1;
        quoteAmount = isBid ? quoteAmount + correction : quoteAmount - correction;
    }

    function _partialLeafQuote(int32 tick, uint160 originalQuantity, uint160 fillQuantity, bool roundUp)
        internal
        pure
        returns (uint256)
    {
        if (fillQuantity == originalQuantity) return _quoteValue(tick, originalQuantity, roundUp);
        return
            _quoteValue(tick, originalQuantity, roundUp) - _quoteValue(tick, originalQuantity - fillQuantity, roundUp);
    }

    function _quoteValue(int32 tick, uint160 quantity, bool roundUp) internal pure returns (uint256 quoteAmount) {
        if (quantity == 0) return 0;
        if (tick == 0) return quantity;

        (uint256 factor, uint16 shift) = TickMath32.getPriceFactorAtTick(tick);
        uint256 denominator = uint256(1) << shift;
        quoteAmount = Math.mulDiv(uint256(quantity), factor, denominator);
        if (roundUp && mulmod(uint256(quantity), factor, denominator) != 0) ++quoteAmount;
    }

    /// @dev Monotone-safe gross threshold for exact-output quote traversal. Any gross >= this value
    ///      necessarily nets at least targetNet because independent floors deduct no more than the
    ///      floor of the summed fee rate. This is used as the fallback when a reachable raw gross lands
    ///      on the one-unit non-monotonic dip of the independent-fee net function.
    function _safeGrossForNet(uint256 targetNet, uint16 protocolFeeBps) internal pure returns (uint256 gross) {
        if (targetNet == 0) revert InvalidAmount();

        uint256 combinedFeeBps = uint256(protocolFeeBps) + uint256(DeepStateConstants.ROUTING_FEE_BPS);
        gross = Math.mulDiv(targetNet - 1, DeepStateConstants.BPS, DeepStateConstants.BPS - combinedFeeBps) + 1;
    }

    /// @dev Globally minimal gross when the gross output itself is directly selectable (token0 exact-output).
    ///      Let G be the monotone-safe summed-rate threshold. Because separate floor fees can improve net by
    ///      at most one unit relative to the summed floor, and the <=110 bps summed fee cannot advance on
    ///      consecutive raw gross values, no value below G-2 can satisfy the target. Check G-2 then G-1.
    function _minimalGrossForNet(uint256 targetNet, uint16 protocolFeeBps) internal pure returns (uint256 gross) {
        gross = _safeGrossForNet(targetNet, protocolFeeBps);
        if (gross > 2 && _netAfterFees(gross - 2, protocolFeeBps) >= targetNet) return gross - 2;
        if (gross > 1 && _netAfterFees(gross - 1, protocolFeeBps) >= targetNet) return gross - 1;
    }

    function _feeAmount(uint256 gross, uint16 feeBps) internal pure returns (uint256) {
        return feeBps == 0 || gross == 0 ? 0 : Math.mulDiv(gross, uint256(feeBps), DeepStateConstants.BPS);
    }

    function _netAfterFees(uint256 gross, uint16 protocolFeeBps) internal pure returns (uint256) {
        uint256 protocolFee = _feeAmount(gross, protocolFeeBps);
        uint256 routingFee = _feeAmount(gross, DeepStateConstants.ROUTING_FEE_BPS);
        return gross - protocolFee - routingFee;
    }

    function _mulDivUp(uint256 x, uint256 y, uint256 denominator) internal pure returns (uint256 result) {
        result = Math.mulDiv(x, y, denominator);
        if (mulmod(x, y, denominator) != 0) ++result;
    }

    function _toUint160(uint256 value) internal pure returns (uint160 result) {
        if (value > type(uint160).max) revert AmountTooLarge();
        result = uint160(value);
    }

    function _price(bytes32 node) internal pure returns (int32) {
        return int32(uint32(uint256(node) >> 224));
    }

    function _quantity(bytes32 node) internal pure returns (uint160) {
        return uint160(uint256(node) >> 64);
    }

    function _correctionCode(bytes32 node) internal pure returns (uint32) {
        return uint32(uint256(node) >> 32);
    }

    function _poolId(address token0, address token1) internal pure returns (bytes32 id) {
        /// @solidity memory-safe-assembly
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, token0)
            mstore(add(ptr, 0x20), token1)
            id := keccak256(ptr, 0x40)
        }
    }

    function _bookId(address token0, address token1, uint256 epoch) internal pure returns (bytes32 id) {
        /// @solidity memory-safe-assembly
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, token0)
            mstore(add(ptr, 0x20), token1)
            mstore(add(ptr, 0x40), epoch)
            id := keccak256(ptr, 0x60)
        }
    }
}

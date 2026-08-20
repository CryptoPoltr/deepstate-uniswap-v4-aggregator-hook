// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IDeepStateV1} from "../../../src/aggregator-hooks/implementations/DeepState/interfaces/IDeepStateV1.sol";
import {DeepStateForkBase} from "./helpers/DeepStateForkBase.sol";

/// @notice Fork coverage against the actually deployed DeepState protocol on Robinhood Chain (4663).
/// @dev Configure FORK_RPC_URL_4663 and optionally FORK_BLOCK_NUMBER_4663. The suite is a no-op when
///      the RPC is absent, matching the optional fork-test convention used by upstream aggregator hooks.
contract DeepStateRobinhoodForkTest is DeepStateForkBase {
    using SafeERC20 for IERC20;

    address internal constant DEEPSTATE = 0x6cf19308C22FC82ea620Fa0B3E94948d20f27B96;
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address internal constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address internal constant V3_POOL = 0xd4EB21209C4D6093f80B5b84f5C45cc093EA14a3;

    IDeepStateV1 internal liveDeepState;

    function setUp() public {
        _selectFork("FORK_RPC_URL_4663", "FORK_BLOCK_NUMBER_4663", 4663);
        if (!forkEnabled) return;

        assertTrue(DEEPSTATE.code.length != 0, "DeepState is not deployed at configured address");
        assertTrue(USDG.code.length != 0 && NVDA.code.length != 0, "fork token missing");

        liveDeepState = IDeepStateV1(DEEPSTATE);
        uint256 epoch = liveDeepState.poolEpoch(_pairId(USDG, NVDA));
        assertGt(liveDeepState.nextNonce(USDG, NVDA, epoch), 0, "live DeepState book is not initialized");

        _setUpAggregator(liveDeepState, USDG, NVDA);
        assertTrue(V3_POOL.code.length != 0, "live NVDA/USDG V3 pool missing");
    }

    function testFork_liveNVDAUSDG_bookAndPlannerAreReadable() public view {
        if (!forkEnabled) return;

        uint256 epoch = liveDeepState.poolEpoch(_pairId(USDG, NVDA));
        (bytes32 askRoot, bytes32 bidRoot) = liveDeepState.roots(USDG, NVDA, epoch);
        assertTrue(askRoot != bytes32(0) || bidRoot != bytes32(0), "live book has no liquidity");

        (uint256 amount0, uint256 amount1) = planner.pseudoTotalValueLocked(USDG, NVDA);
        assertTrue(amount0 != 0 || amount1 != 0, "planner sees no live liquidity");
    }

    function testFork_exactInput_USDGToNVDA_matchesQuoteOnLiveDeepState() public {
        if (!forkEnabled) return;

        (uint256 amountIn, uint256 expectedOut) = _findExactInputQuote(true, 1_000, 10);
        _fundLiveInput(USDG, amountIn);
        uint256 inputBefore = IERC20(USDG).balanceOf(forkTaker);
        uint256 outputBefore = IERC20(NVDA).balanceOf(forkTaker);

        _swap(true, -int256(amountIn));

        assertEq(inputBefore - IERC20(USDG).balanceOf(forkTaker), amountIn);
        assertEq(IERC20(NVDA).balanceOf(forkTaker) - outputBefore, expectedOut);
    }

    function testFork_exactInput_NVDAToUSDG_matchesQuoteOnLiveDeepState() public {
        if (!forkEnabled) return;

        (uint256 amountIn, uint256 expectedOut) = _findExactInputQuote(false, 1e10, 10);
        _fundLiveInput(NVDA, amountIn);
        uint256 inputBefore = IERC20(NVDA).balanceOf(forkTaker);
        uint256 outputBefore = IERC20(USDG).balanceOf(forkTaker);

        _swap(false, -int256(amountIn));

        assertEq(inputBefore - IERC20(NVDA).balanceOf(forkTaker), amountIn);
        assertEq(IERC20(USDG).balanceOf(forkTaker) - outputBefore, expectedOut);
    }

    function _fundLiveInput(address token, uint256 amountIn) internal {
        // Do not use forge-std `deal()` for Robinhood's proxy tokens: its stdStorage
        // balance-slot discovery is not reliable for these implementations. Instead,
        // borrow a tiny amount of real fork state from the existing NVDA/USDG V3 pool.
        uint256 required = amountIn * 2;
        assertGe(IERC20(token).balanceOf(V3_POOL), required, "V3 pool has insufficient funding balance");

        vm.startPrank(V3_POOL);
        IERC20(token).safeTransfer(address(poolManager), amountIn);
        IERC20(token).safeTransfer(forkTaker, amountIn);
        vm.stopPrank();

        vm.prank(forkTaker);
        IERC20(token).forceApprove(address(swapRouter), type(uint256).max);
    }

    function _findExactInputQuote(bool zeroForOne, uint256 firstCandidate, uint256 attempts)
        internal
        returns (uint256 amountIn, uint256 amountOut)
    {
        uint256 candidate = firstCandidate;
        for (uint256 i; i < attempts; ++i) {
            try hook.quote(zeroForOne, -int256(candidate), poolId) returns (uint256 quoted) {
                if (quoted != 0) return (candidate, quoted);
            } catch {}
            candidate *= 10;
        }
        revert("no executable live DeepState quote in candidate range");
    }
}

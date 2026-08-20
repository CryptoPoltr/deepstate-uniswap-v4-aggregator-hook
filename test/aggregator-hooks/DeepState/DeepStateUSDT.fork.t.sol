// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IDeepStateV1} from "../../../src/aggregator-hooks/implementations/DeepState/interfaces/IDeepStateV1.sol";
import {DeepStateForkBase, IDeepStateForkEngine} from "./helpers/DeepStateForkBase.sol";

/// @notice USDT compatibility fork using the real Ethereum USDT contract and real DeepstateV1 bytecode.
/// @dev Robinhood Chain's canonical token list currently exposes USDG rather than USDT, so the actual
///      deployed-protocol fork lives in DeepStateRobinhoodForkTest while this mainnet fork specifically
///      exercises USDT's non-standard ERC20 return/allowance behavior end-to-end.
contract DeepStateUSDTForkTest is DeepStateForkBase {
    using SafeERC20 for IERC20;

    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;

    IDeepStateForkEngine internal engine;

    function setUp() public {
        _selectFork("FORK_RPC_URL_1", "FORK_BLOCK_NUMBER_1", 1);
        if (!forkEnabled) return;

        assertTrue(USDC.code.length != 0 && USDT.code.length != 0, "mainnet stablecoin missing");

        engine = IDeepStateForkEngine(vm.deployCode("deepstate-out/DeepstateV1.sol/DeepstateV1.json"));
        engine.setFeeConfig(makeAddr("forkProtocolFeeRecipient"), 37);

        uint256 makerFunds = 5_000_000e6;
        deal(USDC, forkMaker, makerFunds, false);
        deal(USDT, forkMaker, makerFunds, false);
        vm.startPrank(forkMaker);
        IERC20(USDC).forceApprove(address(engine), type(uint256).max);
        IERC20(USDT).forceApprove(address(engine), type(uint256).max);
        vm.stopPrank();

        // Same construction used by the real-engine fuzz suite: negative bids and positive asks do not cross.
        _rest(engine, USDC, USDT, -1_000, 1_000_000e6, true);
        _rest(engine, USDC, USDT, 1_000, 1_000_000e6, false);

        _setUpAggregator(IDeepStateV1(address(engine)), USDC, USDT);
        _fundSwapPath(USDC, USDT, 5_000_000e6);
    }

    function testFork_USDT_hookApprovalUsesCompatibleAllowancePath() public view {
        if (!forkEnabled) return;
        assertEq(IERC20(USDT).allowance(address(hook), address(engine)), type(uint256).max);
    }

    function testFork_exactInput_USDCToUSDT_matchesQuote() public {
        if (!forkEnabled) return;

        uint256 amountIn = 1_000e6;
        uint256 expectedOut = hook.quote(true, -int256(amountIn), poolId);
        uint256 inputBefore = IERC20(USDC).balanceOf(forkTaker);
        uint256 outputBefore = IERC20(USDT).balanceOf(forkTaker);

        _swap(true, -int256(amountIn));

        assertEq(inputBefore - IERC20(USDC).balanceOf(forkTaker), amountIn);
        assertEq(IERC20(USDT).balanceOf(forkTaker) - outputBefore, expectedOut);
    }

    function testFork_exactInput_USDTToUSDC_matchesQuote() public {
        if (!forkEnabled) return;

        uint256 amountIn = 1_000e6;
        uint256 expectedOut = hook.quote(false, -int256(amountIn), poolId);
        uint256 inputBefore = IERC20(USDT).balanceOf(forkTaker);
        uint256 outputBefore = IERC20(USDC).balanceOf(forkTaker);

        _swap(false, -int256(amountIn));

        assertEq(inputBefore - IERC20(USDT).balanceOf(forkTaker), amountIn);
        assertEq(IERC20(USDC).balanceOf(forkTaker) - outputBefore, expectedOut);
    }
}

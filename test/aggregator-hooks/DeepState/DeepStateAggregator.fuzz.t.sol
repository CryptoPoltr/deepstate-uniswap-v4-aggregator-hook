// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {HookMiner} from "v4-hooks-public/src/utils/HookMiner.sol";
import {SafePoolSwapTest} from "v4-hooks-public/test/aggregator-hooks/shared/SafePoolSwapTest.sol";

import {IDeepStateV1} from "../../../src/aggregator-hooks/implementations/DeepState/interfaces/IDeepStateV1.sol";
import {
    IDeepStatePlanner
} from "../../../src/aggregator-hooks/implementations/DeepState/interfaces/IDeepStatePlanner.sol";
import {DeepStatePlanner} from "../../../src/aggregator-hooks/implementations/DeepState/DeepStatePlanner.sol";
import {DeepStateAggregator} from "../../../src/aggregator-hooks/implementations/DeepState/DeepStateAggregator.sol";
import {DeepStateFuzzBase} from "./helpers/DeepStateFuzzBase.sol";

/// @notice End-to-end fuzzing through real PoolManager + DeepstateV1 + DeepStatePlanner + aggregator hook.
/// @dev Mirrors the official aggregator fuzz pattern: quote through the hook, execute through
///      SafePoolSwapTest, then compare the quote with actual user token balance deltas.
contract DeepStateAggregatorFuzz is DeepStateFuzzBase {
    using PoolIdLibrary for PoolKey;

    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint160 internal constant MIN_PRICE = TickMath.MIN_SQRT_PRICE + 1;
    uint160 internal constant MAX_PRICE = TickMath.MAX_SQRT_PRICE - 1;
    uint256 internal constant MAX_FUZZ_AMOUNT = 1e22;
    uint16 internal constant RAW_PROTOCOL_FEE_ZERO_FOR_ONE = 400;
    uint16 internal constant RAW_PROTOCOL_FEE_ONE_FOR_ZERO = 600;
    uint256 internal constant PIPS_DENOMINATOR = 1_000_000;

    IPoolManager internal poolManager;
    SafePoolSwapTest internal swapRouter;
    DeepStatePlanner internal planner;
    DeepStateAggregator internal hook;
    PoolKey internal poolKey;
    PoolId internal poolId;

    function setUp() public {
        _setUpRealDeepState();
        engine.setFeeConfig(protocolFeeRecipient, 37);

        // A non-crossing live book on both sides. This is actual DeepState state, not a mock tree.
        _rest(-300_000, 1_000_000 ether, true);
        _rest(-200_000, 1_000_000 ether, true);
        _rest(-100_000, 1_000_000 ether, true);
        _rest(100_000, 1_000_000 ether, false);
        _rest(200_000, 1_000_000 ether, false);
        _rest(300_000, 1_000_000 ether, false);

        planner = new DeepStatePlanner(IDeepStateV1(address(engine)));
        poolManager =
            IPoolManager(vm.deployCode("foundry-out/PoolManager.sol/PoolManager.json", abi.encode(address(this))));
        swapRouter = new SafePoolSwapTest(poolManager);
        hook = _deployHook();

        poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 0,
            tickSpacing: 1,
            hooks: IHooks(address(hook))
        });
        poolId = poolKey.toId();
        poolManager.initialize(poolKey, SQRT_PRICE_1_1);

        // PoolManager temporarily carries the swapper funds that the hook takes during unlock.
        token0.mint(address(poolManager), type(uint128).max);
        token1.mint(address(poolManager), type(uint128).max);

        vm.startPrank(taker);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    function testFuzz_swapExactInput_zeroForOne(uint128 amountSeed) public {
        uint256 amountIn = bound(uint256(amountSeed), 1e12, MAX_FUZZ_AMOUNT);
        uint256 expectedOut = hook.quote(true, -int256(amountIn), poolId);

        uint256 inputBefore = token0.balanceOf(taker);
        uint256 outputBefore = token1.balanceOf(taker);
        _swap(true, -int256(amountIn));

        assertEq(inputBefore - token0.balanceOf(taker), amountIn);
        assertEq(token1.balanceOf(taker) - outputBefore, expectedOut);
    }

    function testFuzz_swapExactOutput_zeroForOne(uint128 outputSeed) public {
        uint256 amountOut = bound(uint256(outputSeed), 1e12, MAX_FUZZ_AMOUNT);
        uint256 expectedIn = hook.quote(true, int256(amountOut), poolId);

        uint256 inputBefore = token0.balanceOf(taker);
        uint256 outputBefore = token1.balanceOf(taker);
        _swap(true, int256(amountOut));

        assertEq(inputBefore - token0.balanceOf(taker), expectedIn);
        assertEq(token1.balanceOf(taker) - outputBefore, amountOut);
    }

    function testFuzz_swapExactInput_oneForZero(uint128 amountSeed) public {
        uint256 amountIn = bound(uint256(amountSeed), 1e12, MAX_FUZZ_AMOUNT);
        uint256 expectedOut = hook.quote(false, -int256(amountIn), poolId);

        uint256 inputBefore = token1.balanceOf(taker);
        uint256 outputBefore = token0.balanceOf(taker);
        _swap(false, -int256(amountIn));

        assertEq(inputBefore - token1.balanceOf(taker), amountIn);
        assertEq(token0.balanceOf(taker) - outputBefore, expectedOut);
    }

    function testFuzz_swapExactOutput_oneForZero(uint128 outputSeed) public {
        uint256 amountOut = bound(uint256(outputSeed), 1e12, MAX_FUZZ_AMOUNT);
        uint256 expectedIn = hook.quote(false, int256(amountOut), poolId);

        uint256 inputBefore = token1.balanceOf(taker);
        uint256 outputBefore = token0.balanceOf(taker);
        _swap(false, int256(amountOut));

        assertEq(inputBefore - token1.balanceOf(taker), expectedIn);
        assertEq(token0.balanceOf(taker) - outputBefore, amountOut);
    }

    function test_protocolFee_exactInput_zeroForOne_e2e() public {
        uint256 amountIn = 100 ether;
        uint256 rawOut = hook.quote(true, -int256(amountIn), poolId);
        (address tokenJar, uint256 effectiveFee) = _enableProtocolFee(true);

        uint256 feeAmount = _ceilMulDiv(rawOut, effectiveFee, PIPS_DENOMINATOR);
        uint256 expectedOut = rawOut - feeAmount;
        assertEq(hook.quote(true, -int256(amountIn), poolId), expectedOut);
        assertEq(hook.tokenJar(), tokenJar);

        uint256 inputBefore = token0.balanceOf(taker);
        uint256 outputBefore = token1.balanceOf(taker);
        uint256 jarBefore = token1.balanceOf(tokenJar);
        _swap(true, -int256(amountIn));

        assertEq(inputBefore - token0.balanceOf(taker), amountIn);
        assertEq(token1.balanceOf(taker) - outputBefore, expectedOut);
        assertEq(token1.balanceOf(tokenJar) - jarBefore, feeAmount);
    }

    function test_protocolFee_exactOutput_zeroForOne_e2e() public {
        uint256 amountOut = 100 ether;
        uint256 rawIn = hook.quote(true, int256(amountOut), poolId);
        (address tokenJar, uint256 effectiveFee) = _enableProtocolFee(true);

        uint256 feeAmount = _ceilMulDiv(rawIn, effectiveFee, PIPS_DENOMINATOR - effectiveFee);
        uint256 expectedIn = rawIn + feeAmount;
        assertEq(hook.quote(true, int256(amountOut), poolId), expectedIn);
        assertEq(hook.tokenJar(), tokenJar);

        uint256 inputBefore = token0.balanceOf(taker);
        uint256 outputBefore = token1.balanceOf(taker);
        uint256 jarBefore = token0.balanceOf(tokenJar);
        _swap(true, int256(amountOut));

        assertEq(inputBefore - token0.balanceOf(taker), expectedIn);
        assertEq(token1.balanceOf(taker) - outputBefore, amountOut);
        assertEq(token0.balanceOf(tokenJar) - jarBefore, feeAmount);
    }

    function test_protocolFee_exactInput_oneForZero_e2e() public {
        uint256 amountIn = 100 ether;
        uint256 rawOut = hook.quote(false, -int256(amountIn), poolId);
        (address tokenJar, uint256 effectiveFee) = _enableProtocolFee(false);

        uint256 feeAmount = _ceilMulDiv(rawOut, effectiveFee, PIPS_DENOMINATOR);
        uint256 expectedOut = rawOut - feeAmount;
        assertEq(hook.quote(false, -int256(amountIn), poolId), expectedOut);
        assertEq(hook.tokenJar(), tokenJar);

        uint256 inputBefore = token1.balanceOf(taker);
        uint256 outputBefore = token0.balanceOf(taker);
        uint256 jarBefore = token0.balanceOf(tokenJar);
        _swap(false, -int256(amountIn));

        assertEq(inputBefore - token1.balanceOf(taker), amountIn);
        assertEq(token0.balanceOf(taker) - outputBefore, expectedOut);
        assertEq(token0.balanceOf(tokenJar) - jarBefore, feeAmount);
    }

    function test_protocolFee_exactOutput_oneForZero_e2e() public {
        uint256 amountOut = 100 ether;
        uint256 rawIn = hook.quote(false, int256(amountOut), poolId);
        (address tokenJar, uint256 effectiveFee) = _enableProtocolFee(false);

        uint256 feeAmount = _ceilMulDiv(rawIn, effectiveFee, PIPS_DENOMINATOR - effectiveFee);
        uint256 expectedIn = rawIn + feeAmount;
        assertEq(hook.quote(false, int256(amountOut), poolId), expectedIn);
        assertEq(hook.tokenJar(), tokenJar);

        uint256 inputBefore = token1.balanceOf(taker);
        uint256 outputBefore = token0.balanceOf(taker);
        uint256 jarBefore = token1.balanceOf(tokenJar);
        _swap(false, int256(amountOut));

        assertEq(inputBefore - token1.balanceOf(taker), expectedIn);
        assertEq(token0.balanceOf(taker) - outputBefore, amountOut);
        assertEq(token1.balanceOf(tokenJar) - jarBefore, feeAmount);
    }

    function _enableProtocolFee(bool zeroForOne) internal returns (address tokenJar, uint256 effectiveFee) {
        tokenJar = makeAddr("v4TokenJar");
        TestV4FeeController controller = new TestV4FeeController(tokenJar);
        poolManager.setProtocolFeeController(address(controller));

        uint24 packedFee = uint24(RAW_PROTOCOL_FEE_ZERO_FOR_ONE) | (uint24(RAW_PROTOCOL_FEE_ONE_FOR_ZERO) << 12);
        controller.setProtocolFee(poolManager, poolKey, packedFee);

        uint256 rawFee = zeroForOne ? RAW_PROTOCOL_FEE_ZERO_FOR_ONE : RAW_PROTOCOL_FEE_ONE_FOR_ZERO;
        effectiveFee = rawFee * uint256(hook.protocolFeeMultiplier());
        assertLt(effectiveFee, PIPS_DENOMINATOR);
    }

    function _ceilMulDiv(uint256 x, uint256 y, uint256 denominator) internal pure returns (uint256) {
        return (x * y + denominator - 1) / denominator;
    }

    function _swap(bool zeroForOne, int256 amountSpecified) internal {
        vm.prank(taker);
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? MIN_PRICE : MAX_PRICE
            }),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _deployHook() internal returns (DeepStateAggregator deployed) {
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_INITIALIZE_FLAG
                | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        );
        bytes memory args = abi.encode(poolManager, IDeepStatePlanner(address(planner)), routingFeeRecipient);
        (, bytes32 salt) = HookMiner.find(address(this), flags, type(DeepStateAggregator).creationCode, args);
        deployed =
            new DeepStateAggregator{salt: salt}(poolManager, IDeepStatePlanner(address(planner)), routingFeeRecipient);
    }
}

contract TestV4FeeController {
    address public immutable TOKEN_JAR;

    constructor(address tokenJar_) {
        TOKEN_JAR = tokenJar_;
    }

    function setProtocolFee(IPoolManager manager, PoolKey calldata key, uint24 protocolFee) external {
        manager.setProtocolFee(key, protocolFee);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {ProtocolFeeLibrary} from "@uniswap/v4-core/src/libraries/ProtocolFeeLibrary.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {HookMiner} from "v4-hooks-public/src/utils/HookMiner.sol";
import {SafePoolSwapTest} from "v4-hooks-public/test/aggregator-hooks/shared/SafePoolSwapTest.sol";
import {IAggregatorHook} from "v4-hooks-public/src/aggregator-hooks/interfaces/IAggregatorHook.sol";

import {DeepStateAggregator} from "../../../src/aggregator-hooks/implementations/DeepState/DeepStateAggregator.sol";
import {
    IDeepStatePlanner
} from "../../../src/aggregator-hooks/implementations/DeepState/interfaces/IDeepStatePlanner.sol";
import {IDeepStateV1} from "../../../src/aggregator-hooks/implementations/DeepState/interfaces/IDeepStateV1.sol";
import {
    DeepStateConstants
} from "../../../src/aggregator-hooks/implementations/DeepState/libraries/DeepStateConstants.sol";
import {MockDeepStateV1} from "./mocks/MockDeepStateV1.sol";
import {MockDeepStatePlanner} from "./mocks/MockDeepStatePlanner.sol";
import {TestERC20} from "./mocks/TestERC20.sol";
import {DeepStateAggregatorHarness} from "./helpers/DeepStateAggregatorHarness.sol";

contract DeepStateAggregatorUnitTest is Test {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint160 internal constant MIN_PRICE = TickMath.MIN_SQRT_PRICE + 1;
    uint160 internal constant MAX_PRICE = TickMath.MAX_SQRT_PRICE - 1;

    IPoolManager internal poolManager;
    SafePoolSwapTest internal swapRouter;
    MockDeepStateV1 internal deepstate;
    MockDeepStatePlanner internal planner;
    DeepStateAggregator internal hook;

    TestERC20 internal token0;
    TestERC20 internal token1;
    PoolKey internal poolKey;
    PoolId internal poolId;

    address internal alice = makeAddr("alice");
    address internal feeRecipient = makeAddr("feeRecipient");

    function setUp() public {
        poolManager =
            IPoolManager(vm.deployCode("foundry-out/PoolManager.sol/PoolManager.json", abi.encode(address(this))));
        swapRouter = new SafePoolSwapTest(poolManager);
        deepstate = new MockDeepStateV1();
        planner = new MockDeepStatePlanner(deepstate);

        token0 = new TestERC20("Token 0", "TK0");
        token1 = new TestERC20("Token 1", "TK1");
        if (address(token0) > address(token1)) (token0, token1) = (token1, token0);

        _setBookInitialized(address(token0), address(token1), 7);
        hook = _deployHook(feeRecipient);
        poolKey = _key(address(token0), address(token1), 0, 1);
        poolId = poolKey.toId();
        poolManager.initialize(poolKey, SQRT_PRICE_1_1);

        token0.mint(alice, 1_000_000 ether);
        token1.mint(alice, 1_000_000 ether);
        token0.mint(address(poolManager), 1_000_000 ether);
        token1.mint(address(poolManager), 1_000_000 ether);
        token0.mint(address(deepstate), 1_000_000 ether);
        token1.mint(address(deepstate), 1_000_000 ether);

        vm.startPrank(alice);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    function test_constructorAndPermissions() public view {
        assertEq(address(hook.poolManager()), address(poolManager));
        assertEq(address(hook.planner()), address(planner));
        assertEq(address(hook.deepstate()), address(deepstate));
        assertEq(hook.routingFeeRecipient(), feeRecipient);
        assertEq(hook.ROUTING_FEE_BPS(), DeepStateConstants.ROUTING_FEE_BPS);
        assertEq(hook.MAX_ROUNDING_DUST_BPS(), 1);
        assertEq(hook.protocolFeeMultiplier(), 25);
        assertEq(hook.aggregatorHookVersion(), "DeepStateAggregator v1.0");

        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.beforeInitialize);
        assertTrue(p.beforeSwap);
        assertTrue(p.beforeSwapReturnDelta);
        assertTrue(p.beforeAddLiquidity);
        assertFalse(p.afterInitialize);
        assertFalse(p.afterSwap);
        assertFalse(p.afterSwapReturnDelta);
        assertFalse(p.afterAddLiquidity);
        assertFalse(p.beforeRemoveLiquidity);
        assertFalse(p.afterRemoveLiquidity);
        assertFalse(p.beforeDonate);
        assertFalse(p.afterDonate);
    }

    function test_constructor_zeroFeeRecipient_reverts() public {
        vm.expectRevert(DeepStateAggregator.InvalidRoutingFeeRecipient.selector);
        _deployHook(address(0));
    }

    function test_initialize_registersPoolAndApprovesDeepState() public view {
        assertEq(hook.initializedLength(), 1);
        PoolKey memory stored = hook.initialized(0);
        assertEq(Currency.unwrap(stored.currency0), address(token0));
        assertEq(Currency.unwrap(stored.currency1), address(token1));
        assertEq(stored.fee, 0);
        assertEq(stored.tickSpacing, 1);
        assertEq(address(stored.hooks), address(hook));

        (address stored0, address stored1) = hook.poolIdToTokens(poolId);
        assertEq(stored0, address(token0));
        assertEq(stored1, address(token1));
        assertEq(token0.allowance(address(hook), address(deepstate)), type(uint256).max);
        assertEq(token1.allowance(address(hook), address(deepstate)), type(uint256).max);
    }

    function test_initialize_secondPool_reusesExistingAllowance() public {
        TestERC20 token2 = new TestERC20("Token 2", "TK2");
        (address a, address b) = _sort(address(token0), address(token2));
        _setBookInitialized(a, b, 9);
        PoolKey memory second = _key(a, b, 0, 1);
        poolManager.initialize(second, SQRT_PRICE_1_1);

        assertEq(hook.initializedLength(), 2);
        assertEq(token0.allowance(address(hook), address(deepstate)), type(uint256).max);
        assertEq(IERC20(address(token2)).allowance(address(hook), address(deepstate)), type(uint256).max);
    }

    function test_initialize_permissionless() public {
        TestERC20 aToken = new TestERC20("Permissionless A", "PA");
        TestERC20 bToken = new TestERC20("Permissionless B", "PB");
        (address a, address b) = _sort(address(aToken), address(bToken));
        _setBookInitialized(a, b, 11);
        PoolKey memory key = _key(a, b, 0, 1);

        vm.prank(alice);
        poolManager.initialize(key, SQRT_PRICE_1_1);
        assertEq(hook.initializedLength(), 2);
    }

    function test_initialize_nativeCurrency_reverts() public {
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token1)),
            fee: 0,
            tickSpacing: 1,
            hooks: IHooks(address(hook))
        });
        vm.expectRevert();
        poolManager.initialize(key, SQRT_PRICE_1_1);
    }

    function test_initialize_nonZeroFee_reverts() public {
        PoolKey memory key = _key(address(token0), address(token1), 1, 1);
        vm.expectRevert();
        poolManager.initialize(key, SQRT_PRICE_1_1);
    }

    function test_initialize_wrongTickSpacing_reverts() public {
        PoolKey memory key = _key(address(token0), address(token1), 0, 2);
        vm.expectRevert();
        poolManager.initialize(key, SQRT_PRICE_1_1);
    }

    function test_initialize_missingDeepStateBook_reverts() public {
        TestERC20 aToken = new TestERC20("A", "A");
        TestERC20 bToken = new TestERC20("B", "B");
        (address a, address b) = _sort(address(aToken), address(bToken));
        deepstate.setPoolEpoch(a, b, 3);
        PoolKey memory key = _key(a, b, 0, 1);
        vm.expectRevert();
        poolManager.initialize(key, SQRT_PRICE_1_1);
    }

    function test_pseudoTVL_delegatesToPlanner() public {
        planner.setTVL(123, 456);
        planner.setExpectedPlanCall(address(token0), address(token1), true, -1);
        (uint256 amount0, uint256 amount1) = hook.pseudoTotalValueLocked(poolId);
        assertEq(amount0, 123);
        assertEq(amount1, 456);
    }

    function test_pseudoTVL_unregisteredPool_reverts() public {
        vm.expectRevert();
        hook.pseudoTotalValueLocked(PoolId.wrap(bytes32(uint256(123))));
    }

    function test_quote_fourModes_delegateAndReturnRawPlanSide() public {
        _assertQuote(true, -int256(100), _plan(7, 100, 100, 80, 100, 11), 80);
        _assertQuote(false, -int256(100), _plan(7, 100, 100, 80, 80, -11), 80);
        _assertQuote(true, int256(80), _plan(7, 100, 100, 80, 100, 11), 100);
        _assertQuote(false, int256(80), _plan(7, 100, 100, 80, 80, -11), 100);
    }

    function test_quote_unregisteredPool_reverts() public {
        vm.expectRevert();
        hook.quote(true, -int256(1), PoolId.wrap(bytes32(uint256(999))));
    }

    function test_conductSwap_unregisteredPool_reverts() public {
        DeepStateAggregatorHarness harness = _deployHarness(feeRecipient);
        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: -int256(1), sqrtPriceLimitX96: MIN_PRICE});
        vm.expectRevert(IAggregatorHook.PoolDoesNotExist.selector);
        harness.conductSwapForCoverage(
            Currency.wrap(address(token1)), Currency.wrap(address(token0)), params, PoolId.wrap(bytes32(uint256(12345)))
        );
    }

    function test_validatePlan_zeroBase_reverts() public {
        _expectInvalidQuote(_plan(7, 100, 100, 80, 0, 0), true, -100);
    }

    function test_validatePlan_zeroOutput_reverts() public {
        _expectInvalidQuote(_plan(7, 100, 100, 0, 100, 0), true, -100);
    }

    function test_validatePlan_deepStateInputAboveTake_reverts() public {
        _expectInvalidQuote(_plan(7, 100, 101, 80, 100, 0), true, -100);
    }

    function test_validatePlan_exactInputTakeMismatch_reverts() public {
        _expectInvalidQuote(_plan(7, 99, 99, 80, 99, 0), true, -100);
    }

    function test_validatePlan_int256Min_reverts() public {
        planner.setPlan(_plan(7, 1, 1, 1, 1, 0));
        vm.expectRevert(DeepStateAggregator.AmountTooLarge.selector);
        hook.quote(true, type(int256).min, poolId);
    }

    function test_validatePlan_amountTakeTooLarge_reverts() public {
        uint256 maxV4 = uint256(uint128(type(int128).max));
        planner.setPlan(_plan(7, maxV4 + 1, maxV4 + 1, 1, 1, 0));
        vm.expectRevert(DeepStateAggregator.AmountTooLarge.selector);
        hook.quote(true, int256(1), poolId);
    }

    function test_validatePlan_amountOutTooLarge_reverts() public {
        uint256 maxV4 = uint256(uint128(type(int128).max));
        planner.setPlan(_plan(7, 1, 1, maxV4 + 1, 1, 0));
        vm.expectRevert(DeepStateAggregator.AmountTooLarge.selector);
        hook.quote(true, int256(1), poolId);
    }

    function test_validatePlan_exactOutputHeadroomBoundary() public {
        uint256 maxV4 = uint256(uint128(type(int128).max));
        uint256 maxFee = uint256(ProtocolFeeLibrary.MAX_PROTOCOL_FEE) * uint256(hook.protocolFeeMultiplier());
        uint256 cap =
            Math.mulDiv(maxV4, ProtocolFeeLibrary.PIPS_DENOMINATOR - maxFee, ProtocolFeeLibrary.PIPS_DENOMINATOR);

        planner.setPlan(_plan(7, cap, cap, 1, 1, 0));
        assertEq(hook.quote(true, int256(1), poolId), cap);

        planner.setPlan(_plan(7, cap + 1, cap + 1, 1, 1, 0));
        vm.expectRevert(DeepStateAggregator.AmountTooLarge.selector);
        hook.quote(true, int256(1), poolId);
    }

    function test_validatePlan_exactOutputUnderDelivery_reverts() public {
        planner.setPlan(_plan(7, 100, 100, 99, 100, 0));
        vm.expectRevert(DeepStateAggregator.InvalidQuotePlan.selector);
        hook.quote(true, int256(100), poolId);
    }

    function test_validatePlan_exactOutputSurplusWithinOneBp() public {
        planner.setPlan(_plan(7, 100, 100, 10_001, 100, 0));
        assertEq(hook.quote(true, int256(10_000), poolId), 100);
    }

    function test_validatePlan_exactOutputSurplusAboveOneBp_reverts() public {
        planner.setPlan(_plan(7, 100, 100, 10_002, 100, 0));
        vm.expectRevert(abi.encodeWithSelector(DeepStateAggregator.OutputSurplusTooLarge.selector, 2, 10_000));
        hook.quote(true, int256(10_000), poolId);
    }

    function test_validatePlan_roundingDustOnlyAllowedForOneForZeroExactInput() public {
        planner.setPlan(_plan(7, 10_000, 9_999, 5_000, 5_000, 0));
        assertEq(hook.quote(false, -int256(10_000), poolId), 5_000);

        vm.expectRevert(DeepStateAggregator.InvalidQuotePlan.selector);
        hook.quote(true, -int256(10_000), poolId);

        vm.expectRevert(DeepStateAggregator.InvalidQuotePlan.selector);
        hook.quote(false, int256(5_000), poolId);
    }

    function test_validatePlan_roundingDustAboveOneBp_reverts() public {
        planner.setPlan(_plan(7, 10_000, 9_998, 5_000, 5_000, 0));
        vm.expectRevert(abi.encodeWithSelector(DeepStateAggregator.RoundingDustTooLarge.selector, 2, 10_000));
        hook.quote(false, -int256(10_000), poolId);
    }

    function test_swapExactInput_zeroForOne_executesPlannedFill() public {
        IDeepStatePlanner.Plan memory p = _plan(7, 100 ether, 100 ether, 80 ether, 100 ether, 123);
        planner.setPlan(p);
        planner.setExpectedPlanCall(address(token0), address(token1), true, -int256(100 ether));
        deepstate.configureFill(p.deepStateInput, p.amountOut);

        uint256 inBefore = token0.balanceOf(alice);
        uint256 outBefore = token1.balanceOf(alice);
        _swap(true, -int256(100 ether));
        assertEq(inBefore - token0.balanceOf(alice), 100 ether);
        assertEq(token1.balanceOf(alice) - outBefore, 80 ether);
        _assertLastFill(p, true);
    }

    function test_swapExactOutput_oneForZero_executesPlannedFill() public {
        IDeepStatePlanner.Plan memory p = _plan(7, 100 ether, 100 ether, 80 ether, 80 ether, -321);
        planner.setPlan(p);
        planner.setExpectedPlanCall(address(token0), address(token1), false, int256(80 ether));
        deepstate.configureFill(p.deepStateInput, p.amountOut);

        uint256 inBefore = token1.balanceOf(alice);
        uint256 outBefore = token0.balanceOf(alice);
        _swap(false, int256(80 ether));
        assertEq(inBefore - token1.balanceOf(alice), 100 ether);
        assertEq(token0.balanceOf(alice) - outBefore, 80 ether);
        _assertLastFill(p, false);
    }

    function test_swapExactInput_roundingDustRemainsInHookAndDoesNotPolluteNextSwap() public {
        IDeepStatePlanner.Plan memory p = _plan(7, 10_000, 9_999, 5_000, 5_000, 0);
        planner.setPlan(p);
        deepstate.configureFill(9_999, 5_000);
        _swap(false, -int256(10_000));
        assertEq(token1.balanceOf(address(hook)), 1);

        p = _plan(7, 10_000, 10_000, 5_000, 5_000, 0);
        planner.setPlan(p);
        deepstate.configureFill(10_000, 5_000);
        _swap(false, -int256(10_000));
        assertEq(token1.balanceOf(address(hook)), 1);
    }

    function test_swapExactOutput_boundedSurplusRemainsInHook() public {
        IDeepStatePlanner.Plan memory p = _plan(7, 100, 100, 10_001, 100, 0);
        planner.setPlan(p);
        deepstate.configureFill(100, 10_001);
        uint256 before = token1.balanceOf(alice);
        _swap(true, int256(10_000));
        assertEq(token1.balanceOf(alice) - before, 10_000);
        assertEq(token1.balanceOf(address(hook)), 1);
    }

    function test_swap_inputDeltaMismatch_reverts() public {
        IDeepStatePlanner.Plan memory p = _plan(7, 100, 100, 80, 100, 0);
        planner.setPlan(p);
        deepstate.configureFill(99, 80);
        vm.expectRevert();
        _swap(true, -int256(100));
    }

    function test_swap_outputDeltaMismatch_reverts() public {
        IDeepStatePlanner.Plan memory p = _plan(7, 100, 100, 80, 100, 0);
        planner.setPlan(p);
        deepstate.configureFill(100, 79);
        vm.expectRevert();
        _swap(true, -int256(100));
    }

    function test_swap_inputBalanceAboveAvailable_reverts() public {
        IDeepStatePlanner.Plan memory p = _plan(7, 100, 100, 80, 100, 0);
        planner.setPlan(p);
        deepstate.configureAdversarialFill(100, 80, 101, 0);
        vm.expectRevert();
        _swap(true, -int256(100));
    }

    function test_swap_outputBalanceBelowPreexisting_reverts() public {
        IDeepStatePlanner.Plan memory p = _plan(7, 100, 100, 80, 100, 0);
        planner.setPlan(p);
        token1.mint(address(hook), 1);
        deepstate.configureAdversarialFill(100, 0, 0, 1);
        vm.expectRevert();
        _swap(true, -int256(100));
    }

    function test_setRoutingFeeRecipient() public {
        address next = makeAddr("nextRecipient");
        vm.prank(feeRecipient);
        hook.setRoutingFeeRecipient(next);
        assertEq(hook.routingFeeRecipient(), next);

        vm.prank(feeRecipient);
        vm.expectRevert(DeepStateAggregator.UnauthorizedRoutingFeeRecipient.selector);
        hook.setRoutingFeeRecipient(feeRecipient);
    }

    function test_swap_usesUpdatedRoutingFeeRecipient() public {
        address next = makeAddr("updatedFeeRecipient");
        vm.prank(feeRecipient);
        hook.setRoutingFeeRecipient(next);

        IDeepStatePlanner.Plan memory p = _plan(7, 100, 100, 80, 100, 0);
        planner.setPlan(p);
        deepstate.configureFill(100, 80);
        _swap(true, -int256(100));
        IDeepStateV1.IntegratorFee memory fee = deepstate.lastIntegratorFee();
        assertEq(fee.recipient, next);
        assertEq(fee.bps, DeepStateConstants.ROUTING_FEE_BPS);
    }

    function test_setRoutingFeeRecipient_invalidNewRecipient_reverts() public {
        vm.startPrank(feeRecipient);
        vm.expectRevert(DeepStateAggregator.InvalidRoutingFeeRecipient.selector);
        hook.setRoutingFeeRecipient(address(0));
        vm.expectRevert(DeepStateAggregator.InvalidRoutingFeeRecipient.selector);
        hook.setRoutingFeeRecipient(address(hook));
        vm.stopPrank();
    }

    function test_receiveNative_reverts() public {
        vm.deal(address(this), 1 ether);
        (bool ok, bytes memory data) = address(hook).call{value: 1}("");
        assertFalse(ok);
        bytes4 selector;
        assembly ("memory-safe") {
            selector := mload(add(data, 0x20))
        }
        assertEq(selector, DeepStateAggregator.NativeCurrencyNotSupported.selector);
    }

    function _assertQuote(bool zeroToOne, int256 amountSpecified, IDeepStatePlanner.Plan memory p, uint256 expected)
        internal
    {
        planner.setPlan(p);
        planner.setExpectedPlanCall(address(token0), address(token1), zeroToOne, amountSpecified);
        assertEq(hook.quote(zeroToOne, amountSpecified, poolId), expected);
    }

    function _expectInvalidQuote(IDeepStatePlanner.Plan memory p, bool zeroToOne, int256 amountSpecified) internal {
        planner.setPlan(p);
        vm.expectRevert(DeepStateAggregator.InvalidQuotePlan.selector);
        hook.quote(zeroToOne, amountSpecified, poolId);
    }

    function _assertLastFill(IDeepStatePlanner.Plan memory p, bool zeroToOne) internal view {
        IDeepStateV1.FillParams memory fill = deepstate.lastFill();
        IDeepStateV1.IntegratorFee memory fee = deepstate.lastIntegratorFee();
        assertEq(fill.token0, address(token0));
        assertEq(fill.token1, address(token1));
        assertEq(fill.epoch, p.epoch);
        assertEq(fill.order, _packOrder(p.limitTick, p.baseQuantity));
        assertEq(fill.isBid, !zeroToOne);
        assertTrue(fill.noRest);
        assertTrue(fill.fillOrKill);
        assertEq(fee.recipient, feeRecipient);
        assertEq(fee.bps, DeepStateConstants.ROUTING_FEE_BPS);
    }

    function _swap(bool zeroForOne, int256 amountSpecified) internal {
        uint160 limit = zeroForOne ? MIN_PRICE : MAX_PRICE;
        vm.prank(alice);
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: limit}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _deployHook(address recipient) internal returns (DeepStateAggregator deployed) {
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_INITIALIZE_FLAG
                | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        );
        bytes memory args = abi.encode(poolManager, planner, recipient);
        (, bytes32 salt) = HookMiner.find(address(this), flags, type(DeepStateAggregator).creationCode, args);
        deployed = new DeepStateAggregator{salt: salt}(poolManager, planner, recipient);
    }

    function _deployHarness(address recipient) internal returns (DeepStateAggregatorHarness deployed) {
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_INITIALIZE_FLAG
                | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        );
        bytes memory args = abi.encode(poolManager, planner, recipient);
        (, bytes32 salt) = HookMiner.find(address(this), flags, type(DeepStateAggregatorHarness).creationCode, args);
        deployed = new DeepStateAggregatorHarness{salt: salt}(poolManager, planner, recipient);
    }

    function _setBookInitialized(address a, address b, uint256 epoch) internal {
        deepstate.setPoolEpoch(a, b, epoch);
        deepstate.setNextNonce(a, b, epoch, 1);
    }

    function _key(address a, address b, uint24 fee, int24 tickSpacing) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(a),
            currency1: Currency.wrap(b),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(hook))
        });
    }

    function _sort(address a, address b) internal pure returns (address, address) {
        return a < b ? (a, b) : (b, a);
    }

    function _plan(
        uint256 epoch,
        uint256 amountTake,
        uint256 deepStateInput,
        uint256 amountOut,
        uint160 baseQuantity,
        int32 limitTick
    ) internal pure returns (IDeepStatePlanner.Plan memory) {
        return IDeepStatePlanner.Plan({
            epoch: epoch,
            amountTake: amountTake,
            deepStateInput: deepStateInput,
            amountOut: amountOut,
            baseQuantity: baseQuantity,
            limitTick: limitTick
        });
    }

    function _packOrder(int32 tick, uint160 quantity) internal pure returns (bytes32) {
        return bytes32((uint256(uint32(tick)) << 224) | (uint256(quantity) << 64));
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseAggregatorHook} from "v4-hooks-public/src/aggregator-hooks/BaseAggregatorHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ProtocolFeeLibrary} from "@uniswap/v4-core/src/libraries/ProtocolFeeLibrary.sol";

import {IDeepStateV1} from "./interfaces/IDeepStateV1.sol";
import {IDeepStatePlanner} from "./interfaces/IDeepStatePlanner.sol";
import {DeepStateConstants} from "./libraries/DeepStateConstants.sol";

/// @title DeepStateAggregator
/// @notice Singleton Uniswap v4 Aggregator Hook backed by DeepState V1 order-book liquidity.
/// @dev The v4 pools are zero-LP-fee accounting shells: all executable liquidity lives in DeepState.
///      Only ERC20/ERC20 pools are supported. DeepState protocol fees and the fixed 10 bps
///      integrator fee are included in the raw source quote; BaseAggregatorHook may additionally
///      apply the Uniswap aggregator protocol fee.
contract DeepStateAggregator is BaseAggregatorHook {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;

    /// @notice Fixed DeepState integrator/routing fee: 10 bps = 0.1%.
    uint16 public constant ROUTING_FEE_BPS = DeepStateConstants.ROUTING_FEE_BPS;

    /// @notice Maximum accepted representability dust/output surplus: 1 bp = 0.01%.
    uint16 public constant MAX_ROUNDING_DUST_BPS = 1;

    IDeepStateV1 public immutable deepstate;
    IDeepStatePlanner public immutable planner;

    /// @notice Recipient of the fixed DeepState routing fee.
    /// @dev This address has no pool-admission or emergency-control privileges. It may only transfer
    ///      the fee-recipient role to another nonzero address in one transaction.
    address public routingFeeRecipient;

    struct PoolTokens {
        address token0;
        address token1;
    }

    /// @notice DeepState token pair associated with each initialized v4 aggregator pool.
    mapping(PoolId => PoolTokens) public poolIdToTokens;

    /// @notice PoolKeys initialized with this singleton, in initialization order.
    PoolKey[] internal _initializedPools;

    error NativeCurrencyNotSupported();
    error ExternalPoolMismatch();
    error DeepStateBookNotInitialized();
    error InvalidQuotePlan();
    error UnexpectedSwapDelta();
    error RoundingDustTooLarge(uint256 dust, uint256 amountIn);
    error OutputSurplusTooLarge(uint256 surplus, uint256 requestedOutput);
    error AmountTooLarge();
    error UnauthorizedRoutingFeeRecipient();
    error InvalidRoutingFeeRecipient();

    event RoutingFeeRecipientChanged(address indexed previousRecipient, address indexed newRecipient);

    /// @param manager Uniswap v4 PoolManager.
    /// @param planner_ DeepState order-book planner used by both quote and execution paths.
    /// @param routingFeeRecipient_ Initial recipient of the fixed 10 bps routing fee.
    constructor(IPoolManager manager, IDeepStatePlanner planner_, address routingFeeRecipient_)
        BaseAggregatorHook(manager, "DeepStateAggregator v1.0")
    {
        if (routingFeeRecipient_ == address(0) || routingFeeRecipient_ == address(this)) {
            revert InvalidRoutingFeeRecipient();
        }

        planner = planner_;
        deepstate = planner_.deepstate();
        routingFeeRecipient = routingFeeRecipient_;
    }

    /// @inheritdoc BaseAggregatorHook
    function pseudoTotalValueLocked(PoolId poolId) external view override returns (uint256 amount0, uint256 amount1) {
        PoolTokens memory pair = poolIdToTokens[poolId];
        if (pair.token0 == address(0)) revert PoolDoesNotExist();
        return planner.pseudoTotalValueLocked(pair.token0, pair.token1);
    }

    /// @notice Number of v4 pools initialized with this singleton hook.
    function initializedLength() external view returns (uint256) {
        return _initializedPools.length;
    }

    /// @notice PoolKey initialized at `index`.
    function initialized(uint256 index) external view returns (PoolKey memory) {
        return _initializedPools[index];
    }

    /// @dev Registration is permissionless and deterministic: a shell is admitted only when it maps
    ///      to an already-initialized DeepState book for the same ordered token pair.
    function _beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96)
        internal
        override
        returns (bytes4)
    {
        if (key.currency0.isAddressZero() || key.currency1.isAddressZero()) {
            revert NativeCurrencyNotSupported();
        }

        // DeepState's dynamic protocol fee and the fixed routing fee are already part of the raw source quote.
        // Keep the v4 shell LP-fee-free and canonical for this hook.
        if (key.fee != 0 || key.tickSpacing != 1) revert ExternalPoolMismatch();

        address token0 = Currency.unwrap(key.currency0);
        address token1 = Currency.unwrap(key.currency1);

        uint256 epoch = deepstate.poolEpoch(_poolId(token0, token1));
        if (deepstate.nextNonce(token0, token1, epoch) == 0) revert DeepStateBookNotInitialized();

        PoolId poolId = key.toId();
        poolIdToTokens[poolId] = PoolTokens({token0: token0, token1: token1});
        _initializedPools.push(key);

        // DeepState pulls taker input from this adapter. forceApprove also supports USDT-style allowance semantics.
        _approveToDeepState(token0);
        _approveToDeepState(token1);

        return super._beforeInitialize(sender, key, sqrtPriceX96);
    }

    /// @inheritdoc BaseAggregatorHook
    function _rawQuote(bool zeroToOne, int256 amountSpecified, PoolId poolId)
        internal
        view
        override
        returns (uint256 amountUnspecified)
    {
        PoolTokens memory pair = poolIdToTokens[poolId];
        if (pair.token0 == address(0)) revert PoolDoesNotExist();

        IDeepStatePlanner.Plan memory p = planner.plan(pair.token0, pair.token1, zeroToOne, amountSpecified);
        _validatePlan(p, zeroToOne, amountSpecified);
        return amountSpecified < 0 ? p.amountOut : p.amountTake;
    }

    /// @inheritdoc BaseAggregatorHook
    function _conductSwap(Currency settleCurrency, Currency takeCurrency, SwapParams calldata params, PoolId poolId)
        internal
        override
        returns (uint256 amountSettle, uint256 amountTake, bool hasSettled)
    {
        PoolTokens memory pair = poolIdToTokens[poolId];
        if (pair.token0 == address(0)) revert PoolDoesNotExist();

        // Re-plan against the exact in-transaction DeepState state. Execution never trusts an off-chain quote.
        IDeepStatePlanner.Plan memory p =
            planner.plan(pair.token0, pair.token1, params.zeroForOne, params.amountSpecified);
        _validatePlan(p, params.zeroForOne, params.amountSpecified);
        amountTake = p.amountTake;

        uint256 actualDeepStateOutput = _executeDeepState(takeCurrency, settleCurrency, pair, p, params.zeroForOne);

        // Exact-output plans may over-deliver a bounded number of raw units because DeepState quantities
        // are discrete. Settle exactly the requested amount and leave the verified surplus as inert hook dust.
        amountSettle = params.amountSpecified < 0 ? actualDeepStateOutput : uint256(params.amountSpecified);

        _settle(settleCurrency, address(this), amountSettle);
        hasSettled = true;
    }

    /// @dev Pulls the v4 input, executes the planned DeepState fill, and verifies exact token balance deltas.
    ///      Kept separate from `_conductSwap` to keep stack usage bounded under the aggregator-hooks build profile.
    function _executeDeepState(
        Currency takeCurrency,
        Currency settleCurrency,
        PoolTokens memory pair,
        IDeepStatePlanner.Plan memory p,
        bool zeroToOne
    ) private returns (uint256 actualDeepStateOutput) {
        // Track only balance deltas so pre-existing rounding/output dust cannot affect swap accounting.
        uint256 inputBefore = takeCurrency.balanceOfSelf();
        uint256 outputBefore = settleCurrency.balanceOfSelf();

        _take(takeCurrency, address(this), p.amountTake);
        _fillDeepState(pair, p, zeroToOne);

        uint256 inputAfter = takeCurrency.balanceOfSelf();
        uint256 outputAfter = settleCurrency.balanceOfSelf();
        uint256 availableInput = inputBefore + p.amountTake;
        if (inputAfter > availableInput || outputAfter < outputBefore) revert UnexpectedSwapDelta();

        uint256 actualDeepStateInput = availableInput - inputAfter;
        actualDeepStateOutput = outputAfter - outputBefore;
        if (actualDeepStateInput != p.deepStateInput || actualDeepStateOutput != p.amountOut) {
            revert UnexpectedSwapDelta();
        }
    }

    /// @dev Executes exactly the incoming order described by the validated plan.
    function _fillDeepState(PoolTokens memory pair, IDeepStatePlanner.Plan memory p, bool zeroToOne) private {
        IDeepStateV1.FillParams memory fillParams = IDeepStateV1.FillParams({
            token0: pair.token0,
            token1: pair.token1,
            epoch: p.epoch,
            order: _packOrder(p.limitTick, p.baseQuantity),
            isBid: !zeroToOne,
            noRest: true,
            fillOrKill: true
        });
        IDeepStateV1.IntegratorFee memory integratorFee =
            IDeepStateV1.IntegratorFee({recipient: routingFeeRecipient, bps: ROUTING_FEE_BPS});

        deepstate.fillWithIntegratorFee(fillParams, integratorFee);
    }

    /// @notice Transfer the fixed routing-fee recipient in one step.
    /// @dev The role has no authority over pool registration, quoting, execution, or emergency controls.
    function setRoutingFeeRecipient(address newRecipient) external {
        if (msg.sender != routingFeeRecipient) revert UnauthorizedRoutingFeeRecipient();
        if (newRecipient == address(0) || newRecipient == address(this)) revert InvalidRoutingFeeRecipient();

        address previousRecipient = routingFeeRecipient;
        routingFeeRecipient = newRecipient;
        emit RoutingFeeRecipientChanged(previousRecipient, newRecipient);
    }

    function _validatePlan(IDeepStatePlanner.Plan memory p, bool zeroToOne, int256 amountSpecified) internal view {
        if (amountSpecified == type(int256).min) revert AmountTooLarge();
        if (p.baseQuantity == 0 || p.amountOut == 0) revert InvalidQuotePlan();
        if (p.deepStateInput > p.amountTake) revert InvalidQuotePlan();

        // For exact-input BaseAggregatorHook cancels the entire specified-side core delta.
        if (amountSpecified < 0 && p.amountTake != uint256(-amountSpecified)) revert InvalidQuotePlan();

        uint256 maxV4Amount = uint256(uint128(type(int128).max));
        if (p.amountTake > maxV4Amount || p.amountOut > maxV4Amount) revert AmountTooLarge();

        if (amountSpecified >= 0) {
            // BaseAggregatorHook adds its protocol fee to the exact-output input delta after _conductSwap.
            // For raw input x and fee f (pips), total input is ceil(x * D / (D - f)). Therefore
            // floor(int128.max * (D - f) / D) is the exact largest raw input that remains representable.
            // Use the maximum fee allowed by v4-core so a previously valid quote stays execution-safe even
            // if the protocol fee is raised between quote simulation and transaction execution.
            uint256 maxProtocolFee = uint256(ProtocolFeeLibrary.MAX_PROTOCOL_FEE) * uint256(protocolFeeMultiplier);
            uint256 maxExactOutputTake = Math.mulDiv(
                maxV4Amount, ProtocolFeeLibrary.PIPS_DENOMINATOR - maxProtocolFee, ProtocolFeeLibrary.PIPS_DENOMINATOR
            );
            if (p.amountTake > maxExactOutputTake) revert AmountTooLarge();

            uint256 requestedOutput = uint256(amountSpecified);
            if (p.amountOut < requestedOutput) revert InvalidQuotePlan();
            uint256 surplus = p.amountOut - requestedOutput;
            uint256 maximumSurplus =
                Math.mulDiv(requestedOutput, uint256(MAX_ROUNDING_DUST_BPS), DeepStateConstants.BPS);
            if (surplus > maximumSurplus) revert OutputSurplusTooLarge(surplus, requestedOutput);
        }

        uint256 roundingDust = p.amountTake - p.deepStateInput;
        if (roundingDust != 0) {
            // Structural input dust is valid only for DeepState token1->token0 exact-input BID fills.
            if (zeroToOne || amountSpecified >= 0) revert InvalidQuotePlan();
            uint256 maximum = Math.mulDiv(p.amountTake, uint256(MAX_ROUNDING_DUST_BPS), DeepStateConstants.BPS);
            if (roundingDust > maximum) revert RoundingDustTooLarge(roundingDust, p.amountTake);
        }
    }

    function _approveToDeepState(address token) private {
        IERC20 erc20 = IERC20(token);
        if (erc20.allowance(address(this), address(deepstate)) != type(uint256).max) {
            erc20.forceApprove(address(deepstate), type(uint256).max);
        }
    }

    function _packOrder(int32 tick, uint160 quantity) private pure returns (bytes32 order) {
        // [signed tick:32][quantity:160][correction:32=0][nonce:32=0]
        order = bytes32((uint256(uint32(tick)) << 224) | (uint256(quantity) << 64));
    }

    function _poolId(address token0, address token1) private pure returns (bytes32 id) {
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, token0)
            mstore(add(ptr, 0x20), token1)
            id := keccak256(ptr, 0x40)
        }
    }

    receive() external payable override {
        revert NativeCurrencyNotSupported();
    }
}

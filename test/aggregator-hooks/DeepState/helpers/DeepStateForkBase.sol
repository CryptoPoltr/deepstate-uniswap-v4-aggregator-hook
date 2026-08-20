// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {HookMiner} from "v4-hooks-public/src/utils/HookMiner.sol";
import {SafePoolSwapTest} from "v4-hooks-public/test/aggregator-hooks/shared/SafePoolSwapTest.sol";

import {IDeepStateV1} from "../../../../src/aggregator-hooks/implementations/DeepState/interfaces/IDeepStateV1.sol";
import {
    IDeepStatePlanner
} from "../../../../src/aggregator-hooks/implementations/DeepState/interfaces/IDeepStatePlanner.sol";
import {DeepStatePlanner} from "../../../../src/aggregator-hooks/implementations/DeepState/DeepStatePlanner.sol";
import {DeepStateAggregator} from "../../../../src/aggregator-hooks/implementations/DeepState/DeepStateAggregator.sol";

interface IDeepStateForkEngine is IDeepStateV1 {
    function fill(IDeepStateV1.FillParams calldata params) external payable returns (bytes32 restingOrder);
    function setFeeConfig(address recipient, uint16 bps) external;
}

abstract contract DeepStateForkBase is Test {
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;

    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint160 internal constant MIN_PRICE = TickMath.MIN_SQRT_PRICE + 1;
    uint160 internal constant MAX_PRICE = TickMath.MAX_SQRT_PRICE - 1;

    address internal routingFeeRecipient = makeAddr("forkRoutingFeeRecipient");
    address internal forkMaker = makeAddr("forkMaker");
    address internal forkTaker = makeAddr("forkTaker");

    IPoolManager internal poolManager;
    SafePoolSwapTest internal swapRouter;
    DeepStatePlanner internal planner;
    DeepStateAggregator internal hook;
    PoolKey internal poolKey;
    PoolId internal poolId;

    bool internal forkEnabled;

    function _selectFork(string memory rpcEnv, string memory blockEnv, uint256 expectedChainId) internal {
        string memory rpc = vm.envOr(rpcEnv, string(""));
        if (bytes(rpc).length == 0) return;

        uint256 forkBlock = vm.envOr(blockEnv, uint256(0));
        if (forkBlock == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, forkBlock);

        assertEq(block.chainid, expectedChainId, "unexpected fork chain id");
        forkEnabled = true;
    }

    function _setUpAggregator(IDeepStateV1 engine, address token0, address token1) internal {
        assertTrue(uint160(token0) < uint160(token1), "pair must be address-sorted");

        planner = new DeepStatePlanner(engine);
        poolManager =
            IPoolManager(vm.deployCode("foundry-out/PoolManager.sol/PoolManager.json", abi.encode(address(this))));
        swapRouter = new SafePoolSwapTest(poolManager);
        hook = _deployHook();

        poolKey = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: 0,
            tickSpacing: 1,
            hooks: IHooks(address(hook))
        });
        poolId = poolKey.toId();
        poolManager.initialize(poolKey, SQRT_PRICE_1_1);
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

    function _fundSwapPath(address token0, address token1, uint256 amount) internal {
        // BaseAggregatorHook takes from PoolManager during manager.swap, before the test router settles
        // the user's negative delta. Seed PoolManager so that in-swap take can execute on a fork.
        deal(token0, address(poolManager), amount, false);
        deal(token1, address(poolManager), amount, false);
        deal(token0, forkTaker, amount, false);
        deal(token1, forkTaker, amount, false);

        vm.startPrank(forkTaker);
        IERC20(token0).forceApprove(address(swapRouter), type(uint256).max);
        IERC20(token1).forceApprove(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    function _swap(bool zeroForOne, int256 amountSpecified) internal {
        vm.prank(forkTaker);
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

    function _rest(
        IDeepStateForkEngine engine,
        address token0,
        address token1,
        int32 tick,
        uint160 quantity,
        bool isBid
    ) internal returns (bytes32 restingOrder) {
        uint256 epoch = engine.poolEpoch(_pairId(token0, token1));
        IDeepStateV1.FillParams memory params = IDeepStateV1.FillParams({
            token0: token0,
            token1: token1,
            epoch: epoch,
            order: _order(tick, quantity),
            isBid: isBid,
            noRest: false,
            fillOrKill: false
        });
        vm.prank(forkMaker);
        restingOrder = engine.fill(params);
        assertTrue(restingOrder != bytes32(0), "order did not rest");
    }

    function _order(int32 tick, uint160 quantity) internal pure returns (bytes32) {
        return bytes32((uint256(uint32(tick)) << 224) | (uint256(quantity) << 64));
    }

    function _pairId(address token0, address token1) internal pure returns (bytes32) {
        return keccak256(abi.encode(token0, token1));
    }
}

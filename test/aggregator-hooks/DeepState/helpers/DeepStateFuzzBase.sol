// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IDeepStateV1} from "../../../../src/aggregator-hooks/implementations/DeepState/interfaces/IDeepStateV1.sol";

import {TestERC20} from "../mocks/TestERC20.sol";

/// @notice Shared real-DeepState fixture for differential and end-to-end fuzz tests.
interface IDeepStateV1Test is IDeepStateV1 {
    function fill(IDeepStateV1.FillParams calldata params) external payable returns (bytes32 restingOrder);
    function setFeeConfig(address recipient, uint16 bps) external;
}

abstract contract DeepStateFuzzBase is Test {
    uint16 internal constant ROUTING_FEE_BPS = 10;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant MAKER_BALANCE = type(uint128).max;

    IDeepStateV1Test internal engine;
    TestERC20 internal token0;
    TestERC20 internal token1;

    address internal maker = makeAddr("maker");
    address internal taker = makeAddr("taker");
    address internal protocolFeeRecipient = makeAddr("protocolFeeRecipient");
    address internal routingFeeRecipient = makeAddr("routingFeeRecipient");

    function _setUpRealDeepState() internal {
        engine = IDeepStateV1Test(vm.deployCode("deepstate-out/DeepstateV1.sol/DeepstateV1.json"));

        TestERC20 a = new TestERC20("Token A", "TKA");
        TestERC20 b = new TestERC20("Token B", "TKB");
        if (address(a) < address(b)) {
            token0 = a;
            token1 = b;
        } else {
            token0 = b;
            token1 = a;
        }

        _fundAndApprove(maker);
        _fundAndApprove(taker);
    }

    function _fundAndApprove(address account) internal {
        token0.mint(account, MAKER_BALANCE);
        token1.mint(account, MAKER_BALANCE);
        vm.startPrank(account);
        token0.approve(address(engine), type(uint256).max);
        token1.approve(address(engine), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev Creates a real resting maker order in the active epoch. The opposite side is intentionally
    ///      absent in Planner fuzz setup, so the full quantity rests without matching.
    function _rest(int32 tick, uint160 quantity, bool isBid) internal returns (bytes32 restingOrder) {
        vm.prank(maker);
        restingOrder = engine.fill(_fill(0, _order(tick, quantity), isBid, false, false));
        assertTrue(restingOrder != bytes32(0));
    }

    function _fill(uint256 epoch, bytes32 order, bool isBid, bool noRest, bool fillOrKill)
        internal
        view
        returns (IDeepStateV1.FillParams memory params)
    {
        params = IDeepStateV1.FillParams({
            token0: address(token0),
            token1: address(token1),
            epoch: epoch,
            order: order,
            isBid: isBid,
            noRest: noRest,
            fillOrKill: fillOrKill
        });
    }

    function _order(int32 tick, uint160 quantity) internal pure returns (bytes32) {
        return bytes32((uint256(uint32(tick)) << 224) | (uint256(quantity) << 64));
    }

    function _integratorFee() internal view returns (IDeepStateV1.IntegratorFee memory) {
        return IDeepStateV1.IntegratorFee({recipient: routingFeeRecipient, bps: ROUTING_FEE_BPS});
    }

    function _netAfterDeepStateFees(uint256 gross, uint16 protocolFeeBps) internal pure returns (uint256) {
        return gross - (gross * uint256(protocolFeeBps) / BPS) - (gross * ROUTING_FEE_BPS / BPS);
    }

    /// @dev Creates five same-side maker orders using real DeepState insertion logic. The final order
    ///      deliberately repeats the first tick, exercising same-price FIFO/correction behavior as well
    ///      as mixed-tick radix traversal.
    function _buildRandomBook(bool bids, uint256 seed) internal returns (uint160 totalBase) {
        int32 firstTick;
        for (uint256 i; i < 5; ++i) {
            uint256 random = uint256(keccak256(abi.encode(seed, i)));
            int32 tick;
            if (i == 4) {
                tick = firstTick;
            } else {
                tick = int32(int256(random % 4_000_001) - 2_000_000);
                if (i == 0) firstTick = tick;
            }
            uint160 quantity = uint160(1e12 + ((random >> 64) % (1e20 - 1e12)));
            _rest(tick, quantity, bids);
            totalBase += quantity;
        }
    }
}

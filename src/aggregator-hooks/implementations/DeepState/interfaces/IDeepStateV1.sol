// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Minimal DeepState V1 ABI used by the production aggregator and planner.
/// @dev Kept local so the aggregator build depends only on the protocol surface it actually uses.
///      DeepState math libraries may still be imported separately when source-compatible.
interface IDeepStateV1 {
    struct FillParams {
        address token0;
        address token1;
        uint256 epoch;
        bytes32 order;
        bool isBid;
        bool noRest;
        bool fillOrKill;
    }

    struct IntegratorFee {
        address recipient;
        uint16 bps;
    }

    function poolEpoch(bytes32 pid) external view returns (uint256);
    function nextNonce(address token0, address token1, uint256 epoch) external view returns (uint32);
    function roots(address token0, address token1, uint256 epoch)
        external
        view
        returns (bytes32 askRoot, bytes32 bidRoot);
    function tree(bytes32 id, bytes32 node) external view returns (bytes32 leftNode, bytes32 rightNode);
    function feeConfig() external view returns (address recipient, uint16 bps);

    function fillWithIntegratorFee(FillParams calldata params, IntegratorFee calldata integratorFee)
        external
        payable
        returns (bytes32 restingOrder);
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IDeepStateV1} from "../../../../src/aggregator-hooks/implementations/DeepState/interfaces/IDeepStateV1.sol";

/// @dev Synthetic perfect binary tree used only to exercise the non-strict BID TVL scan bound.
///      Nodes 1..4095 are branches and nodes 4096..8191 are leaves. Every aggregate has
///      correctionCode == 0, so BID TVL must expand safe subtrees instead of collapsing them.
contract SyntheticBidTreeDeepStateV1 is IDeepStateV1 {
    uint32 internal constant FIRST_LEAF = 4_096;

    function tree(bytes32, bytes32 node) external pure override returns (bytes32 leftNode, bytes32 rightNode) {
        uint32 index = uint32(uint256(node));
        if (index == 0 || index >= FIRST_LEAF) return (bytes32(0), bytes32(0));

        leftNode = _node(index * 2);
        rightNode = _node(index * 2 + 1);
    }

    function root() external pure returns (bytes32) {
        return _node(1);
    }

    function poolEpoch(bytes32) external pure override returns (uint256) {
        return 0;
    }

    function nextNonce(address, address, uint256) external pure override returns (uint32) {
        return 0;
    }

    function roots(address, address, uint256) external pure override returns (bytes32 askRoot, bytes32 bidRoot) {
        return (bytes32(0), bytes32(0));
    }

    function feeConfig() external pure override returns (address recipient, uint16 bps) {
        return (address(0), 0);
    }

    function fillWithIntegratorFee(FillParams calldata, IntegratorFee calldata)
        external
        payable
        override
        returns (bytes32)
    {
        revert("not used");
    }

    function _node(uint32 nonce) internal pure returns (bytes32) {
        // tick = 0, quantity = 1, correctionCode = 0, nonce = heap index.
        return bytes32((uint256(1) << 64) | uint256(nonce));
    }
}

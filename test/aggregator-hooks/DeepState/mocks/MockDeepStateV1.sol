// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IDeepStateV1} from "../../../../src/aggregator-hooks/implementations/DeepState/interfaces/IDeepStateV1.sol";

contract MockDeepStateV1 is IDeepStateV1 {
    struct RootsData {
        bytes32 askRoot;
        bytes32 bidRoot;
    }

    struct Children {
        bytes32 left;
        bytes32 right;
    }

    mapping(bytes32 => uint256) internal _epochs;
    mapping(bytes32 => uint32) internal _nextNonce;
    mapping(bytes32 => RootsData) internal _roots;
    mapping(bytes32 => mapping(bytes32 => Children)) internal _tree;

    address internal _feeRecipient;
    uint16 internal _feeBps;

    uint256 public pullAmount;
    uint256 public sendAmount;
    uint256 public extraInputToHook;
    uint256 public drainOutputFromHook;

    FillParams internal _lastFill;
    IntegratorFee internal _lastIntegratorFee;
    uint256 public fillCalls;

    function setPoolEpoch(address token0, address token1, uint256 epoch) external {
        _epochs[_poolId(token0, token1)] = epoch;
    }

    function setNextNonce(address token0, address token1, uint256 epoch, uint32 nonce) external {
        _nextNonce[_bookId(token0, token1, epoch)] = nonce;
    }

    function setRoots(address token0, address token1, uint256 epoch, bytes32 askRoot, bytes32 bidRoot) external {
        _roots[_bookId(token0, token1, epoch)] = RootsData(askRoot, bidRoot);
    }

    function setTree(bytes32 book, bytes32 node, bytes32 left, bytes32 right) external {
        _tree[book][node] = Children(left, right);
    }

    function setFeeConfig(address recipient, uint16 bps) external {
        _feeRecipient = recipient;
        _feeBps = bps;
    }

    function configureFill(uint256 pullAmount_, uint256 sendAmount_) external {
        pullAmount = pullAmount_;
        sendAmount = sendAmount_;
        extraInputToHook = 0;
        drainOutputFromHook = 0;
    }

    function configureAdversarialFill(
        uint256 pullAmount_,
        uint256 sendAmount_,
        uint256 extraInputToHook_,
        uint256 drainOutputFromHook_
    ) external {
        pullAmount = pullAmount_;
        sendAmount = sendAmount_;
        extraInputToHook = extraInputToHook_;
        drainOutputFromHook = drainOutputFromHook_;
    }

    function lastFill() external view returns (FillParams memory) {
        return _lastFill;
    }

    function lastIntegratorFee() external view returns (IntegratorFee memory) {
        return _lastIntegratorFee;
    }

    function poolEpoch(bytes32 pid) external view override returns (uint256) {
        return _epochs[pid];
    }

    function nextNonce(address token0, address token1, uint256 epoch) external view override returns (uint32) {
        return _nextNonce[_bookId(token0, token1, epoch)];
    }

    function roots(address token0, address token1, uint256 epoch)
        external
        view
        override
        returns (bytes32 askRoot, bytes32 bidRoot)
    {
        RootsData memory r = _roots[_bookId(token0, token1, epoch)];
        return (r.askRoot, r.bidRoot);
    }

    function tree(bytes32 id, bytes32 node) external view override returns (bytes32 leftNode, bytes32 rightNode) {
        Children memory c = _tree[id][node];
        return (c.left, c.right);
    }

    function feeConfig() external view override returns (address recipient, uint16 bps) {
        return (_feeRecipient, _feeBps);
    }

    function fillWithIntegratorFee(FillParams calldata params, IntegratorFee calldata integratorFee)
        external
        payable
        override
        returns (bytes32 restingOrder)
    {
        _lastFill = params;
        _lastIntegratorFee = integratorFee;
        ++fillCalls;

        address input = params.isBid ? params.token1 : params.token0;
        address output = params.isBid ? params.token0 : params.token1;

        if (pullAmount != 0) require(IERC20(input).transferFrom(msg.sender, address(this), pullAmount), "pull");
        if (extraInputToHook != 0) require(IERC20(input).transfer(msg.sender, extraInputToHook), "extra input");
        if (drainOutputFromHook != 0) {
            require(IERC20(output).transferFrom(msg.sender, address(this), drainOutputFromHook), "drain output");
        }
        if (sendAmount != 0) require(IERC20(output).transfer(msg.sender, sendAmount), "send");
        return bytes32(0);
    }

    function poolId(address token0, address token1) external pure returns (bytes32) {
        return _poolId(token0, token1);
    }

    function bookId(address token0, address token1, uint256 epoch) external pure returns (bytes32) {
        return _bookId(token0, token1, epoch);
    }

    function _poolId(address token0, address token1) internal pure returns (bytes32) {
        return keccak256(abi.encode(token0, token1));
    }

    function _bookId(address token0, address token1, uint256 epoch) internal pure returns (bytes32) {
        return keccak256(abi.encode(token0, token1, epoch));
    }
}

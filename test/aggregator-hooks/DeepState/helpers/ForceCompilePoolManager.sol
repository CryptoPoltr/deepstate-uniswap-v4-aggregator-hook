// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";

contract ForceCompilePoolManager {
    function creationCodeHash() external pure returns (bytes32) {
        return keccak256(type(PoolManager).creationCode);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

/// @title AggregatorHookMiner
/// @notice Mines CREATE2 salts for Uniswap v4 aggregator hooks.
/// @dev Extends the standard hook-address mining constraint with the aggregator first-byte ID.
///      Kept local because this repository is pinned to Solidity 0.8.28.
library AggregatorHookMiner {
    /// @dev Mask for the 14 low-order Uniswap v4 hook permission bits.
    uint160 internal constant FLAG_MASK = Hooks.ALL_HOOK_MASK;

    /// @dev Mask for the most-significant byte of an EVM address.
    uint160 internal constant FIRST_BYTE_MASK = uint160(0xFF) << 152;

    /// @dev Search window per invocation. Increment saltOffset by this value and retry if no salt is found.
    uint256 internal constant MAX_LOOP = 160_444;

    error SaltNotFound(uint256 saltOffset, uint256 saltsSearched);

    /// @notice Finds a CREATE2 salt matching both the v4 hook flags and aggregator first-byte ID.
    /// @param deployer CREATE2 deployer. For production deterministic deployment this should normally be
    ///        the canonical CREATE2 deployer proxy at 0x4e59b44847b379578588920cA78FbF26c0B4956C.
    /// @param flags Required Uniswap v4 hook permission bits.
    /// @param firstByte Aggregator protocol/type identifier encoded in the first byte of the address.
    /// @param creationCode Hook creation code, e.g. type(DeepStateAggregator).creationCode.
    /// @param constructorArgs ABI-encoded hook constructor arguments.
    /// @param saltOffset First salt to inspect in this search window.
    function find(
        address deployer,
        uint160 flags,
        uint8 firstByte,
        bytes memory creationCode,
        bytes memory constructorArgs,
        uint256 saltOffset
    ) internal view returns (address hookAddress, bytes32 salt) {
        flags &= FLAG_MASK;

        uint160 desiredFirstByte = uint160(firstByte) << 152;
        bytes32 initCodeHash = keccak256(abi.encodePacked(creationCode, constructorArgs));
        uint256 end = saltOffset + MAX_LOOP;

        for (uint256 candidate = saltOffset; candidate < end; ++candidate) {
            hookAddress = computeAddress(deployer, candidate, initCodeHash);

            if (
                uint160(hookAddress) & FLAG_MASK == flags
                    && uint160(hookAddress) & FIRST_BYTE_MASK == desiredFirstByte
                    && hookAddress.code.length == 0
            ) {
                return (hookAddress, bytes32(candidate));
            }
        }

        revert SaltNotFound(saltOffset, MAX_LOOP);
    }

    /// @notice Computes a CREATE2 address from an init-code hash.
    function computeAddress(address deployer, uint256 salt, bytes32 initCodeHash)
        internal
        pure
        returns (address hookAddress)
    {
        hookAddress = address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xFF), deployer, bytes32(salt), initCodeHash))))
        );
    }
}

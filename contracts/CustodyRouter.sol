// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/// @title CustodyRouter — source-chain (Ethereum) side of PayGo Proof-of-Custody.
/// @notice Stateless, ownerless, permissionless — the physical-authenticity twin of PayGoRouter.
///         A chip embedded in the physical asset (EIP-5791 "Physical Backed Token" pattern: a secp256k1
///         keypair that never leaves the chip) signs a challenge twice in the asset's life:
///           role 0 (Origin)   — at listing, proving the seller held the genuine chipped item.
///           role 1 (Delivery) — at handoff, proving whoever now holds the item can produce the SAME
///                                chip's signature.
///         PayGoEscrow (Creditcoin) proves both signatures happened via the identical Attestcoin
///         pipeline already used for InstallmentPaid, then compares the two chip addresses. A match is
///         a cryptographic proof of no substitution; a mismatch is a cryptographic proof of one — no
///         oracle, no jury, no photo review needed for the common case. Attestcoin proves inclusion,
///         never absence, so this — like the payment side — only ever proves a POSITIVE fact.
contract CustodyRouter {
    /// @dev `escrow` namespaces orderId across deployments, exactly like PayGoRouter.InstallmentPaid.
    event PossessionAttested(address indexed escrow, uint256 indexed orderId, address chip, uint8 role, address submitter);

    /// @notice The exact digest a chip must sign for (escrow, orderId, role) — no EIP-191 prefix: PBT-style
    ///         chips sign the raw digest directly, matching EIP-5791's `transferTokenWithChip` convention.
    function digest(address escrow, uint256 orderId, uint8 role) public view returns (bytes32) {
        return keccak256(abi.encodePacked("PayGoCustody", block.chainid, escrow, orderId, role));
    }

    /// @notice Anyone may submit a chip's signature — the buyer scanning at delivery, a courier, the
    ///         seller at listing. `chip` is the chip's own address (its public key, PBT-style); the
    ///         signature is what proves it, not who calls this function.
    function attestPossession(address escrow, uint256 orderId, uint8 role, address chip, bytes calldata signature) external {
        require(role <= 1, "role: 0=origin, 1=delivery");
        require(ECDSA.recover(digest(escrow, orderId, role), signature) == chip, "bad chip signature");
        emit PossessionAttested(escrow, orderId, chip, role, msg.sender);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IERC3009 {
    function receiveWithAuthorization(
        address from, address to, uint256 value, uint256 validAfter, uint256 validBefore, bytes32 nonce,
        uint8 v, bytes32 r, bytes32 s
    ) external;
}

/// @title PayGoRouter — source-chain (Ethereum) side of PayGo.
/// @notice Stateless, ownerless. Moves the installment to the payee and emits the ONE event
///         that PayGoEscrow (on Creditcoin) accepts as proof of payment via Attestcoin.
///         Three ways in, one event out. Anyone may pay / submit for any order.
contract PayGoRouter {
    using SafeERC20 for IERC20;

    /// @dev `escrow` = PayGoEscrow address on Creditcoin (namespaces orderId across deployments).
    event InstallmentPaid(
        address indexed escrow,
        uint256 indexed orderId,
        uint8 installmentNo,
        address payer,
        address payee,
        address token,
        uint256 amount
    );

    /// @notice approve + pay.
    function payInstallment(address escrow, uint256 orderId, uint8 installmentNo, address token, address payee, uint256 amount) external {
        IERC20(token).safeTransferFrom(msg.sender, payee, amount);
        emit InstallmentPaid(escrow, orderId, installmentNo, msg.sender, payee, token, amount);
    }

    /// @notice 1-click: EIP-2612 permit + pay in one tx.
    function payWithPermit(
        address escrow, uint256 orderId, uint8 installmentNo, address token, address payee, uint256 amount,
        uint256 deadline, uint8 v, bytes32 r, bytes32 s
    ) external {
        // a front-run permit would already have set the allowance; don't let that brick the payment
        try IERC20Permit(token).permit(msg.sender, address(this), amount, deadline, v, r, s) {} catch {}
        IERC20(token).safeTransferFrom(msg.sender, payee, amount);
        emit InstallmentPaid(escrow, orderId, installmentNo, msg.sender, payee, token, amount);
    }

    /// @dev EIP-3009 authorization pre-signed by the buyer. The nonce is NOT free: the buyer signs
    ///      nonce = keccak256(escrow, orderId, installmentNo, payee), so the signature commits to where
    ///      the money goes. A submitter who changes payee changes the nonce → signature no longer
    ///      recovers `from` → the token reverts. This is what actually stops autopay theft.
    struct Authorization { address from; uint256 validAfter; uint256 validBefore; uint8 v; bytes32 r; bytes32 s; }

    function authNonce(address escrow, uint256 orderId, uint8 installmentNo, address payee) public pure returns (bytes32) {
        return keccak256(abi.encode(escrow, orderId, installmentNo, payee));
    }

    /// @notice Autopay: authorization pre-signed by the buyer at checkout, submitted by anyone once
    ///         `validAfter` is reached. `receiveWith…` (not `transferWith…`) keeps the token flowing
    ///         through this contract; the routing-bound nonce keeps it flowing to the signed payee.
    function payWithAuthorization(
        address escrow, uint256 orderId, uint8 installmentNo, address token, address payee, uint256 amount,
        Authorization calldata a
    ) external {
        bytes32 nonce = authNonce(escrow, orderId, installmentNo, payee);
        IERC3009(token).receiveWithAuthorization(a.from, address(this), amount, a.validAfter, a.validBefore, nonce, a.v, a.r, a.s);
        IERC20(token).safeTransfer(payee, amount);
        emit InstallmentPaid(escrow, orderId, installmentNo, a.from, payee, token, amount);
    }
}

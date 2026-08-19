// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title PayGoRouter — source-chain (Ethereum) side of PayGo.
/// @notice Stateless, ownerless. Moves the installment to the payee and emits the ONE event
///         that PayGoEscrow (on Creditcoin) accepts as proof of payment via Attestcoin.
///         Anyone may pay any installment for any order (permissionless autopay).
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

    function payInstallment(
        address escrow,
        uint256 orderId,
        uint8 installmentNo,
        address token,
        address payee,
        uint256 amount
    ) external {
        IERC20(token).safeTransferFrom(msg.sender, payee, amount);
        emit InstallmentPaid(escrow, orderId, installmentNo, msg.sender, payee, token, amount);
    }
}

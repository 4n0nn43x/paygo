// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Test} from "forge-std/Test.sol";
import {PayGoRouter} from "../contracts/PayGoRouter.sol";
import {TestUSDC} from "../contracts/Demo.sol";

contract PayGoRouterTest is Test {
    PayGoRouter router;
    TestUSDC usdc;
    uint256 buyerPk = 0xB0B;
    address buyer;
    address payee = address(0xFEE);
    address escrow = address(0xE5C);

    event InstallmentPaid(address indexed escrow, uint256 indexed orderId, uint8 installmentNo, address payer, address payee, address token, uint256 amount);

    function setUp() public {
        router = new PayGoRouter();
        usdc = new TestUSDC();
        buyer = vm.addr(buyerPk);
        usdc.mint(buyer, 1000e6);
    }

    function test_payInstallment() public {
        vm.startPrank(buyer);
        usdc.approve(address(router), 40e6);
        vm.expectEmit(true, true, false, true);
        emit InstallmentPaid(escrow, 1, 0, buyer, payee, address(usdc), 40e6);
        router.payInstallment(escrow, 1, 0, address(usdc), payee, 40e6);
        assertEq(usdc.balanceOf(payee), 40e6);
    }

    function test_payWithPermit_oneTx() public {
        bytes32 digest = _hash(keccak256(abi.encode(
            keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
            buyer, address(router), 40e6, 0, block.timestamp + 1 hours)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(buyerPk, digest);
        vm.prank(buyer);
        router.payWithPermit(escrow, 1, 0, address(usdc), payee, 40e6, block.timestamp + 1 hours, v, r, s);
        assertEq(usdc.balanceOf(payee), 40e6);
    }

    // buyer signs with the routing-bound nonce = keccak256(escrow, orderId, installmentNo, payee)
    function _auth(uint256 after_, uint256 before_, uint256 amount, address escrow_, uint256 id, uint8 no, address payee_)
        internal view returns (PayGoRouter.Authorization memory a)
    {
        bytes32 sh = keccak256(abi.encode(usdc.RECEIVE_WITH_AUTHORIZATION_TYPEHASH(),
            buyer, address(router), amount, after_, before_, router.authNonce(escrow_, id, no, payee_)));
        (a.v, a.r, a.s) = vm.sign(buyerPk, _hash(sh));
        a.from = buyer; a.validAfter = after_; a.validBefore = before_;
    }

    function test_payWithAuthorization_presignedSubmittedByAnyone() public {
        // buyer pre-signs at checkout: valid from t+1h to t+2h
        PayGoRouter.Authorization memory a = _auth(block.timestamp + 1 hours, block.timestamp + 2 hours, 20e6, escrow, 1, 1, payee);

        vm.prank(address(0xA11CE));                                   // anyone, too early
        vm.expectRevert("authorization not yet valid");
        router.payWithAuthorization(escrow, 1, 1, address(usdc), payee, 20e6, a);

        vm.warp(a.validAfter + 1);
        vm.prank(address(0xA11CE));
        vm.expectEmit(true, true, false, true);
        emit InstallmentPaid(escrow, 1, 1, buyer, payee, address(usdc), 20e6);
        router.payWithAuthorization(escrow, 1, 1, address(usdc), payee, 20e6, a);
        assertEq(usdc.balanceOf(payee), 20e6);

        vm.expectRevert("authorization used");                        // replay
        router.payWithAuthorization(escrow, 1, 1, address(usdc), payee, 20e6, a);
    }

    // HIGH-1 regression: a submitter cannot redirect a pre-signed autopay to themselves
    function test_payWithAuthorization_payeeIsBound() public {
        address attacker = address(0xBAD);
        PayGoRouter.Authorization memory a = _auth(0, block.timestamp + 1 hours, 20e6, escrow, 1, 1, payee);
        vm.prank(attacker);
        vm.expectRevert("invalid signature");                        // nonce for attacker-payee != signed nonce
        router.payWithAuthorization(escrow, 1, 1, address(usdc), attacker, 20e6, a);
        assertEq(usdc.balanceOf(attacker), 0);
    }

    // SC-AUDIT-09: a pre-signed installment outlives the order it was signed for — after a default the
    // seller could still submit the remaining authorizations. EIP-3009 revocation (which real USDC has) is
    // the buyer's only remedy, so the demo token must expose it too.
    function test_cancelAuthorization_revokesAPresignedInstallment() public {
        PayGoRouter.Authorization memory a = _auth(0, block.timestamp + 1 hours, 20e6, escrow, 1, 1, payee);
        bytes32 nonce = router.authNonce(escrow, 1, 1, payee);

        bytes32 digest = _hash(keccak256(abi.encode(usdc.CANCEL_AUTHORIZATION_TYPEHASH(), buyer, nonce)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(buyerPk, digest);
        usdc.cancelAuthorization(buyer, nonce, v, r, s);

        vm.expectRevert("authorization used");
        router.payWithAuthorization(escrow, 1, 1, address(usdc), payee, 20e6, a);
        assertEq(usdc.balanceOf(payee), 0, "the revoked installment can never be pulled");
    }

    function test_cancelAuthorization_onlyTheSignerCanRevoke() public {
        bytes32 nonce = router.authNonce(escrow, 1, 1, payee);
        bytes32 digest = _hash(keccak256(abi.encode(usdc.CANCEL_AUTHORIZATION_TYPEHASH(), buyer, nonce)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xBAD, digest);
        vm.expectRevert("invalid signature");
        usdc.cancelAuthorization(buyer, nonce, v, r, s);
    }

    function test_authorization_boundToRouter() public {
        bytes32 nonce = router.authNonce(escrow, 1, 1, payee);
        bytes32 digest = _hash(keccak256(abi.encode(usdc.RECEIVE_WITH_AUTHORIZATION_TYPEHASH(),
            buyer, address(router), 20e6, 0, block.timestamp + 1, nonce)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(buyerPk, digest);
        vm.expectRevert("invalid signature");                        // signed to=router: a thief calling the token as themselves is rejected
        usdc.receiveWithAuthorization(buyer, address(this), 20e6, 0, block.timestamp + 1, nonce, v, r, s);
    }

    function _hash(bytes32 structHash) internal view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", usdc.DOMAIN_SEPARATOR(), structHash));
    }
}

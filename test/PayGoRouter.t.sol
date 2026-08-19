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

    function _auth(uint256 after_, uint256 before_, bytes32 nonce, uint256 amount) internal view returns (PayGoRouter.Authorization memory a) {
        (a.v, a.r, a.s) = vm.sign(buyerPk, _hash(keccak256(abi.encode(usdc.RECEIVE_WITH_AUTHORIZATION_TYPEHASH(),
            buyer, address(router), amount, after_, before_, nonce))));
        a.from = buyer; a.validAfter = after_; a.validBefore = before_; a.nonce = nonce;
    }

    function test_payWithAuthorization_presignedSubmittedByAnyone() public {
        // buyer pre-signs at checkout: valid from t+1h to t+2h, random nonce
        PayGoRouter.Authorization memory a = _auth(block.timestamp + 1 hours, block.timestamp + 2 hours, keccak256("n1"), 20e6);

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

    function test_authorization_boundToRouter() public {
        bytes32 digest = _hash(keccak256(abi.encode(usdc.RECEIVE_WITH_AUTHORIZATION_TYPEHASH(),
            buyer, address(router), 20e6, 0, block.timestamp + 1, keccak256("n2"))));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(buyerPk, digest);
        vm.expectRevert("invalid signature");                        // signed for the router: a thief can't redirect it
        usdc.receiveWithAuthorization(buyer, address(this), 20e6, 0, block.timestamp + 1, keccak256("n2"), v, r, s);
    }

    function _hash(bytes32 structHash) internal view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", usdc.DOMAIN_SEPARATOR(), structHash));
    }
}

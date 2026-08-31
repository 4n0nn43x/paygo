// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Test} from "forge-std/Test.sol";
import {CustodyRouter} from "../contracts/CustodyRouter.sol";

contract CustodyRouterTest is Test {
    CustodyRouter router;
    uint256 chipPk = 0xC41B;              // the "chip" is just a keypair for this test — no hardware needed
    address chip;
    address escrow = address(0xE5C);

    event PossessionAttested(address indexed escrow, uint256 indexed orderId, address chip, uint8 role, address submitter);

    function setUp() public {
        router = new CustodyRouter();
        chip = vm.addr(chipPk);
    }

    function _sign(uint256 orderId, uint8 role) internal view returns (bytes memory sig) {
        bytes32 digest = router.digest(escrow, orderId, role);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(chipPk, digest);
        sig = abi.encodePacked(r, s, v);
    }

    function test_attestPossession_validSignature() public {
        bytes memory sig = _sign(1, 0);
        vm.prank(address(0xA11CE));                     // anyone may submit — the signature is what proves it
        vm.expectEmit(true, true, false, true);
        emit PossessionAttested(escrow, 1, chip, 0, address(0xA11CE));
        router.attestPossession(escrow, 1, 0, chip, sig);
    }

    function test_attestPossession_rejectsWrongChip() public {
        bytes memory sig = _sign(1, 0);
        vm.expectRevert("bad chip signature");
        router.attestPossession(escrow, 1, 0, address(0xBAD), sig);   // signature doesn't recover to the claimed chip
    }

    function test_attestPossession_rejectsBadRole() public {
        bytes memory sig = _sign(1, 0);
        vm.expectRevert("role: 0=origin, 1=delivery");
        router.attestPossession(escrow, 1, 2, chip, sig);
    }

    // domain separation: a signature for one orderId or role must not verify for another
    function test_digest_isDomainSeparated() public {
        bytes memory sigForOrder1 = _sign(1, 0);
        vm.expectRevert("bad chip signature");
        router.attestPossession(escrow, 2, 0, chip, sigForOrder1);    // different orderId

        bytes memory sigForRoleOrigin = _sign(1, 0);
        vm.expectRevert("bad chip signature");
        router.attestPossession(escrow, 1, 1, chip, sigForRoleOrigin); // different role
    }
}

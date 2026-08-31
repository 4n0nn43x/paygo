// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/// @title CreditPassport — ERC-5192 soulbound record of payment facts.
/// @notice Not a score. Every entry is an Attestcoin-verified installment (or a consumed default)
///         written by PayGoEscrow, and read back by PayGoEscrow itself to size the next deposit.
///         One token per address, tokenId = uint160(owner), minted on first fact, never transferable.
contract CreditPassport {
    /// @dev `volume` is `uint256`, not a narrower type: it's purely informational (never gates
    ///      `depositBps`), and a narrower type invites exactly the truncating-cast-then-overflow DoS a
    ///      security pass found here (SC-AUDIT-01) — `amount` is attacker-controlled ERC20 input with no
    ///      protocol-level ceiling, so any fixed-width accumulator is a griefing vector, not just uint128.
    struct Record { uint32 honored; uint32 defaulted; uint256 volume; }

    address public immutable escrow;
    mapping(address => Record) public records;

    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId); // ERC-721 mint only
    event Locked(uint256 tokenId);                                                     // ERC-5192
    event Fact(address indexed buyer, bool honored, uint256 amount);

    constructor(address escrow_) { escrow = escrow_; }

    function record(address buyer, bool ok, uint256 amount) external {
        require(msg.sender == escrow, "escrow only");
        Record storage r = records[buyer];
        if (r.honored + r.defaulted == 0) { emit Transfer(address(0), buyer, uint160(buyer)); emit Locked(uint160(buyer)); }
        if (ok) { r.honored++; r.volume += amount; } else r.defaulted++;
        emit Fact(buyer, ok, amount);
    }

    /// @notice The one rule PayGo consumes: 4+ honored installments and no default → 15% deposit, else 40%.
    function depositBps(address buyer) external view returns (uint16) {
        Record storage r = records[buyer];
        return (r.honored >= 4 && r.defaulted == 0) ? 1500 : 4000;
    }

    // ---- ERC-721 read surface + ERC-5192 (no transfers: soulbound)
    function name() external pure returns (string memory) { return "PayGo Credit Passport"; }
    function symbol() external pure returns (string memory) { return "PAYGO-ID"; }
    function locked(uint256) external pure returns (bool) { return true; }
    function balanceOf(address a) external view returns (uint256) { Record storage r = records[a]; return r.honored + r.defaulted > 0 ? 1 : 0; }
    function ownerOf(uint256 id) external view returns (address a) {
        a = address(uint160(id));
        require(records[a].honored + records[a].defaulted > 0, "no passport");
    }
    function tokenURI(uint256 id) external view returns (string memory) {
        Record storage r = records[address(uint160(id))];
        return string.concat('data:application/json,{"name":"PayGo Credit Passport","honored":', _u(r.honored),
            ',"defaulted":', _u(r.defaulted), ',"volume":', _u(r.volume), '}');
    }
    function supportsInterface(bytes4 i) external pure returns (bool) {
        return i == 0xb45a3c0e /* ERC-5192 */ || i == 0x5b5e139f /* ERC-721 metadata */ || i == 0x01ffc9a7;
    }
    function transferFrom(address, address, uint256) external pure { revert("soulbound"); }
    function safeTransferFrom(address, address, uint256) external pure { revert("soulbound"); }
    function approve(address, uint256) external pure { revert("soulbound"); }
    function setApprovalForAll(address, bool) external pure { revert("soulbound"); }
    function getApproved(uint256) external pure returns (address) { return address(0); }
    function isApprovedForAll(address, address) external pure returns (bool) { return false; }

    function _u(uint256 v) private pure returns (string memory s) {
        if (v == 0) return "0";
        bytes memory b; while (v > 0) { b = abi.encodePacked(uint8(48 + v % 10), b); v /= 10; } return string(b);
    }
}

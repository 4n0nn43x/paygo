// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/// @title SellerPassport — ERC-5192 soulbound record of custody facts (the seller-side twin of CreditPassport).
/// @notice Not a score. Every entry is an Attestcoin-verified chip match (or a proven chip mismatch)
///         written by PayGoEscrow, and read back by PayGoEscrow itself to decide whether a seller may
///         list without posting a custody bond. "casier de faits de livraison", jamais un score.
contract SellerPassport {
    struct Record { uint32 confirmed; uint32 disputed; }

    address public immutable escrow;
    mapping(address => Record) public records;

    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId); // ERC-721 mint only
    event Locked(uint256 tokenId);                                                     // ERC-5192
    event Fact(address indexed seller, bool matched);

    constructor(address escrow_) { escrow = escrow_; }

    function record(address seller, bool matched) external {
        require(msg.sender == escrow, "escrow only");
        Record storage r = records[seller];
        if (r.confirmed + r.disputed == 0) { emit Transfer(address(0), seller, uint160(seller)); emit Locked(uint160(seller)); }
        if (matched) r.confirmed++; else r.disputed++;
        emit Fact(seller, matched);
    }

    /// @notice The one rule PayGo consumes: 4+ chip-matched deliveries and never a proven mismatch →
    ///         may list without posting a custody bond. One proven mismatch, ever, and the waiver is gone
    ///         for good — this is a fact ledger, not a score that recovers by volume.
    function waivesBond(address seller) external view returns (bool) {
        Record storage r = records[seller];
        return r.confirmed >= 4 && r.disputed == 0;
    }

    // ---- ERC-721 read surface + ERC-5192 (no transfers: soulbound)
    function name() external pure returns (string memory) { return "PayGo Seller Passport"; }
    function symbol() external pure returns (string memory) { return "PAYGO-SELLER"; }
    function locked(uint256) external pure returns (bool) { return true; }
    function balanceOf(address a) external view returns (uint256) { Record storage r = records[a]; return r.confirmed + r.disputed > 0 ? 1 : 0; }
    function ownerOf(uint256 id) external view returns (address a) {
        a = address(uint160(id));
        require(records[a].confirmed + records[a].disputed > 0, "no passport");
    }
    function tokenURI(uint256 id) external view returns (string memory) {
        Record storage r = records[address(uint160(id))];
        return string.concat('data:application/json,{"name":"PayGo Seller Passport","confirmed":', _u(r.confirmed),
            ',"disputed":', _u(r.disputed), '}');
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

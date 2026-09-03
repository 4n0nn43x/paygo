// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Soulbound} from "./Soulbound.sol";

/// @title SellerPassport — ERC-5192 soulbound record of custody facts (the seller-side twin of CreditPassport).
/// @notice Not a score. Every entry is an Attestcoin-verified chip match (or a proven chip mismatch)
///         written by PayGoEscrow, and read back by PayGoEscrow itself to decide whether a seller may
///         list without posting a custody bond. "casier de faits de livraison", jamais un score.
contract SellerPassport is Soulbound {
    struct Record { uint32 confirmed; uint32 disputed; }

    mapping(address => Record) public records;

    event Fact(address indexed seller, bool matched);

    constructor(address escrow_) Soulbound(escrow_) {}

    function record(address seller, bool matched) external {
        require(msg.sender == escrow, "escrow only");
        _mintOnFirstFact(seller);
        Record storage r = records[seller];
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

    function _has(address a) internal view override returns (bool) { Record storage r = records[a]; return r.confirmed + r.disputed > 0; }
    function name() external pure returns (string memory) { return "PayGo Seller Passport"; }
    function symbol() external pure returns (string memory) { return "PAYGO-SELLER"; }
    function tokenURI(uint256 id) external view returns (string memory) {
        Record storage r = records[address(uint160(id))];
        return string.concat('data:application/json,{"name":"PayGo Seller Passport","confirmed":', Strings.toString(r.confirmed),
            ',"disputed":', Strings.toString(r.disputed), '}');
    }
}

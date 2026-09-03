// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Soulbound} from "./Soulbound.sol";

/// @title CreditPassport — ERC-5192 soulbound record of payment facts.
/// @notice Not a score. Every entry is an Attestcoin-verified installment (or a consumed default)
///         written by PayGoEscrow, and read back by PayGoEscrow itself to size the next deposit.
contract CreditPassport is Soulbound {
    /// @dev `volume` is `uint256`, not a narrower type: it's purely informational (never gates
    ///      `depositBps`), and a narrower type invites exactly the truncating-cast-then-overflow DoS a
    ///      security pass found here (SC-AUDIT-01) — `amount` is attacker-controlled ERC20 input with no
    ///      protocol-level ceiling, so any fixed-width accumulator is a griefing vector, not just uint128.
    struct Record { uint32 honored; uint32 defaulted; uint256 volume; }

    mapping(address => Record) public records;

    event Fact(address indexed buyer, bool honored, uint256 amount);

    constructor(address escrow_) Soulbound(escrow_) {}

    function record(address buyer, bool ok, uint256 amount) external {
        require(msg.sender == escrow, "escrow only");
        _mintOnFirstFact(buyer);
        Record storage r = records[buyer];
        // SC-AUDIT-08: `volume` is informational and never gates `depositBps`, but `amount` is unbounded
        // attacker input (an allowlisted payToken may have an unbounded `mint`). A checked `+=` lets anyone
        // pin a victim's volume at max and panic every later settle naming them. Saturate: no wider type
        // fixes this, only refusing to revert does.
        if (ok) { r.honored++; unchecked { uint256 v = r.volume + amount; r.volume = v < r.volume ? type(uint256).max : v; } }
        else r.defaulted++;
        emit Fact(buyer, ok, amount);
    }

    /// @notice The one rule PayGo consumes: 4+ honored installments and no default → 15% deposit, else 40%.
    function depositBps(address buyer) external view returns (uint16) {
        Record storage r = records[buyer];
        return (r.honored >= 4 && r.defaulted == 0) ? 1500 : 4000;
    }

    function _has(address a) internal view override returns (bool) { Record storage r = records[a]; return r.honored + r.defaulted > 0; }
    function name() external pure returns (string memory) { return "PayGo Credit Passport"; }
    function symbol() external pure returns (string memory) { return "PAYGO-ID"; }
    function tokenURI(uint256 id) external view returns (string memory) {
        Record storage r = records[address(uint160(id))];
        return string.concat('data:application/json,{"name":"PayGo Credit Passport","honored":', Strings.toString(r.honored),
            ',"defaulted":', Strings.toString(r.defaulted), ',"volume":', Strings.toString(r.volume), '}');
    }
}

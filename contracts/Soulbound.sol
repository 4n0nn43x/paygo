// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/// @title Soulbound — the ERC-721 read surface + ERC-5192 lock shared by PayGo's two passports.
/// @notice One token per address, tokenId = uint160(owner), minted on the first fact, never transferable.
///         Children own the facts (`records`, `record`, the one rule PayGo consumes, `tokenURI`).
abstract contract Soulbound {
    address public immutable escrow;

    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId); // ERC-721 mint only
    event Locked(uint256 tokenId);                                                     // ERC-5192

    constructor(address escrow_) { escrow = escrow_; }

    /// @dev Does `a` hold at least one fact (i.e. a passport)?
    function _has(address a) internal view virtual returns (bool);

    /// @dev Call BEFORE writing the first fact: mints (emits) the passport if `a` has none yet.
    function _mintOnFirstFact(address a) internal {
        if (!_has(a)) { emit Transfer(address(0), a, uint160(a)); emit Locked(uint160(a)); }
    }

    function locked(uint256) external pure returns (bool) { return true; }
    function balanceOf(address a) external view returns (uint256) { return _has(a) ? 1 : 0; }
    function ownerOf(uint256 id) external view returns (address a) {
        a = address(uint160(id));
        require(_has(a), "no passport");
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
}

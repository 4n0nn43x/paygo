// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/// @dev Demo stand-in for USDC: ERC20 + EIP-2612 permit + EIP-3009 receiveWithAuthorization,
///      the same surface real USDC v2 exposes. Swapping to the real address is zero code change.
contract TestUSDC is ERC20Permit {
    bytes32 public constant RECEIVE_WITH_AUTHORIZATION_TYPEHASH =
        keccak256("ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)");
    mapping(address => mapping(bytes32 => bool)) public authorizationState;
    event AuthorizationUsed(address indexed authorizer, bytes32 indexed nonce);

    constructor() ERC20("Test USDC", "tUSDC") ERC20Permit("Test USDC") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }

    function receiveWithAuthorization(
        address from, address to, uint256 value, uint256 validAfter, uint256 validBefore, bytes32 nonce,
        uint8 v, bytes32 r, bytes32 s
    ) external {
        require(to == msg.sender, "caller must be the payee");
        require(block.timestamp > validAfter, "authorization not yet valid");
        require(block.timestamp < validBefore, "authorization expired");
        require(!authorizationState[from][nonce], "authorization used");
        bytes32 digest = _hashTypedDataV4(keccak256(abi.encode(
            RECEIVE_WITH_AUTHORIZATION_TYPEHASH, from, to, value, validAfter, validBefore, nonce)));
        require(ECDSA.recover(digest, v, r, s) == from, "invalid signature");
        authorizationState[from][nonce] = true;
        emit AuthorizationUsed(from, nonce);
        _transfer(from, to, value);
    }
}

/// @dev `mint` is unchanged (every existing caller keeps working); `mintWithMeta` is additive —
///      real on-chain tokenURI metadata (name/description/image), the same on-chain JSON data-URI
///      pattern CreditPassport/SellerPassport already use. A tokenized asset a buyer can only see as
///      "Asset #128" isn't really tokenization; this is what a seller listing a real item needs.
contract DemoAsset is ERC721("PayGo Demo Asset", "PGA") {
    struct Meta { string name; string description; string image; }
    uint256 public next = 1;
    mapping(uint256 => Meta) public meta;

    function mint(address to) external returns (uint256 id) { id = next++; _mint(to, id); }

    function mintWithMeta(address to, string calldata name_, string calldata description, string calldata image)
        external returns (uint256 id)
    {
        id = next++;
        meta[id] = Meta(name_, description, image);
        _mint(to, id);
    }

    function tokenURI(uint256 id) public view override returns (string memory) {
        _requireOwned(id);
        Meta storage m = meta[id];
        if (bytes(m.name).length == 0) {
            return string.concat('data:application/json,{"name":"PayGo Demo Asset #', Strings.toString(id),
                '","description":"Demo escrowed asset (no image set)."}');
        }
        return string.concat('data:application/json,{"name":"', _esc(m.name), '","description":"', _esc(m.description),
            '","image":"', _esc(m.image), '"}');
    }

    /// @dev Minimal JSON-string escaping for attacker-controlled input (unlike CreditPassport's tokenURI,
    ///      whose fields are plain integers) — quotes and backslashes would otherwise break out of the
    ///      surrounding JSON string. Informational metadata only; nothing in the escrow reads it.
    function _esc(string memory s) private pure returns (string memory) {
        bytes memory b = bytes(s);
        bytes memory out = new bytes(b.length * 2);
        uint256 j;
        for (uint256 i; i < b.length; i++) {
            if (b[i] == '"' || b[i] == "\\") out[j++] = "\\";
            out[j++] = b[i];
        }
        bytes memory trimmed = new bytes(j);
        for (uint256 k; k < j; k++) trimmed[k] = out[k];
        return string(trimmed);
    }
}

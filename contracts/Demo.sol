// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

/// @dev Demo-only stand-ins. Real USDC on Sepolia is rationed; swapping the address is zero code change.
contract TestUSDC is ERC20("Test USDC", "tUSDC") {
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract DemoAsset is ERC721("PayGo Demo Asset", "PGA") {
    uint256 public next = 1;
    function mint(address to) external returns (uint256 id) { id = next++; _mint(to, id); }
}

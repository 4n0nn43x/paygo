// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Test} from "forge-std/Test.sol";
import {DemoAsset} from "../contracts/Demo.sol";

contract DemoAssetTest is Test {
    DemoAsset nft;
    address seller = address(0x5E11E2);

    function setUp() public { nft = new DemoAsset(); }

    function test_plainMint_getsGenericTokenURI() public {
        uint256 id = nft.mint(seller);
        assertEq(nft.tokenURI(id), 'data:application/json,{"name":"PayGo Demo Asset #1","description":"Demo escrowed asset (no image set)."}');
    }

    function test_mintWithMeta_tokenURIReflectsRealMetadata() public {
        uint256 id = nft.mintWithMeta(seller, "1978 Vespa", "Restored, original engine", "https://example.com/vespa.jpg");
        assertEq(nft.ownerOf(id), seller);
        assertEq(nft.tokenURI(id), 'data:application/json,{"name":"1978 Vespa","description":"Restored, original engine","image":"https://example.com/vespa.jpg"}');
    }

    function test_tokenURI_revertsForUnmintedToken() public {
        vm.expectRevert();
        nft.tokenURI(999);
    }

    // Regression: attacker-controlled name/description/image must not break out of the JSON string.
    function test_mintWithMeta_escapesQuotesAndBackslashes() public {
        uint256 id = nft.mintWithMeta(seller, 'Fake","image":"https://evil.example/x.jpg', "desc", "img");
        string memory uri = nft.tokenURI(id);
        assertEq(uri, 'data:application/json,{"name":"Fake\\",\\"image\\":\\"https://evil.example/x.jpg","description":"desc","image":"img"}');
    }
}

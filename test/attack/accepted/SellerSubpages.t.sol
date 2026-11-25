// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {AcceptedBase} from "./AcceptedBase.sol";

// A sale moves the parent and nothing under it. Subpages the seller made for itself stay with the seller and keep
// answering the seller's addresses, payment entries included, under the name the buyer now holds, until the buyer
// mints over each one.
contract AcceptedSellerSubpagesTest is AcceptedBase {
    uint256 constant BTC = 0;

    function test_sellersSubpageKeepsAnsweringTheSellerUntilReminted() public {
        uint256 shop = _buy(alice, "shop", alice, 0);
        vm.startPrank(alice);
        uint256 pay = nft.registerSubpage("pay", shop);
        nft.setAddrForCoin(pay, BTC, bytes("bc1qalice"));
        nft.setText(pay, "url", "https://alice.example");
        nft.transferFrom(alice, bob, shop);
        vm.stopPrank();

        assertEq(nft.ownerOf(shop), bob);
        assertEq(nft.ownerOf(pay), alice, "the subpage stays with the seller");
        assertEq(nft.getPageName(pay), "pay.shop");
        assertEq(nft.resolve(pay), alice, "pay.shop still pays the seller");
        assertEq(nft.addr(pay, 0x8000000a), abi.encodePacked(alice));
        // the seller saved nothing for coin type 60 and no default, so it answers empty
        assertEq(nft.addr(pay, 60).length, 0);
        assertEq(nft.addr(pay, BTC), bytes("bc1qalice"));
        assertEq(nft.text(pay, "url"), "https://alice.example");
        // the seller can still change where it pays
        vm.prank(alice);
        nft.setAddr(pay, hot);
        assertEq(nft.resolve(pay), hot);

        // the buyer mints over it once it knows the label, and every answer is then its own
        vm.prank(bob);
        nft.registerSubpage("pay", shop);
        assertEq(nft.ownerOf(pay), bob);
        assertEq(nft.resolve(pay), bob);
        assertEq(nft.addr(pay, BTC).length, 0);
        assertEq(nft.text(pay, "url"), "");
    }
}

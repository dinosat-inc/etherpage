// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Base64} from "solady/utils/Base64.sol";
import {LibString} from "solady/utils/LibString.sol";
import {PageNFT} from "../../../src/PageNFT.sol";
import {PageCard} from "../../../src/PageCard.sol";
import {EdgesBase} from "./EdgesBase.sol";

// a renderer whose card is its own arguments, abi encoded, so the image of tokenURI tells what it was asked to draw
// (the constructor's probe gets 256 bytes, so the deployment passes)
contract ArgumentsCard {
    function render(string memory label, string memory parentLabel, bytes32 id, PageCard.Status status, uint256 expiry)
        external
        pure
        returns (string memory)
    {
        return string(abi.encode(label, parentLabel, id, status, expiry));
    }

    function shortAddress(address) external pure returns (string memory) {
        return "0x0000...0000";
    }
}

// tokenURI asks the card for the image of a page with five arguments. The card of this release reads the expiry only
// for an Active top level page, so its image is the same whatever expiry a subpage or an Invalid page gets. Here
// PageNFT is deployed with a card that draws its arguments, and tokenURI gives them back: a subpage gets the expiry of
// its parent, and an Invalid page gets expiry 0.
contract RenderArgumentsTest is EdgesBase {
    function setUp() public override {
        super.setUp();
        card = PageCard(address(new ArgumentsCard()));
        nft = new PageNFT(card);
    }

    // the arguments the card got for the image of tokenURI(id)
    function _drawn(uint256 id)
        internal
        view
        returns (string memory label, string memory parentLabel, bytes32 cardId, PageCard.Status st, uint256 expiry)
    {
        string memory json = _json(id);
        string memory head = '"image":"data:image/svg+xml;base64,';
        uint256 found = LibString.indexOf(json, head);
        assertTrue(found != LibString.NOT_FOUND, "the image of tokenURI");
        uint256 start = found + bytes(head).length;
        uint256 end = LibString.indexOf(json, '"', start);
        assertTrue(end != LibString.NOT_FOUND, "the end of the image");
        bytes memory drawn = Base64.decode(LibString.slice(json, start, end));
        (label, parentLabel, cardId, st, expiry) =
            abi.decode(drawn, (string, string, bytes32, PageCard.Status, uint256));
    }

    function _assertDrawn(
        uint256 id,
        string memory label,
        string memory parentLabel,
        PageCard.Status st,
        uint256 expiry,
        string memory what
    ) internal view {
        (string memory l, string memory pl, bytes32 i, PageCard.Status s, uint256 e) = _drawn(id);
        assertEq(l, label, string.concat(what, ": label"));
        assertEq(pl, parentLabel, string.concat(what, ": parent label"));
        assertEq(i, bytes32(id), string.concat(what, ": id"));
        assertEq(uint256(s), uint256(st), string.concat(what, ": status"));
        assertEq(e, expiry, string.concat(what, ": expiry"));
    }

    // a live subpage is drawn Active with the expiry of its parent, not the 0 of its own record
    function test_aLiveSubpageIsDrawnWithTheExpiryOfItsParent() public {
        uint256 parent = _buy(alice, "alpha", alice, 0);
        vm.prank(alice);
        uint256 sub = nft.registerSubpage("kid", parent);
        uint256 e = nft.expiresAt(parent);
        assertGt(e, block.timestamp, "the parent runs");
        assertEq(nft.expiresAt(sub), 0, "a subpage keeps no expiry of its own");
        _assertDrawn(parent, "alpha", "", PageCard.Status.Active, e, "the parent");
        _assertDrawn(sub, "kid", "alpha", PageCard.Status.Active, e, "the subpage");
    }

    // a subpage whose parent was registered again is drawn Invalid with expiry 0
    function test_aSubpageOfAParentRegisteredAgainIsDrawnInvalidWithExpiryZero() public {
        uint256 parent = _buy(alice, "alpha", alice, 0);
        vm.prank(alice);
        uint256 sub = nft.registerSubpage("kid", parent);
        vm.warp(nft.expiresAt(parent) + GRACE + DECAY + 1);
        _buy(bob, "alpha", bob, 0);
        assertEq(nft.epochOf(parent), 2, "the parent was registered again");
        assertEq(uint256(nft.status(sub)), uint256(PageCard.Status.Invalid), "the subpage is Invalid");
        _assertDrawn(sub, "kid", "alpha", PageCard.Status.Invalid, 0, "the subpage");
    }

    // a page held by the dead address is drawn Invalid with expiry 0, though its record still runs
    function test_aPageHeldByTheDeadAddressIsDrawnInvalidWithExpiryZero() public {
        uint256 id = _buy(alice, "alpha", alice, 0);
        vm.prank(alice);
        nft.transferFrom(alice, DEAD, id);
        assertGt(nft.expiresAt(id), block.timestamp, "its record still runs");
        _assertDrawn(id, "alpha", "", PageCard.Status.Invalid, 0, "the page");
    }
}

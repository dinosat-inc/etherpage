// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {PageNFT} from "../../src/PageNFT.sol";
import {RulesBase} from "../utils/RulesBase.sol";

// A display name never comes back under a new holder: it shows only while the name is held by the
// account that held it when the name was chosen.
contract DisplayRevivalTest is RulesBase {
    address stranger = makeAddr("stranger");
    address hot = makeAddr("hot");
    uint256 club;

    function setUp() public override {
        super.setUp();
        vm.deal(stranger, 10 ether);
        club = _buy(dave, "club");
    }

    function _sub(string memory label, address to) internal returns (uint256 id) {
        vm.prank(dave);
        id = nft.registerSubpageFor(label, club, to);
    }

    // E1: a stranger who buys a deleted subpage again through the registrar and points it at the old
    // holder does not revive the old holder's display name
    function test_E1_strangerCannotReviveOldHoldersDisplayName() public {
        uint256 id = _sub("bob", bob);
        vm.prank(bob);
        nft.setPrimaryPage(id);
        assertEq(nft.reverseResolve(bob), "bob.club");
        vm.prank(bob);
        nft.transferFrom(bob, DEAD, id);
        assertEq(nft.reverseResolve(bob), "");
        vm.startPrank(dave);
        nft.setSubpageMinter(club, address(shop));
        shop.configure(club, dave, address(0), 0.001 ether, true, address(0), 0, false);
        vm.stopPrank();
        vm.prank(stranger);
        shop.registerSubpage{value: 0.001 ether}(club, "bob", 0.001 ether, address(0));
        vm.startPrank(stranger);
        nft.setAddr(id, bob);
        nft.setText(id, "url", "https://phish.example");
        vm.stopPrank();
        assertEq(nft.ownerOf(id), stranger);
        assertEq(nft.primaryPage(bob), 0, "sending it to DEAD cleared bob's pointer");
        assertEq(nft.reverseResolve(bob), "", "nothing shows under the new holder");
        // even if bob had kept a pointer, the holder check hides it: a pointer set by a third account
        vm.prank(stranger);
        nft.setAddr(id, carol);
        vm.prank(carol);
        nft.setPrimaryPage(id);
        assertEq(nft.reverseResolve(carol), "bob.club");
        vm.prank(stranger);
        nft.transferFrom(stranger, dave, id);
        vm.prank(dave);
        nft.setAddr(id, carol);
        assertEq(nft.primaryPage(carol), id, "carol's pointer stays stored");
        assertEq(nft.reverseResolve(carol), "", "and stays hidden under the next holder");
    }

    // E1b: the same after an ordinary transfer
    function test_E1b_noRevivalAfterOrdinaryTransfer() public {
        uint256 id = _sub("bob", bob);
        vm.prank(bob);
        nft.setPrimaryPage(id);
        vm.prank(bob);
        nft.transferFrom(bob, carol, id);
        vm.prank(carol);
        nft.setAddr(id, bob);
        assertEq(nft.reverseResolve(bob), "");
        // only bob's own new choice, under the new holder, shows it again
        vm.prank(bob);
        nft.setPrimaryPage(id);
        assertEq(nft.reverseResolve(bob), "bob.club");
    }

    // a deleted subpage: the old saved address keeps its stored pointer, but a stranger who takes the
    // label and points it back at that address cannot make it show the name
    function test_atk08_deletedSubpageDoesNotReviveItsDisplayName() public {
        uint256 id = _sub("bob", bob);
        vm.prank(bob);
        nft.setAddr(id, carol);
        vm.prank(carol);
        nft.setPrimaryPage(id);
        assertEq(nft.reverseResolve(carol), "bob.club");
        vm.prank(bob);
        nft.transferFrom(bob, DEAD, id);
        assertEq(nft.reverseResolve(carol), "");
        vm.prank(dave);
        nft.setSubpageMinter(club, hot);
        vm.prank(hot);
        nft.registerSubpageFor("bob", club, stranger);
        vm.prank(stranger);
        nft.setAddr(id, carol);
        assertEq(nft.primaryPage(carol), id, "the stored pointer stays");
        assertEq(nft.reverseResolve(carol), "", "a new holder pointing at carol does not show her display name again");
    }
}

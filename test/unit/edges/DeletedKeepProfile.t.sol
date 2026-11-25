// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {PageNFT} from "../../../src/PageNFT.sol";
import {EdgesBase} from "./EdgesBase.sol";

// keepProfile checks activity before the caller, so on a subpage DEAD holds every caller, DEAD
// included, gets Expired and the profile's writer stays as it was. The same calls on the live subpage fail
// with Unauthorized or AlreadyKept instead.
contract DeletedKeepProfileTest is EdgesBase {
    uint256 club;
    uint256 sub;

    function setUp() public override {
        super.setUp();
        club = _buy(alice, "club", alice, 0);
        vm.prank(alice);
        nft.setSubpageMinter(club, hot);
        vm.prank(alice);
        sub = nft.registerSubpageFor("bob", club, bob);
        vm.prank(bob);
        nft.setText(sub, "url", "https://bob.example");
        vm.prank(bob);
        nft.approve(carol, sub);
        vm.prank(bob);
        nft.setApprovalForAll(dave, true);
    }

    function _expectExpired(address who, uint256 id) internal {
        vm.prank(who);
        vm.expectRevert(PageNFT.Expired.selector);
        nft.keepProfile(id);
    }

    function test_liveSubpageRefusesForOtherReasons() public {
        vm.prank(bob);
        vm.expectRevert(PageNFT.AlreadyKept.selector);
        nft.keepProfile(sub);
        address[5] memory who = [alice, carol, dave, hot, stranger];
        for (uint256 i; i < who.length; ++i) {
            vm.prank(who[i]);
            vm.expectRevert(PageNFT.Unauthorized.selector);
            nft.keepProfile(sub);
        }
    }

    // deleted by its holder: the holder, the parent's holder and minter, the accounts bob approved, a
    // stranger, DEAD and the contract itself all get Expired, and DEAD also in a bundle
    function test_keepProfileOnADeletedSubpageIsExpiredForEveryCaller() public {
        vm.prank(bob);
        nft.transferFrom(bob, DEAD, sub);
        address[8] memory who = [bob, alice, hot, carol, dave, stranger, DEAD, address(nft)];
        for (uint256 i; i < who.length; ++i) _expectExpired(who[i], sub);
        vm.prank(DEAD);
        vm.expectRevert(PageNFT.Expired.selector);
        nft.multicall(_one(abi.encodeCall(PageNFT.keepProfile, (sub))));
        assertEq(nft.profileWriter(sub), bob, "the writer stays");
        assertEq(nft.text(sub, "url"), "", "a deleted subpage answers no text");
    }

    function testFuzz_keepProfileOnADeletedSubpageIsExpired(address caller) public {
        vm.prank(bob);
        nft.transferFrom(bob, DEAD, sub);
        _expectExpired(caller, sub);
        assertEq(nft.profileWriter(sub), bob, "the writer stays");
    }

    // deleted by the parent's holder minting it again straight to DEAD: the stored writer is still bob, so
    // DEAD would pass both the holder and the AlreadyKept checks, and the activity check refuses it first
    function test_reMintToDeadRefusesDeadToo() public {
        vm.prank(alice);
        nft.registerSubpageFor("bob", club, DEAD);
        assertEq(nft.ownerOf(sub), DEAD);
        assertEq(nft.profileWriter(sub), bob);
        _expectExpired(DEAD, sub);
        _expectExpired(bob, sub);
        _expectExpired(alice, sub);
        assertEq(nft.profileWriter(sub), bob);
    }

    // minted straight to DEAD by the minter: no writer at all, and still Expired for DEAD
    function test_mintedToDeadRefusesDead() public {
        vm.prank(hot);
        uint256 gone = nft.registerSubpageFor("gone", club, DEAD);
        assertEq(nft.profileWriter(gone), address(0));
        _expectExpired(DEAD, gone);
        _expectExpired(hot, gone);
        _expectExpired(alice, gone);
        assertEq(nft.profileWriter(gone), address(0));
    }

    // the parent in grace or past it changes nothing for a deleted subpage
    function testFuzz_deletedUnderAnyParentClock(address caller, uint256 t) public {
        vm.prank(bob);
        nft.transferFrom(bob, DEAD, sub);
        t = bound(t, vm.getBlockTimestamp(), nft.expiresAt(club) + GRACE + DECAY + YEAR);
        vm.warp(t);
        _expectExpired(caller, sub);
    }
}

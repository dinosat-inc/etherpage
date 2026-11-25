// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {PageNFT} from "../../../src/PageNFT.sol";
import {PageCard} from "../../../src/PageCard.sol";

// The basic minter rules, and that a mint by the minter moves no money.
contract MinterRulesTest is Test {
    PageNFT nft;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address hot = makeAddr("hot");
    address carol = makeAddr("carol");

    function setUp() public {
        vm.warp(1_800_000_000);
        nft = new PageNFT(new PageCard());
        vm.deal(alice, 1000 ether);
        vm.deal(bob, 1000 ether);
    }

    function _reg(address who, string memory label) internal returns (uint256 id) {
        bytes32 secret = keccak256(abi.encode(who, label, block.timestamp));
        bytes32 commitment = nft.makeCommitment(label, who, 0, secret);
        vm.prank(who);
        nft.commit(commitment);
        vm.warp(block.timestamp + 61);
        (,,, uint256 total) = nft.quote(label);
        vm.prank(who);
        id = nft.reveal{value: total}(label, who, 0, secret);
    }

    function test_minterRulesAndNoMoney() public {
        uint256 club = _reg(alice, "club");
        uint256 dep = nft.depositOf(club);
        uint256 bal = address(nft).balance;
        vm.prank(alice);
        nft.setSubpageMinter(club, hot);

        vm.prank(hot);
        uint256 a = nft.registerSubpageFor("a", club, carol);
        assertEq(nft.ownerOf(a), carol);
        assertEq(nft.depositOf(club), dep);
        assertEq(nft.depositOf(a), 0);
        assertEq(address(nft).balance, bal);
        assertEq(nft.owed(hot), 0);

        vm.prank(hot);
        vm.expectRevert(PageNFT.AlreadyRegistered.selector);
        nft.registerSubpageFor("a", club, hot);
        // a bad label is InvalidLabel for the minter too, before any parent check
        vm.prank(hot);
        vm.expectRevert(PageNFT.InvalidLabel.selector);
        nft.registerSubpageFor("-bad", club, hot);
        // one level: the minter cannot mint under a subpage, NotTopLevel first
        vm.prank(hot);
        vm.expectRevert(PageNFT.NotTopLevel.selector);
        nft.registerSubpageFor("deep", a, hot);
        // the owner overwrites
        vm.prank(alice);
        nft.registerSubpageFor("a", club, alice);
        assertEq(nft.ownerOf(a), alice);

        // off on transfer
        vm.prank(alice);
        nft.transferFrom(alice, bob, club);
        vm.prank(hot);
        vm.expectRevert(PageNFT.NotParentOwner.selector);
        nft.registerSubpageFor("b", club, hot);
        address cm = nft.subpageMinterOf(club);
        assertEq(cm, address(0));
    }

    function test_minterAfterExpiryAndReRegistration() public {
        uint256 club = _reg(alice, "club");
        vm.prank(alice);
        nft.setSubpageMinter(club, hot);
        uint256 exp = nft.expiresAt(club);
        vm.warp(exp + 1);
        vm.prank(hot);
        vm.expectRevert(PageNFT.Expired.selector);
        nft.registerSubpageFor("b", club, hot);
        // well past grace and the premium, alice registers again: the earlier pick is gone
        vm.warp(exp + 200 days);
        _reg(alice, "club");
        address cm = nft.subpageMinterOf(club);
        assertEq(cm, address(0));
        vm.prank(hot);
        vm.expectRevert(PageNFT.NotParentOwner.selector);
        nft.registerSubpageFor("b", club, hot);
    }
}

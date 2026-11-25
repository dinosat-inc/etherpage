// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {PageNFT} from "../../../src/PageNFT.sol";
import {EdgesBase} from "./EdgesBase.sol";

// Refusals that the campaigns predict, made here by name: a transfer to PageNFT itself on every path and by every
// mover, a withdrawal for the zero address, a release of an id with no record, and a mint under a subpage with
// any label, whose label check comes first.
contract DirectedRefusalsTest is EdgesBase {
    bytes4 constant TOKEN_DOES_NOT_EXIST = 0xceea21b6; // TokenDoesNotExist()

    uint256 parent;
    uint256 sub;

    function setUp() public override {
        super.setUp();
        parent = _buy(alice, "alpha", alice, 0);
        vm.startPrank(alice);
        sub = nft.registerSubpage("bob", parent);
        nft.setSubpageMinter(parent, dave);
        vm.stopPrank();
    }

    function test_transferToPageNFTRevertsOnEveryPath() public {
        vm.startPrank(alice);
        nft.approve(carol, parent);
        nft.setApprovalForAll(dave, true);
        vm.stopPrank();
        address target = address(nft);
        address[3] memory movers = [alice, carol, dave];
        uint256[2] memory ids = [parent, sub];
        for (uint256 k; k < ids.length; ++k) {
            uint256 id = ids[k];
            for (uint256 i; i < movers.length; ++i) {
                // carol is approved for the parent only
                if (movers[i] == carol && id != parent) continue;
                vm.prank(movers[i]);
                vm.expectRevert(PageNFT.InvalidRecipient.selector);
                nft.transferFrom(alice, target, id);
                vm.prank(movers[i]);
                vm.expectRevert(PageNFT.InvalidRecipient.selector);
                nft.safeTransferFrom(alice, target, id);
                vm.prank(movers[i]);
                vm.expectRevert(PageNFT.InvalidRecipient.selector);
                nft.safeTransferFrom(alice, target, id, "data");
            }
            assertEq(nft.ownerOf(id), alice, "nothing moved");
        }
        assertEq(nft.balanceOf(address(nft)), 0, "PageNFT holds no name");
        assertEq(nft.getApproved(parent), carol, "the approval stays");
    }

    // after money went to DEAD, to a payee and to a trial payer, nothing is owed to the zero address
    function test_zeroAddressHasNothingToWithdraw() public {
        uint256 id = _buy(bob, "beta", bob, 0);
        uint256 trial = _trial(relayer, "gamma", carol, 0);
        vm.warp(nft.expiresAt(id) + GRACE + 1);
        // a purchase with a premium and no referrer credits DEAD a quarter of it and bob the rest with the deposit
        _buy(stranger, "beta", stranger, 0);
        nft.release(trial);
        assertEq(nft.owed(address(0)), 0, "nothing is owed to the zero address");
        assertGt(nft.owed(DEAD), 0, "DEAD holds the referrer share");
        assertGt(nft.owed(bob), 0);
        assertGt(nft.owed(relayer), 0);
        uint256 balance = address(nft).balance;
        vm.recordLogs();
        vm.prank(stranger);
        vm.expectRevert(PageNFT.NothingToWithdraw.selector);
        nft.withdraw(address(0));
        assertEq(vm.getRecordedLogs().length, 0, "nothing is logged");
        assertEq(address(nft).balance, balance);
    }

    // any id with no record reverts TokenDoesNotExist on release and is not releasable
    function testFuzz_releaseOfAnIdWithNoRecordReverts(uint256 id) public {
        (string memory stored,,,,) = nft.records(id);
        vm.assume(bytes(stored).length == 0);
        uint256 dead = nft.owed(DEAD);
        vm.prank(stranger);
        vm.expectRevert(TOKEN_DOES_NOT_EXIST);
        nft.release(id);
        assertFalse(nft.isReleasable(id));
        assertEq(nft.owed(DEAD), dead);
        assertEq(nft.depositOf(id), 0);
    }

    // a mint under a subpage by alice, who holds it and its parent, by the parent's minter or by two accounts with no
    // role: a label the validator refuses gives its own error, any other label NotTopLevel
    function testFuzz_mintUnderASubpageChecksTheLabelFirst(string memory label, uint8 who) public {
        address[4] memory callers = [bob, alice, dave, stranger];
        address caller = callers[who % 4];
        bytes memory expected = abi.encodeWithSelector(PageNFT.NotTopLevel.selector);
        try nft.normalize(label) returns (string memory) {}
        catch (bytes memory err) {
            expected = err;
        }
        vm.prank(caller);
        (bool ok, bytes memory ret) =
            address(nft).call(abi.encodeCall(PageNFT.registerSubpageFor, (label, sub, caller)));
        assertFalse(ok);
        assertEq(ret, expected, "the label error first, then NotTopLevel");
        vm.prank(caller);
        (ok, ret) = address(nft).call(abi.encodeCall(PageNFT.registerSubpage, (label, sub)));
        assertFalse(ok);
        assertEq(ret, expected);
    }

    // the same with labels that pass the validator, so every run reaches the top level check
    function testFuzz_mintUnderASubpageWithAValidLabelIsNotTopLevel(uint256 seed, uint8 who) public {
        bytes memory b = new bytes(1 + seed % 63);
        // no x, so no label reads as an address and every label passes the validator
        bytes memory set = "abcdefghijklmnopqrstuvwyz0123456789";
        for (uint256 i; i < b.length; ++i) b[i] = set[uint256(keccak256(abi.encode(seed, i))) % set.length];
        address[4] memory callers = [bob, alice, dave, stranger];
        address caller = callers[who % 4];
        vm.prank(caller);
        vm.expectRevert(PageNFT.NotTopLevel.selector);
        nft.registerSubpageFor(string(b), sub, caller);
        assertFalse(nft.isAvailable(string(b), sub), "no label is free under a subpage");
    }
}

// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Vm} from "forge-std/Test.sol";
import {PageCard} from "../../../src/PageCard.sol";
import {AcceptedBase} from "./AcceptedBase.sol";

// Minting a subpage over an existing record can change its holder, its payee and its metadata, with a burn, a
// mint and a SubpageRegistered but no ERC4906 MetadataUpdate; its two Transfer events are the signal to refresh
// it. A transfer and a top level registration over a lapsed name each emit one MetadataUpdate.
contract AcceptedRemintMetadataTest is AcceptedBase {
    bytes32 constant T_METADATA = keccak256("MetadataUpdate(uint256)");
    bytes32 constant T_TRANSFER = keccak256("Transfer(address,address,uint256)");
    bytes32 constant T_SUBPAGE = keccak256("SubpageRegistered(uint256,uint256,string)");

    uint256 parent;
    uint256 sub;

    function setUp() public override {
        super.setUp();
        parent = _buy(alice, "parent-name", alice, 0);
        vm.prank(alice);
        sub = nft.registerSubpageFor("bob", parent, bob);
    }

    // a burn from the old holder, then a mint to the new one, one SubpageRegistered and no MetadataUpdate
    function _assertRemintLogs(Vm.Log[] memory logs, address from, address to) internal pure {
        assertEq(_count(logs, T_METADATA), 0, "no MetadataUpdate");
        assertEq(_count(logs, T_SUBPAGE), 1);
        assertEq(_count(logs, T_TRANSFER), 2);
        uint256 seen;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length == 0 || logs[i].topics[0] != T_TRANSFER) continue;
            address f = address(uint160(uint256(logs[i].topics[1])));
            address t = address(uint160(uint256(logs[i].topics[2])));
            assertEq(f, seen == 0 ? from : address(0));
            assertEq(t, seen == 0 ? address(0) : to);
            ++seen;
        }
    }

    // the parent's holder takes a live subpage back for itself
    function test_takeBackEmitsNoMetadataUpdate() public {
        vm.recordLogs();
        vm.prank(alice);
        nft.registerSubpage("bob", parent);
        _assertRemintLogs(vm.getRecordedLogs(), bob, alice);
        assertEq(nft.ownerOf(sub), alice);
        assertEq(nft.payee(sub), alice);
    }

    // the parent's holder gives a live subpage to another account
    function test_reissueEmitsNoMetadataUpdate() public {
        vm.recordLogs();
        vm.prank(alice);
        nft.registerSubpageFor("bob", parent, carol);
        _assertRemintLogs(vm.getRecordedLogs(), bob, carol);
        assertEq(nft.ownerOf(sub), carol);
        assertEq(nft.payee(sub), carol);
    }

    // after the parent is registered again, its new holder mints over the stale subpage, whose card goes from
    // Invalid to Active
    function test_staleReplacementEmitsNoMetadataUpdate() public {
        vm.warp(nft.expiresAt(parent) + 90 days + 21 days + 1);
        _buy(stranger, "parent-name", stranger, 0);
        assertEq(uint256(nft.status(sub)), uint256(PageCard.Status.Invalid));
        vm.recordLogs();
        vm.prank(stranger);
        nft.registerSubpage("bob", parent);
        _assertRemintLogs(vm.getRecordedLogs(), bob, stranger);
        assertEq(uint256(nft.status(sub)), uint256(PageCard.Status.Active));
        assertEq(nft.payee(sub), stranger);
    }

    // moving the same subpage emits one
    function test_subpageTransferEmitsOneMetadataUpdate() public {
        vm.recordLogs();
        vm.prank(bob);
        nft.transferFrom(bob, carol, sub);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_count(logs, T_METADATA), 1);
        assertEq(_count(logs, T_TRANSFER), 1);
    }

    // registering the parent again over its lapsed record burns, mints and emits one
    function test_topLevelReRegistrationEmitsOneMetadataUpdate() public {
        vm.warp(nft.expiresAt(parent) + 90 days + 21 days + 1);
        _commitPaid(stranger, "parent-name", stranger, 0);
        vm.warp(vm.getBlockTimestamp() + 61);
        (,,, uint256 total) = nft.quote("parent-name");
        bytes32 s = _secret("parent-name", stranger);
        vm.recordLogs();
        vm.prank(stranger);
        nft.reveal{value: total}("parent-name", stranger, 0, s);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_count(logs, T_METADATA), 1);
        assertEq(_count(logs, T_TRANSFER), 2);
    }
}

// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Vm} from "forge-std/Test.sol";
import {PageNFT} from "../../../src/PageNFT.sol";
import {EdgesBase} from "./EdgesBase.sol";

// A live unpaid trial moves only to DEAD. A transfer to its own holder reverts Unpaid like
// a transfer to anyone else, whoever sends it, and an ended trial reverts Expired. Once a renewal pays the
// trial it moves freely, and a transfer to its own holder then emits Transfer alone.
contract TrialSelfTransferTest is EdgesBase {
    uint256 id;
    uint256 e;

    function setUp() public override {
        super.setUp();
        id = _trial(relayer, "alpha", alice, 0);
        e = nft.expiresAt(id);
        vm.startPrank(alice);
        nft.approve(carol, id);
        nft.setApprovalForAll(dave, true);
        nft.setPrimaryPage(id);
        vm.stopPrank();
    }

    // a move from alice to `to` through the three transfer functions by `caller`, each expected to revert
    function _expectAllRevert(address caller, address to, bytes4 err) internal {
        vm.prank(caller);
        vm.expectRevert(err);
        nft.transferFrom(alice, to, id);
        vm.prank(caller);
        vm.expectRevert(err);
        nft.safeTransferFrom(alice, to, id);
        vm.prank(caller);
        vm.expectRevert(err);
        nft.safeTransferFrom(alice, to, id, "data");
    }

    function testFuzz_liveTrialCannotMoveToItsOwnHolder(uint256 t) public {
        t = bound(t, vm.getBlockTimestamp(), e);
        vm.warp(t);
        _expectAllRevert(alice, alice, PageNFT.Unpaid.selector);
        _expectAllRevert(carol, alice, PageNFT.Unpaid.selector);
        _expectAllRevert(dave, alice, PageNFT.Unpaid.selector);
        bytes memory self = abi.encodeWithSignature("transferFrom(address,address,uint256)", alice, alice, id);
        vm.prank(alice);
        vm.expectRevert(PageNFT.Unpaid.selector);
        nft.multicall(_one(self));
        assertEq(nft.ownerOf(id), alice);
        assertEq(nft.getApproved(id), carol, "the approval stays");
        assertEq(nft.primaryPage(alice), id, "the display name stays");
    }

    function testFuzz_liveTrialMovesOnlyToDead(address to, uint256 t) public {
        // the zero address and the contract itself are refused by other checks first
        vm.assume(to != DEAD && to != address(0) && to != address(nft));
        t = bound(t, vm.getBlockTimestamp(), e);
        vm.warp(t);
        _expectAllRevert(alice, to, PageNFT.Unpaid.selector);
        _expectAllRevert(dave, to, PageNFT.Unpaid.selector);
        vm.prank(carol);
        nft.transferFrom(alice, DEAD, id);
        assertEq(nft.ownerOf(id), DEAD);
    }

    // past its last second the trial is inactive, so every move, its own holder and DEAD included, is Expired
    function test_endedTrialSelfTransferRevertsExpired() public {
        vm.warp(e);
        _expectAllRevert(alice, alice, PageNFT.Unpaid.selector);
        vm.warp(e + 1);
        _expectAllRevert(alice, alice, PageNFT.Expired.selector);
        _expectAllRevert(alice, DEAD, PageNFT.Expired.selector);
        _expectAllRevert(alice, bob, PageNFT.Expired.selector);
    }

    function testFuzz_convertedTrialMovesFreely(address to, uint256 t) public {
        vm.assume(to != address(0) && to != address(nft));
        t = bound(t, vm.getBlockTimestamp(), e);
        vm.warp(t);
        uint256 fee = nft.getFee(5);
        vm.prank(stranger);
        nft.renew{value: fee}(id);

        vm.recordLogs();
        vm.prank(alice);
        nft.transferFrom(alice, alice, id);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "a self transfer emits Transfer alone");
        assertEq(logs[0].topics[0], keccak256("Transfer(address,address,uint256)"));
        assertEq(nft.ownerOf(id), alice);
        assertEq(nft.primaryPage(alice), id, "the display name stays");

        vm.prank(dave);
        nft.transferFrom(alice, to, id);
        assertEq(nft.ownerOf(id), to);
    }
}

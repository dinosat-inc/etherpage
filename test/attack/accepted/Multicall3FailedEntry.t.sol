// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {IMulticall3} from "forge-std/interfaces/IMulticall3.sol";
import {PageNFT} from "../../../src/PageNFT.sol";
import {AcceptedBase} from "./AcceptedBase.sol";

// Multicall3 keeps no account of who sent the value of a batch. Through aggregate3Value with allowFailure true, a
// reveal entry that fails does not revert the batch, so its whole value stays in Multicall3: the relayer loses it,
// PageNFT holds and credits none of it, and the commitment survives. Multicall3 adds the entry values without an
// overflow check, so anyone takes that value out with a batch whose values add up to 2^256 plus the value it sends,
// which wraps to what it sends.
contract AcceptedMulticall3FailedEntryTest is AcceptedBase {
    address u1 = makeAddr("u1");
    address u2 = makeAddr("u2");
    address u3 = makeAddr("u3");

    function setUp() public override {
        super.setUp();
        _etchMulticall3();
    }

    // a reveal of label for owner sent with value, whose failure is allowed
    function _entry(string memory label, address owner, uint256 value)
        internal
        view
        returns (IMulticall3.Call3Value memory)
    {
        return IMulticall3.Call3Value(
            address(nft), true, value, abi.encodeCall(PageNFT.reveal, (label, owner, 0, _secret(label, owner)))
        );
    }

    function test_failedRevealEntriesLeaveTheirWholeValueInMulticall3() public {
        _commitPaid(relayer, "overpaid", u1, 0);
        _commitPaid(relayer, "exact", u3, 0);
        vm.warp(vm.getBlockTimestamp() + 61);
        // committed now, so its reveal in the same block is too new
        _commitPaid(relayer, "too-new", u2, 0);
        (,,, uint256 p1) = nft.quote("overpaid");
        (,,, uint256 p2) = nft.quote("too-new");
        (,,, uint256 p3) = nft.quote("exact");

        IMulticall3.Call3Value[] memory calls = new IMulticall3.Call3Value[](3);
        calls[0] = _entry("overpaid", u1, p1 + 1 ether);
        calls[1] = _entry("too-new", u2, p2);
        calls[2] = _entry("exact", u3, p3);
        uint256 sum = p1 + 1 ether + p2 + p3;

        uint256 relayerBefore = relayer.balance;
        uint256 nftBefore = address(nft).balance;
        vm.prank(relayer);
        IMulticall3.Result[] memory res = IMulticall3(MULTICALL3).aggregate3Value{value: sum}(calls);

        // the overpaid reveal fails on its refund to Multicall3, the early one on its commitment, the exact one lands
        assertFalse(res[0].success, "the overpaid entry failed");
        assertEq(bytes4(res[0].returnData), ETH_TRANSFER_FAILED);
        assertFalse(res[1].success, "the early entry failed");
        assertEq(bytes4(res[1].returnData), PageNFT.CommitmentTooNew.selector);
        assertTrue(res[2].success, "the exact entry landed");
        assertEq(nft.ownerOf(nft.computeId("exact")), u3);

        uint256 stuck = p1 + 1 ether + p2;
        assertEq(MULTICALL3.balance, stuck, "the whole value of both failed entries stays in Multicall3");
        assertEq(relayerBefore - relayer.balance, sum, "the relayer paid the whole batch");
        assertEq(address(nft).balance - nftBefore, p3, "PageNFT keeps only the price of the entry that landed");
        assertEq(nft.owed(relayer), 0, "nothing is credited to the relayer");
        assertEq(nft.owed(MULTICALL3), 0, "nor to Multicall3");
        assertTrue(nft.isAvailable("overpaid", 0), "nothing registered");
        assertTrue(nft.isAvailable("too-new", 0));
        bytes32 c1 = nft.makeCommitment("overpaid", u1, 0, _secret("overpaid", u1));
        bytes32 c2 = nft.makeCommitment("too-new", u2, 0, _secret("too-new", u2));
        assertGt(nft.commitments(c1), 0, "the commitments survive");
        assertGt(nft.commitments(c2), 0);

        // anyone takes it out: one entry sends the value to the stranger, and a second that cannot be paid brings the
        // sum of the values to 2^256, which wraps to the zero the stranger sends
        IMulticall3.Call3Value[] memory sweep = new IMulticall3.Call3Value[](2);
        sweep[0] = IMulticall3.Call3Value(stranger, false, stuck, "");
        sweep[1] = IMulticall3.Call3Value(stranger, true, type(uint256).max - stuck + 1, "");
        uint256 strangerBefore = stranger.balance;
        vm.prank(stranger);
        IMulticall3.Result[] memory out = IMulticall3(MULTICALL3).aggregate3Value{value: 0}(sweep);
        assertTrue(out[0].success);
        assertFalse(out[1].success, "the entry that cannot be paid fails");
        assertEq(stranger.balance - strangerBefore, stuck, "the stranger took the relayer's value");
        assertEq(MULTICALL3.balance, 0);
    }
}

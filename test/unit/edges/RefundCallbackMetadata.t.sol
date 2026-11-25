// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Vm} from "forge-std/Test.sol";
import {PageNFT} from "../../../src/PageNFT.sol";
import {EdgesBase} from "./EdgesBase.sol";
import {LogShapes} from "../../utils/LogShapes.sol";
import {trialCommitment} from "../../utils/TrialCommitment.sol";

// A contract that registers a name for itself and acts on it from the receive that takes its excess. It has no
// receiver hook, which a mint to the caller never calls.
contract SelfRegistrant {
    PageNFT immutable nft;
    uint8 public action;
    address public target;
    uint256 public id;
    uint256 public refunds;

    constructor(PageNFT n) {
        nft = n;
    }

    // action 0 does nothing, 1 saves target as main address, 2 clears the records, 3 moves the name to target
    function arm(uint8 a, address t, uint256 tokenId) external {
        action = a;
        target = t;
        id = tokenId;
    }

    function commit(bytes32 c) external {
        nft.commit(c);
    }

    function reveal(string calldata label, bytes32 secret, uint256 value) external returns (uint256) {
        return nft.reveal{value: value}(label, address(this), 0, secret);
    }

    function revealTrial(string calldata label, bytes32 secret, uint256 value) external returns (uint256) {
        return nft.revealTrial{value: value}(label, address(this), 0, secret);
    }

    receive() external payable {
        ++refunds;
        if (action == 1) nft.setAddr(id, target);
        else if (action == 2) nft.clearRecords(id);
        else if (action == 3) nft.transferFrom(address(this), target, id);
    }
}

// A registration emits MetadataUpdate once, right after PageRegistered, as its last event. A contract that
// registers for itself and overpays gets its excess back after that MetadataUpdate, and a call it makes on the
// name from the receive that takes the excess adds that call's own events, its MetadataUpdate included, right
// after the registration's MetadataUpdate, with nothing of the registration after them.
contract RefundCallbackMetadataTest is EdgesBase {
    // registers label for a fresh SelfRegistrant armed with action and target, paying the price plus extra;
    // returns the registrant, the id and the logs of the reveal
    function _register(string memory label, uint8 action, address target, uint256 extra, bool trial)
        internal
        returns (SelfRegistrant r, uint256 id, Vm.Log[] memory logs)
    {
        r = new SelfRegistrant(nft);
        vm.deal(address(r), 10 ether);
        id = nft.computeId(label);
        r.arm(action, target, id);
        bytes32 secret = keccak256(abi.encode("self", label));
        bytes32 c = trial
            ? trialCommitment(address(nft), label, address(r), 0, secret)
            : nft.makeCommitment(label, address(r), 0, secret);
        r.commit(c);
        vm.warp(vm.getBlockTimestamp() + 61);
        uint256 price = nft.getFee(bytes(label).length);
        if (trial) price /= 10;
        vm.recordLogs();
        if (trial) r.revealTrial(label, secret, price + extra);
        else r.reveal(label, secret, price + extra);
        logs = vm.getRecordedLogs();
        assertEq(nft.ownerOf(id), action == 3 && extra != 0 ? target : address(r), "registered to the contract");
        assertEq(r.refunds(), extra == 0 ? 0 : 1, "the excess came back once");
    }

    // the logs of the registration of label for r, then room for extraLogs more; nothing is saved for coin type 60,
    // so that answer is empty
    function _registrationLogs(SelfRegistrant r, uint256 id, string memory label, bool trial, uint256 extraLogs)
        internal
        view
        returns (bytes32[] memory want)
    {
        uint256 price = nft.getFee(bytes(label).length);
        want = new bytes32[](8 + extraLogs);
        want[0] = LogShapes.referrerSet(id, 0);
        if (trial) {
            bytes32 started = keccak256("TrialStarted(uint256,address,uint256)");
            want[1] = keccak256(
                abi.encode(LogShapes.t3(started, bytes32(id), LogShapes.word(address(r))), abi.encode(price / 10))
            );
        } else {
            want[1] = LogShapes.depositAdded(id, address(r), price, price);
        }
        want[2] = LogShapes.transfer(address(0), address(r), id);
        LogShapes.trio(id, address(r), address(0), want, 3);
        want[6] = LogShapes.nameRegistered(id, label, address(r), nft.expiresAt(id));
        want[7] = LogShapes.meta(id);
    }

    function _assertLogs(Vm.Log[] memory logs, bytes32[] memory want, string memory which) internal view {
        assertEq(logs.length, want.length, string.concat(which, ": log count"));
        for (uint256 i; i < want.length; ++i) {
            assertEq(logs[i].emitter, address(nft), which);
            assertEq(LogShapes.hashOf(logs[i]), want[i], string.concat(which, ": log ", vm.toString(i)));
        }
    }

    function _metadataCount(Vm.Log[] memory logs) internal pure returns (uint256 n) {
        for (uint256 i; i < logs.length; ++i) if (logs[i].topics[0] == LogShapes.METADATA) ++n;
    }

    // paid exactly, nothing comes back and the MetadataUpdate after PageRegistered is the only one
    function test_exactPaymentEmitsOneMetadataUpdate() public {
        (SelfRegistrant r, uint256 id, Vm.Log[] memory logs) = _register("exact", 1, hot, 0, false);
        _assertLogs(logs, _registrationLogs(r, id, "exact", false, 0), "exact");
        assertEq(_metadataCount(logs), 1);
        assertEq(nft.resolve(id), address(r), "the receive never ran");
    }

    function test_refundCallbackSaveAddsItsMetadataUpdateAfterSiteTwo() public {
        (SelfRegistrant r, uint256 id, Vm.Log[] memory logs) = _register("saved", 1, hot, 1 ether, false);
        bytes32[] memory want = _registrationLogs(r, id, "saved", false, 4);
        // the save announces hot as the main address and coin type 60 empty, as r saved nothing for it
        LogShapes.trio(id, hot, address(0), want, 8);
        want[11] = LogShapes.meta(id);
        _assertLogs(logs, want, "save");
        assertEq(_metadataCount(logs), 2);
        assertEq(nft.resolve(id), hot);
    }

    function test_refundCallbackClearAddsItsMetadataUpdateAfterSiteTwo() public {
        (SelfRegistrant r, uint256 id, Vm.Log[] memory logs) = _register("clear", 2, address(0), 1 ether, false);
        bytes32[] memory want = _registrationLogs(r, id, "clear", false, 5);
        want[8] = LogShapes.version(id, 1);
        LogShapes.trio(id, address(r), address(0), want, 9);
        want[12] = LogShapes.meta(id);
        _assertLogs(logs, want, "clear");
        assertEq(_metadataCount(logs), 2);
        assertEq(nft.recordVersion(id), 1);
    }

    function test_refundCallbackMoveAddsItsMetadataUpdateAfterSiteTwo() public {
        (SelfRegistrant r, uint256 id, Vm.Log[] memory logs) = _register("moved", 3, bob, 1 ether, false);
        bytes32[] memory want = _registrationLogs(r, id, "moved", false, 5);
        want[8] = LogShapes.transfer(address(r), bob, id);
        // bob saved nothing for coin type 60, so the move announces it empty
        LogShapes.trio(id, bob, address(0), want, 9);
        want[12] = LogShapes.meta(id);
        _assertLogs(logs, want, "move");
        assertEq(_metadataCount(logs), 2);
        assertEq(nft.ownerOf(id), bob);
    }

    // a trial for itself: its excess too comes back after the registration's MetadataUpdate, and the save made then
    // follows it
    function test_trialRefundCallbackSaveAddsItsMetadataUpdateAfterSiteTwo() public {
        (SelfRegistrant r, uint256 id, Vm.Log[] memory logs) = _register("trial", 1, hot, 1 ether, true);
        bytes32[] memory want = _registrationLogs(r, id, "trial", true, 4);
        // the save announces hot as the main address and coin type 60 empty, as r saved nothing for it
        LogShapes.trio(id, hot, address(0), want, 8);
        want[11] = LogShapes.meta(id);
        _assertLogs(logs, want, "trial save");
        assertEq(_metadataCount(logs), 2);
        assertEq(nft.resolve(id), hot);
    }
}

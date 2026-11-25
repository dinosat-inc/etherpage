// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {trialCommitmentRaw} from "../utils/TrialCommitment.sol";

import {Test, Vm} from "forge-std/Test.sol";
import {PageNFT} from "../../src/PageNFT.sol";
import {PageCard} from "../../src/PageCard.sol";
import {PageNFTBurnedTrial} from "../differential/harness/PageNFTBurnedTrial.sol";

// Gas of the main paths in PageNFTBurnedTrial, a reference that burns the trial price, logged as base,
// and in PageNFT, logged as nft. Run with the isolate option so every call is its own transaction
// and cold storage is counted as on chain; each figure is vm.lastCallGas().gasTotalUsed of the call.
contract TrialMoneyGasTest is Test {
    PageNFTBurnedTrial base;
    PageNFT nft;
    address user = makeAddr("user");
    address relayer = makeAddr("relayer");
    address bob = makeAddr("bob");

    function setUp() public {
        vm.warp(1_800_000_000);
        PageCard card = new PageCard();
        base = new PageNFTBurnedTrial(card);
        nft = new PageNFT(card);
        vm.deal(user, 100 ether);
        vm.deal(relayer, 100 ether);
        vm.deal(bob, 100 ether);
    }

    function _s(string memory l, address o) internal pure returns (bytes32) {
        return keccak256(abi.encode(l, o));
    }

    function _gas() internal view returns (uint256) {
        return vm.lastCallGas().gasTotalUsed;
    }

    function _commit(address w, address from, string memory l, address o, bool trial) internal {
        bytes32 c = PageNFT(w).makeCommitment(l, o, 0, _s(l, o));
        vm.prank(from);
        PageNFT(w).commit(trial ? trialCommitmentRaw(l, o, 0, _s(l, o)) : c);
    }

    function _reveal(address w, address from, string memory l, address o, uint256 v) internal returns (uint256) {
        vm.prank(from);
        PageNFT(w).reveal{value: v}(l, o, 0, _s(l, o));
        return _gas();
    }

    function _trialCall(address w, address from, string memory l, address o, uint256 v) internal returns (uint256) {
        vm.prank(from);
        PageNFT(w).revealTrial{value: v}(l, o, 0, _s(l, o));
        return _gas();
    }

    function _renew(address w, address from, uint256 id, uint256 v) internal returns (uint256) {
        vm.prank(from);
        PageNFT(w).renew{value: v}(id);
        return _gas();
    }

    function test_gas() public {
        address[2] memory ws = [address(base), address(nft)];
        string[2] memory tag = ["base", "nft"];
        uint256 id = nft.computeId("alpha");
        uint256 tid = nft.computeId("trial");
        for (uint256 i; i < 2; ++i) {
            address w = ws[i];
            _commit(w, user, "alpha", user, false);
            _commit(w, relayer, "trial", user, true);
        }
        vm.warp(block.timestamp + 61);
        for (uint256 i; i < 2; ++i) {
            address w = ws[i];
            emit log_named_uint(string.concat(tag[i], ": paid reveal of a fresh name"), _reveal(w, user, "alpha", user, 0.0001 ether));
            emit log_named_uint(string.concat(tag[i], ": renew of a paid name"), _renew(w, bob, id, 0.0001 ether));
            emit log_named_uint(string.concat(tag[i], ": trial of a fresh name"), _trialCall(w, relayer, "trial", user, 0.00001 ether));
            vm.prank(user);
            PageNFT(w).setPrimaryPage(id);
            emit log_named_uint(string.concat(tag[i], ": setPrimaryPage"), _gas());
            vm.prank(user);
            PageNFT(w).transferFrom(user, bob, id);
            emit log_named_uint(string.concat(tag[i], ": transferFrom that clears the display name"), _gas());
        }
        uint256 snap = vm.snapshotState();
        for (uint256 i; i < 2; ++i) {
            emit log_named_uint(string.concat(tag[i], ": renew converting a trial"), _renew(ws[i], bob, tid, 0.0001 ether));
        }
        vm.revertToState(snap);
        // after the trial ends: release of the trial money and its withdraw (PageNFT only), then, from the state
        // before the release, a paid reveal over the ended trial
        uint256 end = nft.expiresAt(tid);
        vm.warp(end - 1 hours);
        for (uint256 i; i < 2; ++i) _commit(ws[i], bob, "trial", bob, false);
        vm.warp(end + 1);
        snap = vm.snapshotState();
        vm.prank(bob);
        nft.release(tid);
        emit log_named_uint("nft: release of an ended trial's money", _gas());
        vm.prank(relayer);
        nft.withdraw(relayer);
        emit log_named_uint("nft: withdraw of the trial money", _gas());
        vm.revertToState(snap);
        for (uint256 i; i < 2; ++i) {
            emit log_named_uint(string.concat(tag[i], ": paid reveal over an ended trial"), _reveal(ws[i], bob, "trial", bob, 0.0001 ether));
        }
        vm.revertToState(snap);
        // a new trial after the pause
        vm.warp(end + 14 days - 1 hours);
        for (uint256 i; i < 2; ++i) _commit(ws[i], relayer, "trial", bob, true);
        vm.warp(end + 14 days + 1);
        for (uint256 i; i < 2; ++i) {
            emit log_named_uint(string.concat(tag[i], ": trial over an ended trial after the pause"), _trialCall(ws[i], relayer, "trial", bob, 0.00001 ether));
        }
    }
}

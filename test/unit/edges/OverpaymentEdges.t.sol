// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Vm} from "forge-std/Test.sol";
import {PageNFT} from "../../../src/PageNFT.sol";
import {EdgesBase} from "./EdgesBase.sol";
import {trialCommitment} from "../../utils/TrialCommitment.sol";

// makes calls as itself and has no receive, so any ETH sent to it fails
contract PlainPayer {
    function exec(address to, uint256 value, bytes calldata data) external returns (bytes memory) {
        (bool ok, bytes memory ret) = to.call{value: value}(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        return ret;
    }
}

// What an overpayment does and does not do. The excess goes back to the caller in the same call, so a payer that
// refuses ETH reverts its own overpaid trial and keeps its commitment; any value up to 200 ether is charged exactly
// the price; and an overpaid purchase, trial or renewal logs exactly what the exact one logs.
contract OverpaymentEdgesTest is EdgesBase {
    bytes4 constant ETH_TRANSFER_FAILED = 0xb12d13eb; // ETHTransferFailed()

    function test_overpaidTrialFromAPayerThatRefusesEthReverts() public {
        PlainPayer p = new PlainPayer();
        vm.deal(address(p), 1 ether);
        bytes32 s = _secret("alpha", alice, 0);
        bytes32 c = trialCommitment(address(nft), "alpha", alice, 0, s);
        p.exec(address(nft), 0, abi.encodeCall(PageNFT.commit, (c)));
        vm.warp(vm.getBlockTimestamp() + 61);
        uint256 price = _trialPrice("alpha");
        bytes memory call = abi.encodeCall(PageNFT.revealTrial, ("alpha", alice, 0, s));

        vm.expectRevert(ETH_TRANSFER_FAILED);
        p.exec(address(nft), price + 1, call);
        assertGt(nft.commitments(c), 0, "the commitment survives");
        assertTrue(nft.isAvailable("alpha", 0), "nothing was registered");
        assertEq(address(p).balance, 1 ether, "nothing was taken");

        uint256 id = abi.decode(p.exec(address(nft), price, call), (uint256));
        assertEq(nft.ownerOf(id), alice, "the exact price starts the trial");
        (address payer, uint256 held) = _held(id);
        assertEq(payer, address(p));
        assertEq(held, price);
        assertEq(address(p).balance, 1 ether - price);
    }

    // at a zero gas price each payer's balance falls by exactly the price, whatever it sends up to 200 ether: an
    // auction purchase at any second of its window or after it, a trial and a renewal
    function testFuzz_overpaymentUpTo200EtherChargesExactlyThePrice(uint256 a, uint256 b, uint256 c, uint256 t) public {
        vm.txGasPrice(0);
        uint256 id = _buy(carol, "alpha", carol, 0);
        uint256 g = nft.expiresAt(id) + GRACE;
        t = bound(t, g + 1, g + DECAY + 30 days);
        vm.warp(t - 61);
        _commitPaid(bob, "alpha", bob, 0);
        vm.warp(t);
        (,,, uint256 total) = nft.quote("alpha");
        uint256 v = bound(a, total, 200 ether);
        vm.deal(bob, 200 ether);
        uint256 kept = address(nft).balance;
        bytes32 s = _secret("alpha", bob, 0);
        vm.prank(bob);
        nft.reveal{value: v}("alpha", bob, 0, s);
        assertEq(200 ether - bob.balance, total, "the purchase keeps exactly the quote");
        assertEq(address(nft).balance - kept, total);

        _commitTrial(relayer, "beta", dave, 0);
        vm.warp(vm.getBlockTimestamp() + 61);
        uint256 price = _trialPrice("beta");
        v = bound(b, price, 200 ether);
        vm.deal(relayer, 200 ether);
        s = _secret("beta", dave, 0);
        vm.prank(relayer);
        nft.revealTrial{value: v}("beta", dave, 0, s);
        assertEq(200 ether - relayer.balance, price, "the trial keeps exactly its price");

        uint256 fee = nft.getFee(5);
        v = bound(c, fee, 200 ether);
        vm.deal(stranger, 200 ether);
        vm.prank(stranger);
        nft.renew{value: v}(id);
        assertEq(200 ether - stranger.balance, fee, "the renewal keeps exactly the fee");

        assertEq(address(nft).balance, nft.depositOf(id) + price + nft.owed(carol) + nft.owed(DEAD));
    }

    // one hash per log, over its emitter, topics and data
    function _logsOf(address sender, uint256 value, bytes memory data) internal returns (bytes32[] memory h) {
        vm.recordLogs();
        vm.prank(sender);
        (bool ok,) = address(nft).call{value: value}(data);
        assertTrue(ok, "the call went through");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        h = new bytes32[](logs.length);
        for (uint256 i; i < logs.length; ++i) {
            h[i] = keccak256(abi.encode(logs[i].emitter, logs[i].topics, logs[i].data));
        }
    }

    // the same call from the same state, exact and with excess
    function _sameLogs(address sender, uint256 price, bytes memory data, string memory which) internal {
        uint256 snap = vm.snapshotState();
        bytes32[] memory exact = _logsOf(sender, price, data);
        vm.revertToState(snap);
        bytes32[] memory over = _logsOf(sender, price + 7 ether, data);
        assertGt(exact.length, 0, which);
        assertEq(over, exact, which);
    }

    function test_overpaidCallsLogExactlyWhatExactOnesLog() public {
        // an auction purchase with a premium, a referrer paid and the old holder's display name cleared
        uint256 ref = _buy(dave, "referrer", dave, 0);
        uint256 id = _buy(carol, "alpha", carol, ref);
        vm.prank(carol);
        nft.setPrimaryPage(id);
        uint256 t = nft.expiresAt(id) + GRACE + 1 days;
        vm.warp(t - 61);
        _commitPaid(bob, "alpha", bob, ref);
        _commitTrial(relayer, "beta", alice, 0);
        vm.warp(t);
        (,, uint256 premium, uint256 total) = nft.quote("alpha");
        assertGt(premium, 0);
        bytes32 s = _secret("alpha", bob, ref);
        _sameLogs(bob, total, abi.encodeCall(PageNFT.reveal, ("alpha", bob, ref, s)), "purchase");
        _sameLogs(
            relayer,
            _trialPrice("beta"),
            abi.encodeCall(PageNFT.revealTrial, ("beta", alice, 0, _secret("beta", alice, 0))),
            "trial"
        );
        // bob's new registration, renewed by a stranger
        _sameLogs(stranger, nft.getFee(5), abi.encodeCall(PageNFT.renew, (id)), "renewal");
    }
}

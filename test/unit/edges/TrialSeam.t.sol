// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Vm} from "forge-std/Test.sol";
import {PageNFT} from "../../../src/PageNFT.sol";
import {EdgesBase} from "./EdgesBase.sol";

// The trial seam. One second after an unpaid trial ends a paid registration and the release of the
// held trial money both open, and they race in one block. Either way the trial's payer is credited its money
// once, nobody else is credited anything, and the two orders end in the same ledgers. No new trial can join
// before the pause ends; from then on a new trial races the release the same way, and the release fails in
// the trial branch while the new trial runs.
contract TrialSeamTest is EdgesBase {
    string constant L = "alpha";
    bytes32 constant TRIAL_REFUNDED = keccak256("TrialRefunded(uint256,address,uint256)");

    address main = makeAddr("main");
    uint256 ref;
    uint256 id;
    uint256 e;
    uint256 price;
    uint256 fee;
    address[9] accounts;

    function setUp() public override {
        super.setUp();
        // relayer pays a trial for alice, referred by dave's name, and alice points the name at main
        ref = _buy(dave, "dave-ref", dave, 0);
        id = _trial(relayer, L, alice, ref);
        vm.startPrank(alice);
        nft.setAddr(id, main);
        nft.setPrimaryPage(id);
        vm.stopPrank();
        e = nft.expiresAt(id);
        price = _trialPrice(L);
        fee = nft.getFee(bytes(L).length);
        accounts = [relayer, alice, main, dave, bob, carol, stranger, DEAD, address(nft)];
        assertEq(nft.payee(id), main);
        assertEq(nft.payee(ref), dave);
    }

    // the money ledgers, ETH balances and the name's record
    function _ledgers() internal view returns (uint256[] memory l) {
        l = new uint256[](2 * accounts.length + 7);
        uint256 k;
        for (uint256 i; i < accounts.length; ++i) {
            l[k++] = nft.owed(accounts[i]);
            l[k++] = accounts[i].balance;
        }
        l[k++] = nft.depositOf(id);
        (address payer, uint256 held) = _held(id);
        l[k++] = uint256(uint160(payer));
        l[k++] = held;
        l[k++] = uint256(uint160(nft.ownerOf(id)));
        l[k++] = nft.expiresAt(id);
        l[k++] = nft.epochOf(id);
        l[k++] = nft.depositOf(ref);
    }

    // every wei the contract holds is a deposit, a credit or held trial money
    function _assertBacked() internal view {
        uint256 sum = nft.depositOf(id) + nft.depositOf(ref);
        (, uint256 held) = _held(id);
        sum += held;
        for (uint256 i; i < accounts.length; ++i) sum += nft.owed(accounts[i]);
        assertEq(address(nft).balance, sum, "every wei is backed");
    }

    // the TrialRefunded events in logs, of any name: their number, each checked for the given payer and amount
    function _refunds(Vm.Log[] memory logs, address payer, uint256 amount) internal pure returns (uint256 n) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length == 3 && logs[i].topics[0] == TRIAL_REFUNDED) {
                assertEq(address(uint160(uint256(logs[i].topics[2]))), payer, "refund to the payer");
                assertEq(abi.decode(logs[i].data, (uint256)), amount, "the price it paid");
                ++n;
            }
        }
    }

    // after the race: the payer got its trial money and nobody else got anything
    function _assertPaidOutcome(uint256[] memory before, address buyer, uint256 buyerEth) internal view {
        uint256[] memory l = _ledgers();
        for (uint256 i; i < accounts.length; ++i) {
            uint256 want = before[2 * i] + (accounts[i] == relayer ? price : 0);
            assertEq(l[2 * i], want, "only the trial payer is credited, and once");
        }
        assertEq(buyerEth - buyer.balance, fee, "the buyer pays the fee alone");
        assertEq(nft.depositOf(id), fee, "the new deposit is the fee");
        (address payer, uint256 held) = _held(id);
        assertEq(payer, address(0));
        assertEq(held, 0);
        assertEq(nft.ownerOf(id), buyer);
        assertEq(nft.epochOf(id), 2);
        assertEq(nft.primaryPage(alice), 0);
        _assertBacked();
    }

    function test_paidRegistrationAndReleaseAtTheSeamInBothOrders() public {
        vm.warp(e - 1 hours);
        _commitPaid(bob, L, bob, 0);
        // the second before the seam refuses both
        vm.warp(e);
        assertFalse(nft.isReleasable(id));
        vm.prank(stranger);
        vm.expectRevert(PageNFT.NotReleasable.selector);
        nft.release(id);
        vm.prank(bob);
        vm.expectRevert(PageNFT.AlreadyRegistered.selector);
        nft.reveal{value: fee}(L, bob, 0, _secret(L, bob, 0));

        vm.warp(e + 1);
        assertTrue(nft.isReleasable(id));
        assertTrue(nft.isAvailable(L, 0));
        (,,, uint256 total) = nft.quote(L);
        assertEq(total, fee, "no deposit to take over and no premium");
        _assertBacked();
        uint256[] memory before = _ledgers();
        uint256 bobEth = bob.balance;
        uint256 snap = vm.snapshotState();

        // registration first
        vm.recordLogs();
        vm.prank(bob);
        nft.reveal{value: total}(L, bob, 0, _secret(L, bob, 0));
        vm.prank(stranger);
        vm.expectRevert(PageNFT.NotReleasable.selector);
        nft.release(id);
        assertEq(_refunds(vm.getRecordedLogs(), relayer, price), 1, "credited once");
        _assertPaidOutcome(before, bob, bobEth);
        uint256[] memory registrationFirst = _ledgers();

        // release first
        vm.revertToState(snap);
        vm.recordLogs();
        vm.prank(stranger);
        nft.release(id);
        assertEq(nft.owed(relayer), before[0] + price);
        vm.prank(bob);
        nft.reveal{value: total}(L, bob, 0, _secret(L, bob, 0));
        assertEq(_refunds(vm.getRecordedLogs(), relayer, price), 1, "credited once");
        _assertPaidOutcome(before, bob, bobEth);
        uint256[] memory releaseFirst = _ledgers();

        assertEq(registrationFirst, releaseFirst, "both orders end in the same ledgers");
    }

    // the same race at any later second, before or after the pause
    function testFuzz_paidRaceAtAnyLaterSecond(uint256 t) public {
        t = bound(t, e + 1, e + PAUSE + 3 * YEAR);
        vm.warp(t - 1 hours);
        _commitPaid(bob, L, bob, 0);
        vm.warp(t);
        uint256[] memory before = _ledgers();
        uint256 bobEth = bob.balance;
        uint256 snap = vm.snapshotState();

        vm.prank(bob);
        nft.reveal{value: fee}(L, bob, 0, _secret(L, bob, 0));
        vm.prank(stranger);
        vm.expectRevert(PageNFT.NotReleasable.selector);
        nft.release(id);
        _assertPaidOutcome(before, bob, bobEth);
        uint256[] memory registrationFirst = _ledgers();

        vm.revertToState(snap);
        vm.prank(stranger);
        nft.release(id);
        vm.prank(bob);
        nft.reveal{value: fee}(L, bob, 0, _secret(L, bob, 0));
        _assertPaidOutcome(before, bob, bobEth);
        assertEq(registrationFirst, _ledgers(), "both orders end in the same ledgers");
    }

    function test_newTrialAndReleaseAfterThePauseInBothOrders() public {
        // carol pays a new trial for herself; the release is valid from e + 1, the trial only after the pause
        vm.warp(e + PAUSE - 1 hours);
        _commitTrial(carol, L, carol, 0);
        vm.warp(e + PAUSE);
        assertTrue(nft.isReleasable(id));
        vm.prank(carol);
        vm.expectRevert(PageNFT.TrialNotAllowed.selector);
        nft.revealTrial{value: price}(L, carol, 0, _secret(L, carol, 0));

        vm.warp(e + PAUSE + 1);
        uint256[] memory before = _ledgers();
        uint256 carolEth = carol.balance;
        uint256 snap = vm.snapshotState();

        // the new trial first: it credits the old payer, and the release then fails in the trial branch
        vm.recordLogs();
        vm.prank(carol);
        nft.revealTrial{value: price}(L, carol, 0, _secret(L, carol, 0));
        vm.prank(stranger);
        vm.expectRevert(PageNFT.NotReleasable.selector);
        nft.release(id);
        assertEq(_refunds(vm.getRecordedLogs(), relayer, price), 1, "credited once");
        _assertTrialOutcome(before, carolEth);
        uint256[] memory trialFirst = _ledgers();

        // the release first, then the new trial
        vm.revertToState(snap);
        vm.recordLogs();
        vm.prank(stranger);
        nft.release(id);
        vm.prank(carol);
        nft.revealTrial{value: price}(L, carol, 0, _secret(L, carol, 0));
        assertEq(_refunds(vm.getRecordedLogs(), relayer, price), 1, "credited once");
        _assertTrialOutcome(before, carolEth);
        assertEq(trialFirst, _ledgers(), "both orders end in the same ledgers");

        // the refusal came from the trial branch: one second after the new trial ends the release passes
        // and credits the new payer, long before the deposit branch would open
        uint256 e2 = nft.expiresAt(id);
        vm.warp(e2);
        vm.prank(stranger);
        vm.expectRevert(PageNFT.NotReleasable.selector);
        nft.release(id);
        vm.warp(e2 + 1);
        vm.prank(stranger);
        nft.release(id);
        assertEq(nft.owed(carol), price, "the new payer is credited at its own seam");
        _assertBacked();
    }

    function _assertTrialOutcome(uint256[] memory before, uint256 carolEth) internal view {
        uint256[] memory l = _ledgers();
        for (uint256 i; i < accounts.length; ++i) {
            uint256 want = before[2 * i] + (accounts[i] == relayer ? price : 0);
            assertEq(l[2 * i], want, "only the old trial payer is credited, and once");
        }
        assertEq(carolEth - carol.balance, price, "the new payer pays the trial price");
        assertEq(nft.depositOf(id), 0);
        (address payer, uint256 held) = _held(id);
        assertEq(payer, carol, "the new trial's money is held for its payer");
        assertEq(held, price);
        assertEq(nft.ownerOf(id), carol);
        assertEq(nft.epochOf(id), 2);
        _assertBacked();
    }
}

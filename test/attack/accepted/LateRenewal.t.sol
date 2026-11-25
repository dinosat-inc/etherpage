// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {AcceptedBase} from "./AcceptedBase.sol";

// A renewal that lands after someone else has claimed the name does not fail: it pays for the new holder's page. The
// token id of a name never changes, whoever registers it, and renew takes only the token id and is open to anyone
// until the grace period of the page ends, so a renewal sent for the old registration renews the new one. It adds a
// year to the new holder's page and puts the fee into its deposit, which pays the new holder's payee when it is
// released. The sender loses one yearly fee, on a name it had already lost: a trial has no grace period and is free
// one second after it ends, and a paid page lapses into the auction after its grace period. Wallets and agents that
// renew read epochOf and ownerOf just before they send, and do not renew when either has changed since they chose to.
contract AcceptedLateRenewalTest is AcceptedBase {
    // alice's trial ends at E; bob, who committed in time, claims a paid year at E + 1; alice's renewal, sent for her
    // trial, lands at E + 3, succeeds and pays for bob's year
    function test_lateTrialRenewalPaysForTheNewHoldersPage() public {
        string memory l = "brand";
        uint256 id = _trial(alice, l, alice, 0);
        uint256 e = nft.expiresAt(id);
        uint256 fee = nft.getFee(bytes(l).length);
        assertEq(nft.epochOf(id), 1);
        assertEq(nft.ownerOf(id), alice);

        vm.warp(e - 60);
        _commitPaid(bob, l, bob, 0);
        vm.warp(e);
        assertFalse(nft.isAvailable(l, 0), "the trial runs to its last second");
        vm.warp(e + 1);
        assertTrue(nft.isAvailable(l, 0), "a trial has no grace period");
        (,,, uint256 total) = nft.quote(l);
        assertEq(total, fee);
        bytes32 s = _secret(l, bob);
        vm.prank(bob);
        assertEq(nft.reveal{value: total}(l, bob, 0, s), id, "the name keeps its token id");
        assertEq(nft.ownerOf(id), bob);
        assertEq(nft.epochOf(id), 2, "a new registration, which a renewer can read");
        uint256 bobExpiry = nft.expiresAt(id);
        assertEq(bobExpiry, e + 1 + 365 days);
        assertEq(nft.depositOf(id), fee);

        vm.warp(e + 3);
        uint256 before = alice.balance;
        vm.prank(alice);
        nft.renew{value: fee}(id);
        assertEq(before - alice.balance, fee, "alice paid a yearly fee");
        assertEq(nft.ownerOf(id), bob, "the page stays bob's");
        assertEq(nft.expiresAt(id), bobExpiry + 365 days, "bob's page has a year more");
        assertEq(nft.depositOf(id), 2 * fee, "and alice's fee in its deposit");
        assertEq(nft.payee(id), bob);
        assertEq(nft.owed(alice), _trialPrice(l), "alice has only her trial money back");

        // the deposit, alice's fee included, is bob's once the page lapses and he releases it
        vm.warp(nft.expiresAt(id) + 111 days + 1);
        vm.prank(bob);
        nft.release(id);
        assertEq(nft.owed(bob), 2 * fee);
    }

    // alice's paid page lapses and bob buys it one day into the premium; alice's renewal, sent for her page, lands two
    // seconds later and pays for bob's year
    function test_lateRenewalAfterAPremiumClaimPaysForTheNewHoldersPage() public {
        string memory l = "lapsed";
        uint256 id = _buy(alice, l, alice, 0);
        uint256 fee = nft.getFee(bytes(l).length);
        uint256 aliceDeposit = nft.depositOf(id);
        uint256 g = nft.expiresAt(id) + 90 days;
        assertEq(nft.epochOf(id), 1);

        // alice could still renew at the last second of the grace period
        uint256 snap = vm.snapshotState();
        vm.warp(g);
        vm.prank(alice);
        nft.renew{value: fee}(id);
        assertEq(nft.ownerOf(id), alice);
        vm.revertToState(snap);

        vm.warp(g + 1 days - 61);
        _commitPaid(bob, l, bob, 0);
        vm.warp(g + 1 days);
        (, uint256 carried, uint256 premium, uint256 total) = nft.quote(l);
        assertEq(carried, aliceDeposit);
        assertGt(premium, 0, "inside the premium");
        bytes32 s = _secret(l, bob);
        vm.prank(bob);
        assertEq(nft.reveal{value: total}(l, bob, 0, s), id, "the name keeps its token id");
        assertEq(nft.ownerOf(id), bob);
        assertEq(nft.epochOf(id), 2, "a new registration, which a renewer can read");
        // alice is paid her deposit and the owner's three quarters of the premium; with no referrer the other quarter
        // goes to DEAD
        uint256 credited = carried + premium - premium * 2500 / 10_000;
        assertEq(nft.owed(alice), credited);
        uint256 bobExpiry = nft.expiresAt(id);
        uint256 bobDeposit = nft.depositOf(id);
        assertEq(bobDeposit, carried + fee, "bob bought out alice's deposit and added his fee");

        vm.warp(g + 1 days + 2);
        uint256 before = alice.balance;
        vm.prank(alice);
        nft.renew{value: fee}(id);
        assertEq(before - alice.balance, fee, "alice paid a yearly fee");
        assertEq(nft.ownerOf(id), bob, "the page stays bob's");
        assertEq(nft.expiresAt(id), bobExpiry + 365 days, "bob's page has a year more");
        assertEq(nft.depositOf(id), bobDeposit + fee, "and alice's fee in its deposit");
        assertEq(nft.payee(id), bob);
        assertEq(nft.owed(alice), credited, "alice's credit from the sale is unchanged");
    }
}

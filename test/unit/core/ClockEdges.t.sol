// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Vm} from "forge-std/Test.sol";
import {PageNFT} from "../../../src/PageNFT.sol";
import {RulesBase} from "../../utils/RulesBase.sol";

// Renewal, release and registration at the instants where one of them changes: the horizon of renewals, the
// release window after a new registration, a purchase at the end of the premium window, and the quote over time.
contract ClockEdgesTest is RulesBase {
    bytes32 constant T_WITHDRAWN = keccak256("Withdrawn(address,address,uint256)");

    // commits for carol at when minus 61 seconds and buys label at when, paying the quote
    function _buyAt(string memory l, uint256 when, uint256 ref) internal returns (uint256 id, Vm.Log[] memory logs) {
        vm.warp(when - 61);
        _commitPaid(carol, l, carol, ref);
        vm.warp(when);
        (,,, uint256 total) = nft.quote(l);
        vm.recordLogs();
        vm.prank(carol);
        id = nft.reveal{value: total}(l, carol, ref, _s(l, carol, ref));
        logs = vm.getRecordedLogs();
    }

    // every money event names a non zero account and a non zero amount
    function _noZeroMoney(Vm.Log[] memory logs) internal view {
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory l = logs[i];
            if (l.emitter != address(nft)) continue;
            bytes32 t = l.topics[0];
            // the topic that names the account
            uint256 who;
            if (t == T_REF_PREMIUM) {
                who = 3;
            } else if (t == T_WITHDRAWN) {
                who = 1;
            } else if (
                t == T_DEPOSIT || t == T_BOUGHT || t == T_RELEASED || t == T_OWNER_PREMIUM || t == T_STARTED
                    || t == T_REFUNDED
            ) {
                who = 2;
            } else {
                continue;
            }
            assertTrue(l.topics[who] != bytes32(0), "a money event names address zero");
            assertGt(abi.decode(l.data, (uint256)), 0, "a money event of amount zero");
        }
    }

    // at exactly the end of the premium window the premium is zero: the buyer pays the fee and the deposit, the
    // deposit goes to the last payee and no premium event is logged; one second earlier both premium events are
    function test_noZeroAmountMoneyEvents() public {
        uint256 id = _buy(bob, "alpha");
        uint256 p = nft.expiresAt(id) + 111 days;
        uint256 snap = vm.snapshotState();

        (, Vm.Log[] memory logs) = _buyAt("alpha", p - 1, 0);
        assertEq(_count(logs, T_REF_PREMIUM), 1, "one second before, the referrer share");
        assertEq(_count(logs, T_OWNER_PREMIUM), 1, "and the owner share");
        _noZeroMoney(logs);

        vm.revertToState(snap);
        vm.warp(p);
        (uint256 fee, uint256 carried, uint256 premium, uint256 total) = nft.quote("alpha");
        assertEq(premium, 0, "no premium at the end of the window");
        assertEq(carried, FEE5);
        assertEq(total, fee + carried);
        assertFalse(nft.isReleasable(id), "release is still shut");
        (, logs) = _buyAt("alpha", p, 0);
        assertEq(_count(logs, T_REF_PREMIUM) + _count(logs, T_OWNER_PREMIUM), 0, "no premium event");
        assertEq(_count(logs, T_BOUGHT), 1, "the deposit is bought out");
        _noZeroMoney(logs);
        assertEq(nft.owed(bob), FEE5, "the last payee gets the deposit");
        assertEq(nft.owed(DEAD), 0, "and nothing goes to DEAD");

        // a first registration, a renewal, a release and a withdrawal log no zero amount either
        vm.recordLogs();
        uint256 other = _buy(dave, "bravo");
        uint256 year = nft.getFee(5);
        vm.prank(dave);
        nft.renew{value: year}(other);
        vm.warp(nft.expiresAt(other) + 111 days + 1);
        nft.release(other);
        nft.withdraw(dave);
        nft.withdraw(bob);
        logs = vm.getRecordedLogs();
        assertEq(_count(logs, T_BOUGHT), 0, "nothing carried, no DepositBoughtOut");
        assertEq(_count(logs, T_RELEASED), 1);
        _noZeroMoney(logs);

        // trials log no zero amount and no address zero either: one renewed out of its trial, one released after its
        // end, one taken over by a paid registration and one by a new trial after the pause
        vm.recordLogs();
        uint256 renewed = _trial("tango", user);
        uint256 released = _trial("tribe", user);
        _trial("tulip", user);
        uint256 last = _trial("taupe", user);
        vm.prank(bob);
        nft.renew{value: year}(renewed);
        vm.warp(nft.expiresAt(last) + PAUSE + 1);
        nft.release(released);
        _buy(dave, "tulip");
        _trial("taupe", carol);
        nft.withdraw(relayer);
        logs = vm.getRecordedLogs();
        assertEq(_count(logs, T_STARTED), 5, "five trials started");
        assertEq(_count(logs, T_REFUNDED), 4, "four trials refunded");
        _noZeroMoney(logs);
    }

    // a registration over a lapsed name moves the release window to the new expiry: release stays shut at every
    // instant until 476 days after the purchase, the old window included, and opens one second later
    function test_registerThenReleaseReverts() public {
        uint256 id = _buy(bob, "alpha");
        uint256 e = nft.expiresAt(id);
        uint256 g = e + 90 days;
        _buyAt("alpha", g + 1, 0);
        uint256 e2 = nft.expiresAt(id);
        assertEq(e2, g + 1 + 365 days);
        uint256 p2 = e2 + 111 days;
        assertEq(p2, g + 1 + 476 days);
        uint256[7] memory instants = [g + 1, e + 111 days, e + 111 days + 1, e2, e2 + 90 days, p2 - 1, p2];
        for (uint256 i; i < instants.length; ++i) {
            vm.warp(instants[i]);
            assertFalse(nft.isReleasable(id), string.concat("instant ", vm.toString(i)));
            vm.expectRevert(PageNFT.NotReleasable.selector);
            nft.release(id);
        }
        vm.warp(p2 + 1);
        assertTrue(nft.isReleasable(id));
        uint256 before = nft.owed(carol);
        nft.release(id);
        assertEq(nft.owed(carol) - before, 2 * FEE5, "the grown deposit goes to the new holder");
    }

    // the same at every instant between the purchase and the new window's end
    function testFuzz_registerThenReleaseReverts(uint256 dt) public {
        uint256 id = _buy(bob, "alpha");
        uint256 g = nft.expiresAt(id) + 90 days;
        _buyAt("alpha", g + 1, 0);
        vm.warp(g + 1 + dt % (476 days + 1));
        assertFalse(nft.isReleasable(id));
        vm.expectRevert(PageNFT.NotReleasable.selector);
        nft.release(id);
    }

    // a first registration and a purchase at each auction instant never meet the renewal horizon and expire exactly
    // a year after their block
    function test_registrationNeverHitsCap() public {
        uint256 id = _buy(bob, "alpha");
        uint256 e = nft.expiresAt(id);
        uint256[4] memory instants = [e + 90 days + 1, e + 111 days - 1, e + 111 days, e + 111 days + 1];
        uint256 snap = vm.snapshotState();
        for (uint256 i; i < instants.length; ++i) {
            vm.revertToState(snap);
            vm.warp(instants[i] - 61);
            _commitPaid(dave, "fresh", dave, 0);
            (uint256 got,) = _buyAt("alpha", instants[i], 0);
            string memory which = vm.toString(i);
            assertEq(nft.expiresAt(got), instants[i] + 365 days, string.concat("the auction purchase, instant ", which));
            (,,, uint256 total) = nft.quote("fresh");
            vm.prank(dave);
            uint256 f = nft.reveal{value: total}("fresh", dave, 0, _s("fresh", dave, 0));
            assertEq(nft.expiresAt(f), instants[i] + 365 days, string.concat("the first registration, instant ", which));
        }
    }

    // release opens the deposit to its payee; a registration in the next block starts a fresh deposit of exactly one
    // fee, takes nothing from the released money and records its own referrer
    function test_releaseThenRegister() public {
        uint256 r1 = _buy(dave, "refone");
        uint256 r2 = _buy(dave, "reftwo");
        uint256 id = _buy(bob, "alpha", bob, r1);
        uint256 year = nft.getFee(5);
        vm.prank(bob);
        nft.renew{value: year}(id);
        uint256 p = nft.expiresAt(id) + 111 days;
        // carol commits a minute before the release, to register in the block after it
        vm.warp(p - 59);
        _commitPaid(carol, "alpha", carol, r2);
        vm.warp(p + 1);
        vm.prank(user);
        nft.release(id);
        assertEq(nft.depositOf(id), 0, "release empties the deposit");
        assertEq(nft.owed(bob), 2 * FEE5, "and credits the payee");
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(p + 2);
        (uint256 fee, uint256 carried, uint256 premium, uint256 total) = nft.quote("alpha");
        assertEq(carried + premium, 0, "nothing to take over");
        assertEq(total, fee);
        vm.recordLogs();
        vm.prank(carol);
        nft.reveal{value: total}("alpha", carol, r2, _s("alpha", carol, r2));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_count(logs, T_BOUGHT), 0);
        assertEq(nft.depositOf(id), FEE5, "a fresh deposit of exactly one fee");
        assertEq(nft.referrerOf(id), r2, "the new referrer");
        assertEq(nft.owed(bob), 2 * FEE5, "the released money is untouched");
        assertEq(nft.owed(dave), 0, "and no referrer is paid");
    }

    // a paid renewal never meets the horizon in grace, nor while the expiry is at most 3285 days ahead
    function testFuzz_renewDuringGracePassesCap(uint256 startSeed, uint8 k, uint256 activeSeed, uint256 graceSeed)
        public
    {
        vm.warp(1_000_000 + startSeed % 4_000_000_000);
        uint256 id = _buy(bob, "alpha");
        uint256 registeredAt = vm.getBlockTimestamp();
        uint256 year = nft.getFee(5);
        uint256 n = k % 9;
        for (uint256 i; i < n; ++i) {
            vm.prank(carol);
            nft.renew{value: year}(id);
        }
        uint256 e = nft.expiresAt(id);
        assertLe(e, registeredAt + 3285 days);
        // an active name whose expiry is at most 3285 days ahead
        uint256 now1 = e - activeSeed % (e - registeredAt + 1);
        vm.warp(now1);
        assertLe(e, now1 + 3285 days);
        vm.prank(dave);
        nft.renew{value: year}(id);
        assertEq(nft.expiresAt(id), e + 365 days, "renewed from the stored expiry");
        // any instant of the grace period that follows
        e = e + 365 days;
        vm.warp(e + 1 + graceSeed % 90 days);
        vm.prank(dave);
        nft.renew{value: year}(id);
        assertEq(nft.expiresAt(id), e + 365 days, "renewed in grace from the stored expiry");
    }

    // one second beyond the horizon the renewal fails, and an underpaid one fails on its price first
    function test_renewOneSecondBeyondHorizonReverts() public {
        uint256 id = _buy(bob, "alpha");
        uint256 fee = nft.getFee(5);
        for (uint256 i; i < 9; ++i) nft.renew{value: fee}(id);
        uint256 e = nft.expiresAt(id);
        uint256 edge = e + 365 days - 3650 days;
        vm.warp(edge - 1);
        vm.prank(carol);
        vm.expectRevert(PageNFT.InsufficientFee.selector);
        nft.renew{value: fee - 1}(id);
        vm.prank(carol);
        vm.expectRevert(PageNFT.RenewalTooFar.selector);
        nft.renew{value: fee}(id);
        // one second later the same call goes through
        vm.warp(edge);
        vm.prank(carol);
        nft.renew{value: fee}(id);
        assertEq(nft.expiresAt(id), e + 365 days);
    }

    // a subpage has no expiry of its own and cannot be renewed, before or after its parent's expiry
    function test_renewSubpageReverts() public {
        uint256 parent = _buy(bob, "alpha");
        vm.prank(bob);
        uint256 sub = nft.registerSubpage("sub", parent);
        uint256 fee = nft.getFee(3);
        uint256[3] memory instants = [vm.getBlockTimestamp(), nft.expiresAt(parent) + 1, nft.expiresAt(parent) + 200 days];
        for (uint256 i; i < 3; ++i) {
            vm.warp(instants[i]);
            vm.prank(carol);
            vm.expectRevert(PageNFT.NotTopLevel.selector);
            nft.renew{value: fee}(sub);
        }
    }

    // a stranger renewing back to back reaches at most the horizon; with nothing more paid, release opens one
    // second after the premium window, no later than 3650 plus 111 days and a second after the stranger's last call
    function testFuzz_thirdPartyRenewalLockUpBounded(uint256 waitSeed) public {
        uint256 id = _buy(bob, "alpha");
        vm.warp(vm.getBlockTimestamp() + waitSeed % (365 days + 90 days));
        uint256 t = vm.getBlockTimestamp();
        uint256 fee = nft.getFee(5);
        uint256 n;
        while (true) {
            vm.prank(dave);
            (bool ok, bytes memory ret) = address(nft).call{value: fee}(abi.encodeCall(nft.renew, (id)));
            if (!ok) {
                assertEq(bytes4(ret), PageNFT.RenewalTooFar.selector);
                break;
            }
            ++n;
        }
        uint256 e = nft.expiresAt(id);
        assertLe(e, t + 3650 days, "never past the horizon");
        assertGt(e + 365 days, t + 3650 days, "and the next year would be");
        assertEq(nft.depositOf(id), FEE5 * (n + 1), "every renewal fee is in the deposit");

        // a year of real time later exactly one more year can be bought, and its fee joins the deposit
        uint256 snap = vm.snapshotState();
        vm.warp(t + 365 days);
        vm.prank(dave);
        nft.renew{value: fee}(id);
        assertEq(nft.depositOf(id), FEE5 * (n + 2));
        vm.prank(dave);
        vm.expectRevert(PageNFT.RenewalTooFar.selector);
        nft.renew{value: fee}(id);

        vm.revertToState(snap);
        vm.warp(e + 111 days);
        vm.expectRevert(PageNFT.NotReleasable.selector);
        nft.release(id);
        vm.warp(e + 111 days + 1);
        assertLe(e + 111 days + 1, t + 3650 days + 111 days + 1);
        nft.release(id);
        assertEq(nft.depositOf(id), 0);
        assertEq(nft.owed(bob), FEE5 * (n + 1), "the whole deposit goes to the payee");
    }

    // after grace the quote never rises, and the quote of an earlier second still buys the name later, with the
    // difference sent back
    function testFuzz_quoteNonIncreasingAfterGrace(uint256 d1, uint256 gap, uint256 farSeed) public {
        uint256 id = _buy(bob, "alpha");
        uint256 year = nft.getFee(5);
        nft.renew{value: year}(id);
        nft.renew{value: year}(id);
        uint256 g = nft.expiresAt(id) + 90 days;
        uint256 t1 = g + 1 + d1 % 30 days;
        uint256 t2 = t1 + 1 + gap % (86400 - 62);
        // the commitment is made before t1 and is still valid at t2
        vm.warp(t1 - 61);
        _commitPaid(carol, "alpha", carol, 0);
        vm.warp(t1);
        (,,, uint256 q1) = nft.quote("alpha");
        uint256 snap = vm.snapshotState();
        vm.warp(t1 + 1 + farSeed % 400 days);
        (,,, uint256 qFar) = nft.quote("alpha");
        assertLe(qFar, q1, "a later quote is never higher");
        vm.revertToState(snap);
        vm.warp(t2);
        (,,, uint256 q2) = nft.quote("alpha");
        assertLe(q2, q1);
        uint256 before = carol.balance;
        vm.prank(carol);
        nft.reveal{value: q1}("alpha", carol, 0, _s("alpha", carol, 0));
        assertEq(before - carol.balance, q2, "the buyer pays the quote of t2 and gets the rest back");
        assertEq(nft.ownerOf(id), carol);
    }
}

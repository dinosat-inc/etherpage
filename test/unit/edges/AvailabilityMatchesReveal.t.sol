// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {PageNFT} from "../../../src/PageNFT.sol";
import {EdgesBase} from "./EdgesBase.sol";

// isAvailable(label, 0) is true exactly when a paid reveal of the label passes the AlreadyRegistered check at
// the same second. Each probe pays more than any price and holds a valid commitment, so the availability
// check is the only one that can refuse it. Through the 14 day pause after a trial the view is true while
// revealTrial reverts TrialNotAllowed.
contract AvailabilityMatchesRevealTest is EdgesBase {
    string constant L = "alpha";

    uint8 constant UNREGISTERED = 0;
    uint8 constant LIVE_PAID = 1;
    uint8 constant GRACE_PAID = 2;
    uint8 constant PREMIUM = 3;
    // past the premium window with the deposit still held
    uint8 constant LAPSED = 4;
    uint8 constant RELEASED = 5;
    uint8 constant LIVE_TRIAL = 6;
    // the 14 days after a trial ends
    uint8 constant PAUSED_TRIAL = 7;
    uint8 constant ENDED_TRIAL = 8;
    // an ended trial whose money was credited back by release
    uint8 constant TRIAL_MONEY_RELEASED = 9;
    // a trial renewed by a stranger, then live, in grace or past its grace
    uint8 constant CONVERTED_LIVE = 10;
    uint8 constant CONVERTED_GRACE = 11;
    uint8 constant CONVERTED_AFTER = 12;
    uint8 constant KINDS = 13;

    // a time in [lo, hi]: an end, a second next to an end, or any time between
    function _at(uint256 lo, uint256 hi, uint256 pick, uint256 r) internal pure returns (uint256) {
        uint256 k = pick % 5;
        if (k == 0) return lo;
        if (k == 1) return hi;
        if (k == 2) return lo < hi ? lo + 1 : lo;
        if (k == 3) return lo < hi ? hi - 1 : hi;
        return lo + r % (hi - lo + 1);
    }

    // builds a state of label L and returns a time at least a minute after the last setup call, with the
    // answer the view must give then. toDead sends a live name to DEAD first
    function _build(uint8 kind, uint256 pick, uint256 r1, uint256 r2, bool toDead)
        internal
        returns (uint256 t, bool want)
    {
        uint256 start = vm.getBlockTimestamp();
        if (kind == UNREGISTERED) return (_at(start + 61, start + 10 * YEAR, pick, r1), true);
        if (kind <= RELEASED) {
            uint256 id = _buy(carol, L, carol, 0);
            uint256 bought = vm.getBlockTimestamp();
            uint256 e = nft.expiresAt(id);
            if (kind == LIVE_PAID) {
                if (toDead) {
                    vm.prank(carol);
                    nft.transferFrom(carol, DEAD, id);
                }
                return (_at(bought + 61, e, pick, r1), false);
            }
            if (kind == GRACE_PAID) return (_at(e + 1, e + GRACE, pick, r1), false);
            if (kind == PREMIUM) return (_at(e + GRACE + 1, e + GRACE + DECAY - 1, pick, r1), true);
            if (kind == LAPSED) return (_at(e + GRACE + DECAY, e + GRACE + DECAY + 5 * YEAR, pick, r1), true);
            uint256 rel = _at(e + GRACE + DECAY + 1, e + GRACE + DECAY + YEAR, r2, r1);
            vm.warp(rel);
            nft.release(id);
            assertEq(nft.depositOf(id), 0);
            return (_at(rel + 61, rel + 5 * YEAR, pick, r1), true);
        }
        uint256 tid = _trial(relayer, L, alice, 0);
        uint256 began = vm.getBlockTimestamp();
        uint256 te = nft.expiresAt(tid);
        if (kind == LIVE_TRIAL) {
            if (toDead) {
                vm.prank(alice);
                nft.transferFrom(alice, DEAD, tid);
            }
            return (_at(began + 61, te, pick, r1), false);
        }
        if (kind == PAUSED_TRIAL) return (_at(te + 1, te + PAUSE, pick, r1), true);
        if (kind == ENDED_TRIAL) return (_at(te + PAUSE + 1, te + PAUSE + 5 * YEAR, pick, r1), true);
        if (kind == TRIAL_MONEY_RELEASED) {
            uint256 rel = _at(te + 1, te + PAUSE + YEAR, r2, r1);
            vm.warp(rel);
            nft.release(tid);
            (, uint256 held) = _held(tid);
            assertEq(held, 0);
            return (_at(rel + 61, rel + 5 * YEAR, pick, r1), true);
        }
        uint256 cv = _at(began, te, r2, r1);
        vm.warp(cv);
        uint256 fee = nft.getFee(bytes(L).length);
        vm.prank(stranger);
        nft.renew{value: fee}(tid);
        uint256 e2 = nft.expiresAt(tid);
        if (kind == CONVERTED_LIVE) return (_at(cv + 61, e2, pick, r1), false);
        if (kind == CONVERTED_GRACE) return (_at(e2 + 1, e2 + GRACE, pick, r1), false);
        return (_at(e2 + GRACE + 1, e2 + GRACE + DECAY + 5 * YEAR, pick, r1), true);
    }

    // at the current second: the view, then a paid reveal for bob with a valid commitment and more than any
    // price, which either passes or reverts with AlreadyRegistered and nothing else
    function _probe() internal returns (bool avail, bool passed) {
        uint256 id = nft.computeId(L);
        avail = nft.isAvailable(L, 0);
        uint256 value = nft.getFee(bytes(L).length) + nft.depositOf(id) + nft.getPremium(id) + 1 ether;
        bytes memory call = abi.encodeCall(PageNFT.reveal, (L, bob, 0, _secret(L, bob, 0)));
        vm.prank(bob);
        (bool ok, bytes memory ret) = address(nft).call{value: value}(call);
        if (!ok) assertEq(ret, abi.encodeWithSelector(PageNFT.AlreadyRegistered.selector), "only availability refuses");
        else assertEq(nft.ownerOf(id), bob);
        passed = ok;
    }

    // commits bob's paid form 61 seconds before t, then probes at t
    function _observe(uint256 t) internal returns (bool avail, bool passed) {
        vm.warp(t - 61);
        _commitPaid(bob, L, bob, 0);
        vm.warp(t);
        return _probe();
    }

    function testFuzz_isAvailableMatchesThePaidReveal(uint8 kind, uint256 pick, uint256 r1, uint256 r2, bool toDead)
        public
    {
        kind = uint8(bound(kind, 0, KINDS - 1));
        (uint256 t, bool want) = _build(kind, pick, r1, r2, toDead);
        (bool avail, bool passed) = _observe(t);
        assertEq(avail, want, "the answer for this state");
        assertEq(passed, avail, "isAvailable agrees with the AlreadyRegistered check");
    }

    // every state at both ends of its window and the seconds next to them
    function test_everyStateAtTheEdgesOfItsWindow() public {
        uint256 start = vm.getBlockTimestamp();
        for (uint8 kind; kind < KINDS; ++kind) {
            for (uint256 pick; pick < 4; ++pick) {
                uint256 snap = vm.snapshotState();
                (uint256 t, bool want) = _build(kind, pick, 0, pick, pick % 2 == 0);
                (bool avail, bool passed) = _observe(t);
                assertEq(avail, want, "the answer for this state");
                assertEq(passed, avail, "isAvailable agrees with the AlreadyRegistered check");
                vm.revertToState(snap);
                vm.warp(start);
            }
        }
    }

    // the grace end of a paid name is expiry plus 90 days, and an unpaid trial has none
    function test_theSecondsAroundEachGraceEnd() public {
        uint256 snap = vm.snapshotState();
        uint256 id = _buy(carol, L, carol, 0);
        uint256 e = nft.expiresAt(id);
        uint256[4] memory ts = [e, e + 1, e + GRACE, e + GRACE + 1];
        bool[4] memory want = [false, false, false, true];
        for (uint256 i; i < 4; ++i) {
            uint256 s2 = vm.snapshotState();
            (bool avail, bool passed) = _observe(ts[i]);
            assertEq(avail, want[i]);
            assertEq(passed, avail);
            vm.revertToState(s2);
        }
        vm.revertToState(snap);
        id = _trial(relayer, L, alice, 0);
        e = nft.expiresAt(id);
        uint256 s3 = vm.snapshotState();
        (bool a1, bool p1) = _observe(e);
        assertFalse(a1);
        assertFalse(p1);
        vm.revertToState(s3);
        (bool a2, bool p2) = _observe(e + 1);
        assertTrue(a2);
        assertTrue(p2);
    }

    // through the pause the view is true and a paid reveal passes, while revealTrial with a valid trial
    // commitment and its full price reverts TrialNotAllowed
    function testFuzz_pauseIsAvailableWhileTrialsAreRefused(uint256 t) public {
        uint256 id = _trial(relayer, L, alice, 0);
        uint256 e = nft.expiresAt(id);
        t = bound(t, e + 1, e + PAUSE);
        vm.warp(t - 61);
        _commitPaid(bob, L, bob, 0);
        _commitTrial(relayer, L, carol, 0);
        vm.warp(t);
        assertTrue(nft.isAvailable(L, 0), "free for reveal");
        uint256 price = _trialPrice(L);
        vm.prank(relayer);
        vm.expectRevert(PageNFT.TrialNotAllowed.selector);
        nft.revealTrial{value: price}(L, carol, 0, _secret(L, carol, 0));
        (bool avail, bool passed) = _probe();
        assertTrue(avail);
        assertTrue(passed, "a paid reveal passes in the pause");
    }

    // the last second of the pause refuses the trial, the next one takes it
    function test_trialPassesOneSecondAfterThePause() public {
        uint256 id = _trial(relayer, L, alice, 0);
        uint256 e = nft.expiresAt(id);
        vm.warp(e + PAUSE - 61);
        _commitTrial(relayer, L, carol, 0);
        uint256 price = _trialPrice(L);
        vm.warp(e + PAUSE);
        assertTrue(nft.isAvailable(L, 0));
        vm.prank(relayer);
        vm.expectRevert(PageNFT.TrialNotAllowed.selector);
        nft.revealTrial{value: price}(L, carol, 0, _secret(L, carol, 0));
        vm.warp(e + PAUSE + 1);
        assertTrue(nft.isAvailable(L, 0));
        vm.prank(relayer);
        nft.revealTrial{value: price}(L, carol, 0, _secret(L, carol, 0));
        assertEq(nft.ownerOf(id), carol);
        assertFalse(nft.isAvailable(L, 0), "the new trial is live");
    }
}

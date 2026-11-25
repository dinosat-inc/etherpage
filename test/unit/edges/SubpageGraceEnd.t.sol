// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {PageNFT} from "../../../src/PageNFT.sol";
import {PageCard} from "../../../src/PageCard.sol";
import {EdgesBase} from "./EdgesBase.sol";

// _cardState ends a subpage's grace GRACE_PERIOD after its parent's expiry without asking whether the parent
// holds a deposit, while the parent's own grace end is _graceEnd. In every reachable state the two agree:
// status and the metadata Status of a current subpage equal its parent's at every second, for a paid parent,
// a trial paid by renew and a parent whose deposit was released, and a subpage of an earlier registration of
// its parent reads Invalid.
contract SubpageGraceEndTest is EdgesBase {
    uint8 constant PAID = 0;
    uint8 constant CONVERTED = 1;
    uint8 constant RELEASED = 2;
    // released and registered again, paid or as a trial, which leaves the old subpage stale
    uint8 constant AGAIN_PAID = 3;
    uint8 constant AGAIN_TRIAL = 4;
    uint8 constant KINDS = 5;

    uint256 parent;
    uint256 sub;
    // a subpage of the parent's new registration, when there is one
    uint256 sub2;

    // a time in [lo, hi]: an end, a second next to an end, or any time between
    function _at(uint256 lo, uint256 hi, uint256 pick, uint256 r) internal pure returns (uint256) {
        uint256 k = pick % 5;
        if (k == 0) return lo;
        if (k == 1) return hi;
        if (k == 2) return lo < hi ? lo + 1 : lo;
        if (k == 3) return lo < hi ? hi - 1 : hi;
        return lo + r % (hi - lo + 1);
    }

    // a second at or around one of the parent's boundaries, or any time from lo to just under 3 years later, and never
    // earlier than lo
    function _around(uint256 e, uint256 lo, uint256 pick, uint256 r) internal pure returns (uint256 t) {
        uint256[8] memory b =
            [e - 1, e, e + 1, e + GRACE - 1, e + GRACE, e + GRACE + 1, e + GRACE + DECAY, e + GRACE + DECAY + 1];
        uint256 k = pick % 10;
        t = k < 8 ? b[k] : lo + r % (3 * YEAR);
        if (t < lo) t = lo;
    }

    // renews the parent n mod 3 times, so at most twice, each at a second no later than its expiry, paid by a stranger
    function _renewals(uint256 n, uint256 r) internal {
        uint256 fee = nft.getFee(4);
        for (uint256 i; i < n % 3; ++i) {
            uint256 e = nft.expiresAt(parent);
            vm.warp(_at(vm.getBlockTimestamp(), e, r >> (8 * i), r >> (8 * i + 4)));
            vm.prank(stranger);
            nft.renew{value: fee}(parent);
        }
    }

    // builds the parent and the subpage bob holds, and returns the second to look at
    function _build(uint8 kind, uint256 pick, uint256 r1, uint256 r2, uint256 n) internal returns (uint256 t) {
        if (kind == CONVERTED) {
            parent = _trial(relayer, "club", alice, 0);
            vm.warp(_at(vm.getBlockTimestamp(), nft.expiresAt(parent), r2, r1));
            uint256 fee = nft.getFee(4);
            vm.prank(stranger);
            nft.renew{value: fee}(parent);
        } else {
            parent = _buy(alice, "club", alice, 0);
        }
        _renewals(n, r2);
        uint256 e = nft.expiresAt(parent);
        vm.warp(_at(vm.getBlockTimestamp(), e, r1, r2));
        vm.prank(alice);
        sub = nft.registerSubpageFor("sub", parent, bob);
        if (kind == PAID || kind == CONVERTED) return _around(e, vm.getBlockTimestamp(), pick, r1);

        uint256 rel = _at(e + GRACE + DECAY + 1, e + GRACE + DECAY + YEAR, r2, r1);
        vm.warp(rel);
        nft.release(parent);
        assertEq(nft.depositOf(parent), 0);
        if (kind == RELEASED) return _at(rel, rel + 3 * YEAR, pick, r1);
        if (kind == AGAIN_PAID) {
            assertEq(_buy(carol, "club", carol, 0), parent);
            vm.prank(carol);
            sub2 = nft.registerSubpageFor("sub2", parent, dave);
            return _around(nft.expiresAt(parent), vm.getBlockTimestamp(), pick, r1);
        }
        assertEq(_trial(relayer, "club", carol, 0), parent);
        return _at(vm.getBlockTimestamp(), nft.expiresAt(parent) + 3 * YEAR, pick, r1);
    }

    function _status(uint256 id) internal view returns (PageCard.Status s) {
        s = nft.status(id);
        assertEq(_metaStatus(id), statusNames[uint256(s)], "the metadata shows the status");
    }

    // the parent's status from its own grace end, GRACE_PERIOD after its expiry with a deposit and at it without
    function _parentWant() internal view returns (PageCard.Status) {
        uint256 e = nft.expiresAt(parent);
        uint256 graceEnd = nft.depositOf(parent) == 0 ? e : e + GRACE;
        uint256 t = vm.getBlockTimestamp();
        if (t <= e) return nft.depositOf(parent) == 0 ? PageCard.Status.Trial : PageCard.Status.Active;
        return t <= graceEnd ? PageCard.Status.Grace : PageCard.Status.Expired;
    }

    // a current subpage: its status equals its parent's, and both follow the parent's own grace end
    function _assertFollows(uint256 s) internal view {
        PageCard.Status ps = _status(parent);
        PageCard.Status ss = _status(s);
        assertEq(uint256(ps), uint256(_parentWant()), "the parent reads its own grace end");
        assertEq(uint256(ss), uint256(ps), "the subpage reads its parent's status");
        assertEq(nft.inGracePeriod(parent), ss == PageCard.Status.Grace, "grace agrees with the parent's view");
        assertEq(nft.isExpired(parent), ss == PageCard.Status.Expired, "expiry agrees with the parent's view");
    }

    function _check(uint8 kind) internal view {
        if (kind <= RELEASED) {
            _assertFollows(sub);
            return;
        }
        assertEq(uint256(_status(sub)), uint256(PageCard.Status.Invalid), "a stale subpage is Invalid");
        assertEq(uint256(_status(parent)), uint256(_parentWant()), "the parent reads its own grace end");
        if (kind == AGAIN_PAID) _assertFollows(sub2);
    }

    function testFuzz_subpageGraceEndIsTheParents(uint8 kind, uint256 pick, uint256 r1, uint256 r2, uint256 n)
        public
    {
        kind = uint8(bound(kind, 0, KINDS - 1));
        uint256 t = _build(kind, pick, r1, r2, n);
        vm.warp(t);
        _check(kind);
    }

    // each kind of parent at each of its boundaries
    function test_everyKindAtEveryBoundary() public {
        uint256 start = vm.getBlockTimestamp();
        for (uint8 kind; kind < KINDS; ++kind) {
            for (uint256 pick; pick < 8; ++pick) {
                uint256 snap = vm.snapshotState();
                uint256 t = _build(kind, pick, pick, pick + 1, pick);
                vm.warp(t);
                _check(kind);
                vm.revertToState(snap);
                vm.warp(start);
            }
        }
    }
}

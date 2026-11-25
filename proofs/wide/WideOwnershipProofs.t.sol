// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {PageCard} from "../../src/PageCard.sol";
import {PageNFT} from "../../src/PageNFT.sol";
import {WideHarness} from "./WideHarness.sol";

/// @notice Widened ownership proofs, stated outright rather than against a reference build:
/// WTA1/WTA2 who may move a page (transferFrom, safeTransferFrom with and without data), for any
/// caller, any from, any approved account and operator, any value and time, a top level page paid or
/// not, or a subpage live or stale; the tier proofs CP1x, D2, T3 fix the caller among a few accounts
/// and compare with a reference build.
/// WAP1 who may approve, WAP2 what setApprovalForAll changes.
/// WCR1 clearRecords empties every address, text, website and data record and only the holder of an
/// active page may call it (no tier proof asserts the emptying).
/// The holder is one of HOLDER, OTHER and DEAD: with a symbolic holder Solady builds a revert offset from
/// iszero(owner), which Halmos cannot follow.
/// Halmos: FOUNDRY_PROFILE=proofs halmos --contract WideOwnershipProofsTest --forge-build-out out-proofs --loop 4 --storage-layout generic
contract WideOwnershipProofsTest is Test {
    WideHarness n;
    address cardAddr;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address constant HOLDER = address(0xB0B);
    address constant OTHER = address(0xC0FFEE);
    address constant OWNER = address(0xA11CE);
    bytes32 constant ROOT = 0x62460c06d95b73747abf6ea4f28aefd78b4ad2abee112e7cf15fe6a924cca3c6;
    uint256 pid;
    uint256 sub;

    function setUp() public {
        PageCard card = new PageCard();
        cardAddr = address(card);
        n = new WideHarness(card);
        pid = uint256(keccak256(abi.encodePacked(ROOT, keccak256(bytes("club")))));
        sub = uint256(keccak256(abi.encodePacked(bytes32(pid), keccak256(bytes("fresh")))));
    }

    function _holder(uint8 k) internal pure returns (address) {
        uint8 m = k % 3;
        return m == 0 ? HOLDER : m == 1 ? OTHER : DEAD;
    }

    struct T {
        uint256 tid;
        address holder;
        bool active;
        bool paidOk;
        address approved;
        bool operator;
        uint256 hs;
    }

    // the page: club top level, paid or not, held by holder; or its subpage fresh held by holder under
    // club held by OWNER, live (parent epoch) or stale
    function _page(bool isSub, uint8 hPick, uint64 exp, uint64 epoch, bool paid, bool stale, uint256 t)
        internal
        returns (T memory s)
    {
        vm.assume(t < 2 ** 40 && epoch > 0 && epoch < type(uint64).max);
        s.holder = _holder(hPick);
        n.h_setRecord(pid, "club", 0, exp, epoch, 0);
        if (isSub) {
            n.h_mint(OWNER, pid);
            n.h_setDeposit(pid, 1);
            n.h_setRecord(sub, "fresh", pid, 0, 1, stale ? epoch - 1 : epoch);
            n.h_mint(s.holder, sub);
            s.tid = sub;
            s.paidOk = true;
            s.active = s.holder != DEAD && !stale && t <= exp;
        } else {
            n.h_mint(s.holder, pid);
            n.h_setDeposit(pid, paid ? 1 : 0);
            s.tid = pid;
            s.paidOk = paid;
            s.active = s.holder != DEAD && t <= exp;
        }
    }

    // the recipient: another codeless account, DEAD, the holder, address 0, this contract, or the parent's
    // holder. A symbolic recipient makes Solady build a revert offset from iszero(to), which Halmos cannot
    // follow (NotConcreteError); the transfer code compares the recipient only with 0, DEAD, this contract
    // and the sender, so these six cover every case it can tell apart.
    function _to(uint8 k, address, address holder) internal view returns (address) {
        uint8 m = k % 6;
        if (m == 5) return OWNER;
        if (m == 0) return address(0x4EAF);
        if (m == 1) return DEAD;
        if (m == 2) return holder;
        if (m == 3) return address(0);
        return address(n);
    }

    struct W {
        uint8 form;
        bool isSub;
        uint8 hPick;
        uint64 exp;
        uint64 epoch;
        bool paid;
        bool stale;
        uint256 t;
        address caller;
        address from;
        uint8 toPick;
        address toSym;
        address ap;
        address op;
        bool opOn;
        bool primary;
        uint256 value;
    }

    function _wta(W memory w) internal {
        T memory s = _page(w.isSub, w.hPick, w.exp, w.epoch, w.paid, w.stale, w.t);
        address caller = w.caller;
        address from = w.from;
        address toSym = w.toSym;
        address ap = w.ap;
        address op = w.op;
        bool opOn = w.opOn;
        bool primary = w.primary;
        uint256 value = w.value;
        uint256 t = w.t;
        uint8 form = w.form;
        address to = _to(w.toPick, toSym, s.holder);
        vm.prank(s.holder);
        n.approve(ap, s.tid);
        vm.prank(s.holder);
        n.setApprovalForAll(op, opOn);
        if (primary) n.h_setPrimary(s.holder, s.tid, s.holder);
        vm.warp(t);
        s.approved = n.getApproved(s.tid);
        s.operator = n.isApprovedForAll(s.holder, caller);
        s.hs = n.holderSince(s.tid);
        uint256 bTo = to == address(0) ? 0 : n.balanceOf(to);
        bool authorized = caller == s.holder || caller == s.approved || s.operator;
        bool expected = value == 0 && caller != address(0) && from == s.holder && authorized && to != address(0)
            && to != address(n) && s.active && (s.paidOk || to == DEAD);
        vm.assume(value < 2 ** 96);
        vm.deal(caller, value);
        bytes memory d = form == 0
            ? abi.encodeWithSignature("transferFrom(address,address,uint256)", from, to, s.tid)
            : form == 1
                ? abi.encodeWithSignature("safeTransferFrom(address,address,uint256)", from, to, s.tid)
                : abi.encodeWithSignature("safeTransferFrom(address,address,uint256,bytes)", from, to, s.tid, hex"beef");
        vm.prank(caller);
        (bool ok,) = address(n).call{value: value}(d);
        assert(ok == expected);
        assert(n.isApprovedForAll(s.holder, op) == opOn);
        if (ok) {
            assert(n.ownerOf(s.tid) == to);
            assert(n.h_getApproved(s.tid) == address(0));
            if (to != s.holder) {
                assert(n.holderSince(s.tid) == t);
                assert(n.balanceOf(to) == bTo + 1);
                if (primary) assert(n.primaryPage(s.holder) == 0);
            } else {
                assert(n.holderSince(s.tid) == s.hs);
                if (primary) assert(n.primaryPage(s.holder) == s.tid);
            }
        } else {
            assert(n.ownerOf(s.tid) == s.holder);
            assert(n.h_getApproved(s.tid) == s.approved);
            assert(n.holderSince(s.tid) == s.hs);
            if (primary) assert(n.primaryPage(s.holder) == s.tid);
        }
    }

    /// @notice WTA1: transferFrom succeeds exactly when no ETH is sent, the caller is not address 0 and is
    /// the holder, the approved account or an operator of the holder, from is the holder, the recipient is
    /// neither address 0 nor this contract, the page is active, and a top level page with no deposit goes
    /// only to DEAD. Then the recipient holds it, the approval is gone, and on a move to another account
    /// holderSince is now and the old holder's display page is dropped. A refusal changes nothing.
    function check_WTA1_transferFrom(
        bool isSub, uint8 hPick, uint64 exp, uint64 epoch, bool paid, bool stale, uint256 t, address caller,
        address from, uint8 toPick, address toSym, address ap, address op, bool opOn, bool primary, uint256 value
    ) public {
        _wta(W(0, isSub, hPick, exp, epoch, paid, stale, t, caller, from, toPick, toSym, ap, op, opOn, primary, value));
    }

    /// @notice WTA2: WTA1 for both forms of safeTransferFrom, to recipients with no code.
    function check_WTA2_safeTransferFrom(
        bool withData, bool isSub, uint8 hPick, uint64 exp, uint64 epoch, bool paid, bool stale, uint256 t,
        address caller, address from, uint8 toPick, address toSym, address ap, address op, bool opOn, bool primary,
        uint256 value
    ) public {
        _wta(W(withData ? 2 : 1, isSub, hPick, exp, epoch, paid, stale, t, caller, from, toPick, toSym, ap, op, opOn,
            primary, value));
    }

    /// @notice WAP1: approve succeeds exactly when no ETH is sent, the caller is not address 0, the page
    /// exists and the caller is its holder or an operator of the holder, at any time and in any state; it
    /// then sets exactly the approved account and moves nothing.
    function check_WAP1_approve(
        bool isSub, uint8 hPick, uint64 exp, uint64 epoch, bool paid, bool stale, uint256 t, address caller,
        address account, address ap, address op, bool opOn, bool missing, uint256 value
    ) public {
        T memory s = _page(isSub, hPick, exp, epoch, paid, stale, t);
        vm.prank(s.holder);
        n.approve(ap, s.tid);
        vm.prank(s.holder);
        n.setApprovalForAll(op, opOn);
        vm.warp(t);
        uint256 id = missing ? uint256(keccak256("missing")) : s.tid;
        bool operator = n.isApprovedForAll(s.holder, caller);
        bool expected = value == 0 && caller != address(0) && !missing && (caller == s.holder || operator);
        vm.assume(value < 2 ** 96);
        vm.deal(caller, value);
        // the caller may be any address, this contract included, so its balance is read after the deal
        uint256 nb = address(n).balance;
        vm.prank(caller);
        (bool ok,) = address(n).call{value: value}(abi.encodeCall(PageNFT.approve, (account, id)));
        assert(ok == expected);
        assert(n.ownerOf(s.tid) == s.holder);
        assert(n.h_getApproved(s.tid) == (ok ? account : ap));
        assert(address(n).balance == nb);
    }

    /// @notice WAP2: setApprovalForAll by any caller sets only the caller's own flag for that operator;
    /// the holder's flags for other operators, the approval and the holder stay.
    function check_WAP2_setApprovalForAll(
        uint8 hPick, uint64 exp, uint64 epoch, uint256 t, address caller, address op2, bool flag, address op,
        bool opOn, address ap
    ) public {
        T memory s = _page(false, hPick, exp, epoch, true, false, t);
        vm.prank(s.holder);
        n.approve(ap, s.tid);
        vm.prank(s.holder);
        n.setApprovalForAll(op, opOn);
        vm.warp(t);
        vm.prank(caller);
        n.setApprovalForAll(op2, flag);
        assert(n.isApprovedForAll(caller, op2) == flag);
        if (!(caller == s.holder && op2 == op)) assert(n.isApprovedForAll(s.holder, op) == opOn);
        assert(n.ownerOf(s.tid) == s.holder);
        assert(n.getApproved(s.tid) == ap);
    }

    /// @notice WCR1: for a top level page or a subpage whose holder saved a main address, an address for
    /// any coin type, a text, a website and a data record, clearRecords by any caller at any time
    /// succeeds exactly when the page is active and the caller holds it. It then raises the record
    /// version by one, and every saved record reads empty: the main address and resolve fall back to the
    /// holder, every other coin type reads empty, text, website and data read empty, keepProfile cannot
    /// bring them back, and addressesUpdatedAt is now. A refusal changes nothing.
    function check_WCR1_clearRecords(
        bool isSub, bool other, uint64 exp, uint64 epoch, uint256 t0, uint256 t, address caller, address main,
        uint256 coin, bytes20 val
    ) public {
        address holder = other ? OTHER : HOLDER;
        T memory s = _page(isSub, other ? 1 : 0, exp, epoch, true, false, t);
        vm.assume(t0 <= exp && t0 < 2 ** 40 && t0 <= t);
        vm.assume(main != address(n) && address(val) != address(n));
        vm.warp(t0);
        vm.startPrank(holder);
        n.setAddr(s.tid, main);
        n.setAddrForCoin(s.tid, coin, abi.encodePacked(val));
        n.setText(s.tid, "k", "v");
        n.setContenthash(s.tid, hex"01");
        n.setData(s.tid, "k", hex"02");
        vm.stopPrank();
        uint256 v0 = n.recordVersion(s.tid);
        uint256 upd0 = n.addressesUpdatedAt(s.tid);
        vm.warp(t);
        bool expected = s.active && caller == holder;
        vm.prank(caller);
        (bool ok,) = address(n).call(abi.encodeCall(PageNFT.clearRecords, (s.tid)));
        assert(ok == expected);
        if (ok) {
            assert(n.recordVersion(s.tid) == v0 + 1);
            assert(n.addressesUpdatedAt(s.tid) == t);
            assert(n.resolve(s.tid) == holder);
            assert(n.payee(s.tid) == holder);
            bytes memory a = n.addr(s.tid, coin);
            if (coin == 0x8000000a) assert(keccak256(a) == keccak256(abi.encodePacked(holder)));
            else assert(a.length == 0);
            assert(n.addr(bytes32(s.tid)) == address(0));
            assert(bytes(n.text(s.tid, "k")).length == 0);
            assert(n.contenthash(s.tid).length == 0);
            assert(n.data(bytes32(s.tid), "k").length == 0);
            vm.prank(holder);
            (bool kept,) = address(n).call(abi.encodeCall(PageNFT.keepProfile, (s.tid)));
            assert(!kept);
            assert(bytes(n.text(s.tid, "k")).length == 0);
            assert(n.contenthash(s.tid).length == 0);
        } else {
            assert(n.recordVersion(s.tid) == v0);
            assert(n.addressesUpdatedAt(s.tid) == upd0);
        }
    }
}

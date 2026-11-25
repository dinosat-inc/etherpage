// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {PageCard} from "../src/PageCard.sol";
import {PageNFT} from "../src/PageNFT.sol";
import {ProfileHarness, NoProfileResetHarness} from "./ProfileHarness.sol";

/// @notice Symbolic proofs of the profile rule: text and the website count only while the stored
/// writer of the profile, the account that last wrote or kept it, holds the name. The start state is
/// built through the harness: a top level name and one subpage, any expiry, epochs and time, any
/// holder among four accounts (DEAD included), any stored writer among five (zero included), any
/// profile version and record version, the current profile present or not, and discarded content in
/// the older slots. A name DEAD holds is never active. DR1 and DR2 prove the rule of data records,
/// which count only while the account that saved them holds the name, and HS1 and AU1 the times
/// holderSince and addressesUpdatedAt.
/// Halmos: FOUNDRY_PROFILE=proofs halmos --contract ProfileProofsTest --function test_check_ --forge-build-out out-proofs --loop 4 --storage-layout generic
contract ProfileProofsTest is Test {
    PageCard card;
    ProfileHarness n;
    NoProfileResetHarness f;

    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address constant OWNER = address(0xA11CE);
    address constant HOLDER = address(0xB0B);
    address constant OTHER = address(0xC0FFEE);
    address constant OPR = address(0x0FE2);
    bytes32 constant ROOT = 0x62460c06d95b73747abf6ea4f28aefd78b4ad2abee112e7cf15fe6a924cca3c6;
    uint256 constant FEE = 0.0001 ether;
    uint256 constant FEE4 = 0.001 ether;

    uint256 pid;
    uint256 sub;
    // a top level label with no record
    uint256 nova;

    function setUp() public {
        card = new PageCard();
        n = new ProfileHarness(card);
        f = new NoProfileResetHarness(card);
        pid = uint256(keccak256(abi.encodePacked(ROOT, keccak256(bytes("club")))));
        sub = uint256(keccak256(abi.encodePacked(bytes32(pid), keccak256(bytes("fresh")))));
        nova = uint256(keccak256(abi.encodePacked(ROOT, keccak256(bytes("nova")))));
    }

    function _pick(uint8 p) internal pure returns (address) {
        uint8 k = p % 4;
        if (k == 0) return DEAD;
        if (k == 1) return HOLDER;
        if (k == 2) return OWNER;
        return OTHER;
    }

    function _pickW(uint8 p) internal pure returns (address) {
        uint8 k = p % 5;
        if (k == 0) return address(0);
        if (k == 1) return HOLDER;
        if (k == 2) return OWNER;
        if (k == 3) return OTHER;
        return DEAD;
    }

    function _eq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    function _eqB(bytes memory a, bytes memory b) internal pure returns (bool) {
        return keccak256(a) == keccak256(b);
    }

    struct S {
        bool top;
        uint64 exp;
        uint64 epoch;
        uint64 pe;
        address holder;
        address writer;
        uint96 ver;
        uint64 rv;
        bool cur;
        bool old;
        bool paid;
    }

    // the target name is the top level name or its subpage; the other one is held by OWNER
    function _world(S memory s) internal returns (uint256 id) {
        n.h_setRecord(pid, "club", 0, s.exp, s.epoch, 0);
        n.h_setDeposit(pid, s.paid ? 1 : 0);
        n.h_mint(s.top ? s.holder : OWNER, pid);
        n.h_setRecord(sub, "fresh", pid, 0, 1, s.pe);
        n.h_mint(s.top ? OWNER : s.holder, sub);
        id = s.top ? pid : sub;
        n.h_setVersion(id, s.rv);
        n.h_setProfile(id, s.writer, s.ver);
        if (s.cur) n.h_put(id, n.h_key(s.rv, s.ver));
        if (s.old) {
            if (s.ver > 0) n.h_putOld(id, n.h_key(s.rv, s.ver - 1));
            if (s.rv > 0) n.h_putOld(id, n.h_key(s.rv - 1, s.ver));
        }
    }

    // activity computed from the start state alone, not from the contract: a name DEAD holds is never
    // active, a top level name is active until it expires, and a subpage until its parent expires, in
    // the registration it was made in
    function _activeOf(S memory s, uint64 ts) internal pure returns (bool) {
        if (s.holder == DEAD) return false;
        if (s.top) return ts <= s.exp;
        return s.pe == s.epoch && ts <= s.exp;
    }

    function _text(uint256 id) internal view returns (string memory) {
        return n.text(id, "k");
    }

    // the read rule

    /// @notice PP1: for any start state and time, text and contenthash (both forms) show the current
    /// profile exactly when the name is active and its stored writer is its holder, and nothing
    /// otherwise; a discarded profile in an older slot is never shown; a nonempty answer implies
    /// profileWriter equals ownerOf.
    /// @dev Technique: built symbolic state, exact characterization of a view. Classification: DIRECT.
    function test_check_PP1_readRule(
        bool top, uint64 exp, uint64 epoch, uint64 pe, uint8 hPick, uint8 wPick, uint96 ver, uint64 rv, bool cur,
        bool old, bool paid, uint64 ts
    ) public {
        S memory s = S(top, exp, epoch, pe, _pick(hPick), _pickW(wPick), ver, rv, cur, old, paid);
        uint256 id = _world(s);
        vm.warp(ts);
        bool counts = _activeOf(s, ts) && s.writer == s.holder;
        string memory t = _text(id);
        bytes memory c = n.contenthash(id);
        assert(_eq(t, counts && cur ? "v" : ""));
        assert(_eqB(c, counts && cur ? bytes(hex"e301") : bytes("")));
        assert(_eq(n.text(bytes32(id), "k"), t));
        assert(_eqB(n.contenthash(bytes32(id)), c));
        if (bytes(t).length != 0 || c.length != 0) assert(n.profileWriter(id) == n.ownerOf(id));
    }

    // the slot key

    /// @notice PP3: the slot key recordVersion << 96 | version is one to one for every record version
    /// below 2^160 and every version below 2^96, and the key of a larger pair (compared as record
    /// version first) is larger.
    /// @dev Technique: pure arithmetic over the harness's copy of the formula and the contract's own
    /// _slot. Classification: DIRECT.
    function test_check_PP3_slotKey(uint160 rv1, uint96 v1, uint160 rv2, uint96 v2) public {
        uint256 k1 = n.h_key(rv1, v1);
        uint256 k2 = n.h_key(rv2, v2);
        assert((k1 == k2) == (rv1 == rv2 && v1 == v2));
        if (rv1 < rv2 || (rv1 == rv2 && v1 < v2)) assert(k1 < k2);
        // the contract's own key for a stored pair
        n.h_setVersion(pid, rv1);
        n.h_setProfile(pid, OWNER, v1);
        assert(n.h_slotOf(pid) == k1);
    }

    // keep

    /// @notice PP4: keepProfile by any account succeeds exactly when the name is active, the caller is
    /// its holder and not already the writer; it reverts Expired, Unauthorized or AlreadyKept in that
    /// order otherwise. On success only the writer changes, to the caller: the version, the record
    /// version and every stored entry stay, and the caller now reads exactly the profile it found.
    /// So the holder of an active name can always make a profile count.
    /// @dev Technique: built symbolic state, symbolic caller. Classification: DIRECT.
    function test_check_PP4_keep(
        bool top, uint64 exp, uint64 epoch, uint64 pe, uint8 hPick, uint8 wPick, uint96 ver, uint64 rv, bool cur,
        bool old, bool paid, uint64 ts, address caller
    ) public {
        S memory s = S(top, exp, epoch, pe, _pick(hPick), _pickW(wPick), ver, rv, cur, old, paid);
        // Justification: no transaction has msg.sender == address(0)
        vm.assume(caller != address(0));
        uint256 id = _world(s);
        vm.warp(ts);
        bool active = _activeOf(s, ts);
        vm.prank(caller);
        (bool ok, bytes memory ret) = address(n).call(abi.encodeCall(PageNFT.keepProfile, (id)));
        bytes4 want = !active ? PageNFT.Expired.selector
            : caller != s.holder ? PageNFT.Unauthorized.selector
            : s.writer == caller ? PageNFT.AlreadyKept.selector : bytes4(0);
        assert(ok == (want == bytes4(0)));
        (address w, uint96 v) = n.h_profile(id);
        assert(v == ver);
        assert(n.recordVersion(id) == rv);
        if (!ok) {
            assert(bytes4(ret) == want && ret.length == 4);
            assert(w == s.writer);
            return;
        }
        assert(w == caller);
        assert(_eq(_text(id), cur ? "v" : ""));
        assert(_eqB(n.contenthash(id), cur ? bytes(hex"e301") : bytes("")));
    }

    // the fresh start

    /// @notice PP5: a text or website write succeeds exactly for the holder of an active name. After it
    /// the caller is the writer and reads what it wrote. When the caller was already the writer the rest
    /// of its profile stays; when it was not, every other entry reads empty (a fresh start), the version
    /// went up by one if a writer was set, and the discarded profile is never shown again.
    /// Assumption: a name whose stored writer is zero has no stored profile and version zero (every
    /// write sets a writer, and the version only moves once a writer is set).
    /// @dev Technique: built symbolic state, symbolic caller. Classification: DIRECT.
    function test_check_PP5_freshStart(
        bool top, uint64 exp, uint64 epoch, uint64 pe, uint8 hPick, uint8 wPick, uint96 ver, uint64 rv, bool cur,
        bool old, bool paid, uint64 ts, address caller, bool site
    ) public {
        S memory s = S(top, exp, epoch, pe, _pick(hPick), _pickW(wPick), ver, rv, cur, old, paid);
        vm.assume(caller != address(0));
        // Justification: every write sets a writer, and the version only moves once a writer is set
        vm.assume(s.writer != address(0) || (!cur && !old && ver == 0));
        // Justification: the version only goes up by one per fresh start, far below 2^96
        vm.assume(ver < type(uint96).max);
        uint256 id = _world(s);
        vm.warp(ts);
        bool active = _activeOf(s, ts);
        vm.prank(caller);
        (bool ok,) = site
            ? address(n).call(abi.encodeCall(PageNFT.setContenthash, (id, hex"77")))
            : address(n).call(abi.encodeWithSignature("setText(uint256,string,string)", id, "j", "w"));
        assert(ok == (active && caller == s.holder));
        (address w, uint96 v) = n.h_profile(id);
        if (!ok) {
            assert(w == s.writer && v == ver);
            return;
        }
        assert(w == caller);
        assert(n.recordVersion(id) == rv);
        bool fresh = s.writer != caller;
        assert(v == (fresh && s.writer != address(0) ? ver + 1 : ver));
        if (site) {
            assert(_eqB(n.contenthash(id), hex"77"));
            assert(_eq(_text(id), !fresh && cur ? "v" : ""));
        } else {
            assert(_eq(n.text(id, "j"), "w"));
            assert(_eq(_text(id), !fresh && cur ? "v" : ""));
            assert(_eqB(n.contenthash(id), !fresh && cur ? bytes(hex"e301") : bytes("")));
        }
    }

    // every call

    function _call(uint8 which, uint256 id, address holder, address to, address x) internal returns (bool ok, bytes4 sel) {
        bytes memory d;
        uint8 k = which % 17;
        if (k == 0) d = abi.encodeWithSignature("setText(uint256,string,string)", id, "k", "w");
        else if (k == 1) d = abi.encodeCall(PageNFT.setContenthash, (id, hex"77"));
        else if (k == 2) d = abi.encodeCall(PageNFT.keepProfile, (id));
        else if (k == 3) d = abi.encodeCall(PageNFT.clearRecords, (id));
        else if (k == 4) d = abi.encodeCall(PageNFT.setAddr, (id, x));
        else if (k == 5) d = abi.encodeCall(PageNFT.setAddrForCoin, (id, 60, abi.encodePacked(x)));
        else if (k == 6) d = abi.encodeWithSignature("transferFrom(address,address,uint256)", holder, to, id);
        else if (k == 7) d = abi.encodeWithSignature("safeTransferFrom(address,address,uint256)", holder, to, id);
        else if (k == 8) d = abi.encodeWithSignature("safeTransferFrom(address,address,uint256,bytes)", holder, to, id, hex"01");
        else if (k == 9) d = abi.encodeWithSignature("approve(address,uint256)", x, id);
        else if (k == 10) d = abi.encodeWithSignature("setApprovalForAll(address,bool)", x, true);
        else if (k == 11) d = abi.encodeCall(PageNFT.setPrimaryPage, (id));
        else if (k == 12) d = abi.encodeCall(PageNFT.registerSubpageFor, ("fresh", pid, to));
        else if (k == 13) d = abi.encodeCall(PageNFT.setSubpageMinter, (pid, x));
        else if (k == 14) d = abi.encodeCall(PageNFT.release, (id));
        else if (k == 15) d = abi.encodeCall(PageNFT.renew, (id));
        else d = abi.encodeCall(PageNFT.setData, (id, "k", hex"01"));
        sel = bytes4(d);
        (ok,) = address(n).call{value: k == 15 ? FEE4 : 0}(d);
    }

    /// @notice PP2: for any start state, any of 17 calls that change state (every profile writer, clear,
    /// both address writers, the three transfer forms, both approvals, the display name, the subpage
    /// mint over the existing subpage, the minter pick, release, renew and setData), by any account that
    /// has no code and is not zero or this contract, with or without operator and token approval: the
    /// stored writer changes only in setText, setContenthash or keepProfile, only to the caller, only
    /// when the caller held the active name. The version goes up by at most one and only in a write by a
    /// new writer over a set writer. The record version never goes down. The other name's profile never
    /// changes.
    /// @dev Technique: dispatcher with symbolic selector index, caller and arguments; recipients from
    /// four accounts, and the address argument one of four accounts. Classification: DIRECT.
    function test_check_PP2_everyCall(
        bool top, uint64 exp, uint64 epoch, uint64 pe, uint8 hPick, uint8 wPick, uint96 ver, uint64 rv, bool paid,
        uint64 ts, address caller, bool opApproved, bool tokApproved, uint8 which, uint8 toPick, uint8 x
    ) public {
        _pp2(top, exp, epoch, pe, hPick, wPick, ver, rv, paid, ts, caller, opApproved, tokApproved, which, toPick, x);
    }

    function _pp2(
        bool top, uint64 exp, uint64 epoch, uint64 pe, uint8 hPick, uint8 wPick, uint96 ver, uint64 rv, bool paid,
        uint64 ts, address caller, bool opApproved, bool tokApproved, uint8 which, uint8 toPick, uint8 x
    ) internal {
        S memory s = S(top, exp, epoch, pe, _pick(hPick), _pickW(wPick), ver, rv, true, false, paid);
        // Justification: no transaction has msg.sender == address(0); the contract never calls itself
        // except through multicall, proved separately
        vm.assume(caller != address(0) && caller != address(n));
        vm.assume(caller.code.length == 0);
        // Justification: record versions go up by one per registration or clear, and versions by one per
        // fresh start, so neither is near its limit
        vm.assume(rv < type(uint64).max && ver < type(uint96).max);
        uint256 id = _world(s);
        uint256 other = top ? sub : pid;
        (address ow0, uint96 ov0) = n.h_profile(other);
        if (opApproved) n.h_setApprovalForAll(s.holder, caller, true);
        if (tokApproved) n.h_approve(caller, id);
        vm.deal(caller, FEE4);
        vm.warp(ts);
        bool active = _activeOf(s, ts);
        vm.prank(caller);
        (bool ok, bytes4 sel) = _call(which, id, s.holder, _pick(toPick), _pick(x));
        (address w, uint96 v) = n.h_profile(id);
        if (w != s.writer) {
            assert(ok);
            assert(sel == PageNFT.setText.selector || sel == PageNFT.setContenthash.selector || sel == PageNFT.keepProfile.selector);
            assert(w == caller);
            assert(caller == s.holder && active);
        }
        if (v != ver) {
            assert(v == ver + 1);
            assert(sel == PageNFT.setText.selector || sel == PageNFT.setContenthash.selector);
            assert(s.writer != address(0) && s.writer != caller && w == caller);
        }
        assert(n.recordVersion(id) >= rv);
        (address ow1, uint96 ov1) = n.h_profile(other);
        assert(ow1 == ow0 && ov1 == ov0);
    }

    /// @notice PP2 split by call. Each part finishes on its own except w15 for renew, which is split
    /// again by kind of name (w15t and w15s at the end of this contract). w16 is setData.
    function test_check_PP2_w00(bool top, uint64 exp, uint64 epoch, uint64 pe, uint8 hPick, uint8 wPick, uint96 ver, uint64 rv, bool paid, uint64 ts, address caller, bool op, bool tok, uint8 toPick, uint8 x) public {
        _pp2(top, exp, epoch, pe, hPick, wPick, ver, rv, paid, ts, caller, op, tok, 0, toPick, x);
    }

    function test_check_PP2_w01(bool top, uint64 exp, uint64 epoch, uint64 pe, uint8 hPick, uint8 wPick, uint96 ver, uint64 rv, bool paid, uint64 ts, address caller, bool op, bool tok, uint8 toPick, uint8 x) public {
        _pp2(top, exp, epoch, pe, hPick, wPick, ver, rv, paid, ts, caller, op, tok, 1, toPick, x);
    }

    function test_check_PP2_w02(bool top, uint64 exp, uint64 epoch, uint64 pe, uint8 hPick, uint8 wPick, uint96 ver, uint64 rv, bool paid, uint64 ts, address caller, bool op, bool tok, uint8 toPick, uint8 x) public {
        _pp2(top, exp, epoch, pe, hPick, wPick, ver, rv, paid, ts, caller, op, tok, 2, toPick, x);
    }

    function test_check_PP2_w03(bool top, uint64 exp, uint64 epoch, uint64 pe, uint8 hPick, uint8 wPick, uint96 ver, uint64 rv, bool paid, uint64 ts, address caller, bool op, bool tok, uint8 toPick, uint8 x) public {
        _pp2(top, exp, epoch, pe, hPick, wPick, ver, rv, paid, ts, caller, op, tok, 3, toPick, x);
    }

    function test_check_PP2_w04(bool top, uint64 exp, uint64 epoch, uint64 pe, uint8 hPick, uint8 wPick, uint96 ver, uint64 rv, bool paid, uint64 ts, address caller, bool op, bool tok, uint8 toPick, uint8 x) public {
        _pp2(top, exp, epoch, pe, hPick, wPick, ver, rv, paid, ts, caller, op, tok, 4, toPick, x);
    }

    function test_check_PP2_w05(bool top, uint64 exp, uint64 epoch, uint64 pe, uint8 hPick, uint8 wPick, uint96 ver, uint64 rv, bool paid, uint64 ts, address caller, bool op, bool tok, uint8 toPick, uint8 x) public {
        _pp2(top, exp, epoch, pe, hPick, wPick, ver, rv, paid, ts, caller, op, tok, 5, toPick, x);
    }

    function test_check_PP2_w06(bool top, uint64 exp, uint64 epoch, uint64 pe, uint8 hPick, uint8 wPick, uint96 ver, uint64 rv, bool paid, uint64 ts, address caller, bool op, bool tok, uint8 toPick, uint8 x) public {
        _pp2(top, exp, epoch, pe, hPick, wPick, ver, rv, paid, ts, caller, op, tok, 6, toPick, x);
    }

    function test_check_PP2_w07(bool top, uint64 exp, uint64 epoch, uint64 pe, uint8 hPick, uint8 wPick, uint96 ver, uint64 rv, bool paid, uint64 ts, address caller, bool op, bool tok, uint8 toPick, uint8 x) public {
        _pp2(top, exp, epoch, pe, hPick, wPick, ver, rv, paid, ts, caller, op, tok, 7, toPick, x);
    }

    function test_check_PP2_w08(bool top, uint64 exp, uint64 epoch, uint64 pe, uint8 hPick, uint8 wPick, uint96 ver, uint64 rv, bool paid, uint64 ts, address caller, bool op, bool tok, uint8 toPick, uint8 x) public {
        _pp2(top, exp, epoch, pe, hPick, wPick, ver, rv, paid, ts, caller, op, tok, 8, toPick, x);
    }

    function test_check_PP2_w09(bool top, uint64 exp, uint64 epoch, uint64 pe, uint8 hPick, uint8 wPick, uint96 ver, uint64 rv, bool paid, uint64 ts, address caller, bool op, bool tok, uint8 toPick, uint8 x) public {
        _pp2(top, exp, epoch, pe, hPick, wPick, ver, rv, paid, ts, caller, op, tok, 9, toPick, x);
    }

    function test_check_PP2_w10(bool top, uint64 exp, uint64 epoch, uint64 pe, uint8 hPick, uint8 wPick, uint96 ver, uint64 rv, bool paid, uint64 ts, address caller, bool op, bool tok, uint8 toPick, uint8 x) public {
        _pp2(top, exp, epoch, pe, hPick, wPick, ver, rv, paid, ts, caller, op, tok, 10, toPick, x);
    }

    function test_check_PP2_w11(bool top, uint64 exp, uint64 epoch, uint64 pe, uint8 hPick, uint8 wPick, uint96 ver, uint64 rv, bool paid, uint64 ts, address caller, bool op, bool tok, uint8 toPick, uint8 x) public {
        _pp2(top, exp, epoch, pe, hPick, wPick, ver, rv, paid, ts, caller, op, tok, 11, toPick, x);
    }

    function test_check_PP2_w12(bool top, uint64 exp, uint64 epoch, uint64 pe, uint8 hPick, uint8 wPick, uint96 ver, uint64 rv, bool paid, uint64 ts, address caller, bool op, bool tok, uint8 toPick, uint8 x) public {
        _pp2(top, exp, epoch, pe, hPick, wPick, ver, rv, paid, ts, caller, op, tok, 12, toPick, x);
    }

    function test_check_PP2_w13(bool top, uint64 exp, uint64 epoch, uint64 pe, uint8 hPick, uint8 wPick, uint96 ver, uint64 rv, bool paid, uint64 ts, address caller, bool op, bool tok, uint8 toPick, uint8 x) public {
        _pp2(top, exp, epoch, pe, hPick, wPick, ver, rv, paid, ts, caller, op, tok, 13, toPick, x);
    }

    function test_check_PP2_w14(bool top, uint64 exp, uint64 epoch, uint64 pe, uint8 hPick, uint8 wPick, uint96 ver, uint64 rv, bool paid, uint64 ts, address caller, bool op, bool tok, uint8 toPick, uint8 x) public {
        _pp2(top, exp, epoch, pe, hPick, wPick, ver, rv, paid, ts, caller, op, tok, 14, toPick, x);
    }

    function test_check_PP2_w15(bool top, uint64 exp, uint64 epoch, uint64 pe, uint8 hPick, uint8 wPick, uint96 ver, uint64 rv, bool paid, uint64 ts, address caller, bool op, bool tok, uint8 toPick, uint8 x) public {
        _pp2(top, exp, epoch, pe, hPick, wPick, ver, rv, paid, ts, caller, op, tok, 15, toPick, x);
    }

    function test_check_PP2_w16(bool top, uint64 exp, uint64 epoch, uint64 pe, uint8 hPick, uint8 wPick, uint96 ver, uint64 rv, bool paid, uint64 ts, address caller, bool op, bool tok, uint8 toPick, uint8 x) public {
        _pp2(top, exp, epoch, pe, hPick, wPick, ver, rv, paid, ts, caller, op, tok, 16, toPick, x);
    }

    // bundles

    function _entry(uint8 k, uint256 id, address holder, address to) internal pure returns (bytes memory) {
        uint8 m = k % 5;
        if (m == 0) return abi.encodeWithSignature("setText(uint256,string,string)", id, "j", "w");
        if (m == 1) return abi.encodeCall(PageNFT.setContenthash, (id, hex"77"));
        if (m == 2) return abi.encodeCall(PageNFT.keepProfile, (id));
        if (m == 3) return abi.encodeWithSignature("transferFrom(address,address,uint256)", holder, to, id);
        return abi.encodeCall(PageNFT.clearRecords, (id));
    }

    /// @notice PP8: a bundle of any two of setText, setContenthash, keepProfile, transferFrom and
    /// clearRecords, by any account with no code, with or without operator approval: the writer ends as it was or as
    /// the caller; the version goes up by at most one, and only when a writer was set and was not the
    /// caller; the record version never goes down. A keepProfile then a setText succeeds exactly when
    /// keepProfile alone would, and ends with the caller reading the text it found plus the text it
    /// wrote. A setText then a keepProfile never succeeds.
    /// @dev Technique: two symbolic entries through multicall. Classification: DIRECT.
    function test_check_PP8_bundles(
        bool top, uint64 exp, uint64 epoch, uint64 pe, uint8 hPick, uint8 wPick, uint96 ver, uint64 rv, bool cur,
        bool paid, uint64 ts, address caller, bool opApproved, uint8 k1, uint8 k2, uint8 toPick
    ) public {
        S memory s = S(top, exp, epoch, pe, _pick(hPick), _pickW(wPick), ver, rv, cur, false, paid);
        vm.assume(caller != address(0) && caller != address(n));
        vm.assume(caller.code.length == 0);
        vm.assume(rv < type(uint64).max && ver < type(uint96).max);
        vm.assume(s.writer != address(0) || (!cur && ver == 0));
        uint256 id = _world(s);
        if (opApproved) n.h_setApprovalForAll(s.holder, caller, true);
        vm.warp(ts);
        bool active = _activeOf(s, ts);
        bytes[] memory d = new bytes[](2);
        d[0] = _entry(k1, id, s.holder, _pick(toPick));
        d[1] = _entry(k2, id, s.holder, _pick(toPick));
        vm.prank(caller);
        (bool ok,) = address(n).call(abi.encodeCall(PageNFT.multicall, (d)));
        (address w, uint96 v) = n.h_profile(id);
        assert(w == s.writer || w == caller);
        assert(v == ver || (v == ver + 1 && s.writer != address(0) && s.writer != caller && w == caller));
        assert(n.recordVersion(id) >= rv);
        if (!ok) assert(w == s.writer && v == ver);
        uint8 m1 = k1 % 5;
        uint8 m2 = k2 % 5;
        if (m1 == 0 && m2 == 2) assert(!ok);
        if (m1 == 2 && m2 == 0) {
            assert(ok == (active && caller == s.holder && s.writer != caller));
            if (ok) {
                assert(_eq(n.text(id, "j"), "w"));
                assert(_eq(_text(id), cur ? "v" : ""));
            }
        }
    }

    // registrations erase

    /// @notice PP6: the parent's holder minting the subpage again, to any of four accounts (the stored
    /// writer and the old holder included), leaves nothing of the old profile readable, even after the
    /// new holder keeps, and no data record either, even one the new holder saved.
    /// @dev Technique: built symbolic state, concrete ids. Classification: DIRECT.
    function test_check_PP6_reMintErases(
        uint64 exp, uint64 epoch, uint64 pe, uint8 hPick, uint8 wPick, uint96 ver, uint64 rv, uint64 ts, uint8 toPick
    ) public {
        S memory s = S(false, exp, epoch, pe, _pick(hPick), _pickW(wPick), ver, rv, true, true, true);
        vm.assume(rv < type(uint64).max);
        uint256 id = _world(s);
        vm.warp(ts);
        address to = _pick(toPick);
        n.h_putData(id, rv, to, hex"d1");
        vm.prank(OWNER);
        (bool ok,) = address(n).call(abi.encodeCall(PageNFT.registerSubpageFor, ("fresh", pid, to)));
        if (!ok) return;
        assert(n.recordVersion(id) == uint256(rv) + 1);
        assert(bytes(_text(id)).length == 0);
        assert(n.contenthash(id).length == 0);
        assert(n.data(bytes32(id), "k").length == 0);
        vm.prank(to);
        (bool kept,) = address(n).call(abi.encodeCall(PageNFT.keepProfile, (id)));
        kept;
        assert(bytes(_text(id)).length == 0);
        assert(n.contenthash(id).length == 0);
        assert(n.data(bytes32(id), "k").length == 0);
    }

    /// @notice PP6t: a paid registration over an ended trial, paid by OTHER for HOLDER, OWNER or OTHER (the
    /// old writer included), leaves nothing of the old profile readable, even after the new holder keeps,
    /// and no data record either, even one the new holder saved.
    /// @dev Technique: built symbolic state with a stored commitment. Classification: DIRECT.
    function test_check_PP6t_registrationErases(
        uint64 exp, uint8 hPick, uint8 wPick, uint96 ver, uint64 rv, uint64 ts, uint8 toPick, bytes32 secret
    ) public {
        S memory s = S(true, exp, 1, 0, _pick(hPick), _pickW(wPick), ver, rv, true, true, false);
        vm.assume(rv < type(uint64).max);
        // Justification: the time is after the trial's end and far below the limit of the commitment math
        vm.assume(ts > exp && ts > 61 && ts < type(uint64).max);
        uint256 id = _world(s);
        address to = _pick(toPick);
        vm.assume(to != DEAD);
        n.h_putData(id, rv, to, hex"d1");
        bytes32 c = n.makeCommitment("club", to, 0, secret);
        n.h_setCommit(c, ts - 61);
        vm.warp(ts);
        vm.deal(OTHER, FEE * 100);
        vm.prank(OTHER);
        (bool ok,) = address(n).call{value: FEE * 100}(abi.encodeCall(PageNFT.reveal, ("club", to, 0, secret)));
        if (!ok) return;
        assert(n.ownerOf(id) == to);
        assert(bytes(_text(id)).length == 0);
        assert(n.contenthash(id).length == 0);
        assert(n.data(bytes32(id), "k").length == 0);
        vm.prank(to);
        (bool kept,) = address(n).call(abi.encodeCall(PageNFT.keepProfile, (id)));
        kept;
        assert(bytes(_text(id)).length == 0);
        assert(n.contenthash(id).length == 0);
        assert(n.data(bytes32(id), "k").length == 0);
    }

    // against the reference build that keeps profiles

    function _both(S memory s) internal returns (uint256 id) {
        id = _world(s);
        f.h_setRecord(pid, "club", 0, s.exp, s.epoch, 0);
        f.h_setDeposit(pid, s.paid ? 1 : 0);
        f.h_mint(s.top ? s.holder : OWNER, pid);
        f.h_setRecord(sub, "fresh", pid, 0, 1, s.pe);
        f.h_mint(s.top ? OWNER : s.holder, sub);
        f.h_setVersion(id, s.rv);
    }

    /// @notice PP7: the three transfer forms, by any account with or without operator or token approval,
    /// to any of four accounts, succeed or fail exactly as in the PageNFTNoProfileReset reference build,
    /// with the same return or revert data and the same new holder, and never touch the stored writer
    /// or version.
    /// @dev Technique: symbolic differential against the reference build. Classification: DIRECT.
    function test_check_PP7_transfersAsReference(
        bool top, uint64 exp, uint64 epoch, uint64 pe, uint8 hPick, uint8 wPick, uint96 ver, uint64 rv, bool paid,
        uint64 ts, address caller, bool opApproved, bool tokApproved, uint8 form, uint8 toPick
    ) public {
        S memory s = S(top, exp, epoch, pe, _pick(hPick), _pickW(wPick), ver, rv, true, false, paid);
        vm.assume(caller != address(0) && caller != address(n) && caller != address(f));
        uint256 id = _both(s);
        if (opApproved) {
            n.h_setApprovalForAll(s.holder, caller, true);
            f.h_setApprovalForAll(s.holder, caller, true);
        }
        if (tokApproved) {
            n.h_approve(caller, id);
            f.h_approve(caller, id);
        }
        vm.warp(ts);
        address to = _pick(toPick);
        uint8 k = form % 3;
        bytes memory d = k == 0 ? abi.encodeWithSignature("transferFrom(address,address,uint256)", s.holder, to, id)
            : k == 1 ? abi.encodeWithSignature("safeTransferFrom(address,address,uint256)", s.holder, to, id)
            : abi.encodeWithSignature("safeTransferFrom(address,address,uint256,bytes)", s.holder, to, id, hex"01");
        vm.prank(caller);
        (bool okN, bytes memory rN) = address(n).call(d);
        vm.prank(caller);
        (bool okF, bytes memory rF) = address(f).call(d);
        assert(okN == okF);
        assert(_eqB(rN, rF));
        assert(n.h_ownerOf(id) == f.h_ownerOf(id));
        (address w, uint96 v) = n.h_profile(id);
        assert(w == s.writer && v == ver);
    }

    /// @notice PP9: in any start state, the views that do not read the profile answer as in the
    /// PageNFTNoProfileReset reference build: resolve, addr for OP, Ethereum and Base, payee,
    /// reverseResolve of four accounts and status.
    /// @dev Technique: symbolic differential of views. Classification: DIRECT.
    function test_check_PP9_viewsAsReference(
        bool top, uint64 exp, uint64 epoch, uint64 pe, uint8 hPick, uint8 wPick, uint96 ver, uint64 rv, bool paid,
        uint64 ts, uint8 rPick, uint8 svPick, uint8 xPick, uint8 phPick
    ) public {
        _pp9(top, exp, epoch, pe, hPick, wPick, ver, rv, paid, ts, rPick, svPick, xPick, phPick, 3);
    }

    // which: 0 the address views and payee, 1 reverseResolve, 2 status, 3 all
    function _pp9(
        bool top, uint64 exp, uint64 epoch, uint64 pe, uint8 hPick, uint8 wPick, uint96 ver, uint64 rv, bool paid,
        uint64 ts, uint8 rPick, uint8 svPick, uint8 xPick, uint8 phPick, uint8 which
    ) internal {
        S memory s = S(top, exp, epoch, pe, _pick(hPick), _pickW(wPick), ver, rv, true, true, paid);
        uint256 id = _both(s);
        n.h_setResolved(id, _pick(rPick), _pick(svPick));
        f.h_setResolved(id, _pick(rPick), _pick(svPick));
        address xa = _pick(xPick);
        n.h_setPrimary(xa, id, _pick(phPick));
        f.h_setPrimary(xa, id, _pick(phPick));
        vm.warp(ts);
        if (which == 0 || which == 3) {
            assert(n.resolve(id) == f.resolve(id));
            assert(_eqB(n.addr(id, 0x8000000a), f.addr(id, 0x8000000a)));
            assert(_eqB(n.addr(id, 60), f.addr(id, 60)));
            assert(_eqB(n.addr(id, 0x80002105), f.addr(id, 0x80002105)));
            assert(n.payee(id) == f.payee(id));
        }
        if (which == 1 || which == 3) assert(_eq(n.reverseResolve(xa), f.reverseResolve(xa)));
        if (which == 2 || which == 3) assert(uint256(n.status(id)) == uint256(f.status(id)));
    }

    // the same proofs split by the kind of name

    /// @notice PP1, PP4 and PP5 with the target fixed to the top level name (t) or the subpage (s),
    /// so each finishes on its own.
    function test_check_PP1t(uint64 exp, uint64 epoch, uint64 pe, uint8 hPick, uint8 wPick, uint96 ver, uint64 rv, bool cur, bool old, bool paid, uint64 ts) public {
        test_check_PP1_readRule(true, exp, epoch, pe, hPick, wPick, ver, rv, cur, old, paid, ts);
    }

    function test_check_PP1s(uint64 exp, uint64 epoch, uint64 pe, uint8 hPick, uint8 wPick, uint96 ver, uint64 rv, bool cur, bool old, bool paid, uint64 ts) public {
        test_check_PP1_readRule(false, exp, epoch, pe, hPick, wPick, ver, rv, cur, old, paid, ts);
    }

    function test_check_PP4t(uint64 exp, uint64 epoch, uint64 pe, uint8 hPick, uint8 wPick, uint96 ver, uint64 rv, bool cur, bool old, bool paid, uint64 ts, address caller) public {
        test_check_PP4_keep(true, exp, epoch, pe, hPick, wPick, ver, rv, cur, old, paid, ts, caller);
    }

    function test_check_PP4s(uint64 exp, uint64 epoch, uint64 pe, uint8 hPick, uint8 wPick, uint96 ver, uint64 rv, bool cur, bool old, bool paid, uint64 ts, address caller) public {
        test_check_PP4_keep(false, exp, epoch, pe, hPick, wPick, ver, rv, cur, old, paid, ts, caller);
    }

    function test_check_PP5t(uint64 exp, uint64 epoch, uint64 pe, uint8 hPick, uint8 wPick, uint96 ver, uint64 rv, bool cur, bool old, bool paid, uint64 ts, address caller, bool site) public {
        test_check_PP5_freshStart(true, exp, epoch, pe, hPick, wPick, ver, rv, cur, old, paid, ts, caller, site);
    }

    function test_check_PP5s(uint64 exp, uint64 epoch, uint64 pe, uint8 hPick, uint8 wPick, uint96 ver, uint64 rv, bool cur, bool old, bool paid, uint64 ts, address caller, bool site) public {
        test_check_PP5_freshStart(false, exp, epoch, pe, hPick, wPick, ver, rv, cur, old, paid, ts, caller, site);
    }

    /// @notice PP7 split by transfer form and kind of name.
    function test_check_PP7_f0t(uint64 exp, uint64 epoch, uint64 pe, uint8 hPick, uint8 wPick, uint96 ver, uint64 rv, bool paid, uint64 ts, address caller, bool op, bool tok, uint8 toPick) public {
        test_check_PP7_transfersAsReference(true, exp, epoch, pe, hPick, wPick, ver, rv, paid, ts, caller, op, tok, 0, toPick);
    }

    function test_check_PP7_f0s(uint64 exp, uint64 epoch, uint64 pe, uint8 hPick, uint8 wPick, uint96 ver, uint64 rv, bool paid, uint64 ts, address caller, bool op, bool tok, uint8 toPick) public {
        test_check_PP7_transfersAsReference(false, exp, epoch, pe, hPick, wPick, ver, rv, paid, ts, caller, op, tok, 0, toPick);
    }

    function test_check_PP7_f1t(uint64 exp, uint64 epoch, uint64 pe, uint8 hPick, uint8 wPick, uint96 ver, uint64 rv, bool paid, uint64 ts, address caller, bool op, bool tok, uint8 toPick) public {
        test_check_PP7_transfersAsReference(true, exp, epoch, pe, hPick, wPick, ver, rv, paid, ts, caller, op, tok, 1, toPick);
    }

    function test_check_PP7_f1s(uint64 exp, uint64 epoch, uint64 pe, uint8 hPick, uint8 wPick, uint96 ver, uint64 rv, bool paid, uint64 ts, address caller, bool op, bool tok, uint8 toPick) public {
        test_check_PP7_transfersAsReference(false, exp, epoch, pe, hPick, wPick, ver, rv, paid, ts, caller, op, tok, 1, toPick);
    }

    function test_check_PP7_f2t(uint64 exp, uint64 epoch, uint64 pe, uint8 hPick, uint8 wPick, uint96 ver, uint64 rv, bool paid, uint64 ts, address caller, bool op, bool tok, uint8 toPick) public {
        test_check_PP7_transfersAsReference(true, exp, epoch, pe, hPick, wPick, ver, rv, paid, ts, caller, op, tok, 2, toPick);
    }

    function test_check_PP7_f2s(uint64 exp, uint64 epoch, uint64 pe, uint8 hPick, uint8 wPick, uint96 ver, uint64 rv, bool paid, uint64 ts, address caller, bool op, bool tok, uint8 toPick) public {
        test_check_PP7_transfersAsReference(false, exp, epoch, pe, hPick, wPick, ver, rv, paid, ts, caller, op, tok, 2, toPick);
    }

    /// @notice PP8 split by the first entry and kind of name, for the first entries setText (0),
    /// keepProfile (2) and transferFrom (3). ProfileBundleProofsTest has the parts for
    /// setContenthash (1) and clearRecords (4).
    function _pp8k(bool top, uint8 k1, uint64 exp, uint64 epoch, uint64 pe, uint8 hPick, uint8 wPick, uint96 ver, uint64 rv, bool cur, bool paid, uint64 ts, address caller, bool op, uint8 k2, uint8 toPick) internal {
        test_check_PP8_bundles(top, exp, epoch, pe, hPick, wPick, ver, rv, cur, paid, ts, caller, op, k1, k2, toPick);
    }

    function test_check_PP8_k0t(uint64 exp, uint64 epoch, uint64 pe, uint8 hPick, uint8 wPick, uint96 ver, uint64 rv, bool cur, bool paid, uint64 ts, address caller, bool op, uint8 k2, uint8 toPick) public {
        _pp8k(true, 0, exp, epoch, pe, hPick, wPick, ver, rv, cur, paid, ts, caller, op, k2, toPick);
    }

    function test_check_PP8_k2t(uint64 exp, uint64 epoch, uint64 pe, uint8 hPick, uint8 wPick, uint96 ver, uint64 rv, bool cur, bool paid, uint64 ts, address caller, bool op, uint8 k2, uint8 toPick) public {
        _pp8k(true, 2, exp, epoch, pe, hPick, wPick, ver, rv, cur, paid, ts, caller, op, k2, toPick);
    }

    function test_check_PP8_k3t(uint64 exp, uint64 epoch, uint64 pe, uint8 hPick, uint8 wPick, uint96 ver, uint64 rv, bool cur, bool paid, uint64 ts, address caller, bool op, uint8 k2, uint8 toPick) public {
        _pp8k(true, 3, exp, epoch, pe, hPick, wPick, ver, rv, cur, paid, ts, caller, op, k2, toPick);
    }

    function test_check_PP8_k0s(uint64 exp, uint64 epoch, uint64 pe, uint8 hPick, uint8 wPick, uint96 ver, uint64 rv, bool cur, bool paid, uint64 ts, address caller, bool op, uint8 k2, uint8 toPick) public {
        _pp8k(false, 0, exp, epoch, pe, hPick, wPick, ver, rv, cur, paid, ts, caller, op, k2, toPick);
    }

    function test_check_PP8_k2s(uint64 exp, uint64 epoch, uint64 pe, uint8 hPick, uint8 wPick, uint96 ver, uint64 rv, bool cur, bool paid, uint64 ts, address caller, bool op, uint8 k2, uint8 toPick) public {
        _pp8k(false, 2, exp, epoch, pe, hPick, wPick, ver, rv, cur, paid, ts, caller, op, k2, toPick);
    }

    function test_check_PP8_k3s(uint64 exp, uint64 epoch, uint64 pe, uint8 hPick, uint8 wPick, uint96 ver, uint64 rv, bool cur, bool paid, uint64 ts, address caller, bool op, uint8 k2, uint8 toPick) public {
        _pp8k(false, 3, exp, epoch, pe, hPick, wPick, ver, rv, cur, paid, ts, caller, op, k2, toPick);
    }

    /// @notice PP9 split by kind of name and by view.
    function test_check_PP9t0(uint64 exp, uint64 epoch, uint64 pe, uint8 hPick, uint8 wPick, uint96 ver, uint64 rv, bool paid, uint64 ts, uint8 rPick, uint8 svPick, uint8 xPick, uint8 phPick) public {
        _pp9(true, exp, epoch, pe, hPick, wPick, ver, rv, paid, ts, rPick, svPick, xPick, phPick, 0);
    }

    function test_check_PP9t1(uint64 exp, uint64 epoch, uint64 pe, uint8 hPick, uint8 wPick, uint96 ver, uint64 rv, bool paid, uint64 ts, uint8 rPick, uint8 svPick, uint8 xPick, uint8 phPick) public {
        _pp9(true, exp, epoch, pe, hPick, wPick, ver, rv, paid, ts, rPick, svPick, xPick, phPick, 1);
    }

    function test_check_PP9t2(uint64 exp, uint64 epoch, uint64 pe, uint8 hPick, uint8 wPick, uint96 ver, uint64 rv, bool paid, uint64 ts, uint8 rPick, uint8 svPick, uint8 xPick, uint8 phPick) public {
        _pp9(true, exp, epoch, pe, hPick, wPick, ver, rv, paid, ts, rPick, svPick, xPick, phPick, 2);
    }

    function test_check_PP9s0(uint64 exp, uint64 epoch, uint64 pe, uint8 hPick, uint8 wPick, uint96 ver, uint64 rv, bool paid, uint64 ts, uint8 rPick, uint8 svPick, uint8 xPick, uint8 phPick) public {
        _pp9(false, exp, epoch, pe, hPick, wPick, ver, rv, paid, ts, rPick, svPick, xPick, phPick, 0);
    }

    function test_check_PP9s1(uint64 exp, uint64 epoch, uint64 pe, uint8 hPick, uint8 wPick, uint96 ver, uint64 rv, bool paid, uint64 ts, uint8 rPick, uint8 svPick, uint8 xPick, uint8 phPick) public {
        _pp9(false, exp, epoch, pe, hPick, wPick, ver, rv, paid, ts, rPick, svPick, xPick, phPick, 1);
    }

    function test_check_PP9s2(uint64 exp, uint64 epoch, uint64 pe, uint8 hPick, uint8 wPick, uint96 ver, uint64 rv, bool paid, uint64 ts, uint8 rPick, uint8 svPick, uint8 xPick, uint8 phPick) public {
        _pp9(false, exp, epoch, pe, hPick, wPick, ver, rv, paid, ts, rPick, svPick, xPick, phPick, 2);
    }

    /// @notice PP9t0 and PP9s0 split by holder: h0 DEAD, h1 HOLDER, h2 OWNER, h3 OTHER. Each part
    /// finishes on its own except PP9s0h1 to PP9s0h3, which are split again by the resolved
    /// address below.
    function test_check_PP9t0h0(uint64 exp, uint64 epoch, uint64 pe, uint8 wPick, uint96 ver, uint64 rv, bool paid, uint64 ts, uint8 rPick, uint8 svPick, uint8 xPick, uint8 phPick) public {
        _pp9(true, exp, epoch, pe, 0, wPick, ver, rv, paid, ts, rPick, svPick, xPick, phPick, 0);
    }

    function test_check_PP9t0h1(uint64 exp, uint64 epoch, uint64 pe, uint8 wPick, uint96 ver, uint64 rv, bool paid, uint64 ts, uint8 rPick, uint8 svPick, uint8 xPick, uint8 phPick) public {
        _pp9(true, exp, epoch, pe, 1, wPick, ver, rv, paid, ts, rPick, svPick, xPick, phPick, 0);
    }

    function test_check_PP9t0h2(uint64 exp, uint64 epoch, uint64 pe, uint8 wPick, uint96 ver, uint64 rv, bool paid, uint64 ts, uint8 rPick, uint8 svPick, uint8 xPick, uint8 phPick) public {
        _pp9(true, exp, epoch, pe, 2, wPick, ver, rv, paid, ts, rPick, svPick, xPick, phPick, 0);
    }

    function test_check_PP9t0h3(uint64 exp, uint64 epoch, uint64 pe, uint8 wPick, uint96 ver, uint64 rv, bool paid, uint64 ts, uint8 rPick, uint8 svPick, uint8 xPick, uint8 phPick) public {
        _pp9(true, exp, epoch, pe, 3, wPick, ver, rv, paid, ts, rPick, svPick, xPick, phPick, 0);
    }

    function test_check_PP9s0h0(uint64 exp, uint64 epoch, uint64 pe, uint8 wPick, uint96 ver, uint64 rv, bool paid, uint64 ts, uint8 rPick, uint8 svPick, uint8 xPick, uint8 phPick) public {
        _pp9(false, exp, epoch, pe, 0, wPick, ver, rv, paid, ts, rPick, svPick, xPick, phPick, 0);
    }

    function test_check_PP9s0h1(uint64 exp, uint64 epoch, uint64 pe, uint8 wPick, uint96 ver, uint64 rv, bool paid, uint64 ts, uint8 rPick, uint8 svPick, uint8 xPick, uint8 phPick) public {
        _pp9(false, exp, epoch, pe, 1, wPick, ver, rv, paid, ts, rPick, svPick, xPick, phPick, 0);
    }

    function test_check_PP9s0h2(uint64 exp, uint64 epoch, uint64 pe, uint8 wPick, uint96 ver, uint64 rv, bool paid, uint64 ts, uint8 rPick, uint8 svPick, uint8 xPick, uint8 phPick) public {
        _pp9(false, exp, epoch, pe, 2, wPick, ver, rv, paid, ts, rPick, svPick, xPick, phPick, 0);
    }

    function test_check_PP9s0h3(uint64 exp, uint64 epoch, uint64 pe, uint8 wPick, uint96 ver, uint64 rv, bool paid, uint64 ts, uint8 rPick, uint8 svPick, uint8 xPick, uint8 phPick) public {
        _pp9(false, exp, epoch, pe, 3, wPick, ver, rv, paid, ts, rPick, svPick, xPick, phPick, 0);
    }

    /// @notice PP9s0h1 to PP9s0h3 split again by the resolved address: r01 takes DEAD or HOLDER, r23 OWNER or
    /// OTHER, the four values _pick gives.
    function test_check_PP9s0h1r01(uint64 exp, uint64 epoch, uint64 pe, uint8 wPick, uint96 ver, uint64 rv, bool paid, uint64 ts, bool r, uint8 svPick, uint8 xPick, uint8 phPick) public {
        _pp9(false, exp, epoch, pe, 1, wPick, ver, rv, paid, ts, r ? 1 : 0, svPick, xPick, phPick, 0);
    }

    function test_check_PP9s0h1r23(uint64 exp, uint64 epoch, uint64 pe, uint8 wPick, uint96 ver, uint64 rv, bool paid, uint64 ts, bool r, uint8 svPick, uint8 xPick, uint8 phPick) public {
        _pp9(false, exp, epoch, pe, 1, wPick, ver, rv, paid, ts, r ? 3 : 2, svPick, xPick, phPick, 0);
    }

    function test_check_PP9s0h2r01(uint64 exp, uint64 epoch, uint64 pe, uint8 wPick, uint96 ver, uint64 rv, bool paid, uint64 ts, bool r, uint8 svPick, uint8 xPick, uint8 phPick) public {
        _pp9(false, exp, epoch, pe, 2, wPick, ver, rv, paid, ts, r ? 1 : 0, svPick, xPick, phPick, 0);
    }

    function test_check_PP9s0h2r23(uint64 exp, uint64 epoch, uint64 pe, uint8 wPick, uint96 ver, uint64 rv, bool paid, uint64 ts, bool r, uint8 svPick, uint8 xPick, uint8 phPick) public {
        _pp9(false, exp, epoch, pe, 2, wPick, ver, rv, paid, ts, r ? 3 : 2, svPick, xPick, phPick, 0);
    }

    function test_check_PP9s0h3r01(uint64 exp, uint64 epoch, uint64 pe, uint8 wPick, uint96 ver, uint64 rv, bool paid, uint64 ts, bool r, uint8 svPick, uint8 xPick, uint8 phPick) public {
        _pp9(false, exp, epoch, pe, 3, wPick, ver, rv, paid, ts, r ? 1 : 0, svPick, xPick, phPick, 0);
    }

    function test_check_PP9s0h3r23(uint64 exp, uint64 epoch, uint64 pe, uint8 wPick, uint96 ver, uint64 rv, bool paid, uint64 ts, bool r, uint8 svPick, uint8 xPick, uint8 phPick) public {
        _pp9(false, exp, epoch, pe, 3, wPick, ver, rv, paid, ts, r ? 3 : 2, svPick, xPick, phPick, 0);
    }

    /// @notice PP9s1 split by holder: h0 DEAD, h1 HOLDER, h2 OWNER, h3 OTHER, so each finishes on its own.
    function test_check_PP9s1h0(uint64 exp, uint64 epoch, uint64 pe, uint8 wPick, uint96 ver, uint64 rv, bool paid, uint64 ts, uint8 rPick, uint8 svPick, uint8 xPick, uint8 phPick) public {
        _pp9(false, exp, epoch, pe, 0, wPick, ver, rv, paid, ts, rPick, svPick, xPick, phPick, 1);
    }

    function test_check_PP9s1h1(uint64 exp, uint64 epoch, uint64 pe, uint8 wPick, uint96 ver, uint64 rv, bool paid, uint64 ts, uint8 rPick, uint8 svPick, uint8 xPick, uint8 phPick) public {
        _pp9(false, exp, epoch, pe, 1, wPick, ver, rv, paid, ts, rPick, svPick, xPick, phPick, 1);
    }

    function test_check_PP9s1h2(uint64 exp, uint64 epoch, uint64 pe, uint8 wPick, uint96 ver, uint64 rv, bool paid, uint64 ts, uint8 rPick, uint8 svPick, uint8 xPick, uint8 phPick) public {
        _pp9(false, exp, epoch, pe, 2, wPick, ver, rv, paid, ts, rPick, svPick, xPick, phPick, 1);
    }

    function test_check_PP9s1h3(uint64 exp, uint64 epoch, uint64 pe, uint8 wPick, uint96 ver, uint64 rv, bool paid, uint64 ts, uint8 rPick, uint8 svPick, uint8 xPick, uint8 phPick) public {
        _pp9(false, exp, epoch, pe, 3, wPick, ver, rv, paid, ts, rPick, svPick, xPick, phPick, 1);
    }

    /// @notice PP9s2 split by holder: h0 DEAD, h1 HOLDER, h2 OWNER, h3 OTHER, so each finishes on its own.
    function test_check_PP9s2h0(uint64 exp, uint64 epoch, uint64 pe, uint8 wPick, uint96 ver, uint64 rv, bool paid, uint64 ts, uint8 rPick, uint8 svPick, uint8 xPick, uint8 phPick) public {
        _pp9(false, exp, epoch, pe, 0, wPick, ver, rv, paid, ts, rPick, svPick, xPick, phPick, 2);
    }

    function test_check_PP9s2h1(uint64 exp, uint64 epoch, uint64 pe, uint8 wPick, uint96 ver, uint64 rv, bool paid, uint64 ts, uint8 rPick, uint8 svPick, uint8 xPick, uint8 phPick) public {
        _pp9(false, exp, epoch, pe, 1, wPick, ver, rv, paid, ts, rPick, svPick, xPick, phPick, 2);
    }

    function test_check_PP9s2h2(uint64 exp, uint64 epoch, uint64 pe, uint8 wPick, uint96 ver, uint64 rv, bool paid, uint64 ts, uint8 rPick, uint8 svPick, uint8 xPick, uint8 phPick) public {
        _pp9(false, exp, epoch, pe, 2, wPick, ver, rv, paid, ts, rPick, svPick, xPick, phPick, 2);
    }

    function test_check_PP9s2h3(uint64 exp, uint64 epoch, uint64 pe, uint8 wPick, uint96 ver, uint64 rv, bool paid, uint64 ts, uint8 rPick, uint8 svPick, uint8 xPick, uint8 phPick) public {
        _pp9(false, exp, epoch, pe, 3, wPick, ver, rv, paid, ts, rPick, svPick, xPick, phPick, 2);
    }

    /// @notice PP2 for renew, split by kind of name.
    function test_check_PP2_w15t(uint64 exp, uint64 epoch, uint64 pe, uint8 hPick, uint8 wPick, uint96 ver, uint64 rv, bool paid, uint64 ts, address caller, bool op, bool tok, uint8 toPick, uint8 x) public {
        _pp2(true, exp, epoch, pe, hPick, wPick, ver, rv, paid, ts, caller, op, tok, 15, toPick, x);
    }

    function test_check_PP2_w15s(uint64 exp, uint64 epoch, uint64 pe, uint8 hPick, uint8 wPick, uint96 ver, uint64 rv, bool paid, uint64 ts, address caller, bool op, bool tok, uint8 toPick, uint8 x) public {
        _pp2(false, exp, epoch, pe, hPick, wPick, ver, rv, paid, ts, caller, op, tok, 15, toPick, x);
    }

    // data records

    /// @notice DR1: for any start state and time, data(node, "k") answers the stored record exactly when the
    /// name is active and the account that saved the record holds it, and is empty otherwise. A record saved
    /// in an older record version is never answered, and the stored writer of the profile plays no part.
    /// @dev Technique: built symbolic state, exact characterization of a view. Classification: DIRECT.
    function test_check_DR1_readRule(
        bool top, uint64 exp, uint64 epoch, uint64 pe, uint8 hPick, uint8 wPick, uint8 sPick, uint64 rv, bool cur,
        bool old, bool paid, uint64 ts
    ) public {
        S memory s = S(top, exp, epoch, pe, _pick(hPick), _pickW(wPick), 0, rv, true, false, paid);
        uint256 id = _world(s);
        address saver = _pickW(sPick);
        if (cur) n.h_putData(id, rv, saver, hex"d1");
        // a record the holder saved in the record version before
        if (old && rv > 0) n.h_putData(id, rv - 1, s.holder, hex"0bad");
        vm.warp(ts);
        bool counts = cur && _activeOf(s, ts) && saver == s.holder;
        assert(_eqB(n.data(bytes32(id), "k"), counts ? bytes(hex"d1") : bytes("")));
    }

    /// @notice DR2: setData by any account succeeds exactly when the name is active and the caller holds it,
    /// and reverts Expired or Unauthorized in that order otherwise. On success the record of the current
    /// record version holds the caller and the value, and data answers the value. The profile writer and its
    /// version, the record version, the text, the main address, holderSince and addressesUpdatedAt never
    /// move, and a failed call keeps the record as it was.
    /// @dev Technique: built symbolic state, symbolic caller. Classification: DIRECT.
    function test_check_DR2_setData(
        bool top, uint64 exp, uint64 epoch, uint64 pe, uint8 hPick, uint8 wPick, uint8 sPick, uint64 rv, bool paid,
        uint64 ts, address caller, uint64 since, uint64 updated
    ) public {
        S memory s = S(top, exp, epoch, pe, _pick(hPick), _pickW(wPick), 0, rv, true, false, paid);
        // Justification: no transaction has msg.sender == address(0)
        vm.assume(caller != address(0));
        uint256 id = _world(s);
        address saver = _pickW(sPick);
        n.h_putData(id, rv, saver, hex"d1");
        n.h_setTimes(id, since, updated);
        vm.warp(ts);
        bool active = _activeOf(s, ts);
        string memory t0 = _text(id);
        address r0 = n.resolve(id);
        vm.prank(caller);
        (bool ok, bytes memory ret) = address(n).call(abi.encodeCall(PageNFT.setData, (id, "k", hex"77")));
        bytes4 want = !active ? PageNFT.Expired.selector
            : caller != s.holder ? PageNFT.Unauthorized.selector : bytes4(0);
        assert(ok == (want == bytes4(0)));
        (address w, uint96 v) = n.h_profile(id);
        assert(w == s.writer && v == 0);
        assert(n.recordVersion(id) == rv);
        assert(_eq(_text(id), t0));
        assert(n.resolve(id) == r0);
        assert(n.holderSince(id) == since && n.addressesUpdatedAt(id) == updated);
        (address ds, bytes memory dv) = n.h_data(id, rv);
        if (!ok) {
            assert(bytes4(ret) == want && ret.length == 4);
            assert(ds == saver && _eqB(dv, hex"d1"));
            return;
        }
        assert(ds == caller && _eqB(dv, hex"77"));
        assert(_eqB(n.data(bytes32(id), "k"), hex"77"));
    }

    /// @notice DR2k: one keepProfile or one transfer (the three forms, to any of four accounts), by any account
    /// with no code, with or without operator approval, over a record saved by any account: afterwards data
    /// answers the record exactly when the name is active and the account that saved the record holds it. So
    /// keepProfile never changes what data answers, and a transfer brings a record back only to the account
    /// that saved it. PP6 and PP6t prove that a new mint and a new registration leave no record readable.
    /// @dev Technique: built symbolic state, one symbolic call. Classification: DIRECT.
    function test_check_DR2k_keepAndMove(
        bool top, uint64 exp, uint64 epoch, uint64 pe, uint8 hPick, uint8 wPick, uint8 sPick, uint64 rv, bool paid,
        uint64 ts, address caller, bool opApproved, uint8 k, uint8 toPick
    ) public {
        S memory s = S(top, exp, epoch, pe, _pick(hPick), _pickW(wPick), 0, rv, false, false, paid);
        // Justification: no transaction has msg.sender == address(0); the contract never calls itself
        // except through multicall, proved separately
        vm.assume(caller != address(0) && caller != address(n));
        vm.assume(caller.code.length == 0);
        uint256 id = _world(s);
        address saver = _pickW(sPick);
        n.h_putData(id, rv, saver, hex"d1");
        if (opApproved) n.h_setApprovalForAll(s.holder, caller, true);
        vm.warp(ts);
        bytes memory before = n.data(bytes32(id), "k");
        address to = _pick(toPick);
        uint8 m = k % 4;
        bytes memory d = m == 0 ? abi.encodeCall(PageNFT.keepProfile, (id))
            : m == 1 ? abi.encodeWithSignature("transferFrom(address,address,uint256)", s.holder, to, id)
            : m == 2 ? abi.encodeWithSignature("safeTransferFrom(address,address,uint256)", s.holder, to, id)
            : abi.encodeWithSignature("safeTransferFrom(address,address,uint256,bytes)", s.holder, to, id, hex"01");
        vm.prank(caller);
        (bool ok,) = address(n).call(d);
        ok;
        bytes memory got = n.data(bytes32(id), "k");
        if (m == 0) assert(_eqB(got, before));
        // a transfer changes only the holder of the start state
        s.holder = n.h_ownerOf(id);
        bool counts = _activeOf(s, ts) && saver == s.holder;
        assert(_eqB(got, counts ? bytes(hex"d1") : bytes("")));
    }

    // holderSince and addressesUpdatedAt

    // one call of the PP2 dispatcher from a start state with any stored times on both names
    function _hs(
        bool top, uint64 exp, uint64 epoch, uint64 pe, uint8 hPick, bool paid, uint64 ts, address caller,
        bool opApproved, bool tokApproved, uint8 which, uint8 toPick, uint8 x, uint64[4] memory t0
    ) internal {
        S memory s = S(top, exp, epoch, pe, _pick(hPick), address(0), 0, 0, false, false, paid);
        // Justification: as in PP2
        vm.assume(caller != address(0) && caller != address(n));
        vm.assume(caller.code.length == 0);
        uint256 id = _world(s);
        n.h_setTimes(pid, t0[0], t0[1]);
        n.h_setTimes(sub, t0[2], t0[3]);
        if (opApproved) n.h_setApprovalForAll(s.holder, caller, true);
        if (tokApproved) n.h_approve(caller, id);
        vm.deal(caller, FEE4);
        vm.warp(ts);
        address to = _pick(toPick);
        uint8 k = which % 17;
        vm.prank(caller);
        (bool ok,) = _call(which, id, s.holder, to, _pick(x));
        // the name went to another account, the subpage was minted again, or an address writer ran on the name
        bool moved = ok && k >= 6 && k <= 8 && to != s.holder;
        bool minted = ok && k == 12;
        bool saved = ok && k >= 3 && k <= 5;
        assert(n.holderSince(pid) == (top && moved ? ts : t0[0]));
        assert(n.addressesUpdatedAt(pid) == (top && saved ? ts : t0[1]));
        assert(n.holderSince(sub) == ((!top && moved) || minted ? ts : t0[2]));
        assert(n.addressesUpdatedAt(sub) == (!top && saved ? ts : t0[3]));
    }

    /// @notice HS1 and AU1: for any start state, any stored times on both names and any one of the 17 calls of
    /// PP2, by any account that has no code and is not zero or this contract, with or without operator and
    /// token approval: holderSince of a name changes only when the call moved it to another account or minted
    /// it, and then it is the time of the call; addressesUpdatedAt of a name changes only in a successful
    /// setAddr, setAddrForCoin or clearRecords of that name, and then it is the time of the call. A failed
    /// call, a transfer to the holder itself and every other call leave both as they were. Split by call so
    /// each part finishes: x the three transfer forms, m the subpage mint over the existing subpage, w the
    /// address writers, o0 the profile writes and setData, o1 the approvals, the display name and the minter
    /// pick, o2t and o2s release and renew for the top level name and for the subpage, as renew is split by
    /// kind of name in PP2 too. AU1 states the address writers exactly, HS1r a registration and HS1b a
    /// bundle.
    /// @dev Technique: dispatcher with symbolic selector index, caller and arguments; recipients and the
    /// address argument from four accounts. Classification: DIRECT.
    function test_check_HS1x_transfers(bool top, uint64 exp, uint64 epoch, uint64 pe, uint8 hPick, bool paid, uint64 ts, address caller, bool op, bool tok, uint8 which, uint8 toPick, uint8 x, uint64[4] memory t0) public {
        uint8 k = which % 17;
        vm.assume(k >= 6 && k <= 8);
        _hs(top, exp, epoch, pe, hPick, paid, ts, caller, op, tok, which, toPick, x, t0);
    }

    function test_check_HS1m_subpageMint(bool top, uint64 exp, uint64 epoch, uint64 pe, uint8 hPick, bool paid, uint64 ts, address caller, bool op, bool tok, uint8 which, uint8 toPick, uint8 x, uint64[4] memory t0) public {
        vm.assume(which % 17 == 12);
        _hs(top, exp, epoch, pe, hPick, paid, ts, caller, op, tok, which, toPick, x, t0);
    }

    function test_check_HS1w_addressWriters(bool top, uint64 exp, uint64 epoch, uint64 pe, uint8 hPick, bool paid, uint64 ts, address caller, bool op, bool tok, uint8 which, uint8 toPick, uint8 x, uint64[4] memory t0) public {
        uint8 k = which % 17;
        vm.assume(k >= 3 && k <= 5);
        _hs(top, exp, epoch, pe, hPick, paid, ts, caller, op, tok, which, toPick, x, t0);
    }

    function test_check_HS1o0(bool top, uint64 exp, uint64 epoch, uint64 pe, uint8 hPick, bool paid, uint64 ts, address caller, bool op, bool tok, uint8 which, uint8 toPick, uint8 x, uint64[4] memory t0) public {
        uint8 k = which % 17;
        vm.assume(k <= 2 || k == 16);
        _hs(top, exp, epoch, pe, hPick, paid, ts, caller, op, tok, which, toPick, x, t0);
    }

    function test_check_HS1o1(bool top, uint64 exp, uint64 epoch, uint64 pe, uint8 hPick, bool paid, uint64 ts, address caller, bool op, bool tok, uint8 which, uint8 toPick, uint8 x, uint64[4] memory t0) public {
        uint8 k = which % 17;
        vm.assume(k == 9 || k == 10 || k == 11 || k == 13);
        _hs(top, exp, epoch, pe, hPick, paid, ts, caller, op, tok, which, toPick, x, t0);
    }

    function test_check_HS1o2t(uint64 exp, uint64 epoch, uint64 pe, uint8 hPick, bool paid, uint64 ts, address caller, bool op, bool tok, uint8 which, uint8 toPick, uint8 x, uint64[4] memory t0) public {
        uint8 k = which % 17;
        vm.assume(k == 14 || k == 15);
        _hs(true, exp, epoch, pe, hPick, paid, ts, caller, op, tok, which, toPick, x, t0);
    }

    function test_check_HS1o2s(uint64 exp, uint64 epoch, uint64 pe, uint8 hPick, bool paid, uint64 ts, address caller, bool op, bool tok, uint8 which, uint8 toPick, uint8 x, uint64[4] memory t0) public {
        uint8 k = which % 17;
        vm.assume(k == 14 || k == 15);
        _hs(false, exp, epoch, pe, hPick, paid, ts, caller, op, tok, which, toPick, x, t0);
    }

    // the coin types AU1 saves: the home chain, 60, the default EVM coin type, Base and coin type 0
    function _coin(uint8 m) internal pure returns (uint256) {
        if (m == 0) return 0x8000000a;
        if (m == 1) return 60;
        if (m == 2) return 0x80000000;
        if (m == 3) return 0x80002105;
        return 0;
    }

    /// @notice AU1: setAddr with an address or zero, clearRecords, and setAddrForCoin for the home chain, coin
    /// type 60, the default EVM coin type, Base or coin type 0, with 20 bytes or empty, by any account: the
    /// call succeeds exactly when the name is active and the caller holds it. addressesUpdatedAt is then the
    /// time of the call and otherwise stays as it was, and holderSince never moves.
    /// @dev Technique: built symbolic state, one symbolic call. Classification: DIRECT.
    function test_check_AU1_addressWriters(
        bool top, uint64 exp, uint64 epoch, uint64 pe, uint8 hPick, bool paid, uint64 ts, address caller, uint8 k,
        uint8 x, bool empty, uint64 since, uint64 updated
    ) public {
        S memory s = S(top, exp, epoch, pe, _pick(hPick), address(0), 0, 0, false, false, paid);
        // Justification: no transaction has msg.sender == address(0)
        vm.assume(caller != address(0));
        uint256 id = _world(s);
        n.h_setTimes(id, since, updated);
        vm.warp(ts);
        address a = empty ? address(0) : _pick(x);
        uint8 m = k % 7;
        bytes memory d = m == 0 ? abi.encodeCall(PageNFT.setAddr, (id, a))
            : m == 1 ? abi.encodeCall(PageNFT.clearRecords, (id))
            : abi.encodeCall(PageNFT.setAddrForCoin, (id, _coin(m - 2), empty ? bytes("") : abi.encodePacked(a)));
        vm.prank(caller);
        (bool ok,) = address(n).call(d);
        assert(ok == (_activeOf(s, ts) && caller == s.holder));
        assert(n.addressesUpdatedAt(id) == (ok ? ts : updated));
        assert(n.holderSince(id) == since);
    }

    /// @notice HS1r: a paid registration by OTHER for HOLDER, OWNER or OTHER, of a label with no record or of
    /// the top level name over its ended trial, sets holderSince to the time of the registration and leaves
    /// addressesUpdatedAt as it was; a failed one changes neither.
    /// @dev Technique: built symbolic state with a stored commitment. Classification: DIRECT.
    function test_check_HS1r_registration(
        uint64 exp, uint8 hPick, uint64 ts, uint8 toPick, bytes32 secret, bool fresh, uint64 since, uint64 updated
    ) public {
        _world(S(true, exp, 1, 0, _pick(hPick), address(0), 0, 0, false, false, false));
        // Justification: the time is after the trial's end and far below the limit of the commitment math
        vm.assume(ts > exp && ts > 61 && ts < type(uint64).max);
        string memory label = fresh ? "nova" : "club";
        uint256 id = fresh ? nova : pid;
        n.h_setTimes(id, since, updated);
        address to = _pick(toPick);
        vm.assume(to != DEAD);
        n.h_setCommit(n.makeCommitment(label, to, 0, secret), ts - 61);
        vm.warp(ts);
        vm.deal(OTHER, FEE * 100);
        vm.prank(OTHER);
        (bool ok,) = address(n).call{value: FEE * 100}(abi.encodeCall(PageNFT.reveal, (label, to, 0, secret)));
        assert(n.holderSince(id) == (ok ? ts : since));
        assert(n.addressesUpdatedAt(id) == updated);
        if (ok) assert(n.ownerOf(id) == to);
    }

    function _hsEntry(uint8 k, uint256 id, address holder, address to) internal pure returns (bytes memory) {
        uint8 m = k % 4;
        if (m == 0) return abi.encodeWithSignature("transferFrom(address,address,uint256)", holder, to, id);
        if (m == 1) return abi.encodeWithSignature("transferFrom(address,address,uint256)", to, holder, id);
        if (m == 2) return abi.encodeCall(PageNFT.setAddr, (id, to));
        return abi.encodeCall(PageNFT.setData, (id, "k", hex"01"));
    }

    /// @notice HS1b: on the top level name, a bundle of two of a transfer from the holder to an account, the
    /// transfer back, setAddr and setData, by any account with no code, with or without operator approval
    /// from both accounts: holderSince is the time of the bundle when it succeeded and held a transfer
    /// between two different accounts, and addressesUpdatedAt when it succeeded and held setAddr; otherwise
    /// both stay as they were. The parts of HS1 cover the subpage call by call.
    /// @dev Technique: two symbolic entries through multicall. Classification: DIRECT.
    function test_check_HS1b_bundle(
        uint64 exp, uint8 hPick, bool paid, uint64 ts, address caller, bool opApproved, uint8 k1, uint8 k2,
        uint8 toPick, uint64 since, uint64 updated
    ) public {
        S memory s = S(true, exp, 1, 0, _pick(hPick), address(0), 0, 0, false, false, paid);
        // Justification: as in PP8
        vm.assume(caller != address(0) && caller != address(n));
        vm.assume(caller.code.length == 0);
        uint256 id = _world(s);
        n.h_setTimes(id, since, updated);
        address to = _pick(toPick);
        if (opApproved) {
            n.h_setApprovalForAll(s.holder, caller, true);
            n.h_setApprovalForAll(to, caller, true);
        }
        vm.warp(ts);
        bytes[] memory d = new bytes[](2);
        d[0] = _hsEntry(k1, id, s.holder, to);
        d[1] = _hsEntry(k2, id, s.holder, to);
        vm.prank(caller);
        (bool ok,) = address(n).call(abi.encodeCall(PageNFT.multicall, (d)));
        bool moves = (k1 % 4 < 2 || k2 % 4 < 2) && to != s.holder;
        bool saves = k1 % 4 == 2 || k2 % 4 == 2;
        assert(n.holderSince(id) == (ok && moves ? ts : since));
        assert(n.addressesUpdatedAt(id) == (ok && saves ? ts : updated));
    }
}

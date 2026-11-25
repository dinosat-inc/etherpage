// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {PageCard} from "../src/PageCard.sol";
import {PageNFT} from "../src/PageNFT.sol";
import {HolderHarnessA, HolderHarnessB} from "./HolderHarness.sol";

/// @notice Symbolic proofs for the holder check on display names. World a is the PageNFTNoHolder
/// reference build, which keeps no holder with the pointer, world b is src. HD1 to HD3 give both the
/// same symbolic start state through the harness, except that only the top level name in b starts
/// with a deposit of 1, which a never reads there. HD4 uses world b alone.
/// Halmos: FOUNDRY_PROFILE=proofs halmos --contract HolderProofsTest --function test_check_HD --forge-build-out out-proofs --loop 4 --storage-layout generic
contract HolderProofsTest is Test {
    PageCard card;
    HolderHarnessA a;
    HolderHarnessB b;

    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address constant OWNER = address(0xA11CE);
    address constant HOLDER = address(0xB0B);
    address constant OTHER = address(0xC0FFEE);
    address constant PTE = address(0x407);
    address constant OPR = address(0x0FE2);
    address constant MINTER = address(0x3117);
    uint256 constant COIN_OP = 0x8000000a;
    bytes32 constant ROOT = 0x62460c06d95b73747abf6ea4f28aefd78b4ad2abee112e7cf15fe6a924cca3c6;

    uint256 pid;
    uint256 sub;

    function setUp() public {
        card = new PageCard();
        a = new HolderHarnessA(card);
        b = new HolderHarnessB(card);
        pid = uint256(keccak256(abi.encodePacked(ROOT, keccak256(bytes("club")))));
        sub = uint256(keccak256(abi.encodePacked(bytes32(pid), keccak256(bytes("fresh")))));
    }

    function _pick(uint8 p) internal pure returns (address) {
        uint8 k = p % 5;
        if (k == 0) return DEAD;
        if (k == 1) return HOLDER;
        if (k == 2) return OWNER;
        if (k == 3) return PTE;
        return OTHER;
    }

    function _world(uint64 exp, uint64 epoch, uint64 pe, address pHolder, address holder) internal {
        a.h_setRecord(pid, "club", 0, exp, epoch, 0);
        b.h_setRecord(pid, "club", 0, exp, epoch, 0);
        a.h_mint(pHolder, pid);
        b.h_mint(pHolder, pid);
        a.h_setRecord(sub, "fresh", pid, 0, 1, pe);
        b.h_setRecord(sub, "fresh", pid, 0, 1, pe);
        a.h_mint(holder, sub);
        b.h_mint(holder, sub);
        a.h_setProfile(sub);
        b.h_setProfile(sub);
    }

    function _eqS(string memory x, string memory y) internal pure returns (bool) {
        return keccak256(bytes(x)) == keccak256(bytes(y));
    }

    function _rr(address w, address x) internal view returns (bool ok, string memory s) {
        bytes memory r;
        (ok, r) = w.staticcall(abi.encodeCall(PageNFT.reverseResolve, (x)));
        if (ok) s = abi.decode(r, (string));
    }

    /// @notice HD1: for any state (either kind of name, any holder including DEAD, any saved main
    /// address and saver, any time, any pointer and any stored holder), reverseResolve never reverts
    /// in either world. In src it equals the reference build's answer when the name's current holder
    /// is the stored holder, and is empty otherwise. A nonempty answer in src implies the name is
    /// held by the stored holder and resolves to the account.
    /// @dev Technique: symbolic differential of a view. Classification: DIRECT.
    function test_check_HD1_reverseResolve(
        uint64 exp, uint64 epoch, uint64 pe, uint64 ts, uint8 hPick, bool top, bool saved, uint8 rPick,
        uint8 svPick, uint8 xPick, uint8 sPick, uint8 pk, uint256 v
    ) public {
        _hd1(exp, epoch, pe, ts, hPick, top, saved, rPick, svPick, xPick, sPick, pk, v);
    }

    /// @notice HD1t and HD1s: HD1 split by the kind of name, with the pointer one of the two names
    /// or zero, so each finishes.
    function test_check_HD1t(uint64 exp, uint64 epoch, uint64 pe, uint64 ts, uint8 hPick, bool saved, uint8 rPick,
        uint8 svPick, uint8 xPick, uint8 sPick, uint8 pk) public {
        _hd1(exp, epoch, pe, ts, hPick, true, saved, rPick, svPick, xPick, sPick, pk % 3, 0);
    }

    function test_check_HD1s(uint64 exp, uint64 epoch, uint64 pe, uint64 ts, uint8 hPick, bool saved, uint8 rPick,
        uint8 svPick, uint8 xPick, uint8 sPick, uint8 pk) public {
        _hd1(exp, epoch, pe, ts, hPick, false, saved, rPick, svPick, xPick, sPick, pk % 3, 0);
    }

    function _hd1(
        uint64 exp, uint64 epoch, uint64 pe, uint64 ts, uint8 hPick, bool top, bool saved, uint8 rPick,
        uint8 svPick, uint8 xPick, uint8 sPick, uint8 pk, uint256 v
    ) internal {
        address holder = _pick(hPick);
        _world(exp, epoch, pe, top ? holder : OWNER, top ? OWNER : holder);
        uint256 id = top ? pid : sub;
        if (saved) {
            a.h_setResolved(id, _pick(rPick), _pick(svPick));
            b.h_setResolved(id, _pick(rPick), _pick(svPick));
        }
        address x = _pick(xPick);
        address s = _pick(sPick);
        uint8 p = pk % 4;
        uint256 ptr = p == 0 ? id : p == 1 ? (top ? sub : pid) : p == 2 ? 0 : v;
        a.h_setPrimary(x, ptr);
        b.h_setPrimary(x, ptr);
        b.h_setHolder(x, s);
        vm.warp(ts);
        (bool okA, string memory ra) = _rr(address(a), x);
        (bool okB, string memory rb) = _rr(address(b), x);
        assert(okA && okB);
        if (ptr == 0) {
            assert(bytes(rb).length == 0);
            return;
        }
        if (b.h_ownerOf(ptr) == s) assert(_eqS(ra, rb));
        else assert(bytes(rb).length == 0);
        if (bytes(rb).length != 0) {
            assert(b.resolve(ptr) == x);
            assert(b.h_ownerOf(ptr) == s);
        }
    }

    /// @notice HD2: setPrimaryPage by any of five callers, with the name, 0, the other name or any
    /// id, succeeds in src exactly when it does in the reference build, with the same return or revert
    /// data and the same pointer. On success with a nonzero id, src stores the name's holder at the
    /// call as the caller's stored holder; otherwise the caller's stored holder is unchanged. Another
    /// account's pointer and stored holder never change.
    /// @dev Technique: symbolic differential of the write path. Classification: DIRECT.
    function test_check_HD2_setPrimaryPage(
        uint64 exp, uint64 epoch, uint64 pe, uint64 ts, uint8 hPick, bool top, bool saved, uint8 rPick,
        uint8 svPick, uint8 cPick, uint8 argPick, uint256 v, uint256 preC, address preS, address y, uint256 preY,
        address preYS
    ) public {
        address holder = _pick(hPick);
        _world(exp, epoch, pe, top ? holder : OWNER, top ? OWNER : holder);
        uint256 id = top ? pid : sub;
        if (saved) {
            a.h_setResolved(id, _pick(rPick), _pick(svPick));
            b.h_setResolved(id, _pick(rPick), _pick(svPick));
        }
        address caller = _pick(cPick);
        vm.assume(y != caller);
        a.h_setPrimary(caller, preC);
        b.h_setPrimary(caller, preC);
        b.h_setHolder(caller, preS);
        a.h_setPrimary(y, preY);
        b.h_setPrimary(y, preY);
        b.h_setHolder(y, preYS);
        uint8 t = argPick % 4;
        uint256 arg = t == 0 ? id : t == 1 ? 0 : t == 2 ? (top ? sub : pid) : v;
        address ownerBefore = b.h_ownerOf(arg);
        vm.warp(ts);
        bytes memory d = abi.encodeCall(PageNFT.setPrimaryPage, (arg));
        vm.prank(caller);
        (bool okA, bytes memory rA) = address(a).call(d);
        vm.prank(caller);
        (bool okB, bytes memory rB) = address(b).call(d);
        assert(okA == okB);
        assert(keccak256(rA) == keccak256(rB));
        assert(a.primaryPage(caller) == b.primaryPage(caller));
        if (okB && arg != 0) assert(b.h_holder(caller) == ownerBefore);
        else assert(b.h_holder(caller) == preS);
        assert(b.h_ownerOf(arg) == ownerBefore);
        assert(a.primaryPage(y) == preY && b.primaryPage(y) == preY);
        assert(b.h_holder(y) == preYS);
    }

    function _xfer(uint8 kind, address from, address to, uint256 id) internal pure returns (bytes memory) {
        uint8 k = kind % 3;
        if (k == 0) return abi.encodeWithSignature("transferFrom(address,address,uint256)", from, to, id);
        if (k == 1) return abi.encodeWithSignature("safeTransferFrom(address,address,uint256)", from, to, id);
        return abi.encodeWithSignature("safeTransferFrom(address,address,uint256,bytes)", from, to, id, hex"01");
    }

    // a symbolic address as argument makes the event encoding use a symbolic memory offset, so the
    // argument is one of seven fixed accounts, zero included
    function _pickY(uint8 p) internal pure returns (address) {
        uint8 k = p % 7;
        if (k == 0) return address(0);
        if (k == 1) return DEAD;
        if (k == 2) return HOLDER;
        if (k == 3) return OWNER;
        if (k == 4) return PTE;
        if (k == 5) return OTHER;
        return OPR;
    }

    function _both(address caller, bytes memory d) internal returns (bool okA, bool okB) {
        vm.prank(caller);
        (okA,) = address(a).call(d);
        vm.prank(caller);
        (okB,) = address(b).call(d);
    }

    /// @notice HD3: HOLDER saves PTE as the main address and PTE chooses the name as its display
    /// name. After HOLDER sells to OTHER, no single call by any account other than PTE and HOLDER, of
    /// twelve kinds (pointing the name at PTE directly or in a bundle, saving an address, clearing
    /// records, writing text, choosing any display name, sending the name to anyone but HOLDER on the
    /// three transfer paths, minting the subpage again to anyone, approvals), makes reverseResolve(PTE)
    /// nonempty in src (argument addresses are seven fixed accounts, zero included). The reference
    /// build shows the name again once the buyer points it back, so the proof is not vacuous. Sending
    /// the name back to HOLDER is the documented exception and is excluded.
    /// @dev Technique: symbolic dispatcher after a symbolic sale. Classification: DIRECT.
    function test_check_HD3_pointeeNotRevived(
        uint64 exp, uint64 epoch, uint64 pe, uint64 ts, bool top, uint8 kind, bool pointBack, uint8 which,
        address caller, uint8 yPick, uint256 x
    ) public {
        uint256 id = top ? pid : sub;
        _world(exp, epoch, pe, top ? HOLDER : OWNER, top ? OWNER : HOLDER);
        vm.warp(ts);
        (bool s1a, bool s1b) = _both(HOLDER, abi.encodeWithSignature("setAddr(uint256,address)", id, PTE));
        assert(s1a == s1b);
        vm.assume(s1b);
        (bool s2a, bool s2b) = _both(PTE, abi.encodeCall(PageNFT.setPrimaryPage, (id)));
        assert(s2a == s2b);
        vm.assume(s2b);
        assert(b.h_holder(PTE) == HOLDER);
        (bool okA, bool okB) = _both(HOLDER, _xfer(kind, HOLDER, OTHER, id));
        assert(okA == okB);
        vm.assume(okB);
        if (pointBack) {
            (bool pa, bool pb) = _both(OTHER, abi.encodeWithSignature("setAddr(uint256,address)", id, PTE));
            assert(pa == pb);
            if (pb) {
                (, string memory ra) = _rr(address(a), PTE);
                assert(bytes(ra).length != 0);
            }
        }
        // Justification: no call has msg.sender == address(0); PTE and HOLDER are the two accounts
        // allowed to act for the setting
        vm.assume(caller != PTE && caller != HOLDER && caller != address(0));
        uint8 w = which % 12;
        address y = _pickY(yPick);
        bytes memory d;
        if (w == 0) d = abi.encodeWithSignature("setAddr(uint256,address)", id, y);
        else if (w == 1) d = abi.encodeCall(PageNFT.setAddrForCoin, (id, COIN_OP, abi.encodePacked(y)));
        else if (w == 2) d = abi.encodeCall(PageNFT.setPrimaryPage, (x));
        else if (w == 3) d = abi.encodeCall(PageNFT.clearRecords, (id));
        else if (w == 4) d = abi.encodeCall(PageNFT.setText, (id, "url", "x"));
        else if (w == 5 || w == 6 || w == 7) {
            // Justification: sending the name back to HOLDER is the documented exception
            vm.assume(y != HOLDER);
            d = _xfer(w - 5, OTHER, y, id);
        } else if (w == 8) d = abi.encodeCall(PageNFT.registerSubpageFor, ("fresh", pid, y));
        else if (w == 9) {
            bytes[] memory inner = new bytes[](1);
            inner[0] = abi.encodeWithSignature("setAddr(uint256,address)", id, PTE);
            d = abi.encodeCall(PageNFT.multicall, (inner));
        } else if (w == 10) d = abi.encodeWithSignature("approve(address,uint256)", y, id);
        else d = abi.encodeWithSignature("setApprovalForAll(address,bool)", y, true);
        vm.prank(caller);
        (bool ok,) = address(b).call(d);
        ok;
        (bool okR, string memory rb) = _rr(address(b), PTE);
        assert(okR);
        assert(bytes(rb).length == 0);
        assert(b.primaryPage(PTE) == id);
    }

    // HD4, one step from any state

    struct Pre {
        uint256 id;
        address x;
        address s;
        address owner;
        uint256 version;
        bool active;
    }

    // Accounts are interchangeable apart from DEAD, so the account under test is fixed as PTE and
    // every other role ranges over a small set that can also equal PTE:
    // holder of the name: PTE, HOLDER, OTHER or DEAD; stored holder, saved main address and its
    // saver: PTE, HOLDER or OTHER (DEAD never calls, so it is never a saver or a stored holder)
    function _h4(uint8 p) internal pure returns (address) {
        uint8 k = p % 4;
        return k == 0 ? PTE : k == 1 ? HOLDER : k == 2 ? OTHER : DEAD;
    }

    function _p3(uint8 p) internal pure returns (address) {
        uint8 k = p % 3;
        return k == 0 ? PTE : k == 1 ? HOLDER : OTHER;
    }

    // the caller is one of four accounts other than PTE: HOLDER or OTHER, which may hold the name,
    // OWNER, which holds the other name, or OPR, which holds neither; HD4m also lets MINTER, the
    // parent's minter, make the two subpage mints, and HD4x and HD4tr may also make the caller
    // approved or an operator
    function _c4(uint8 p) internal pure returns (address) {
        uint8 k = p % 4;
        return k == 0 ? HOLDER : k == 1 ? OTHER : k == 2 ? OPR : OWNER;
    }

    function _y5(uint8 p) internal pure returns (address) {
        uint8 k = p % 5;
        return k == 0 ? address(0) : k == 1 ? PTE : k == 2 ? HOLDER : k == 3 ? OTHER : DEAD;
    }

    // world b only: the name under test held by holder, the other name by OWNER, an optional saved
    // main address, PTE pointing at the name with stored holder s, and PTE showing nothing
    function _w4(
        uint64 exp, uint64 epoch, uint64 pe, uint64 ts, uint8 hPick, bool top, bool saved, uint8 rPick,
        uint8 svPick, uint8 sPick
    ) internal returns (Pre memory p) {
        return _w4w(exp, epoch, pe, ts, hPick, top, saved, rPick, svPick, sPick, false, address(0));
    }

    // _w4 that can also set the name's stored writer before PTE is checked
    function _w4w(
        uint64 exp, uint64 epoch, uint64 pe, uint64 ts, uint8 hPick, bool top, bool saved, uint8 rPick,
        uint8 svPick, uint8 sPick, bool setW, address w
    ) internal returns (Pre memory p) {
        address holder = _h4(hPick);
        b.h_setRecord(pid, "club", 0, exp, epoch, 0);
        b.h_mint(top ? holder : OWNER, pid);
        b.h_setRecord(sub, "fresh", pid, 0, 1, pe);
        b.h_mint(top ? OWNER : holder, sub);
        b.h_setProfile(sub);
        p.id = top ? pid : sub;
        if (saved) b.h_setResolved(p.id, _p3(rPick), _p3(svPick));
        if (setW) b.h_setWriter(p.id, w);
        p.x = PTE;
        p.s = _p3(sPick);
        b.h_setPrimary(p.x, p.id);
        b.h_setHolder(p.x, p.s);
        // Justification: a setting made while x held the name is cleared whenever the name leaves x
        // (transfer, a new registration, a new mint), so a stored holder equal to x means x still holds it
        vm.assume(p.s != p.x || holder == p.x);
        vm.warp(ts);
        (bool ok, string memory r) = _rr(address(b), p.x);
        assert(ok);
        vm.assume(bytes(r).length == 0);
        p.owner = holder;
        p.version = b.recordVersion(p.id);
        p.active = b.resolve(p.id) != address(0);
    }

    // after one call by caller: x shows a name again only through the proven exceptions
    function _after4(Pre memory p, address caller) internal view {
        (bool ok, string memory r) = _rr(address(b), p.x);
        assert(ok);
        if (bytes(r).length == 0) return;
        address owner = b.h_ownerOf(p.id);
        uint256 version = b.recordVersion(p.id);
        bool byStoredHolder = caller == p.s && p.owner == p.s;
        bool giftBack = p.owner != p.s && owner == p.s && version == p.version;
        bool renewal = !p.active && owner == p.owner && version == p.version;
        assert(byStoredHolder || giftBack || renewal);
        assert(b.primaryPage(p.x) == p.id);
    }

    /// @notice HD4w: from any state where PTE shows nothing, one resolver write or display name
    /// choice by any other account (setAddr, setAddrForCoin for OP with an address or empty, for
    /// Ethereum and for another chain, setText, setContenthash, clearRecords, setData, setPrimaryPage
    /// of the name, the other name, zero or any id) makes PTE show a name only when the caller is PTE's
    /// stored holder and holds the name. t is a top level name, s a subpage.
    /// @dev Technique: symbolic dispatcher from a symbolic state. Classification: DIRECT.
    function test_check_HD4wt(uint64 exp, uint64 epoch, uint64 pe, uint64 ts, uint8 hPick, bool saved, uint8 rPick,
        uint8 svPick, uint8 sPick, uint8 cPick, uint8 which, uint8 yPick, uint256 v) public {
        _hd4w(exp, epoch, pe, ts, hPick, true, saved, rPick, svPick, sPick, cPick, which, yPick, v);
    }

    function test_check_HD4ws(uint64 exp, uint64 epoch, uint64 pe, uint64 ts, uint8 hPick, bool saved, uint8 rPick,
        uint8 svPick, uint8 sPick, uint8 cPick, uint8 which, uint8 yPick, uint256 v) public {
        _hd4w(exp, epoch, pe, ts, hPick, false, saved, rPick, svPick, sPick, cPick, which, yPick, v);
    }

    function _hd4w(
        uint64 exp, uint64 epoch, uint64 pe, uint64 ts, uint8 hPick, bool top, bool saved, uint8 rPick,
        uint8 svPick, uint8 sPick, uint8 cPick, uint8 which, uint8 yPick, uint256 v
    ) internal {
        Pre memory p = _w4(exp, epoch, pe, ts, hPick, top, saved, rPick, svPick, sPick);
        address caller = _c4(cPick);
        address y = _y5(yPick);
        uint8 w = which % 10;
        bytes memory d;
        if (w == 0) d = abi.encodeWithSignature("setAddr(uint256,address)", p.id, y);
        else if (w == 1) d = abi.encodeCall(PageNFT.setAddrForCoin, (p.id, COIN_OP, abi.encodePacked(y)));
        else if (w == 2) d = abi.encodeCall(PageNFT.setAddrForCoin, (p.id, COIN_OP, bytes("")));
        else if (w == 3) d = abi.encodeCall(PageNFT.setAddrForCoin, (p.id, 60, abi.encodePacked(y)));
        else if (w == 4) d = abi.encodeCall(PageNFT.setAddrForCoin, (p.id, 0x80002105, abi.encodePacked(y)));
        else if (w == 5) d = abi.encodeCall(PageNFT.setText, (p.id, "url", "x"));
        else if (w == 6) d = abi.encodeCall(PageNFT.setContenthash, (p.id, hex"e301"));
        else if (w == 7) d = abi.encodeCall(PageNFT.clearRecords, (p.id));
        else if (w == 8) {
            uint8 k = yPick % 4;
            d = abi.encodeCall(PageNFT.setPrimaryPage, (k == 0 ? p.id : k == 1 ? (top ? sub : pid) : k == 2 ? 0 : v));
        } else d = abi.encodeCall(PageNFT.setData, (p.id, "k", hex"01"));
        vm.prank(caller);
        (bool ok,) = address(b).call(d);
        ok;
        _after4(p, caller);
    }

    /// @notice HD4k: from any state where PTE shows nothing, keepProfile by any other account makes PTE
    /// show a name only when the caller is PTE's stored holder and holds the name. t is a top level
    /// name, s a subpage. The stored writer is zero or one of three accounts, so a keep by the holder
    /// can succeed.
    /// @dev Technique: symbolic dispatcher from a symbolic state. Classification: DIRECT.
    function test_check_HD4kt(uint64 exp, uint64 epoch, uint64 pe, uint64 ts, uint8 hPick, bool saved, uint8 rPick,
        uint8 svPick, uint8 sPick, uint8 cPick, uint8 wPick) public {
        _hd4k(exp, epoch, pe, ts, hPick, true, saved, rPick, svPick, sPick, cPick, wPick);
    }

    function test_check_HD4ks(uint64 exp, uint64 epoch, uint64 pe, uint64 ts, uint8 hPick, bool saved, uint8 rPick,
        uint8 svPick, uint8 sPick, uint8 cPick, uint8 wPick) public {
        _hd4k(exp, epoch, pe, ts, hPick, false, saved, rPick, svPick, sPick, cPick, wPick);
    }

    function _hd4k(
        uint64 exp, uint64 epoch, uint64 pe, uint64 ts, uint8 hPick, bool top, bool saved, uint8 rPick,
        uint8 svPick, uint8 sPick, uint8 cPick, uint8 wPick
    ) internal {
        // the stored writer is zero or one of three accounts, so a keep by the holder can succeed
        Pre memory p = _w4w(exp, epoch, pe, ts, hPick, top, saved, rPick, svPick, sPick, true,
            wPick % 4 == 0 ? address(0) : _p3(wPick));
        address caller = _c4(cPick);
        vm.prank(caller);
        (bool ok,) = address(b).call(abi.encodeCall(PageNFT.keepProfile, (p.id)));
        ok;
        _after4(p, caller);
    }

    /// @notice HD4x: from any state where PTE shows nothing, one transfer (transferFrom and both
    /// safeTransferFrom, by any other account, with or without an approval or an operator grant, from
    /// the holder or another account, to zero, PTE, HOLDER, OTHER or DEAD) makes PTE show a name only
    /// when the name arrives at PTE's stored holder without a new record version (the gift back), or
    /// the stored holder moved it while holding it. t is a top level name, s a subpage.
    /// @dev Technique: symbolic dispatcher from a symbolic state. Classification: DIRECT.
    function test_check_HD4xt(uint64 exp, uint64 epoch, uint64 pe, uint64 ts, uint8 hPick, bool saved, uint8 rPick,
        uint8 svPick, uint8 sPick, uint8 cPick, uint8 kind, uint8 tPick, bool approved, bool operator, bool fromHolder)
        public
    {
        _hd4x(exp, epoch, pe, ts, hPick, true, saved, rPick, svPick, sPick, cPick, kind, tPick, approved, operator,
            fromHolder);
    }

    function test_check_HD4xs(uint64 exp, uint64 epoch, uint64 pe, uint64 ts, uint8 hPick, bool saved, uint8 rPick,
        uint8 svPick, uint8 sPick, uint8 cPick, uint8 kind, uint8 tPick, bool approved, bool operator, bool fromHolder)
        public
    {
        _hd4x(exp, epoch, pe, ts, hPick, false, saved, rPick, svPick, sPick, cPick, kind, tPick, approved, operator,
            fromHolder);
    }

    /// @notice HD4x split by the transfer function so each part finishes: x0 transferFrom, x1
    /// safeTransferFrom, x2 safeTransferFrom with data; t a top level name, s a subpage.
    function test_check_HD4x0t(uint64 exp, uint64 epoch, uint64 pe, uint64 ts, uint8 hPick, bool saved, uint8 rPick,
        uint8 svPick, uint8 sPick, uint8 cPick, uint8 tPick, bool approved, bool operator, bool fromHolder) public {
        _hd4x(exp, epoch, pe, ts, hPick, true, saved, rPick, svPick, sPick, cPick, 0, tPick, approved, operator, fromHolder);
    }

    function test_check_HD4x0s(uint64 exp, uint64 epoch, uint64 pe, uint64 ts, uint8 hPick, bool saved, uint8 rPick,
        uint8 svPick, uint8 sPick, uint8 cPick, uint8 tPick, bool approved, bool operator, bool fromHolder) public {
        _hd4x(exp, epoch, pe, ts, hPick, false, saved, rPick, svPick, sPick, cPick, 0, tPick, approved, operator, fromHolder);
    }

    function test_check_HD4x1t(uint64 exp, uint64 epoch, uint64 pe, uint64 ts, uint8 hPick, bool saved, uint8 rPick,
        uint8 svPick, uint8 sPick, uint8 cPick, uint8 tPick, bool approved, bool operator, bool fromHolder) public {
        _hd4x(exp, epoch, pe, ts, hPick, true, saved, rPick, svPick, sPick, cPick, 1, tPick, approved, operator, fromHolder);
    }

    function test_check_HD4x1s(uint64 exp, uint64 epoch, uint64 pe, uint64 ts, uint8 hPick, bool saved, uint8 rPick,
        uint8 svPick, uint8 sPick, uint8 cPick, uint8 tPick, bool approved, bool operator, bool fromHolder) public {
        _hd4x(exp, epoch, pe, ts, hPick, false, saved, rPick, svPick, sPick, cPick, 1, tPick, approved, operator, fromHolder);
    }

    function test_check_HD4x2t(uint64 exp, uint64 epoch, uint64 pe, uint64 ts, uint8 hPick, bool saved, uint8 rPick,
        uint8 svPick, uint8 sPick, uint8 cPick, uint8 tPick, bool approved, bool operator, bool fromHolder) public {
        _hd4x(exp, epoch, pe, ts, hPick, true, saved, rPick, svPick, sPick, cPick, 2, tPick, approved, operator, fromHolder);
    }

    function test_check_HD4x2s(uint64 exp, uint64 epoch, uint64 pe, uint64 ts, uint8 hPick, bool saved, uint8 rPick,
        uint8 svPick, uint8 sPick, uint8 cPick, uint8 tPick, bool approved, bool operator, bool fromHolder) public {
        _hd4x(exp, epoch, pe, ts, hPick, false, saved, rPick, svPick, sPick, cPick, 2, tPick, approved, operator, fromHolder);
    }

    function _hd4x(
        uint64 exp, uint64 epoch, uint64 pe, uint64 ts, uint8 hPick, bool top, bool saved, uint8 rPick,
        uint8 svPick, uint8 sPick, uint8 cPick, uint8 kind, uint8 tPick, bool approved, bool operator, bool fromHolder
    ) internal {
        Pre memory p = _w4(exp, epoch, pe, ts, hPick, top, saved, rPick, svPick, sPick);
        address caller = _c4(cPick);
        if (approved) b.h_approve(caller, p.id);
        if (operator) b.h_setApprovalForAll(p.owner, caller, true);
        address from = fromHolder ? p.owner : _p3(cPick >> 2);
        vm.prank(caller);
        (bool ok,) = address(b).call(_xfer(kind, from, _y5(tPick), p.id));
        ok;
        _after4(p, caller);
    }

    /// @notice HD4m: from any state where PTE shows nothing, one call of the remaining write surface
    /// by any other account (registerSubpageFor and registerSubpage by the parent's holder, its
    /// counted or stale minter or anyone, setSubpageMinter, approve, setApprovalForAll, commit,
    /// withdraw, release) makes PTE show a name only through the proven exceptions. t is a
    /// top level name, s a subpage.
    /// @dev Technique: symbolic dispatcher from a symbolic state. Classification: DIRECT.
    function test_check_HD4mt(uint64 exp, uint64 epoch, uint64 pe, uint64 ts, uint8 hPick, bool saved, uint8 rPick,
        uint8 svPick, uint8 sPick, uint8 cPick, uint8 which, uint8 yPick, bool counted) public {
        _hd4m(exp, epoch, pe, ts, hPick, true, saved, rPick, svPick, sPick, cPick, which, yPick, counted);
    }

    function test_check_HD4ms(uint64 exp, uint64 epoch, uint64 pe, uint64 ts, uint8 hPick, bool saved, uint8 rPick,
        uint8 svPick, uint8 sPick, uint8 cPick, uint8 which, uint8 yPick, bool counted) public {
        _hd4m(exp, epoch, pe, ts, hPick, false, saved, rPick, svPick, sPick, cPick, which, yPick, counted);
    }

    function _hd4m(
        uint64 exp, uint64 epoch, uint64 pe, uint64 ts, uint8 hPick, bool top, bool saved, uint8 rPick,
        uint8 svPick, uint8 sPick, uint8 cPick, uint8 which, uint8 yPick, bool counted
    ) internal {
        Pre memory p = _w4(exp, epoch, pe, ts, hPick, top, saved, rPick, svPick, sPick);
        b.h_setMinter(pid, MINTER, counted ? epoch : epoch ^ 1, b.h_ownerOf(pid));
        b.h_setOwed(OTHER, 1 ether);
        b.h_setDeposit(pid, 1 ether);
        vm.deal(address(b), 2 ether);
        uint8 w = which % 8;
        address caller = w < 2 && (cPick >> 4) % 2 == 0 ? MINTER : _c4(cPick);
        address y = _y5(yPick);
        bytes memory d;
        if (w == 0) d = abi.encodeCall(PageNFT.registerSubpageFor, ("fresh", pid, y));
        else if (w == 1) d = abi.encodeCall(PageNFT.registerSubpage, ("fresh", pid));
        else if (w == 2) d = abi.encodeCall(PageNFT.setSubpageMinter, (pid, y));
        else if (w == 3) d = abi.encodeWithSignature("approve(address,uint256)", y, p.id);
        else if (w == 4) d = abi.encodeWithSignature("setApprovalForAll(address,bool)", y, true);
        else if (w == 5) d = abi.encodeCall(PageNFT.commit, (bytes32(uint256(yPick))));
        else if (w == 6) d = abi.encodeCall(PageNFT.withdraw, (y));
        else d = abi.encodeCall(PageNFT.release, (pid));
        vm.prank(caller);
        (bool ok,) = address(b).call(d);
        ok;
        _after4(p, caller);
    }

    /// @notice HD4r: from any state where PTE shows nothing, a renewal of the name (or, for a
    /// subpage, of its parent, or of the subpage itself, which fails) paid with any value by any
    /// other account makes PTE show a name only when the name was inactive and nothing but the
    /// expiry changed (the renewal exception).
    /// @dev Technique: symbolic dispatcher from a symbolic state. Classification: DIRECT.
    function test_check_HD4r(uint64 exp, uint64 epoch, uint64 pe, uint64 ts, uint8 hPick, bool top, bool saved,
        uint8 rPick, uint8 svPick, uint8 sPick, uint8 cPick, bool onSub, uint96 value) public {
        Pre memory p = _w4(exp, epoch, pe, ts, hPick, top, saved, rPick, svPick, sPick);
        address caller = _c4(cPick);
        vm.deal(caller, value);
        vm.prank(caller);
        (bool ok,) = address(b).call{value: value}(abi.encodeCall(PageNFT.renew, (onSub ? sub : pid)));
        ok;
        _after4(p, caller);
    }

    /// @notice HD4g: from any state where PTE shows nothing, a registration over the top level name
    /// by any other account, for any recipient, leaves PTE showing nothing. Time is one of three
    /// windows around the expiry (last second of grace, first second of the premium, first second
    /// release allows) and the commitment is ripe, too new or missing, as in CP3r.
    /// @dev Technique: symbolic dispatcher from a symbolic state with time in fixed windows. Classification: DIRECT.
    function test_check_HD4g(uint64 exp, uint64 epoch, uint8 hPick, bool top, bool saved, uint8 rPick, uint8 svPick,
        uint8 sPick, uint8 cPick, uint8 tPick, uint8 when, uint8 cwhen, bytes32 secret) public {
        _hd4g(exp, epoch, hPick, top, saved, rPick, svPick, sPick, cPick, tPick, when, cwhen, secret);
    }

    /// @notice HD4g split by the time window so each part finishes: g0 last second of grace, g1
    /// first second of the premium, g2 first second release allows; t a top level name, s a subpage.
    function test_check_HD4g0t(uint64 exp, uint64 epoch, uint8 hPick, bool saved, uint8 rPick, uint8 svPick,
        uint8 sPick, uint8 cPick, uint8 tPick, uint8 cwhen, bytes32 secret) public {
        _hd4g(exp, epoch, hPick, true, saved, rPick, svPick, sPick, cPick, tPick, 0, cwhen, secret);
    }

    function test_check_HD4g0s(uint64 exp, uint64 epoch, uint8 hPick, bool saved, uint8 rPick, uint8 svPick,
        uint8 sPick, uint8 cPick, uint8 tPick, uint8 cwhen, bytes32 secret) public {
        _hd4g(exp, epoch, hPick, false, saved, rPick, svPick, sPick, cPick, tPick, 0, cwhen, secret);
    }

    function test_check_HD4g1t(uint64 exp, uint64 epoch, uint8 hPick, bool saved, uint8 rPick, uint8 svPick,
        uint8 sPick, uint8 cPick, uint8 tPick, uint8 cwhen, bytes32 secret) public {
        _hd4g(exp, epoch, hPick, true, saved, rPick, svPick, sPick, cPick, tPick, 1, cwhen, secret);
    }

    function test_check_HD4g1s(uint64 exp, uint64 epoch, uint8 hPick, bool saved, uint8 rPick, uint8 svPick,
        uint8 sPick, uint8 cPick, uint8 tPick, uint8 cwhen, bytes32 secret) public {
        _hd4g(exp, epoch, hPick, false, saved, rPick, svPick, sPick, cPick, tPick, 1, cwhen, secret);
    }

    function test_check_HD4g2t(uint64 exp, uint64 epoch, uint8 hPick, bool saved, uint8 rPick, uint8 svPick,
        uint8 sPick, uint8 cPick, uint8 tPick, uint8 cwhen, bytes32 secret) public {
        _hd4g(exp, epoch, hPick, true, saved, rPick, svPick, sPick, cPick, tPick, 2, cwhen, secret);
    }

    function test_check_HD4g2s(uint64 exp, uint64 epoch, uint8 hPick, bool saved, uint8 rPick, uint8 svPick,
        uint8 sPick, uint8 cPick, uint8 tPick, uint8 cwhen, bytes32 secret) public {
        _hd4g(exp, epoch, hPick, false, saved, rPick, svPick, sPick, cPick, tPick, 2, cwhen, secret);
    }

    /// @notice HD4g1 split further by the commitment age: c0 ripe, c1 too new, c2 missing.
    function test_check_HD4g1tc0(uint64 exp, uint64 epoch, uint8 hPick, bool saved, uint8 rPick, uint8 svPick,
        uint8 sPick, uint8 cPick, uint8 tPick, bytes32 secret) public {
        _hd4g(exp, epoch, hPick, true, saved, rPick, svPick, sPick, cPick, tPick, 1, 0, secret);
    }

    function test_check_HD4g1tc1(uint64 exp, uint64 epoch, uint8 hPick, bool saved, uint8 rPick, uint8 svPick,
        uint8 sPick, uint8 cPick, uint8 tPick, bytes32 secret) public {
        _hd4g(exp, epoch, hPick, true, saved, rPick, svPick, sPick, cPick, tPick, 1, 1, secret);
    }

    function test_check_HD4g1tc2(uint64 exp, uint64 epoch, uint8 hPick, bool saved, uint8 rPick, uint8 svPick,
        uint8 sPick, uint8 cPick, uint8 tPick, bytes32 secret) public {
        _hd4g(exp, epoch, hPick, true, saved, rPick, svPick, sPick, cPick, tPick, 1, 2, secret);
    }

    function test_check_HD4g1sc0(uint64 exp, uint64 epoch, uint8 hPick, bool saved, uint8 rPick, uint8 svPick,
        uint8 sPick, uint8 cPick, uint8 tPick, bytes32 secret) public {
        _hd4g(exp, epoch, hPick, false, saved, rPick, svPick, sPick, cPick, tPick, 1, 0, secret);
    }

    function test_check_HD4g1sc1(uint64 exp, uint64 epoch, uint8 hPick, bool saved, uint8 rPick, uint8 svPick,
        uint8 sPick, uint8 cPick, uint8 tPick, bytes32 secret) public {
        _hd4g(exp, epoch, hPick, false, saved, rPick, svPick, sPick, cPick, tPick, 1, 1, secret);
    }

    function test_check_HD4g1sc2(uint64 exp, uint64 epoch, uint8 hPick, bool saved, uint8 rPick, uint8 svPick,
        uint8 sPick, uint8 cPick, uint8 tPick, bytes32 secret) public {
        _hd4g(exp, epoch, hPick, false, saved, rPick, svPick, sPick, cPick, tPick, 1, 2, secret);
    }

    /// @notice HD4g1 with a concrete expiry: the premium window's division over a symbolic expiry is
    /// what keeps HD4g1 from finishing. Everything else stays symbolic.
    function test_check_HD4g1kt(uint64 epoch, uint8 hPick, bool saved, uint8 rPick, uint8 svPick, uint8 sPick,
        uint8 cPick, uint8 tPick, uint8 cwhen, bytes32 secret) public {
        _hd4g(1_800_000_000, epoch, hPick, true, saved, rPick, svPick, sPick, cPick, tPick, 1, cwhen, secret);
    }

    function test_check_HD4g1ks(uint64 epoch, uint8 hPick, bool saved, uint8 rPick, uint8 svPick, uint8 sPick,
        uint8 cPick, uint8 tPick, uint8 cwhen, bytes32 secret) public {
        _hd4g(1_800_000_000, epoch, hPick, false, saved, rPick, svPick, sPick, cPick, tPick, 1, cwhen, secret);
    }

    function _hd4g(uint64 exp, uint64 epoch, uint8 hPick, bool top, bool saved, uint8 rPick, uint8 svPick,
        uint8 sPick, uint8 cPick, uint8 tPick, uint8 when, uint8 cwhen, bytes32 secret) internal {
        // Justification: an expiry far from both ends of uint64, so every window below exists
        vm.assume(exp > 1000 && exp < type(uint64).max / 2);
        uint8 wk = when % 3;
        uint256 t = wk == 0 ? uint256(exp) + 90 days : wk == 1 ? uint256(exp) + 90 days + 1 : uint256(exp) + 111 days + 1;
        Pre memory p = _w4(exp, epoch, epoch, uint64(t), hPick, top, saved, rPick, svPick, sPick);
        address caller = _c4(cPick);
        address to = _y5(tPick);
        vm.assume(to != address(0));
        uint8 cw = cwhen % 3;
        bytes32 c = b.makeCommitment("club", to, 0, secret);
        b.h_setCommit(c, cw == 0 ? t - 61 : cw == 1 ? t - 19 : 0);
        // reveal charges the carried deposit even inside grace, where quote leaves it out, so add it there
        // and let the last second of grace reach its own check; after the auction the deposit goes back first
        // and is not charged
        (, uint256 carried,, uint256 total) = b.quote("club");
        if (carried == 0 && t <= uint256(exp) + 111 days) total += b.depositOf(pid);
        vm.deal(caller, total);
        vm.prank(caller);
        (bool ok,) = address(b).call{value: total}(abi.encodeCall(PageNFT.reveal, ("club", to, 0, secret)));
        ok;
        (, string memory r) = _rr(address(b), p.x);
        assert(bytes(r).length == 0);
    }

    /// @notice HD4b: from any state where PTE shows nothing, one bundle by any other account of two
    /// calls (point the name and choose it, point the name then send it, send it then point it,
    /// clear records then send it, write text then send it) makes PTE show a name only through the
    /// proven exceptions.
    /// @dev Technique: symbolic dispatcher from a symbolic state. Classification: DIRECT.
    function test_check_HD4b(uint64 exp, uint64 epoch, uint64 pe, uint64 ts, uint8 hPick, bool top, bool saved,
        uint8 rPick, uint8 svPick, uint8 sPick, uint8 cPick, uint8 which, uint8 yPick, uint8 tPick) public {
        _hd4b(exp, epoch, pe, ts, hPick, top, saved, rPick, svPick, sPick, cPick, which, yPick, tPick);
    }

    /// @notice HD4b split by the bundle form so each part finishes (b0 to b4 as listed above).
    function test_check_HD4b0(uint64 exp, uint64 epoch, uint64 pe, uint64 ts, uint8 hPick, bool top, bool saved,
        uint8 rPick, uint8 svPick, uint8 sPick, uint8 cPick, uint8 yPick, uint8 tPick) public {
        _hd4b(exp, epoch, pe, ts, hPick, top, saved, rPick, svPick, sPick, cPick, 0, yPick, tPick);
    }

    function test_check_HD4b1(uint64 exp, uint64 epoch, uint64 pe, uint64 ts, uint8 hPick, bool top, bool saved,
        uint8 rPick, uint8 svPick, uint8 sPick, uint8 cPick, uint8 yPick, uint8 tPick) public {
        _hd4b(exp, epoch, pe, ts, hPick, top, saved, rPick, svPick, sPick, cPick, 1, yPick, tPick);
    }

    function test_check_HD4b2(uint64 exp, uint64 epoch, uint64 pe, uint64 ts, uint8 hPick, bool top, bool saved,
        uint8 rPick, uint8 svPick, uint8 sPick, uint8 cPick, uint8 yPick, uint8 tPick) public {
        _hd4b(exp, epoch, pe, ts, hPick, top, saved, rPick, svPick, sPick, cPick, 2, yPick, tPick);
    }

    function test_check_HD4b3(uint64 exp, uint64 epoch, uint64 pe, uint64 ts, uint8 hPick, bool top, bool saved,
        uint8 rPick, uint8 svPick, uint8 sPick, uint8 cPick, uint8 yPick, uint8 tPick) public {
        _hd4b(exp, epoch, pe, ts, hPick, top, saved, rPick, svPick, sPick, cPick, 3, yPick, tPick);
    }

    function test_check_HD4b4(uint64 exp, uint64 epoch, uint64 pe, uint64 ts, uint8 hPick, bool top, bool saved,
        uint8 rPick, uint8 svPick, uint8 sPick, uint8 cPick, uint8 yPick, uint8 tPick) public {
        _hd4b(exp, epoch, pe, ts, hPick, top, saved, rPick, svPick, sPick, cPick, 4, yPick, tPick);
    }

    function _hd4b(uint64 exp, uint64 epoch, uint64 pe, uint64 ts, uint8 hPick, bool top, bool saved,
        uint8 rPick, uint8 svPick, uint8 sPick, uint8 cPick, uint8 which, uint8 yPick, uint8 tPick) internal {
        Pre memory p = _w4(exp, epoch, pe, ts, hPick, top, saved, rPick, svPick, sPick);
        address caller = _c4(cPick);
        address y = _y5(yPick);
        bytes memory send = abi.encodeWithSignature("transferFrom(address,address,uint256)", p.owner, _y5(tPick), p.id);
        bytes memory point = abi.encodeWithSignature("setAddr(uint256,address)", p.id, y);
        bytes[] memory inner = new bytes[](2);
        uint8 w = which % 5;
        if (w == 0) {
            inner[0] = point;
            inner[1] = abi.encodeCall(PageNFT.setPrimaryPage, (p.id));
        } else if (w == 1) {
            inner[0] = point;
            inner[1] = send;
        } else if (w == 2) {
            inner[0] = send;
            inner[1] = point;
        } else if (w == 3) {
            inner[0] = abi.encodeCall(PageNFT.clearRecords, (p.id));
            inner[1] = send;
        } else {
            inner[0] = abi.encodeCall(PageNFT.setText, (p.id, "url", "x"));
            inner[1] = send;
        }
        vm.prank(caller);
        (bool ok,) = address(b).call(abi.encodeCall(PageNFT.multicall, (inner)));
        ok;
        _after4(p, caller);
    }

    /// @notice HD4tr: from any state where PTE shows nothing and the top level name is a trial (no
    /// deposit, its price held for OTHER), one trial call by any other account (renew to convert it,
    /// release, a new trial or a paid registration over it with a ripe commitment, transferFrom to DEAD
    /// or safeTransferFrom to any account, with or without an approval or an operator grant) makes PTE
    /// show a name only through the proven exceptions.
    /// @dev Technique: symbolic dispatcher from a symbolic state. Classification: DIRECT.
    function test_check_HD4tr(uint64 exp, uint64 epoch, uint64 ts, uint8 hPick, bool saved, uint8 rPick,
        uint8 svPick, uint8 sPick, uint8 cPick, uint8 which, uint8 yPick, bool approved, bool operator) public {
        _hd4tr(exp, epoch, ts, hPick, saved, rPick, svPick, sPick, cPick, which, yPick, approved, operator);
    }

    /// @notice HD4tr split by the call so each part finishes: 0 renew, 1 release, 2 a new trial,
    /// 3 a paid registration, 4 transferFrom to DEAD, 5 safeTransferFrom to any account.
    function test_check_HD4tr0(uint64 exp, uint64 epoch, uint64 ts, uint8 hPick, bool saved, uint8 rPick,
        uint8 svPick, uint8 sPick, uint8 cPick, uint8 yPick, bool approved, bool operator) public {
        _hd4tr(exp, epoch, ts, hPick, saved, rPick, svPick, sPick, cPick, 0, yPick, approved, operator);
    }

    function test_check_HD4tr1(uint64 exp, uint64 epoch, uint64 ts, uint8 hPick, bool saved, uint8 rPick,
        uint8 svPick, uint8 sPick, uint8 cPick, uint8 yPick, bool approved, bool operator) public {
        _hd4tr(exp, epoch, ts, hPick, saved, rPick, svPick, sPick, cPick, 1, yPick, approved, operator);
    }

    function test_check_HD4tr2(uint64 exp, uint64 epoch, uint64 ts, uint8 hPick, bool saved, uint8 rPick,
        uint8 svPick, uint8 sPick, uint8 cPick, uint8 yPick, bool approved, bool operator) public {
        _hd4tr(exp, epoch, ts, hPick, saved, rPick, svPick, sPick, cPick, 2, yPick, approved, operator);
    }

    function test_check_HD4tr3(uint64 exp, uint64 epoch, uint64 ts, uint8 hPick, bool saved, uint8 rPick,
        uint8 svPick, uint8 sPick, uint8 cPick, uint8 yPick, bool approved, bool operator) public {
        _hd4tr(exp, epoch, ts, hPick, saved, rPick, svPick, sPick, cPick, 3, yPick, approved, operator);
    }

    function test_check_HD4tr4(uint64 exp, uint64 epoch, uint64 ts, uint8 hPick, bool saved, uint8 rPick,
        uint8 svPick, uint8 sPick, uint8 cPick, uint8 yPick, bool approved, bool operator) public {
        _hd4tr(exp, epoch, ts, hPick, saved, rPick, svPick, sPick, cPick, 4, yPick, approved, operator);
    }

    function test_check_HD4tr5(uint64 exp, uint64 epoch, uint64 ts, uint8 hPick, bool saved, uint8 rPick,
        uint8 svPick, uint8 sPick, uint8 cPick, uint8 yPick, bool approved, bool operator) public {
        _hd4tr(exp, epoch, ts, hPick, saved, rPick, svPick, sPick, cPick, 5, yPick, approved, operator);
    }

    function _hd4tr(uint64 exp, uint64 epoch, uint64 ts, uint8 hPick, bool saved, uint8 rPick, uint8 svPick,
        uint8 sPick, uint8 cPick, uint8 which, uint8 yPick, bool approved, bool operator) internal {
        // Justification: the commitment below is dated 61 seconds before now
        vm.assume(ts > 61);
        Pre memory p = _w4(exp, epoch, epoch, ts, hPick, true, saved, rPick, svPick, sPick);
        b.h_setDeposit(pid, 0);
        b.h_setHeld(pid, OTHER, uint96(0.0001 ether));
        vm.deal(address(b), 0.0001 ether);
        address caller = _c4(cPick);
        address y = _y5(yPick);
        if (approved) b.h_approve(caller, p.id);
        if (operator) b.h_setApprovalForAll(p.owner, caller, true);
        uint8 w = which % 6;
        bytes memory d;
        uint256 value;
        if (w == 0) {
            d = abi.encodeCall(PageNFT.renew, (pid));
            value = 0.001 ether;
        } else if (w == 1) {
            d = abi.encodeCall(PageNFT.release, (pid));
        } else if (w == 2 || w == 3) {
            vm.assume(y != address(0));
            bytes32 c = b.makeCommitment("club", y, 0, bytes32(0));
            b.h_setCommit(w == 2 ? keccak256(abi.encode(bytes("club"), y, uint256(0), bytes32(0), true)) : c, uint256(ts) - 61);
            d = w == 2
                ? abi.encodeCall(PageNFT.revealTrial, ("club", y, 0, bytes32(0)))
                : abi.encodeCall(PageNFT.reveal, ("club", y, 0, bytes32(0)));
            value = 0.001 ether;
        } else if (w == 4) {
            d = abi.encodeWithSignature("transferFrom(address,address,uint256)", p.owner, DEAD, pid);
        } else {
            d = abi.encodeWithSignature("safeTransferFrom(address,address,uint256)", p.owner, y, pid);
        }
        vm.deal(caller, value);
        vm.prank(caller);
        (bool ok,) = address(b).call{value: value}(d);
        ok;
        _after4(p, caller);
    }
}

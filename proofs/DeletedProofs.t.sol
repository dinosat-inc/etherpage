// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {PageCard} from "../src/PageCard.sol";
import {PageNFT} from "../src/PageNFT.sol";
import {DeletedHarnessA, DeletedHarnessB} from "./DeletedHarness.sol";

/// @notice Symbolic proofs for the deleted rule. World a is the PageNFTRecycle reference build,
/// which never deletes, world b is src. Both get the same symbolic start state through the harness;
/// each proof then states exactly where b may differ from a: for a page DEAD holds, top level or
/// subpage, where b answers nothing and refuses every transfer, under a parent DEAD holds, where b
/// frees no label, and for the display name pointer after a transfer, which only b clears and checks
/// against the holder.
/// Halmos: FOUNDRY_PROFILE=proofs halmos --contract DeletedProofsTest --function test_check_ --forge-build-out out-proofs --loop 4 --storage-layout generic
contract DeletedProofsTest is Test {
    PageCard card;
    DeletedHarnessA a;
    DeletedHarnessB b;

    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address constant OWNER = address(0xA11CE);
    address constant HOLDER = address(0xB0B);
    address constant OTHER = address(0xC0FFEE);
    address constant NEAR = address(0xdEaE);
    address constant MINTER = address(0x3117);
    uint256 constant COIN_OP = 0x8000000a;
    uint256 constant COIN_BASE = 0x80002105;
    bytes32 constant ROOT = 0x62460c06d95b73747abf6ea4f28aefd78b4ad2abee112e7cf15fe6a924cca3c6;

    uint256 pid;
    uint256 sub;

    function setUp() public {
        card = new PageCard();
        a = new DeletedHarnessA(card);
        b = new DeletedHarnessB(card);
        pid = uint256(keccak256(abi.encodePacked(ROOT, keccak256(bytes("club")))));
        sub = uint256(keccak256(abi.encodePacked(bytes32(pid), keccak256(bytes("fresh")))));
    }

    function _pick(uint8 p) internal pure returns (address) {
        uint8 k = p % 5;
        if (k == 0) return DEAD;
        if (k == 1) return HOLDER;
        if (k == 2) return OWNER;
        if (k == 3) return NEAR;
        return OTHER;
    }

    // the same parent and subpage in both worlds
    function _world(
        uint64 exp, uint64 epoch, uint64 pe, address pHolder, address holder,
        bool saved, address main, address saver, bool coin, address cSaver
    ) internal {
        address[2] memory w = [address(a), address(b)];
        for (uint256 i; i < 2; ++i) {
            DeletedHarnessB n = DeletedHarnessB(w[i]);
            n.h_setRecord(pid, "club", 0, exp, epoch, 0);
            n.h_mint(pHolder, pid);
            n.h_setRecord(sub, "fresh", pid, 0, 1, pe);
            n.h_mint(holder, sub);
            n.h_setProfile(sub);
            n.h_setProfile(pid);
            if (saved) {
                n.h_setResolved(sub, main, saver);
                n.h_setResolved(pid, main, saver);
            }
            if (coin) {
                n.h_setCoin(sub, 60, cSaver, abi.encodePacked(main));
                n.h_setCoin(sub, COIN_BASE, cSaver, abi.encodePacked(main));
                n.h_setCoin(sub, 0, cSaver, hex"0014beef");
                n.h_setCoin(pid, 60, cSaver, abi.encodePacked(main));
                n.h_setCoin(pid, 0, cSaver, hex"0014beef");
                n.h_setData(sub, cSaver);
                n.h_setData(pid, cSaver);
            }
        }
    }

    function _eqB(bytes memory x, bytes memory y) internal pure returns (bool) {
        return keccak256(x) == keccak256(y);
    }

    function _eqS(string memory x, string memory y) internal pure returns (bool) {
        return keccak256(bytes(x)) == keccak256(bytes(y));
    }

    function _sameAnswers(uint256 id) internal view {
        address holder = b.h_ownerOf(id);
        assert(b.resolve(id) == a.resolve(id));
        assert(b.resolveAs(id, HOLDER) == a.resolveAs(id, HOLDER));
        assert(b.resolveAs(id, holder) == a.resolveAs(id, holder));
        assert(b.resolveAs(id, DEAD) == a.resolveAs(id, DEAD));
        assert(_eqB(b.addr(id, COIN_OP), a.addr(id, COIN_OP)));
        assert(_eqB(b.addr(id, 60), a.addr(id, 60)));
        assert(_eqB(b.addr(id, COIN_BASE), a.addr(id, COIN_BASE)));
        assert(_eqB(b.addr(id, 0), a.addr(id, 0)));
        assert(b.addr(bytes32(id)) == a.addr(bytes32(id)));
        assert(_eqS(b.text(id, "k"), a.text(id, "k")));
        assert(_eqB(b.data(bytes32(id), "k"), a.data(bytes32(id), "k")));
        assert(_eqB(b.contenthash(id), a.contenthash(id)));
    }

    function _noAnswers(uint256 id) internal view {
        assert(b.resolve(id) == address(0));
        assert(b.resolveAs(id, HOLDER) == address(0));
        assert(b.resolveAs(id, DEAD) == address(0));
        assert(b.addr(id, COIN_OP).length == 0);
        assert(b.addr(id, 60).length == 0);
        assert(b.addr(id, COIN_BASE).length == 0);
        assert(b.addr(id, 0).length == 0);
        assert(b.addr(bytes32(id)) == address(0));
        assert(bytes(b.text(id, "k")).length == 0);
        assert(b.data(bytes32(id), "k").length == 0);
        assert(b.contenthash(id).length == 0);
    }

    function _pick3(uint8 p) internal pure returns (address) {
        uint8 k = p % 3;
        if (k == 0) return DEAD;
        if (k == 1) return HOLDER;
        return OTHER;
    }

    /// @notice D1s: the resolution views of a subpage (resolve, resolveAs for HOLDER, for its holder
    /// and for DEAD, addr for OP, Ethereum, Base and coin type 0, addr by node, text and data under one
    /// key, and contenthash) equal the reference build unless DEAD holds the subpage, and then answer
    /// nothing, at any time, stale or live, with or without a saved main address, chain entries and a
    /// data record, saved by the holder or by another account. getPageName, payee, ownerOf and
    /// isAvailable never differ.
    /// @dev Technique: symbolic differential over built state. Classification: DIRECT.
    function test_check_D1s_subpageViewsExact(
        uint64 exp, uint64 epoch, uint64 pe, uint64 ts, uint8 hPick,
        bool saved, uint8 mPick, bool saverIsHolder, bool coin, bool cSaverIsHolder
    ) public {
        address holder = _pick(hPick);
        _world(
            exp, epoch, pe, OWNER, holder, saved, _pick3(mPick), saverIsHolder ? holder : OTHER,
            coin, cSaverIsHolder ? holder : OTHER
        );
        vm.warp(ts);
        if (holder == DEAD) _noAnswers(sub);
        else _sameAnswers(sub);
        assert(_eqS(b.getPageName(sub), a.getPageName(sub)));
        assert(b.payee(sub) == a.payee(sub));
        assert(b.h_ownerOf(sub) == a.h_ownerOf(sub));
        assert(b.isAvailable("fresh", pid) == a.isAvailable("fresh", pid));
    }

    /// @notice D1t: every resolution view of a top level name (those of D1s) equals the reference build
    /// unless DEAD holds it, and then answers nothing, at any time and whatever was saved and by whom.
    /// getPageName, payee, isAvailable, isExpired and inGracePeriod never differ, so a name DEAD holds
    /// stays taken until its grace period ends.
    /// @dev Technique: symbolic differential over built state. Classification: DIRECT.
    function test_check_D1t_topLevelViewsSame(
        uint64 exp, uint64 epoch, uint64 ts, uint8 pPick,
        bool saved, uint8 mPick, bool saverIsHolder, bool coin, bool cSaverIsHolder
    ) public {
        address pHolder = _pick(pPick);
        _world(
            exp, epoch, epoch, pHolder, HOLDER, saved, _pick3(mPick), saverIsHolder ? pHolder : OTHER,
            coin, cSaverIsHolder ? pHolder : OTHER
        );
        vm.warp(ts);
        if (pHolder == DEAD) _noAnswers(pid);
        else _sameAnswers(pid);
        assert(_eqS(b.getPageName(pid), a.getPageName(pid)));
        assert(b.payee(pid) == a.payee(pid));
        assert(b.isAvailable("club", 0) == a.isAvailable("club", 0));
        assert(b.isExpired(pid) == a.isExpired(pid));
        assert(b.inGracePeriod(pid) == a.inGracePeriod(pid));
    }

    /// @notice D1p: while DEAD holds the parent, every resolution view of the subpage equals the
    /// reference build unless DEAD also holds the subpage, and then answers nothing. So the subpage of
    /// a deleted parent stays live until the parent expires, in the registration it was made in:
    /// resolve answers an account exactly then. getPageName and payee of the subpage never differ, the
    /// parent answers nothing, and no label under it is free.
    /// @dev Technique: symbolic differential over built state. Classification: DIRECT.
    function test_check_D1p_subpageUnderDeadParent(
        uint64 exp, uint64 epoch, uint64 pe, uint64 ts, uint8 hPick,
        bool saved, uint8 mPick, bool saverIsHolder, bool coin, bool cSaverIsHolder
    ) public {
        address holder = _pick(hPick);
        _world(
            exp, epoch, pe, DEAD, holder, saved, _pick3(mPick), saverIsHolder ? holder : OTHER,
            coin, cSaverIsHolder ? holder : OTHER
        );
        vm.warp(ts);
        if (holder == DEAD) _noAnswers(sub);
        else _sameAnswers(sub);
        assert((b.resolve(sub) != address(0)) == (holder != DEAD && pe == epoch && ts <= exp));
        assert(_eqS(b.getPageName(sub), a.getPageName(sub)));
        assert(b.payee(sub) == a.payee(sub));
        _noAnswers(pid);
        assert(!b.isAvailable("fresh", pid));
    }

    /// @notice D2: a transfer of a subpage or a top level name succeeds in src exactly when it
    /// succeeds in the reference build and leaves the same holder, except a transfer out of a
    /// subpage or a top level name DEAD holds, which src always refuses with Expired, even with an
    /// approval DEAD could never sign. The holder's primary pointer stays as it is in the reference
    /// build; in src it becomes zero exactly when the transfer succeeds, goes to another account and
    /// the pointer named the moved id.
    /// @dev Technique: symbolic differential of the write path. Classification: DIRECT.
    function test_check_D2_transfers(
        uint64 exp, uint64 epoch, uint64 pe, uint64 ts, uint8 hPick, uint8 cPick, uint8 tPick,
        bool approved, bool top, bool safe, uint8 pk
    ) public {
        address holder = _pick(hPick);
        uint8 ck = cPick % 3;
        address caller = ck == 0 ? holder : ck == 1 ? OTHER : DEAD;
        uint8 tk = tPick % 3;
        address to = tk == 0 ? DEAD : tk == 1 ? OTHER : NEAR;
        uint256 id = top ? pid : sub;
        _world(exp, epoch, pe, top ? holder : OWNER, top ? OWNER : holder, false, address(0), address(0), false, address(0));
        uint256 ptr = pk % 3 == 0 ? id : pk % 3 == 1 ? (top ? sub : pid) : 0;
        a.h_setPrimary(holder, ptr);
        b.h_setPrimary(holder, ptr);
        vm.warp(ts);
        if (approved && caller != holder) {
            vm.prank(holder);
            a.approve(caller, id);
            vm.prank(holder);
            b.approve(caller, id);
        }
        bytes memory data = safe
            ? abi.encodeWithSignature("safeTransferFrom(address,address,uint256)", holder, to, id)
            : abi.encodeWithSignature("transferFrom(address,address,uint256)", holder, to, id);
        vm.prank(caller);
        (bool okA,) = address(a).call(data);
        vm.prank(caller);
        (bool okB, bytes memory retB) = address(b).call(data);
        if (holder == DEAD) {
            assert(!okB);
            assert(bytes4(retB) == PageNFT.Expired.selector);
            assert(b.h_ownerOf(id) == DEAD);
        } else {
            assert(okA == okB);
            assert(b.h_ownerOf(id) == a.h_ownerOf(id));
        }
        assert(a.primaryPage(holder) == ptr);
        assert(b.primaryPage(holder) == (okB && to != holder && ptr == id ? 0 : ptr));
    }

    /// @notice D3: a subpage mint by the parent's holder, its counted minter or anyone else succeeds
    /// in src exactly when it does in the reference build, over a subpage any account holds, DEAD
    /// included, or, with first, over a label with no record, and leaves the same holder, version,
    /// epoch, parent epoch and old holder's primary pointer, and after a successful mint to any
    /// account but DEAD the same resolution answers. Minting a deleted subpage again works the same
    /// in both builds.
    /// @dev Technique: symbolic differential of the write path. Classification: DIRECT.
    function test_check_D3_mintsSame(
        uint64 exp, uint64 epoch, uint64 pe, uint64 ts, uint8 hPick, uint8 cPick, uint8 tPick,
        bool counted, bool pointer, bool first
    ) public {
        address holder = _pick(hPick);
        address to = _pick3(tPick);
        uint8 k = cPick % 3;
        address caller = k == 0 ? OWNER : k == 1 ? MINTER : OTHER;
        // first mints the label new, which has no record in either world
        string memory label = "fresh";
        uint256 id = sub;
        if (first) {
            label = "new";
            id = uint256(keccak256(abi.encodePacked(bytes32(pid), keccak256(bytes(label)))));
        }
        _world(exp, epoch, pe, OWNER, holder, false, address(0), address(0), false, address(0));
        a.h_setMinter(pid, MINTER, counted ? epoch : epoch ^ 1, OWNER);
        b.h_setMinter(pid, MINTER, counted ? epoch : epoch ^ 1, OWNER);
        if (pointer) {
            a.h_setPrimary(holder, sub);
            b.h_setPrimary(holder, sub);
        }
        vm.warp(ts);
        vm.prank(caller);
        (bool okA,) = address(a).call(abi.encodeWithSignature("registerSubpageFor(string,uint256,address)", label, pid, to));
        vm.prank(caller);
        (bool okB,) = address(b).call(abi.encodeWithSignature("registerSubpageFor(string,uint256,address)", label, pid, to));
        assert(okA == okB);
        assert(b.h_ownerOf(id) == a.h_ownerOf(id));
        assert(b.recordVersion(id) == a.recordVersion(id));
        assert(b.epochOf(id) == a.epochOf(id));
        assert(b.primaryPage(holder) == a.primaryPage(holder));
        (,,,, uint64 peA) = a.records(id);
        (,,,, uint64 peB) = b.records(id);
        assert(peA == peB);
        if (okB && to != DEAD) _sameAnswers(id);
    }

    /// @notice D4: optionally after the holder sends the subpage to another account, setPrimaryPage
    /// on it succeeds in src exactly when it does in the reference build and DEAD does not hold the
    /// subpage, and reverseResolve equals the reference build for every account unless the pointer
    /// names a subpage DEAD holds, where src answers nothing, or the account sent the subpage away
    /// while its pointer named it, where src answers nothing and stores zero for that account.
    /// @dev Technique: symbolic differential. Classification: DIRECT.
    function test_check_D4_primaryPages(
        uint64 exp, uint64 epoch, uint64 pe, uint64 ts, uint8 hPick, uint8 cPick,
        bool saved, uint8 mPick, bool saverIsHolder, uint8 xPick, bool moved
    ) public {
        address holder = _pick(hPick);
        address caller = _pick3(cPick);
        address x = _pick3(xPick);
        _world(exp, epoch, pe, OWNER, holder, saved, _pick3(mPick), saverIsHolder ? holder : OTHER, false, address(0));
        a.h_setPrimary(x, sub);
        b.h_setPrimary(x, sub);
        vm.warp(ts);
        bool cleared;
        if (moved && holder != DEAD) {
            bytes memory d = abi.encodeWithSignature("transferFrom(address,address,uint256)", holder, NEAR, sub);
            vm.prank(holder);
            (bool mA,) = address(a).call(d);
            vm.prank(holder);
            (bool mB,) = address(b).call(d);
            assert(mA == mB);
            cleared = mB && x == holder;
        }
        assert(a.primaryPage(x) == sub);
        assert(b.primaryPage(x) == (cleared ? 0 : sub));
        if (b.h_ownerOf(sub) == DEAD || cleared) assert(bytes(b.reverseResolve(x)).length == 0);
        else assert(_eqS(b.reverseResolve(x), a.reverseResolve(x)));
        vm.prank(caller);
        (bool okA,) = address(a).call(abi.encodeWithSignature("setPrimaryPage(uint256)", sub));
        vm.prank(caller);
        (bool okB,) = address(b).call(abi.encodeWithSignature("setPrimaryPage(uint256)", sub));
        assert(okB == (okA && b.h_ownerOf(sub) != DEAD));
        assert(b.primaryPage(caller) == (okB ? sub : (caller == x && !cleared ? sub : 0)));
    }
}

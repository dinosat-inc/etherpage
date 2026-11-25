// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {PageCard} from "../src/PageCard.sol";
import {PageNFT} from "../src/PageNFT.sol";
import {SubpageRegistrar, IPageNFT} from "../src/SubpageRegistrar.sol";
import {PageNFTHarness} from "./MinterHarness.sol";

interface SVM {
    function createCalldata(string memory contractOrInterfaceName) external pure returns (bytes memory data);
    function enableSymbolicStorage(address) external;
    function createAddress(string memory name) external pure returns (address value);
    function createUint(uint256 bitSize, string memory name) external pure returns (uint256 value);
    function createBool(string memory name) external pure returns (bool value);
}

/// @notice Symbolic proofs for the subpage minter.
/// Halmos: FOUNDRY_PROFILE=proofs halmos --contract MinterProofsTest --function test_check_ --forge-build-out out-proofs --loop 4 --storage-layout generic
/// Two kinds of start state are used. "Built" state is written through the harness, and approvals
/// through calls by the holder, with the records, holders, minter records and other entries each
/// proof needs, most values symbolic, a deposit on every top level record (1 unless the proof sets
/// another) so each parent is paid, and everything else empty; TrialProofs T4 and T6 cover names
/// with no deposit. "Symbolic storage" makes every unwritten slot of the contract an arbitrary
/// value, so the proof covers any reachable and unreachable prior state.
contract MinterProofsTest is Test {
    SVM constant svm = SVM(0xF3993A62377BCd56AE39D773740A5390411E8BC9);

    PageCard card;
    PageNFTHarness nft;
    SubpageRegistrar reg;

    string constant FRESH = "fresh";
    string constant LIVE = "live";
    // a fixed codeless recipient; no authority check reads the recipient
    address constant TO = address(0xC0FFEE);
    address constant HOLDER = address(0xB0B);
    address constant OWNER = address(0xA11CE);
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    function setUp() public {
        card = new PageCard();
        nft = new PageNFTHarness(card);
        reg = new SubpageRegistrar(IPageNFT(address(nft)));
    }

    // helpers

    // the label is hashed at run time, the same way PageNFT hashes it, so the generic storage
    // model sees one key for the subpage record (a label hash folded at compile time gives another)
    function _sub(uint256 pid, string memory label) internal pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(bytes32(pid), keccak256(bytes(label)))));
    }

    function _load(bytes32 slot) internal view returns (uint256) {
        return uint256(vm.load(address(nft), slot));
    }

    function _mslot(uint256 key, uint256 slot) internal pure returns (bytes32) {
        return keccak256(abi.encode(key, slot));
    }

    function _nested(uint256 k, uint256 v, uint256 slot) internal pure returns (bytes32) {
        return keccak256(abi.encode(v, _mslot(k, slot)));
    }

    function _plainRecipient(address to) internal view {
        vm.assume(to != address(0) && to != address(nft) && to.code.length == 0);
    }

    // a parent in built state: top level, held by owner, symbolic expiry and epoch
    function _parent(uint256 pid, address owner, uint64 exp, uint64 epoch) internal {
        vm.assume(pid != 0);
        vm.assume(owner != address(0) && owner != address(nft));
        nft.h_setRecord(pid, "club", 0, exp, epoch, 0);
        nft.h_mint(owner, pid);
    }

    // the raw minter record as two words, exactly as slot 12 stores it
    function _rawMinter(uint256 pid) internal view returns (uint256 w0, uint256 w1) {
        bytes32 b = _mslot(pid, 12);
        w0 = _load(b);
        w1 = _load(bytes32(uint256(b) + 1));
    }

    // a stored label occupies at most 63 bytes, so its slot word is either the short form or the
    // long form with a length from 32 to 63
    function _assumeLabelWord(uint256 id) internal view {
        uint256 w = _load(_mslot(id, 0));
        if (w & 1 == 0) vm.assume(w & 0xff <= 62);
        else vm.assume(w >= 65 && w <= 127);
    }

    // MP1 who can mint a free label

    /// @notice MP1: a free label under a parent mints if and only if the parent is not past its
    /// expiry and the caller is the holder or the counted minter as subpageMinterOf reports it (the
    /// stored minter when the setter is the holder and the epoch is the parent's current epoch, else
    /// address(0)), and the caller is not address(0), which is never a minter (MPZ). Here the label
    /// has no record; MP1d covers a live subpage held by DEAD and MP2 a stale one.
    /// @dev Technique: exact characterization, both directions. Classification: DIRECT.
    function test_check_MP1_freeLabelMintersExact(
        uint256 pid, address owner, uint64 exp, uint64 epoch, uint64 ts,
        address m, uint64 e, address s, address caller, bool toOwner
    ) public {
        address to = toOwner ? owner : TO;
        // Justification: a recipient with code runs its own hook; contract holders are covered by the concrete suite
        if (toOwner) vm.assume(owner.code.length == 0);
        _parent(pid, owner, exp, epoch);
        uint256 sub = _sub(pid, FRESH);
        // Justification: ids are keccak outputs of distinct preimages, so a subpage id never equals its parent id
        vm.assume(sub != pid);
        nft.h_setMinter(pid, m, e, s);
        vm.warp(ts);

        // the counted minter exactly as subpageMinterOf reports it; with no counted minter it is
        // address(0), which the contract refuses as a caller
        address cm = (s == owner && e == epoch) ? m : address(0);
        bool allowed = ts <= exp && caller != address(0) && (caller == owner || caller == cm);
        vm.prank(caller);
        try nft.registerSubpageFor("fresh", pid, to) returns (uint256 id) {
            assert(allowed);
            assert(id == sub);
            assert(nft.ownerOf(sub) == to);
            (,,, uint64 ne, uint64 npe) = nft.records(sub);
            assert(ne == 1 && npe == epoch);
        } catch {
            assert(!allowed);
            assert(nft.h_ownerOf(sub) == address(0));
        }
    }

    /// @notice MP1d: a live subpage held by DEAD is minted over if and only if the parent is not
    /// past its expiry and the caller is the holder or the counted minter, exactly as for a label
    /// with no record. The mint burns DEAD's token, bumps the subpage epoch and the record version,
    /// clears DEAD's primary pointer to it, and mints to the recipient; a refusal changes nothing.
    /// @dev Technique: exact characterization, both directions. Classification: DIRECT.
    function test_check_MP1d_deadHeldMintersExact(
        uint256 pid, uint64 exp, uint64 epoch, uint64 ts, address m, uint64 e, address s, address caller,
        uint8 toPick, uint64 se, uint256 v0, bool primary
    ) public {
        // Justification: a fixed codeless parent owner, as in MP2 (a symbolic one trips a Halmos
        // memory limit in the burn and mint steps); caller, minter and setter stay symbolic
        address owner = OWNER;
        address to = toPick % 3 == 0 ? TO : (toPick % 3 == 1 ? owner : HOLDER);
        _parent(pid, owner, exp, epoch);
        uint256 sub = _sub(pid, FRESH);
        // Justification: distinct keccak preimages
        vm.assume(sub != pid);
        // Justification: epochs and versions grow by one per write
        vm.assume(se < type(uint64).max && v0 < type(uint256).max);
        nft.h_setRecord(sub, "fresh", pid, 0, se, epoch);
        nft.h_mint(DEAD, sub);
        nft.h_setVersion(sub, v0);
        if (primary) nft.h_setPrimary(DEAD, sub);
        nft.h_setMinter(pid, m, e, s);
        vm.warp(ts);

        address cm = (s == owner && e == epoch) ? m : address(0);
        bool allowed = ts <= exp && caller != address(0) && (caller == owner || caller == cm);
        assert(nft.isAvailable("fresh", pid) == (ts <= exp));
        vm.prank(caller);
        try nft.registerSubpageFor("fresh", pid, to) returns (uint256 id) {
            assert(allowed);
            assert(id == sub);
            assert(nft.ownerOf(sub) == to);
            (,,, uint64 ne, uint64 npe) = nft.records(sub);
            assert(ne == se + 1 && npe == epoch);
            assert(nft.recordVersion(sub) == v0 + 1);
            assert(nft.primaryPage(DEAD) == 0);
        } catch {
            assert(!allowed);
            assert(nft.ownerOf(sub) == DEAD);
            (,,, uint64 ne,) = nft.records(sub);
            assert(ne == se);
            assert(nft.recordVersion(sub) == v0);
            if (primary) assert(nft.primaryPage(DEAD) == sub);
        }
    }

    /// @notice MPZ: the zero caller. When no minter counts, the counted minter is address(0), which
    /// the minter check alone would let a call with msg.sender == address(0) pass. The contract refuses
    /// that caller, so registerSubpageFor by address(0) never mints, for any minter record, setter,
    /// epoch and time. Such a call comes only from a protocol fixed transaction, such as an OP network
    /// upgrade transaction, which is sent from address(0).
    /// @dev Technique: exact characterization of the zero caller. Classification: DIRECT.
    function test_check_MPZ_zeroCaller(
        uint256 pid, address owner, uint64 exp, uint64 epoch, uint64 ts, address m, uint64 e, address s
    ) public {
        _parent(pid, owner, exp, epoch);
        uint256 sub = _sub(pid, FRESH);
        vm.assume(sub != pid);
        nft.h_setMinter(pid, m, e, s);
        vm.warp(ts);
        vm.prank(address(0));
        try nft.registerSubpageFor("fresh", pid, TO) {
            assert(false);
        } catch {}
    }

    // MP2 who can overwrite a subpage

    /// @notice MP2: an existing subpage is overwritten if and only if the parent is not past its
    /// expiry and the caller is the holder, or the counted minter when the subpage is stale or held
    /// by DEAD (a minter never takes back a live subpage another account holds; a live subpage held
    /// by DEAD counts as free), and never when the caller is address(0) (MPZ). On success the subpage
    /// goes to the recipient in a new epoch and version and the old holder's primary pointer to it is
    /// gone; on failure its holder is unchanged.
    /// @dev Technique: exact characterization, both directions. Classification: DIRECT.
    function test_check_MP2_overwriteExact(
        uint256 pid, uint64 exp, uint64 epoch, uint64 ts,
        address m, uint64 e, address s, address caller, uint8 toPick,
        uint8 hPick, uint64 se, uint64 pe, uint256 v0, bool primary
    ) public {
        // Justification: the parent's owner and the subpage's holder are fixed codeless accounts.
        // With a symbolic one, the mint and burn steps build a memory offset from (account == 0),
        // which Halmos cannot follow. The caller, minter and setter stay symbolic, so every
        // relation the authority checks read (caller == owner, setter == owner, minter == caller)
        // is still covered. Contract holders are covered by the concrete suite.
        address owner = OWNER;
        address holder = hPick % 3 == 0 ? TO : (hPick % 3 == 1 ? HOLDER : DEAD);
        address to = toPick == 0 ? TO : (toPick == 1 ? owner : holder);
        _parent(pid, owner, exp, epoch);
        uint256 sub = _sub(pid, LIVE);
        // Justification: distinct keccak preimages
        vm.assume(sub != pid);
        // Justification: epochs and versions grow by one per write, 2^64 and 2^256 writes cannot happen
        vm.assume(se < type(uint64).max && v0 < type(uint256).max);
        nft.h_setRecord(sub, "live", pid, 0, se, pe);
        nft.h_mint(holder, sub);
        nft.h_setVersion(sub, v0);
        if (primary) nft.h_setPrimary(holder, sub);
        nft.h_setMinter(pid, m, e, s);
        vm.warp(ts);

        bool live = pe == epoch;
        bool counted = s == owner && e == epoch;
        address cm = counted ? m : address(0);
        bool ct = false;
        bool allowed =
            ts <= exp && caller != address(0) && (caller == owner || (caller == cm && (!live || ct || holder == DEAD)));
        vm.prank(caller);
        try nft.registerSubpageFor("live", pid, to) {
            assert(allowed);
            assert(nft.ownerOf(sub) == to);
            (,,, uint64 ne, uint64 npe) = nft.records(sub);
            assert(ne == se + 1 && npe == epoch);
            assert(nft.recordVersion(sub) == v0 + 1);
            if (primary) assert(nft.primaryPage(holder) == 0);
        } catch {
            assert(!allowed);
            assert(nft.ownerOf(sub) == holder);
            (,,, uint64 ne,) = nft.records(sub);
            assert(ne == se);
        }
    }

    // MP3 the setter rule

    /// @notice MP3: setSubpageMinter succeeds if and only if the record exists, is top level, the
    /// parent is not past expiry unless the call clears, and the caller is the holder or the
    /// recorded setter clearing. It then stores exactly (minter, current epoch, caller). A
    /// caller that is not the holder never changes what subpageMinterOf answers.
    /// @dev Technique: exact characterization plus a frame on the answer. Classification: DIRECT.
    function test_check_MP3_setterRuleExact(
        uint256 pid, address owner, uint64 exp, uint64 epoch, uint64 ts,
        address m, uint64 e, address s, address caller, address m2,
        bool exists, bool top
    ) public {
        vm.assume(pid != 0);
        vm.assume(owner != address(0) && owner != address(nft));
        if (exists) {
            nft.h_setRecord(pid, "club", top ? 0 : 1, exp, epoch, 0);
            nft.h_mint(owner, pid);
        }
        nft.h_setMinter(pid, m, e, s);
        vm.warp(ts);
        address holder = exists ? owner : address(0);
        address bm = nft.subpageMinterOf(pid);

        bool allowed = exists && top && (m2 == address(0) || ts <= exp)
            && (caller == holder || (m2 == address(0) && caller == s));
        vm.prank(caller);
        try nft.setSubpageMinter(pid, m2) {
            assert(allowed);
            (address rm, uint64 re, address rs) = nft.h_rawMinter(pid);
            assert(rm == m2 && re == epoch && rs == caller);
            if (caller != holder) assert(m2 == address(0) && caller == s);
        } catch {
            assert(!allowed);
        }
        address am = nft.subpageMinterOf(pid);
        if (caller != holder) assert(am == bm);
    }

    // MP4 the view

    /// @notice MP4: subpageMinterOf returns the stored minter exactly when the stored setter is the
    /// current holder and the stored epoch is the name's current epoch, and zero otherwise,
    /// whatever the expiry and timestamp.
    /// @dev Technique: exact characterization. Classification: DIRECT.
    function test_check_MP4_viewExact(
        uint256 pid, address owner, uint64 exp, uint64 epoch, uint64 ts,
        address m, uint64 e, address s, bool exists
    ) public {
        vm.assume(pid != 0);
        vm.assume(owner != address(0) && owner != address(nft));
        if (exists) {
            nft.h_setRecord(pid, "club", 0, exp, epoch, 0);
            nft.h_mint(owner, pid);
        }
        nft.h_setMinter(pid, m, e, s);
        vm.warp(ts);
        address holder = exists ? owner : address(0);
        uint64 ep = exists ? epoch : 0;
        address am = nft.subpageMinterOf(pid);
        if (s == holder && e == ep) assert(am == m);
        else assert(am == address(0));
    }

    /// @notice MP4b: with every storage slot symbolic, subpageMinterOf never reverts and answers
    /// by the counting rule read straight from the raw words.
    /// @dev Technique: symbolic storage, raw slot reads. Classification: DIRECT.
    function test_check_MP4b_viewSymbolicStorage(uint256 pid) public {
        svm.enableSymbolicStorage(address(nft));
        (uint256 w0, uint256 w1) = _rawMinter(pid);
        uint256 rec2 = _load(bytes32(uint256(_mslot(pid, 0)) + 2));
        uint64 curEpoch = uint64(rec2 >> 64);
        address holder = nft.h_ownerOf(pid);
        (bool ok, bytes memory ret) =
            address(nft).staticcall(abi.encodeWithSelector(PageNFT.subpageMinterOf.selector, pid));
        assert(ok);
        assert(ret.length == 32);
        address am = abi.decode(ret, (address));
        if (address(uint160(w1)) == holder && uint64(w0 >> 160) == curEpoch) {
            assert(am == address(uint160(w0)));
        } else {
            assert(am == address(0));
        }
    }

    // MP5 setSubpageMinter writes only slot 12

    /// @notice MP5a: from any storage, a call to setSubpageMinter, successful or not, leaves every
    /// word of PageNFT storage slots 0 to 11 and 13 to 18 unchanged at any key, for slots 10 and 18 at
    /// any key of 32 bytes, leaves the minter record of every other name unchanged, and on success
    /// writes the two words of slot 12 exactly.
    /// @dev Technique: symbolic storage, universally quantified keys, raw words. Classification: DIRECT.
    function test_check_MP5a_setterWritesOnlySlot12(
        uint256 pid, address caller, address m2,
        uint256 k, uint256 v, uint256 coin, address a, uint256 j, bytes32 key32, uint256 q, uint256 n
    ) public {
        svm.enableSymbolicStorage(address(nft));
        vm.assume(q != pid);
        // Justification: the plain slots 0 to 18 are mapping bases; any small index also covers slots never used
        vm.assume(n < 64);
        bytes32[] memory slots = new bytes32[](32);
        slots[0] = _mslot(k, 0);                                   // records[k].label
        slots[1] = bytes32(uint256(_mslot(k, 0)) + 1);             // records[k].parent
        slots[2] = bytes32(uint256(_mslot(k, 0)) + 2);             // records[k] packed
        slots[3] = bytes32(uint256(keccak256(abi.encode(_mslot(k, 0)))) + j); // long label data
        slots[4] = _mslot(k, 1);                                   // recordVersion
        slots[5] = _mslot(k, 2);                                   // commitments
        slots[6] = _mslot(uint256(uint160(a)), 3);                 // primaryPage
        slots[7] = _mslot(k, 4);                                   // referrerOf
        slots[8] = _mslot(k, 5);                                   // depositOf
        slots[9] = _mslot(uint256(uint160(a)), 6);                 // owed
        slots[10] = _nested(k, v, 7);                              // _resolvedAddress
        slots[11] = _nested(k, v, 8);                              // _contenthash head
        slots[12] = bytes32(uint256(keccak256(abi.encode(_nested(k, v, 8)))) + j);
        bytes32 ca = keccak256(abi.encode(coin, _nested(k, v, 9)));
        slots[13] = ca;                                            // _coinAddr saver
        slots[14] = bytes32(uint256(ca) + 1);                      // _coinAddr value head
        slots[15] = bytes32(uint256(keccak256(abi.encode(bytes32(uint256(ca) + 1)))) + j);
        bytes32 tx = keccak256(abi.encodePacked(key32, _nested(k, v, 10)));
        slots[16] = tx;                                            // _text head
        slots[17] = bytes32(uint256(keccak256(abi.encode(tx))) + j);
        slots[18] = _nested(k, v, 11);                             // _addrSaver
        slots[19] = _mslot(q, 12);                                 // another name's minter record
        slots[20] = bytes32(uint256(_mslot(q, 12)) + 1);
        slots[21] = bytes32(n);                                    // plain slots
        slots[22] = _mslot(pid, 0);                                // the parent's own record
        slots[23] = bytes32(uint256(_mslot(pid, 0)) + 2);
        slots[24] = _mslot(uint256(uint160(a)), 13);               // _primaryHolder
        slots[25] = _mslot(k, 14);                                 // trialPaymentOf
        slots[26] = _mslot(k, 15);                                 // _profile
        slots[27] = _mslot(k, 16);                                 // holderSince
        slots[28] = _mslot(k, 17);                                 // addressesUpdatedAt
        bytes32 dt = keccak256(abi.encodePacked(key32, _nested(k, v, 18)));
        slots[29] = dt;                                            // _data saver
        slots[30] = bytes32(uint256(dt) + 1);                      // _data value head
        slots[31] = bytes32(uint256(keccak256(abi.encode(bytes32(uint256(dt) + 1)))) + j);
        uint256[] memory before = new uint256[](32);
        for (uint256 i; i < 32; ++i) before[i] = _load(slots[i]);
        uint256 epochNow = uint64(_load(bytes32(uint256(_mslot(pid, 0)) + 2)) >> 64);
        (uint256 o0, uint256 o1) = _rawMinter(pid);

        vm.prank(caller);
        bool ok;
        try nft.setSubpageMinter(pid, m2) {
            ok = true;
        } catch {}

        for (uint256 i; i < 32; ++i) assert(_load(slots[i]) == before[i]);
        if (ok) {
            (uint256 w0, uint256 w1) = _rawMinter(pid);
            // the struct write sets the used bits and keeps the unused ones, which no code ever sets
            assert(w0 & ((1 << 224) - 1) == (uint256(uint160(m2)) | (epochNow << 160)));
            assert(w0 >> 224 == o0 >> 224);
            assert(uint160(w1) == uint160(caller));
            assert(w1 >> 160 == o1 >> 160);
        }
    }

    /// @notice MP5b: from any storage, setSubpageMinter changes no token owner, approval,
    /// operator approval, balance or aux, moves no ETH, and refuses any call that sends ETH.
    /// @dev Technique: symbolic storage, universally quantified keys, getters. Classification: DIRECT.
    function test_check_MP5b_setterTouchesNoTokenOrEth(
        uint256 pid, address caller, address m2, uint256 k, address a, address b, uint256 value
    ) public {
        svm.enableSymbolicStorage(address(nft));
        vm.assume(a != address(0));
        vm.assume(caller != address(nft));
        address o = nft.h_ownerOf(k);
        uint96 x = nft.h_extraData(k);
        address ap = nft.h_getApproved(k);
        uint256 bal = nft.balanceOf(a);
        uint224 aux = nft.h_aux(a);
        bool op = nft.isApprovedForAll(a, b);
        uint256 nftEth = address(nft).balance;
        uint256 callerEth = caller.balance;

        vm.deal(caller, callerEth + value);
        vm.prank(caller);
        (bool ok,) = address(nft).call{value: value}(abi.encodeCall(PageNFT.setSubpageMinter, (pid, m2)));
        if (value != 0) assert(!ok);

        assert(nft.h_ownerOf(k) == o);
        assert(nft.h_extraData(k) == x);
        assert(nft.h_getApproved(k) == ap);
        assert(nft.balanceOf(a) == bal);
        assert(nft.h_aux(a) == aux);
        assert(nft.isApprovedForAll(a, b) == op);
        assert(address(nft).balance == nftEth);
        assert(caller.balance == callerEth + value);
    }

    // MP6 a minter's mint

    /// @notice MP6: from any storage, a subpage mint by any caller other than the parent's holder
    /// succeeds only for the counted minter, lands on a live subpage only when DEAD holds it, and
    /// leaves unchanged every deposit, every owed balance, the PageNFT ETH balance, and the parent's
    /// owner, extra data, approval, record words, version, referrer, deposit, minter record and
    /// resolver data. A primary pointer changes only from the subpage id to zero.
    /// @dev Technique: symbolic storage, universally quantified keys, raw words. Classification: DIRECT.
    function test_check_MP6_minterMintFrame(
        uint256 pid, address caller, uint256 k, address a, uint256 coin, bytes32 key32
    ) public {
        svm.enableSymbolicStorage(address(nft));
        address to = TO;
        // Justification: no transaction or call has msg.sender == address(0); MPZ covers that case
        vm.assume(caller != address(0));
        uint256 sub = _sub(pid, FRESH);
        // Justification: distinct keccak preimages
        vm.assume(sub != pid);
        address holder = nft.h_ownerOf(pid);
        vm.assume(caller != holder);
        _assumeLabelWord(sub);

        (uint256 w0, uint256 w1) = _rawMinter(pid);
        uint256 v = _load(_mslot(pid, 1));
        bytes32[] memory slots = new bytes32[](16);
        slots[0] = _mslot(k, 5);                                   // depositOf[k]
        slots[1] = _mslot(uint256(uint160(a)), 6);                 // owed[a]
        slots[2] = _mslot(pid, 0);                                 // parent record words
        slots[3] = bytes32(uint256(_mslot(pid, 0)) + 1);
        slots[4] = bytes32(uint256(_mslot(pid, 0)) + 2);
        slots[5] = _mslot(pid, 1);                                 // parent version
        slots[6] = _mslot(pid, 4);                                 // parent referrer
        slots[7] = _mslot(pid, 5);                                 // parent deposit
        slots[8] = _mslot(pid, 12);                                // parent minter record
        slots[9] = bytes32(uint256(_mslot(pid, 12)) + 1);
        slots[10] = _nested(pid, v, 7);                            // parent resolver data
        slots[11] = _nested(pid, v, 11);
        slots[12] = _nested(pid, v, 8);
        slots[13] = keccak256(abi.encode(coin, _nested(pid, v, 9)));
        slots[14] = keccak256(abi.encodePacked(key32, _nested(pid, v, 10)));
        slots[15] = _mslot(uint256(uint160(a)), 3);                // primaryPage[a]
        uint256[] memory before = new uint256[](16);
        for (uint256 i; i < 16; ++i) before[i] = _load(slots[i]);
        uint256 subRec2 = _load(bytes32(uint256(_mslot(sub, 0)) + 2));
        uint256 subLabel = _load(_mslot(sub, 0));
        address subOwner = nft.h_ownerOf(sub);
        uint256 parentEpoch = uint64(before[4] >> 64);
        uint96 x = nft.h_extraData(pid);
        address ap = nft.h_getApproved(pid);
        uint256 nftEth = address(nft).balance;

        vm.prank(caller);
        try nft.registerSubpageFor("fresh", pid, to) {
            // only the counted minter
            assert(address(uint160(w1)) == holder && uint64(w0 >> 160) == parentEpoch);
            assert(address(uint160(w0)) == caller);
            // never a live subpage
            // the record exists when the stored label length is not zero, read as Solidity reads it
            bool existed = (subLabel & 1 == 1) ? (subLabel >> 1) != 0 : ((subLabel & 0xff) >> 1) != 0;
            bool live = existed && uint64(subRec2 >> 128) == parentEpoch;
            // unless DEAD holds it
            assert(!live || subOwner == DEAD);
            // frame
            for (uint256 i; i < 15; ++i) assert(_load(slots[i]) == before[i]);
            uint256 pAfter = _load(slots[15]);
            assert(pAfter == before[15] || (before[15] == sub && pAfter == 0));
            assert(nft.h_ownerOf(pid) == holder);
            assert(nft.h_extraData(pid) == x);
            assert(nft.h_getApproved(pid) == ap);
            assert(address(nft).balance == nftEth);
        } catch {}
    }

    /// @notice MP6s: MP6 with a narrowing of the arbitrary storage, and without the checks on the
    /// parent's extra data and approval. The savers of the subpage's own main address, coin type 60
    /// address and default address of coin type 0x80000000 (at its current version and the next) are
    /// zero, so no saved value counts and the transfer hooks, which read the default after the coin type
    /// 60 address, do not copy a bytes value of any length. Everything else, the parent, its minter
    /// record, deposits, owed balances, primary pointers and the subpage record, stays arbitrary.
    /// @dev Technique: symbolic storage with a pruning assumption on unrelated data. Classification: DIRECT.
    function test_check_MP6s_minterMintFramePruned(
        uint256 pid, address caller, uint256 k, address a, uint256 coin, bytes32 key32
    ) public {
        svm.enableSymbolicStorage(address(nft));
        uint256 sub = _sub(pid, FRESH);
        vm.assume(sub != pid);
        address holder = nft.h_ownerOf(pid);
        // Justification: no transaction or call has msg.sender == address(0); MPZ covers that case
        vm.assume(caller != address(0) && caller != holder);
        _assumeLabelWord(sub);
        uint256 sv = _load(_mslot(sub, 1));
        // Justification: versions grow by one per write
        vm.assume(sv < type(uint256).max);
        for (uint256 d; d < 2; ++d) {
            vm.assume(_load(_nested(sub, sv + d, 11)) == 0);
            vm.assume(_load(keccak256(abi.encode(uint256(60), _nested(sub, sv + d, 9)))) == 0);
            vm.assume(_load(keccak256(abi.encode(uint256(0x80000000), _nested(sub, sv + d, 9)))) == 0);
        }

        (uint256 w0, uint256 w1) = _rawMinter(pid);
        uint256 v = _load(_mslot(pid, 1));
        bytes32[] memory slots = new bytes32[](16);
        slots[0] = _mslot(k, 5);
        slots[1] = _mslot(uint256(uint160(a)), 6);
        slots[2] = _mslot(pid, 0);
        slots[3] = bytes32(uint256(_mslot(pid, 0)) + 1);
        slots[4] = bytes32(uint256(_mslot(pid, 0)) + 2);
        slots[5] = _mslot(pid, 1);
        slots[6] = _mslot(pid, 4);
        slots[7] = _mslot(pid, 5);
        slots[8] = _mslot(pid, 12);
        slots[9] = bytes32(uint256(_mslot(pid, 12)) + 1);
        slots[10] = _nested(pid, v, 7);
        slots[11] = _nested(pid, v, 11);
        slots[12] = _nested(pid, v, 8);
        slots[13] = keccak256(abi.encode(coin, _nested(pid, v, 9)));
        slots[14] = keccak256(abi.encodePacked(key32, _nested(pid, v, 10)));
        slots[15] = _mslot(uint256(uint160(a)), 3);
        uint256[] memory before = new uint256[](16);
        for (uint256 i; i < 16; ++i) before[i] = _load(slots[i]);
        uint256 subRec2 = _load(bytes32(uint256(_mslot(sub, 0)) + 2));
        uint256 subLabel = _load(_mslot(sub, 0));
        address subOwner = nft.h_ownerOf(sub);
        uint256 parentEpoch = uint64(before[4] >> 64);
        uint256 nftEth = address(nft).balance;

        vm.prank(caller);
        try nft.registerSubpageFor("fresh", pid, TO) {
            assert(address(uint160(w1)) == holder && uint64(w0 >> 160) == parentEpoch);
            assert(address(uint160(w0)) == caller);
            bool existed = (subLabel & 1 == 1) ? (subLabel >> 1) != 0 : ((subLabel & 0xff) >> 1) != 0;
            assert(!(existed && uint64(subRec2 >> 128) == parentEpoch) || subOwner == DEAD);
            for (uint256 i; i < 15; ++i) assert(_load(slots[i]) == before[i]);
            uint256 pAfter = _load(slots[15]);
            assert(pAfter == before[15] || (before[15] == sub && pAfter == 0));
            assert(nft.h_ownerOf(pid) == holder);
            assert(address(nft).balance == nftEth);
        } catch {}
    }

    /// @notice MP6b: the same property from built state, where the parent, its minter record, an
    /// existing or missing subpage, a primary pointer, a deposit and an owed balance at symbolic keys
    /// are all symbolic. A mint by any nonzero caller other than the holder succeeds only for the
    /// counted minter, never overwrites a live subpage unless DEAD holds it, and leaves every deposit and
    /// owed balance, the PageNFT ETH balance and the parent's record, record version, referrer, minter
    /// record and version 0 main address with its saver unchanged.
    /// @dev Technique: built symbolic state, universally quantified keys. Classification: DIRECT.
    function test_check_MP6b_minterMintFrameBuilt(
        uint256 pid, uint64 exp, uint64 epoch, uint64 ts, address m, uint64 e, address s,
        address caller, bool exists, uint64 se, uint64 pe, uint256 k, address a, uint256 dk, uint256 ow, bool subDead
    ) public {
        address owner = OWNER;
        address subHolder = subDead ? DEAD : HOLDER;
        _parent(pid, owner, exp, epoch);
        uint256 sub = _sub(pid, FRESH);
        // Justification: distinct keccak preimages
        vm.assume(sub != pid);
        // Justification: no transaction or call has msg.sender == address(0); MPZ covers that case
        vm.assume(caller != address(0) && caller != owner);
        if (exists) {
            // Justification: epochs grow by one per registration
            vm.assume(se < type(uint64).max);
            nft.h_setRecord(sub, "fresh", pid, 0, se, pe);
            nft.h_mint(subHolder, sub);
            nft.h_setPrimary(subHolder, sub);
        }
        nft.h_setMinter(pid, m, e, s);
        nft.h_setDeposit(k, dk);
        nft.h_setDeposit(pid, uint256(keccak256(abi.encode(dk))));
        nft.h_setOwed(a, ow);
        vm.warp(ts);

        bytes32[] memory slots = new bytes32[](9);
        slots[0] = _mslot(pid, 0);
        slots[1] = bytes32(uint256(_mslot(pid, 0)) + 1);
        slots[2] = bytes32(uint256(_mslot(pid, 0)) + 2);
        slots[3] = _mslot(pid, 1);
        slots[4] = _mslot(pid, 4);
        slots[5] = _mslot(pid, 12);
        slots[6] = bytes32(uint256(_mslot(pid, 12)) + 1);
        slots[7] = _nested(pid, 0, 7);
        slots[8] = _nested(pid, 0, 11);
        uint256[] memory before = new uint256[](9);
        for (uint256 i; i < 9; ++i) before[i] = _load(slots[i]);
        uint256 depK = nft.depositOf(k);
        uint256 depP = nft.depositOf(pid);
        uint256 owA = nft.owed(a);
        uint256 nftEth = address(nft).balance;
        address ap = nft.h_getApproved(pid);

        vm.prank(caller);
        try nft.registerSubpageFor("fresh", pid, TO) {
            bool counted = s == owner && e == epoch;
            assert(counted && m == caller);
            assert(!(exists && pe == epoch && !subDead));
            for (uint256 i; i < 9; ++i) assert(_load(slots[i]) == before[i]);
            assert(nft.depositOf(k) == depK && nft.depositOf(pid) == depP);
            assert(nft.owed(a) == owA);
            assert(address(nft).balance == nftEth);
            assert(nft.ownerOf(pid) == owner);
            assert(nft.h_getApproved(pid) == ap);
            assert(nft.ownerOf(sub) == TO);
            if (exists) assert(nft.primaryPage(subHolder) == 0);
        } catch {}
    }

    // MP7 only setSubpageMinter writes the record

    /// @notice MP7: any PageNFT call other than multicall, by an account other than the parent's
    /// holder, leaves the raw minter record unchanged, except setSubpageMinter by the recorded setter
    /// writing zero. If the answer of subpageMinterOf changes, it becomes zero or the parent now sits
    /// with the account that made the pick. A multicall can first move the name to the caller.
    /// @dev Technique: arbitrary calldata over every PageNFT function that is not a view. Classification: DIRECT.
    function test_check_MP7_anyCallByNonHolder(
        uint64 exp, uint64 epoch, uint64 ts, address m, uint64 e, address s, address caller, bool opApproved
    ) public {
        // Justification: concrete parent id and owner, as in MP7d
        uint256 pid = uint256(keccak256(abi.encodePacked(nft.ROOT(), keccak256(bytes("club")))));
        address owner = OWNER;
        _parent(pid, owner, exp, epoch);
        nft.h_setMinter(pid, m, e, s);
        // Justification: no transaction or call has msg.sender == address(0). The ERC721 library also
        // skips its approval check when the caller is address(0)
        vm.assume(caller != owner && caller != address(0));
        if (opApproved) {
            vm.prank(owner);
            nft.setApprovalForAll(caller, true);
        }
        vm.warp(ts);
        (uint256 w0, uint256 w1) = _rawMinter(pid);
        address bm = nft.subpageMinterOf(pid);

        bytes memory data = svm.createCalldata("PageNFT");
        // Justification: a multicall runs its calls one by one, so an operator can first take the name
        // and then pick a minter as its holder; MP7d covers each call alone
        vm.assume(bytes4(data) != PageNFT.multicall.selector);
        vm.prank(caller);
        (bool ok,) = address(nft).call(data);

        (uint256 a0, uint256 a1) = _rawMinter(pid);
        if (a0 != w0 || a1 != w1) {
            assert(ok);
            assert(bytes4(data) == PageNFT.setSubpageMinter.selector);
            assert(address(uint160(w1)) == caller);
            assert(address(uint160(a0)) == address(0) && address(uint160(a1)) == caller);
        }
        address am = nft.subpageMinterOf(pid);
        if (am != bm) {
            assert(am == address(0) || nft.h_ownerOf(pid) == address(uint160(a1)));
        }
    }

    /// @notice MP7d: MP7 split into one symbolic call at a time. Each of the 21 state changing calls of
    /// its dispatcher (registerSubpage runs the same code as registerSubpageFor, and multicall is left
    /// out, as a bundle can first move the name to the caller), called by any nonzero account with no
    /// code other than the holder (an operator, the account approved for the token, the minter, a former
    /// setter or a stranger), leaves the raw minter record unchanged unless it is setSubpageMinter by
    /// the recorded setter writing zero, and changes what subpageMinterOf answers only to zero or to the
    /// pick of the account that now holds the parent. The subpage mint (w == 6) meets no record, a live
    /// subpage held by HOLDER, one held by DEAD or a stale one; it succeeds only for the counted minter
    /// and never over the live subpage HOLDER holds.
    /// @dev Technique: dispatcher over 21 functions with symbolic arguments. Classification: DIRECT.
    function test_check_MP7d_eachCallByNonHolder(
        uint64 exp, uint64 epoch, uint64 ts, address m, uint64 e, uint8 sPick,
        address caller, bool opApproved, bool tokApproved, uint8 which, uint8 toPick, uint256 x, address y
    ) public {
        // Justification: a concrete parent id; with a symbolic one the transfer hooks read the owner
        // through an unresolved storage term and build a memory offset Halmos cannot follow
        uint256 pid = uint256(keccak256(abi.encodePacked(nft.ROOT(), keccak256(bytes("club")))));
        // Justification: fixed codeless owner, setter and recipients, as in MP2 (symbolic ones trip a
        // Halmos memory limit in the transfer hooks); the caller, the minter and all arguments stay symbolic
        address owner = OWNER;
        address s = sPick % 3 == 0 ? OWNER : (sPick % 3 == 1 ? TO : HOLDER);
        address to = toPick % 3 == 0 ? TO : (toPick % 3 == 1 ? HOLDER : OWNER);
        _parent(pid, owner, exp, epoch);
        nft.h_setMinter(pid, m, e, s);
        // Justification: no transaction or call has msg.sender == address(0)
        vm.assume(caller != owner && caller != address(0) && caller != address(nft));
        vm.assume(caller.code.length == 0);
        if (opApproved) {
            vm.prank(owner);
            nft.setApprovalForAll(caller, true);
        }
        if (tokApproved) {
            vm.prank(owner);
            nft.approve(caller, pid);
        }
        uint8 w = which % 21;
        uint256 subA = _sub(pid, "a");
        uint256 aPick = x % 4;
        if (w == 6 && aPick != 0) {
            // Justification: epochs grow by one per registration, so an epoch below 2^64 minus 1 leaves room
            vm.assume(epoch < type(uint64).max);
            nft.h_setRecord(subA, "a", pid, 0, 1, aPick == 3 ? epoch + 1 : epoch);
            nft.h_mint(aPick == 2 ? DEAD : HOLDER, subA);
        }
        vm.warp(ts);
        (uint256 w0, uint256 w1) = _rawMinter(pid);
        address bm = nft.subpageMinterOf(pid);

        vm.deal(caller, 1 ether);
        vm.startPrank(caller);
        bool ok;
        if (w == 0) (ok,) = address(nft).call(abi.encodeWithSignature("transferFrom(address,address,uint256)", owner, to, pid));
        else if (w == 1) (ok,) = address(nft).call(abi.encodeWithSignature("safeTransferFrom(address,address,uint256)", owner, to, pid));
        else if (w == 2) (ok,) = address(nft).call(abi.encodeWithSignature("safeTransferFrom(address,address,uint256,bytes)", owner, to, pid, hex"01"));
        else if (w == 3) (ok,) = address(nft).call(abi.encodeCall(PageNFT.approve, (y, pid)));
        else if (w == 4) (ok,) = address(nft).call(abi.encodeWithSignature("setApprovalForAll(address,bool)", y, x & 1 == 1));
        else if (w == 5) (ok,) = address(nft).call(abi.encodeCall(PageNFT.setSubpageMinter, (pid, y)));
        else if (w == 6) (ok,) = address(nft).call(abi.encodeCall(PageNFT.registerSubpageFor, ("a", pid, TO)));
        else if (w == 7) (ok,) = address(nft).call(abi.encodeWithSignature("setAddr(uint256,address)", pid, y));
        else if (w == 8) (ok,) = address(nft).call(abi.encodeCall(PageNFT.setAddrForCoin, (pid, x, abi.encodePacked(y))));
        else if (w == 9) (ok,) = address(nft).call(abi.encodeWithSignature("setText(uint256,string,string)", pid, "k", "v"));
        else if (w == 10) (ok,) = address(nft).call(abi.encodeWithSignature("setContenthash(uint256,bytes)", pid, hex"01"));
        else if (w == 11) (ok,) = address(nft).call(abi.encodeCall(PageNFT.clearRecords, (pid)));
        else if (w == 12) (ok,) = address(nft).call(abi.encodeCall(PageNFT.setPrimaryPage, (pid)));
        else if (w == 13) (ok,) = address(nft).call{value: 0.005 ether}(abi.encodeCall(PageNFT.renew, (pid)));
        else if (w == 14) (ok,) = address(nft).call(abi.encodeCall(PageNFT.release, (pid)));
        else if (w == 15) (ok,) = address(nft).call(abi.encodeCall(PageNFT.withdraw, (y)));
        else if (w == 16) (ok,) = address(nft).call(abi.encodeCall(PageNFT.commit, (bytes32(x))));
        else if (w == 17) (ok,) = address(nft).call(abi.encodeCall(PageNFT.reveal, ("club", y, 0, bytes32(x))));
        else if (w == 18) (ok,) = address(nft).call(abi.encodeCall(PageNFT.keepProfile, (pid)));
        else if (w == 19) (ok,) = address(nft).call{value: 0.0001 ether}(abi.encodeCall(PageNFT.revealTrial, ("club", y, 0, bytes32(x))));
        else (ok,) = address(nft).call(abi.encodeCall(PageNFT.setData, (pid, "k", hex"01")));
        vm.stopPrank();

        (uint256 a0, uint256 a1) = _rawMinter(pid);
        if (a0 != w0 || a1 != w1) {
            assert(ok && w == 5);
            assert(address(uint160(w1)) == caller);
            assert(address(uint160(a0)) == address(0) && address(uint160(a1)) == caller);
        }
        address am = nft.subpageMinterOf(pid);
        if (am != bm) {
            assert(am == address(0) || nft.h_ownerOf(pid) == address(uint160(a1)));
        }
        if (w == 6 && ok) {
            assert(bm == caller && ts <= exp);
            assert(aPick != 1);
            assert(nft.ownerOf(subA) == TO);
        }
        if (w == 6 && !ok && aPick == 1) assert(nft.ownerOf(subA) == HOLDER);
    }

    /// @notice MP7dA split by the call so each part finishes: G0 transfers, G1 approvals and the
    /// minter choice, G2 the subpage mint, G3 record writes, G4 renew, release, withdraw and commit,
    /// G5 reveal, G6 keepProfile and revealTrial, G7 setData. Same assertions as MP7dA. The reveal
    /// and revealTrial calls carry no commitment, so they always revert here and only show that such a
    /// call changes nothing; MP7r and MP7t prove real registrations over the parent.
    function test_check_MP7dG0(
        uint64 exp, uint64 epoch, uint64 ts, address m, uint64 e, uint8 sPick,
        address caller, bool opApproved, bool tokApproved, uint8 which, uint8 toPick, uint256 x, address y
    ) public {
        uint8 k = which % 21;
        vm.assume(k == 0 || k == 1 || k == 2);
        test_check_MP7dA_eachCallButChoice(exp, epoch, ts, m, e, sPick, caller, opApproved, tokApproved, which, toPick, x, y);
    }

    function test_check_MP7dG1(
        uint64 exp, uint64 epoch, uint64 ts, address m, uint64 e, uint8 sPick,
        address caller, bool opApproved, bool tokApproved, uint8 which, uint8 toPick, uint256 x, address y
    ) public {
        uint8 k = which % 21;
        vm.assume(k == 3 || k == 4 || k == 5);
        test_check_MP7dA_eachCallButChoice(exp, epoch, ts, m, e, sPick, caller, opApproved, tokApproved, which, toPick, x, y);
    }

    function test_check_MP7dG2(
        uint64 exp, uint64 epoch, uint64 ts, address m, uint64 e, uint8 sPick,
        address caller, bool opApproved, bool tokApproved, uint8 which, uint8 toPick, uint256 x, address y
    ) public {
        uint8 k = which % 21;
        vm.assume(k == 6);
        test_check_MP7dA_eachCallButChoice(exp, epoch, ts, m, e, sPick, caller, opApproved, tokApproved, which, toPick, x, y);
    }

    function test_check_MP7dG3(
        uint64 exp, uint64 epoch, uint64 ts, address m, uint64 e, uint8 sPick,
        address caller, bool opApproved, bool tokApproved, uint8 which, uint8 toPick, uint256 x, address y
    ) public {
        uint8 k = which % 21;
        vm.assume(k == 7 || k == 8 || k == 9 || k == 10 || k == 11);
        test_check_MP7dA_eachCallButChoice(exp, epoch, ts, m, e, sPick, caller, opApproved, tokApproved, which, toPick, x, y);
    }

    function test_check_MP7dG4(
        uint64 exp, uint64 epoch, uint64 ts, address m, uint64 e, uint8 sPick,
        address caller, bool opApproved, bool tokApproved, uint8 which, uint8 toPick, uint256 x, address y
    ) public {
        uint8 k = which % 21;
        vm.assume(k == 13 || k == 14 || k == 15 || k == 16);
        test_check_MP7dA_eachCallButChoice(exp, epoch, ts, m, e, sPick, caller, opApproved, tokApproved, which, toPick, x, y);
    }

    function test_check_MP7dG5(
        uint64 exp, uint64 epoch, uint64 ts, address m, uint64 e, uint8 sPick,
        address caller, bool opApproved, bool tokApproved, uint8 which, uint8 toPick, uint256 x, address y
    ) public {
        uint8 k = which % 21;
        vm.assume(k == 17);
        test_check_MP7dA_eachCallButChoice(exp, epoch, ts, m, e, sPick, caller, opApproved, tokApproved, which, toPick, x, y);
    }

    function test_check_MP7dG6(
        uint64 exp, uint64 epoch, uint64 ts, address m, uint64 e, uint8 sPick,
        address caller, bool opApproved, bool tokApproved, uint8 which, uint8 toPick, uint256 x, address y
    ) public {
        uint8 k = which % 21;
        vm.assume(k == 18 || k == 19);
        test_check_MP7dA_eachCallButChoice(exp, epoch, ts, m, e, sPick, caller, opApproved, tokApproved, which, toPick, x, y);
    }

    function test_check_MP7dG7(
        uint64 exp, uint64 epoch, uint64 ts, address m, uint64 e, uint8 sPick,
        address caller, bool opApproved, bool tokApproved, uint8 toPick, uint256 x, address y
    ) public {
        // setData is call 20. It is passed in directly, not picked by an assume on a symbolic index,
        // so a forge fuzz run does not reject most of its inputs. The claim is the same.
        test_check_MP7dA_eachCallButChoice(exp, epoch, ts, m, e, sPick, caller, opApproved, tokApproved, 20, toPick, x, y);
    }

    /// @notice MP7dA and MP7dB: MP7d split so each part finishes, since setPrimaryPage also writes a
    /// slot keyed by the caller. A is every call but setPrimaryPage with a symbolic caller; B is
    /// setPrimaryPage with one of three fixed callers. Same assertions.
    /// @dev Technique: as MP7d. Classification: DIRECT.
    function test_check_MP7dA_eachCallButChoice(
        uint64 exp, uint64 epoch, uint64 ts, address m, uint64 e, uint8 sPick,
        address caller, bool opApproved, bool tokApproved, uint8 which, uint8 toPick, uint256 x, address y
    ) public {
        // this part leaves out setPrimaryPage, which MP7dB covers with a fixed caller
        vm.assume(which % 21 != 12);
        // Justification: a concrete parent id; with a symbolic one the transfer hooks read the owner
        // through an unresolved storage term and build a memory offset Halmos cannot follow
        uint256 pid = uint256(keccak256(abi.encodePacked(nft.ROOT(), keccak256(bytes("club")))));
        // Justification: fixed codeless owner, setter and recipients, as in MP2 (symbolic ones trip a
        // Halmos memory limit in the transfer hooks); the caller, the minter and all arguments stay symbolic
        address owner = OWNER;
        address s = sPick % 3 == 0 ? OWNER : (sPick % 3 == 1 ? TO : HOLDER);
        address to = toPick % 3 == 0 ? TO : (toPick % 3 == 1 ? HOLDER : OWNER);
        _parent(pid, owner, exp, epoch);
        nft.h_setMinter(pid, m, e, s);
        // Justification: no transaction or call has msg.sender == address(0)
        vm.assume(caller != owner && caller != address(0) && caller != address(nft));
        vm.assume(caller.code.length == 0);
        if (opApproved) {
            vm.prank(owner);
            nft.setApprovalForAll(caller, true);
        }
        if (tokApproved) {
            vm.prank(owner);
            nft.approve(caller, pid);
        }
        uint8 w = which % 21;
        uint256 subA = _sub(pid, "a");
        uint256 aPick = x % 4;
        if (w == 6 && aPick != 0) {
            // Justification: epochs grow by one per registration, so an epoch below 2^64 minus 1 leaves room
            vm.assume(epoch < type(uint64).max);
            nft.h_setRecord(subA, "a", pid, 0, 1, aPick == 3 ? epoch + 1 : epoch);
            nft.h_mint(aPick == 2 ? DEAD : HOLDER, subA);
        }
        vm.warp(ts);
        (uint256 w0, uint256 w1) = _rawMinter(pid);
        address bm = nft.subpageMinterOf(pid);

        vm.deal(caller, 1 ether);
        vm.startPrank(caller);
        bool ok;
        if (w == 0) (ok,) = address(nft).call(abi.encodeWithSignature("transferFrom(address,address,uint256)", owner, to, pid));
        else if (w == 1) (ok,) = address(nft).call(abi.encodeWithSignature("safeTransferFrom(address,address,uint256)", owner, to, pid));
        else if (w == 2) (ok,) = address(nft).call(abi.encodeWithSignature("safeTransferFrom(address,address,uint256,bytes)", owner, to, pid, hex"01"));
        else if (w == 3) (ok,) = address(nft).call(abi.encodeCall(PageNFT.approve, (y, pid)));
        else if (w == 4) (ok,) = address(nft).call(abi.encodeWithSignature("setApprovalForAll(address,bool)", y, x & 1 == 1));
        else if (w == 5) (ok,) = address(nft).call(abi.encodeCall(PageNFT.setSubpageMinter, (pid, y)));
        else if (w == 6) (ok,) = address(nft).call(abi.encodeCall(PageNFT.registerSubpageFor, ("a", pid, TO)));
        else if (w == 7) (ok,) = address(nft).call(abi.encodeWithSignature("setAddr(uint256,address)", pid, y));
        else if (w == 8) (ok,) = address(nft).call(abi.encodeCall(PageNFT.setAddrForCoin, (pid, x, abi.encodePacked(y))));
        else if (w == 9) (ok,) = address(nft).call(abi.encodeWithSignature("setText(uint256,string,string)", pid, "k", "v"));
        else if (w == 10) (ok,) = address(nft).call(abi.encodeWithSignature("setContenthash(uint256,bytes)", pid, hex"01"));
        else if (w == 11) (ok,) = address(nft).call(abi.encodeCall(PageNFT.clearRecords, (pid)));
        else if (w == 12) (ok,) = address(nft).call(abi.encodeCall(PageNFT.setPrimaryPage, (pid)));
        else if (w == 13) (ok,) = address(nft).call{value: 0.005 ether}(abi.encodeCall(PageNFT.renew, (pid)));
        else if (w == 14) (ok,) = address(nft).call(abi.encodeCall(PageNFT.release, (pid)));
        else if (w == 15) (ok,) = address(nft).call(abi.encodeCall(PageNFT.withdraw, (y)));
        else if (w == 16) (ok,) = address(nft).call(abi.encodeCall(PageNFT.commit, (bytes32(x))));
        else if (w == 17) (ok,) = address(nft).call(abi.encodeCall(PageNFT.reveal, ("club", y, 0, bytes32(x))));
        else if (w == 18) (ok,) = address(nft).call(abi.encodeCall(PageNFT.keepProfile, (pid)));
        else if (w == 19) (ok,) = address(nft).call{value: 0.0001 ether}(abi.encodeCall(PageNFT.revealTrial, ("club", y, 0, bytes32(x))));
        else (ok,) = address(nft).call(abi.encodeCall(PageNFT.setData, (pid, "k", hex"01")));
        vm.stopPrank();

        (uint256 a0, uint256 a1) = _rawMinter(pid);
        if (a0 != w0 || a1 != w1) {
            assert(ok && w == 5);
            assert(address(uint160(w1)) == caller);
            assert(address(uint160(a0)) == address(0) && address(uint160(a1)) == caller);
        }
        address am = nft.subpageMinterOf(pid);
        if (am != bm) {
            assert(am == address(0) || nft.h_ownerOf(pid) == address(uint160(a1)));
        }
        if (w == 6 && ok) {
            assert(bm == caller && ts <= exp);
            assert(aPick != 1);
            assert(nft.ownerOf(subA) == TO);
        }
        if (w == 6 && !ok && aPick == 1) assert(nft.ownerOf(subA) == HOLDER);
    }

    function test_check_MP7dB_choiceByNonHolder(
        uint64 exp, uint64 epoch, uint64 ts, address m, uint64 e, uint8 sPick,
        uint8 cPick, bool opApproved, bool tokApproved, uint8 which, uint8 toPick, uint256 x, address y,
        bool mainSaved
    ) public {
        // Justification: the choice writes a slot keyed by the caller; a symbolic key there makes
        // every later raw read of the minter record an aliasing query, so the caller is one of three
        // fixed codeless accounts other than the holder
        address caller = cPick % 3 == 0 ? TO : cPick % 3 == 1 ? HOLDER : address(0x0FE2);
        vm.assume(which % 21 == 12);
        // Justification: a concrete parent id; with a symbolic one the transfer hooks read the owner
        // through an unresolved storage term and build a memory offset Halmos cannot follow
        uint256 pid = uint256(keccak256(abi.encodePacked(nft.ROOT(), keccak256(bytes("club")))));
        // Justification: fixed codeless owner, setter and recipients, as in MP2 (symbolic ones trip a
        // Halmos memory limit in the transfer hooks); the minter and all arguments stay symbolic
        address owner = OWNER;
        address s = sPick % 3 == 0 ? OWNER : (sPick % 3 == 1 ? TO : HOLDER);
        address to = toPick % 3 == 0 ? TO : (toPick % 3 == 1 ? HOLDER : OWNER);
        _parent(pid, owner, exp, epoch);
        nft.h_setMinter(pid, m, e, s);
        // Justification: no transaction or call has msg.sender == address(0)
        vm.assume(caller != owner && caller != address(0) && caller != address(nft));
        vm.assume(caller.code.length == 0);
        if (opApproved) {
            vm.prank(owner);
            nft.setApprovalForAll(caller, true);
        }
        if (tokApproved) {
            vm.prank(owner);
            nft.approve(caller, pid);
        }
        // on some paths the holder has saved the caller as the parent's main address, so the caller can
        // choose the parent as its display name without holding it
        if (mainSaved) nft.h_setResolved(pid, caller, owner);
        uint8 w = which % 21;
        uint256 subA = _sub(pid, "a");
        uint256 aPick = x % 4;
        if (w == 6 && aPick != 0) {
            // Justification: epochs grow by one per registration, so an epoch below 2^64 minus 1 leaves room
            vm.assume(epoch < type(uint64).max);
            nft.h_setRecord(subA, "a", pid, 0, 1, aPick == 3 ? epoch + 1 : epoch);
            nft.h_mint(aPick == 2 ? DEAD : HOLDER, subA);
        }
        vm.warp(ts);
        (uint256 w0, uint256 w1) = _rawMinter(pid);
        address bm = nft.subpageMinterOf(pid);

        vm.deal(caller, 1 ether);
        vm.startPrank(caller);
        bool ok;
        if (w == 0) (ok,) = address(nft).call(abi.encodeWithSignature("transferFrom(address,address,uint256)", owner, to, pid));
        else if (w == 1) (ok,) = address(nft).call(abi.encodeWithSignature("safeTransferFrom(address,address,uint256)", owner, to, pid));
        else if (w == 2) (ok,) = address(nft).call(abi.encodeWithSignature("safeTransferFrom(address,address,uint256,bytes)", owner, to, pid, hex"01"));
        else if (w == 3) (ok,) = address(nft).call(abi.encodeCall(PageNFT.approve, (y, pid)));
        else if (w == 4) (ok,) = address(nft).call(abi.encodeWithSignature("setApprovalForAll(address,bool)", y, x & 1 == 1));
        else if (w == 5) (ok,) = address(nft).call(abi.encodeCall(PageNFT.setSubpageMinter, (pid, y)));
        else if (w == 6) (ok,) = address(nft).call(abi.encodeCall(PageNFT.registerSubpageFor, ("a", pid, TO)));
        else if (w == 7) (ok,) = address(nft).call(abi.encodeWithSignature("setAddr(uint256,address)", pid, y));
        else if (w == 8) (ok,) = address(nft).call(abi.encodeCall(PageNFT.setAddrForCoin, (pid, x, abi.encodePacked(y))));
        else if (w == 9) (ok,) = address(nft).call(abi.encodeWithSignature("setText(uint256,string,string)", pid, "k", "v"));
        else if (w == 10) (ok,) = address(nft).call(abi.encodeWithSignature("setContenthash(uint256,bytes)", pid, hex"01"));
        else if (w == 11) (ok,) = address(nft).call(abi.encodeCall(PageNFT.clearRecords, (pid)));
        else if (w == 12) (ok,) = address(nft).call(abi.encodeCall(PageNFT.setPrimaryPage, (pid)));
        else if (w == 13) (ok,) = address(nft).call{value: 0.005 ether}(abi.encodeCall(PageNFT.renew, (pid)));
        else if (w == 14) (ok,) = address(nft).call(abi.encodeCall(PageNFT.release, (pid)));
        else if (w == 15) (ok,) = address(nft).call(abi.encodeCall(PageNFT.withdraw, (y)));
        else if (w == 16) (ok,) = address(nft).call(abi.encodeCall(PageNFT.commit, (bytes32(x))));
        else if (w == 17) (ok,) = address(nft).call(abi.encodeCall(PageNFT.reveal, ("club", y, 0, bytes32(x))));
        else if (w == 18) (ok,) = address(nft).call(abi.encodeCall(PageNFT.keepProfile, (pid)));
        else if (w == 19) (ok,) = address(nft).call{value: 0.0001 ether}(abi.encodeCall(PageNFT.revealTrial, ("club", y, 0, bytes32(x))));
        else (ok,) = address(nft).call(abi.encodeCall(PageNFT.setData, (pid, "k", hex"01")));
        vm.stopPrank();

        (uint256 a0, uint256 a1) = _rawMinter(pid);
        if (a0 != w0 || a1 != w1) {
            assert(ok && w == 5);
            assert(address(uint160(w1)) == caller);
            assert(address(uint160(a0)) == address(0) && address(uint160(a1)) == caller);
        }
        address am = nft.subpageMinterOf(pid);
        if (am != bm) {
            assert(am == address(0) || nft.h_ownerOf(pid) == address(uint160(a1)));
        }
        if (w == 6 && ok) {
            assert(bm == caller && ts <= exp);
            assert(aPick != 1);
            assert(nft.ownerOf(subA) == TO);
        }
        if (w == 6 && !ok && aPick == 1) assert(nft.ownerOf(subA) == HOLDER);
    }

    /// @notice MP7r: a new registration of an expired parent by anyone switches the minter off,
    /// whoever registers it (the former setter included), and leaves the raw record untouched.
    /// @dev Technique: concrete registration with symbolic minter state and registrant. Classification: DIRECT.
    function test_check_MP7r_reRegistrationSwitchesOff(address m, bool sameAccount) public {
        vm.warp(1_800_000_000);
        address first = OWNER;
        address second = sameAccount ? OWNER : TO;
        uint256 id = _register(first, "club");
        vm.prank(first);
        nft.setSubpageMinter(id, m);
        (uint256 w0, uint256 w1) = _rawMinter(id);
        vm.warp(block.timestamp + 365 days + 90 days + 21 days + 1);
        _register(second, "club");
        (uint256 a0, uint256 a1) = _rawMinter(id);
        assert(a0 == w0 && a1 == w1);
        address am = nft.subpageMinterOf(id);
        assert(am == address(0));
        assert(nft.ownerOf(id) == second);
    }

    function _register(address who, string memory label) internal returns (uint256 id) {
        bytes32 secret = bytes32(uint256(7));
        vm.prank(who);
        nft.commit(nft.makeCommitment(label, who, 0, secret));
        vm.warp(block.timestamp + 61);
        (,,, uint256 total) = nft.quote(label);
        vm.deal(who, total);
        vm.prank(who);
        id = nft.reveal{value: total}(label, who, 0, secret);
    }

    // MP8 the registrar sale

    /// @notice MP8: from any registrar storage and a built PageNFT state, an ETH sale through
    /// registerSubpageFor, whose checks the commit and reveal sale shares through _sell, succeeds
    /// only when the registrar is the counted minter, the holder is the config's controller in the
    /// config's epoch, and the label is free, stale or held by DEAD. It never overwrites a live
    /// subpage another account holds, leaves the parent's holder, epoch and minter record, every
    /// deposit and owed balance and the PageNFT ETH balance unchanged, and books exactly the price:
    /// the registrar's ETH and the payout's proceeds both grow by it.
    /// @dev Technique: symbolic registrar storage, built PageNFT state. Classification: DIRECT.
    function test_check_MP8_registrarSale(
        uint256 pid, address owner, uint64 exp, uint64 epoch, uint64 ts,
        address m, uint64 e, address s, address buyer, uint256 value
    ) public {
        svm.enableSymbolicStorage(address(reg));
        address to = TO;
        bool exists = svm.createBool("exists");
        bool dead = svm.createBool("dead");
        // Justification: a fixed codeless holder, as in MP2 (a symbolic one trips a Halmos memory
        // limit); DEAD is the other pick
        address holder = dead ? DEAD : HOLDER;
        uint64 se = uint64(svm.createUint(64, "se"));
        uint64 pe = uint64(svm.createUint(64, "pe"));
        uint256 k = svm.createUint(256, "k");
        address a = svm.createAddress("a");
        vm.assume(buyer != address(nft) && buyer != address(reg) && buyer.code.length == 0);
        _parent(pid, owner, exp, epoch);
        uint256 sub = _sub(pid, FRESH);
        vm.assume(sub != pid);
        if (exists) {
            vm.assume(se < type(uint64).max);
            nft.h_setRecord(sub, "fresh", pid, 0, se, pe);
            nft.h_mint(holder, sub);
        }
        nft.h_setMinter(pid, m, e, s);
        vm.warp(ts);
        // Justification: this proof covers ETH sales without a gate; token calls to unknown code are
        // outside what the solver can model, and the concrete suite covers the ERC20 and gate paths
        (address controller,,, address feeToken, uint96 price, address gateToken,, address pay, uint64 cEpoch) =
            reg.config(pid);
        vm.assume(feeToken == address(0) && gateToken == address(0));
        vm.assume(pay != address(reg) && pay != address(nft));

        uint256 dep = nft.depositOf(k);
        uint256 ow = nft.owed(a);
        uint256 nftEth = address(nft).balance;
        uint256 regEth = address(reg).balance;
        uint256 proceeds = reg.proceedsOf(pay);
        (uint256 w0, uint256 w1) = _rawMinter(pid);
        (,,, uint64 pEpoch,) = nft.records(pid);
        vm.deal(buyer, value);

        vm.prank(buyer);
        try reg.registerSubpageFor{value: value}(pid, "fresh", to, type(uint256).max, address(0)) {
            assert(m == address(reg) && s == owner && e == epoch);
            assert(controller == owner && cEpoch == epoch);
            assert(!exists || pe != epoch || dead);
            assert(nft.ownerOf(sub) == to);
            assert(nft.h_ownerOf(pid) == owner);
            (,,, uint64 pEpochAfter,) = nft.records(pid);
            assert(pEpochAfter == pEpoch);
            (uint256 a0, uint256 a1) = _rawMinter(pid);
            assert(a0 == w0 && a1 == w1);
            assert(nft.depositOf(k) == dep && nft.owed(a) == ow);
            assert(address(nft).balance == nftEth);
            assert(address(reg).balance == regEth + price);
            assert(reg.proceedsOf(pay) == proceeds + price);
        } catch {}
    }

    // MP9 isAvailable and subpages DEAD holds

    /// @notice MP9s: with every top level record paid, as built state makes it,
    /// isAvailable(label, parent) for a subpage is exactly: the parent record exists, is top level,
    /// is not past its expiry and is not held by DEAD, and the subpage has no record, is stale, or is
    /// live and held by DEAD. So no label is free under a parent DEAD holds. TrialProofs T4 covers a
    /// parent with no deposit.
    /// @dev Technique: exact characterization over built state. Classification: DIRECT.
    function test_check_MP9s_isAvailableSubExact(
        uint256 pid, uint64 exp, uint64 epoch, uint64 ts, bool pExists, bool top, bool pDead,
        bool exists, uint8 hPick, uint64 se, uint64 pe
    ) public {
        vm.assume(pid != 0);
        uint256 sub = _sub(pid, FRESH);
        // Justification: distinct keccak preimages
        vm.assume(sub != pid);
        if (pExists) {
            nft.h_setRecord(pid, "club", top ? 0 : 1, exp, epoch, 0);
            nft.h_mint(pDead ? DEAD : OWNER, pid);
        }
        address holder = hPick % 3 == 0 ? TO : (hPick % 3 == 1 ? HOLDER : DEAD);
        if (exists) {
            nft.h_setRecord(sub, "fresh", pid, 0, se, pe);
            nft.h_mint(holder, sub);
        }
        vm.warp(ts);
        bool want = pExists && top && !pDead && ts <= exp && (!exists || pe != epoch || holder == DEAD);
        assert(nft.isAvailable("fresh", pid) == want);
    }

    /// @notice MP9t: isAvailable(label, 0) for a paid top level name is exactly: no record, or past
    /// expiry plus grace. The holder plays no part, so a name held by DEAD is never free early.
    /// TrialProofs T6 covers names with no deposit, which have no grace.
    /// @dev Technique: exact characterization over built state. Classification: DIRECT.
    function test_check_MP9t_isAvailableTopExact(uint64 exp, uint64 epoch, uint64 ts, bool exists, uint8 hPick)
        public
    {
        uint256 id = uint256(keccak256(abi.encodePacked(nft.ROOT(), keccak256(bytes("fresh")))));
        address holder = hPick % 3 == 0 ? OWNER : (hPick % 3 == 1 ? HOLDER : DEAD);
        if (exists) {
            nft.h_setRecord(id, "fresh", 0, exp, epoch, 0);
            nft.h_mint(holder, id);
        }
        vm.warp(ts);
        bool want = !exists || uint256(ts) > uint256(exp) + 90 days;
        assert(nft.isAvailable("fresh", 0) == want);
    }

    /// @notice MP10: for the counted minter of a top level parent, the mint succeeds if and only if
    /// isAvailable says the label is free. So the registrar, which asks isAvailable and then mints
    /// as the counted minter, never meets AlreadyRegistered, and a label it may sell is exactly a
    /// label its mint can take, including ones DEAD holds.
    /// @dev Technique: exact agreement of two functions over built state. Classification: DIRECT.
    function test_check_MP10_minterMintAgreesWithIsAvailable(
        uint256 pid, uint64 exp, uint64 epoch, uint64 ts, address m, bool exists, uint8 hPick, uint64 se, uint64 pe
    ) public {
        address owner = OWNER;
        _parent(pid, owner, exp, epoch);
        uint256 sub = _sub(pid, FRESH);
        vm.assume(sub != pid);
        // Justification: the counted minter is not the holder and not address(0), which no call can use
        vm.assume(m != owner && m != address(0));
        nft.h_setMinter(pid, m, epoch, owner);
        address holder = hPick % 3 == 0 ? TO : (hPick % 3 == 1 ? HOLDER : DEAD);
        if (exists) {
            // Justification: epochs grow by one per registration
            vm.assume(se < type(uint64).max);
            nft.h_setRecord(sub, "fresh", pid, 0, se, pe);
            nft.h_mint(holder, sub);
        }
        vm.warp(ts);
        bool avail = nft.isAvailable("fresh", pid);
        vm.prank(m);
        try nft.registerSubpageFor("fresh", pid, TO) {
            assert(avail);
            assert(nft.ownerOf(sub) == TO);
        } catch {
            assert(!avail);
            if (exists) assert(nft.ownerOf(sub) == holder);
        }
    }
}

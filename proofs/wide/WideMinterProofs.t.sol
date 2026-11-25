// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {PageCard} from "../../src/PageCard.sol";
import {PageNFT} from "../../src/PageNFT.sol";
import {PageNFTHarness} from "../MinterHarness.sol";

interface SVMM {
    function createBytes(uint256 length, string memory name) external pure returns (bytes memory value);
}

/// @notice Widened copies of the subpage mint proofs MP1, MP1d and MP2 (proofs/MinterProofs.t.sol).
/// The tier proofs build every parent with a deposit of 1 wei and use the fixed labels fresh and live.
/// Here the parent's deposit is any amount up to 2^96 wei including zero (a trial or released parent),
/// and WMP1L takes a label of 1, 2 or 3 symbolic bytes, any byte value, upper case included.
/// Halmos: FOUNDRY_PROFILE=proofs halmos --contract WideMinterProofsTest --forge-build-out out-proofs --loop 4 --storage-layout generic
/// (WMP1L with --loop 8)
contract WideMinterProofsTest is Test {
    SVMM constant svm = SVMM(0xF3993A62377BCd56AE39D773740A5390411E8BC9);

    PageNFTHarness nft;
    string constant FRESH = "fresh";
    string constant LIVE = "live";
    address constant TO = address(0xC0FFEE);
    address constant HOLDER = address(0xB0B);
    address constant OWNER = address(0xA11CE);
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    function setUp() public {
        nft = new PageNFTHarness(new PageCard());
    }

    function _sub(uint256 pid, string memory label) internal pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(bytes32(pid), keccak256(bytes(label)))));
    }

    function _parent(uint256 pid, address owner, uint64 exp, uint64 epoch, uint256 dep) internal {
        vm.assume(pid != 0);
        vm.assume(owner != address(0) && owner != address(nft));
        vm.assume(dep <= 2 ** 96);
        nft.h_setRecord(pid, "club", 0, exp, epoch, 0);
        nft.h_setDeposit(pid, dep);
        nft.h_mint(owner, pid);
    }

    /// @notice WMP1: MP1 with any parent deposit: a free label mints exactly when the parent is not past
    /// its expiry, has a deposit, and the caller is not address 0 and is the holder or the counted minter.
    function check_WMP1_freeLabelMintersExact(
        uint256 pid, address owner, uint64 exp, uint64 epoch, uint64 ts, address m, uint64 e, address s,
        address caller, bool toOwner, uint256 dep
    ) public {
        address to = toOwner ? owner : TO;
        if (toOwner) vm.assume(owner.code.length == 0);
        _parent(pid, owner, exp, epoch, dep);
        uint256 sub = _sub(pid, FRESH);
        vm.assume(sub != pid);
        nft.h_setMinter(pid, m, e, s);
        vm.warp(ts);
        address cm = (s == owner && e == epoch) ? m : address(0);
        bool allowed = ts <= exp && dep != 0 && caller != address(0) && (caller == owner || caller == cm);
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

    /// @notice WMP1d: MP1d with any parent deposit.
    function check_WMP1d_deadHeldMintersExact(
        uint256 pid, uint64 exp, uint64 epoch, uint64 ts, address m, uint64 e, address s, address caller,
        uint8 toPick, uint64 se, uint256 v0, bool primary, uint256 dep
    ) public {
        address owner = OWNER;
        address to = toPick % 3 == 0 ? TO : (toPick % 3 == 1 ? owner : HOLDER);
        _parent(pid, owner, exp, epoch, dep);
        uint256 sub = _sub(pid, FRESH);
        vm.assume(sub != pid);
        vm.assume(se < type(uint64).max && v0 < type(uint256).max);
        nft.h_setRecord(sub, "fresh", pid, 0, se, epoch);
        nft.h_mint(DEAD, sub);
        nft.h_setVersion(sub, v0);
        if (primary) nft.h_setPrimary(DEAD, sub);
        nft.h_setMinter(pid, m, e, s);
        vm.warp(ts);
        address cm = (s == owner && e == epoch) ? m : address(0);
        bool allowed = ts <= exp && dep != 0 && caller != address(0) && (caller == owner || caller == cm);
        assert(nft.isAvailable("fresh", pid) == (ts <= exp && dep != 0));
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

    /// @notice WMP2: MP2 with any parent deposit: an existing subpage is overwritten exactly when the
    /// parent is not past its expiry, has a deposit, and the caller is the holder, or the counted minter
    /// when the subpage is stale or held by DEAD, and never address 0.
    function check_WMP2_overwriteExact(
        uint256 pid, uint64 exp, uint64 epoch, uint64 ts, address m, uint64 e, address s, address caller,
        uint8 toPick, uint8 hPick, uint64 se, uint64 pe, uint256 v0, bool primary, uint256 dep
    ) public {
        address owner = OWNER;
        address holder = hPick % 3 == 0 ? TO : (hPick % 3 == 1 ? HOLDER : DEAD);
        address to = toPick == 0 ? TO : (toPick == 1 ? owner : holder);
        _parent(pid, owner, exp, epoch, dep);
        uint256 sub = _sub(pid, LIVE);
        vm.assume(sub != pid);
        vm.assume(se < type(uint64).max && v0 < type(uint256).max);
        nft.h_setRecord(sub, "live", pid, 0, se, pe);
        nft.h_mint(holder, sub);
        nft.h_setVersion(sub, v0);
        if (primary) nft.h_setPrimary(holder, sub);
        nft.h_setMinter(pid, m, e, s);
        vm.warp(ts);
        bool live = pe == epoch;
        address cm = (s == owner && e == epoch) ? m : address(0);
        bool allowed = ts <= exp && dep != 0 && caller != address(0)
            && (caller == owner || (caller == cm && (!live || holder == DEAD)));
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

    function _symLabel(uint8 lenPick) internal pure returns (bytes memory) {
        uint8 k = lenPick % 3;
        if (k == 0) return svm.createBytes(1, "sl1");
        if (k == 1) return svm.createBytes(2, "sl2");
        return svm.createBytes(3, "sl3");
    }

    /// @notice WMP1L: MP1 with a label of 1 to 3 symbolic bytes (any byte values) and any deposit: the mint
    /// succeeds exactly when the label is valid and the MP1 rule holds, the subpage minted is the one of the
    /// lowercase label, its stored label is that lowercase label, and isAvailable agrees beforehand.
    function check_WMP1L_symbolicLabel(
        uint8 lenPick, uint256 pid, address owner, uint64 exp, uint64 epoch, uint64 ts, address m, uint64 e,
        address s, address caller, uint256 dep
    ) public {
        string memory label = string(_symLabel(lenPick));
        _parent(pid, owner, exp, epoch, dep);
        nft.h_setMinter(pid, m, e, s);
        vm.warp(ts);
        (bool okN, bytes memory r) = address(nft).staticcall(abi.encodeCall(PageNFT.normalize, (label)));
        string memory norm = okN ? abi.decode(r, (string)) : "";
        uint256 sub = _sub(pid, norm);
        if (okN) vm.assume(sub != pid);
        address cm = (s == owner && e == epoch) ? m : address(0);
        bool allowed = okN && ts <= exp && dep != 0 && caller != address(0) && (caller == owner || caller == cm);
        assert(nft.isAvailable(label, pid) == (okN && ts <= exp && dep != 0 && owner != DEAD));
        vm.prank(caller);
        try nft.registerSubpageFor(label, pid, TO) returns (uint256 id) {
            assert(allowed);
            assert(id == sub);
            assert(nft.ownerOf(sub) == TO);
            (string memory stored,,, uint64 ne, uint64 npe) = nft.records(sub);
            assert(keccak256(bytes(stored)) == keccak256(bytes(norm)));
            assert(ne == 1 && npe == epoch);
        } catch {
            assert(!allowed);
            if (okN) assert(nft.h_ownerOf(sub) == address(0));
        }
    }
}

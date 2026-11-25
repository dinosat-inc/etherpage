// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {PageNFT} from "../../src/PageNFT.sol";
import {WideAnyStateProofsTest} from "./WideAnyStateProofs.t.sol";

/// @notice WAS2 (renew), WAS3 (reveal) and WAS4 (revealTrial) from any prior state, split into cases that
/// finish. WAS2 ran out of its 2 hour limit on 2026-11-06. Each case runs the same claim as its parent
/// (the touched ledgers change by exactly the balance change, no other credit, deposit or held money
/// moves, the caller gets the rest of its payment back, a refusal moves nothing) over one part of the
/// any-state input, picked by assumptions on the raw storage words of the id:
/// - the stored label: none (length 0), or a record of length class 1-2, 3-4, 5-31 bytes (short form) or
///   32-63 bytes (long form); a stored label is always empty or 1 to 63 bytes (as in WAS1-5);
/// - top level (parent 0) or a subpage; deposit zero or not; held trial money zero or not;
/// - WAS3 only, with a deposit: the time up to the grace end, four fixed seconds of the premium window
///   (the stored expiry then fixed at 1,800,000,000, as in WRVq tB1-tB4), or after the premium window.
/// WAS2 cases use the renew set of WAS2b (the trial payer and DEAD), whose claim implies WAS2's.
/// Halmos: FOUNDRY_PROFILE=proofs halmos --contract WideAnyStatePiecesTest --forge-build-out out-proofs --loop 4 --storage-layout generic
contract WideAnyStatePiecesTest is WideAnyStateProofsTest {
    function _base(uint256 id) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(id, uint256(0))));
    }

    // the stored label length, from its short or long form
    function _len(uint256 id) internal view returns (uint256) {
        uint256 lw = uint256(vm.load(address(n), bytes32(_base(id))));
        return lw & 1 == 0 ? (lw & 0xff) / 2 : (lw - 1) / 2;
    }

    function _parentOf(uint256 id) internal view returns (uint256) {
        return uint256(vm.load(address(n), bytes32(_base(id) + 1)));
    }

    function _expOf(uint256 id) internal view returns (uint64) {
        return uint64(uint256(vm.load(address(n), bytes32(_base(id) + 2))));
    }

    // c 0: no record; 1: 1-2 bytes; 2: 3-4; 3: 5-31 (short form); 4: 32-63 (long form)
    function _lenClass(uint256 id, uint8 c) internal view {
        uint256 len = _len(id);
        if (c == 0) vm.assume(len == 0);
        else if (c == 1) vm.assume(len >= 1 && len <= 2);
        else if (c == 2) vm.assume(len >= 3 && len <= 4);
        else if (c == 3) vm.assume(len >= 5 && len <= 31);
        else vm.assume(len >= 32);
    }

    function _renewCase(uint8 c, bool sub, bool depNZ, bool heldNZ, uint256 id, address z, uint256 w, uint256 t,
        uint256 value) internal {
        vm.assume(value <= CAP && t < 2 ** 40);
        L memory l = _beforeRenew(id, z, w);
        _lenClass(id, c);
        if (c != 0) vm.assume(sub ? _parentOf(id) != 0 : _parentOf(id) == 0);
        vm.assume(depNZ ? l.dep != 0 : l.dep == 0);
        vm.assume(heldNZ ? l.held != 0 : l.held == 0);
        vm.warp(t);
        vm.deal(CALLER, value);
        vm.prank(CALLER);
        (bool ok,) = address(n).call{value: value}(abi.encodeCall(PageNFT.renew, (id)));
        _after(l);
        assert(CALLER.balance + (address(n).balance - l.bal) == value);
        if (!ok) assert(address(n).balance == l.bal);
        if (c == 0 || sub) assert(!ok);
    }

    /// @notice WAS2p_none: renew of an id with no stored label (any other storage).
    function check_WAS2p_none(uint256 id, address z, uint256 w, uint256 t, uint256 value, bool depNZ, bool heldNZ)
        public
    {
        _renewCase(0, false, depNZ, heldNZ, id, z, w, t, value);
    }

    /// @notice WAS2p_sub: renew of a stored record whose parent is not 0 (any length 1-63).
    function check_WAS2p_sub(uint8 c, uint256 id, address z, uint256 w, uint256 t, uint256 value, bool depNZ,
        bool heldNZ) public {
        _renewCase(1 + c % 4, true, depNZ, heldNZ, id, z, w, t, value);
    }

    /// @notice WAS2p_L100: renew of a top level record, length class 1, deposit zero, held money zero.
    function check_WAS2p_L100(uint256 id, address z, uint256 w, uint256 t, uint256 value) public {
        _renewCase(1, false, false, false, id, z, w, t, value);
    }

    /// @notice WAS2p_L101: renew of a top level record, length class 1, deposit zero, held money nonzero.
    function check_WAS2p_L101(uint256 id, address z, uint256 w, uint256 t, uint256 value) public {
        _renewCase(1, false, false, true, id, z, w, t, value);
    }

    /// @notice WAS2p_L110: renew of a top level record, length class 1, deposit nonzero, held money zero.
    function check_WAS2p_L110(uint256 id, address z, uint256 w, uint256 t, uint256 value) public {
        _renewCase(1, false, true, false, id, z, w, t, value);
    }

    /// @notice WAS2p_L111: renew of a top level record, length class 1, deposit nonzero, held money nonzero.
    function check_WAS2p_L111(uint256 id, address z, uint256 w, uint256 t, uint256 value) public {
        _renewCase(1, false, true, true, id, z, w, t, value);
    }

    /// @notice WAS2p_L200: renew of a top level record, length class 2, deposit zero, held money zero.
    function check_WAS2p_L200(uint256 id, address z, uint256 w, uint256 t, uint256 value) public {
        _renewCase(2, false, false, false, id, z, w, t, value);
    }

    /// @notice WAS2p_L201: renew of a top level record, length class 2, deposit zero, held money nonzero.
    function check_WAS2p_L201(uint256 id, address z, uint256 w, uint256 t, uint256 value) public {
        _renewCase(2, false, false, true, id, z, w, t, value);
    }

    /// @notice WAS2p_L210: renew of a top level record, length class 2, deposit nonzero, held money zero.
    function check_WAS2p_L210(uint256 id, address z, uint256 w, uint256 t, uint256 value) public {
        _renewCase(2, false, true, false, id, z, w, t, value);
    }

    /// @notice WAS2p_L211: renew of a top level record, length class 2, deposit nonzero, held money nonzero.
    function check_WAS2p_L211(uint256 id, address z, uint256 w, uint256 t, uint256 value) public {
        _renewCase(2, false, true, true, id, z, w, t, value);
    }

    /// @notice WAS2p_L300: renew of a top level record, length class 3, deposit zero, held money zero.
    function check_WAS2p_L300(uint256 id, address z, uint256 w, uint256 t, uint256 value) public {
        _renewCase(3, false, false, false, id, z, w, t, value);
    }

    /// @notice WAS2p_L301: renew of a top level record, length class 3, deposit zero, held money nonzero.
    function check_WAS2p_L301(uint256 id, address z, uint256 w, uint256 t, uint256 value) public {
        _renewCase(3, false, false, true, id, z, w, t, value);
    }

    /// @notice WAS2p_L310: renew of a top level record, length class 3, deposit nonzero, held money zero.
    function check_WAS2p_L310(uint256 id, address z, uint256 w, uint256 t, uint256 value) public {
        _renewCase(3, false, true, false, id, z, w, t, value);
    }

    /// @notice WAS2p_L311: renew of a top level record, length class 3, deposit nonzero, held money nonzero.
    function check_WAS2p_L311(uint256 id, address z, uint256 w, uint256 t, uint256 value) public {
        _renewCase(3, false, true, true, id, z, w, t, value);
    }

    /// @notice WAS2p_L400: renew of a top level record, length class 4, deposit zero, held money zero.
    function check_WAS2p_L400(uint256 id, address z, uint256 w, uint256 t, uint256 value) public {
        _renewCase(4, false, false, false, id, z, w, t, value);
    }

    /// @notice WAS2p_L401: renew of a top level record, length class 4, deposit zero, held money nonzero.
    function check_WAS2p_L401(uint256 id, address z, uint256 w, uint256 t, uint256 value) public {
        _renewCase(4, false, false, true, id, z, w, t, value);
    }

    /// @notice WAS2p_L410: renew of a top level record, length class 4, deposit nonzero, held money zero.
    function check_WAS2p_L410(uint256 id, address z, uint256 w, uint256 t, uint256 value) public {
        _renewCase(4, false, true, false, id, z, w, t, value);
    }

    /// @notice WAS2p_L411: renew of a top level record, length class 4, deposit nonzero, held money nonzero.
    function check_WAS2p_L411(uint256 id, address z, uint256 w, uint256 t, uint256 value) public {
        _renewCase(4, false, true, true, id, z, w, t, value);
    }

    // reveal and revealTrial cases: the label of each fee class (the id fixed by it), the stored record
    // none or present, deposit zero or not, and for a paid reveal with a deposit the time window
    function _revealCase(bool trial, uint8 lPick, bool exists, uint8 depMode, uint8 phase, address z, uint256 w,
        uint256 t, uint256 value, uint256 ref) internal {
        vm.assume(value <= CAP && t < 2 ** 40);
        string memory label = _label(lPick);
        uint256 id = uint256(keccak256(abi.encodePacked(ROOT, keccak256(bytes(label)))));
        L memory l = _before(id, z, w);
        vm.assume(exists ? _len(id) != 0 : _len(id) == 0);
        if (depMode == 1) vm.assume(l.dep == 0);
        else if (depMode == 2) vm.assume(l.dep != 0);
        uint256 e = _expOf(id);
        if (phase == 1) {
            vm.assume(t <= e + 90 days);
        } else if (phase >= 2 && phase <= 5) {
            // a fixed second of the premium window, with the stored expiry fixed
            vm.assume(e == 1_800_000_000);
            t = e + (phase == 2 ? 90 days + 1 : phase == 3 ? 100 days : phase == 4 ? 111 days - 1 : 111 days);
        } else if (phase == 6) {
            vm.assume(t > e + 111 days);
        }
        vm.warp(t);
        vm.deal(CALLER, value);
        bytes memory d = trial
            ? abi.encodeCall(PageNFT.revealTrial, (label, TO, ref, bytes32("s")))
            : abi.encodeCall(PageNFT.reveal, (label, TO, ref, bytes32("s")));
        vm.prank(CALLER);
        (bool ok,) = address(n).call{value: value}(d);
        _after(l);
        assert(CALLER.balance + (address(n).balance - l.bal) == value);
        if (!ok) assert(address(n).balance == l.bal);
    }

    function check_WAS3p_0_n(address z, uint256 w, uint256 t, uint256 value, uint256 ref) public {
        _revealCase(false, 0, false, 0, 0, z, w, t, value, ref);
    }

    function check_WAS3p_0_d0(address z, uint256 w, uint256 t, uint256 value, uint256 ref) public {
        _revealCase(false, 0, true, 1, 0, z, w, t, value, ref);
    }

    function check_WAS3p_0_d1_tA(address z, uint256 w, uint256 t, uint256 value, uint256 ref) public {
        _revealCase(false, 0, true, 2, 1, z, w, t, value, ref);
    }

    function check_WAS3p_0_d1_tB1(address z, uint256 w, uint256 t, uint256 value, uint256 ref) public {
        _revealCase(false, 0, true, 2, 2, z, w, t, value, ref);
    }

    function check_WAS3p_0_d1_tB2(address z, uint256 w, uint256 t, uint256 value, uint256 ref) public {
        _revealCase(false, 0, true, 2, 3, z, w, t, value, ref);
    }

    function check_WAS3p_0_d1_tB3(address z, uint256 w, uint256 t, uint256 value, uint256 ref) public {
        _revealCase(false, 0, true, 2, 4, z, w, t, value, ref);
    }

    function check_WAS3p_0_d1_tB4(address z, uint256 w, uint256 t, uint256 value, uint256 ref) public {
        _revealCase(false, 0, true, 2, 5, z, w, t, value, ref);
    }

    function check_WAS3p_0_d1_tC(address z, uint256 w, uint256 t, uint256 value, uint256 ref) public {
        _revealCase(false, 0, true, 2, 6, z, w, t, value, ref);
    }

    function check_WAS3p_1_n(address z, uint256 w, uint256 t, uint256 value, uint256 ref) public {
        _revealCase(false, 1, false, 0, 0, z, w, t, value, ref);
    }

    function check_WAS3p_1_d0(address z, uint256 w, uint256 t, uint256 value, uint256 ref) public {
        _revealCase(false, 1, true, 1, 0, z, w, t, value, ref);
    }

    function check_WAS3p_1_d1_tA(address z, uint256 w, uint256 t, uint256 value, uint256 ref) public {
        _revealCase(false, 1, true, 2, 1, z, w, t, value, ref);
    }

    function check_WAS3p_1_d1_tB1(address z, uint256 w, uint256 t, uint256 value, uint256 ref) public {
        _revealCase(false, 1, true, 2, 2, z, w, t, value, ref);
    }

    function check_WAS3p_1_d1_tB2(address z, uint256 w, uint256 t, uint256 value, uint256 ref) public {
        _revealCase(false, 1, true, 2, 3, z, w, t, value, ref);
    }

    function check_WAS3p_1_d1_tB3(address z, uint256 w, uint256 t, uint256 value, uint256 ref) public {
        _revealCase(false, 1, true, 2, 4, z, w, t, value, ref);
    }

    function check_WAS3p_1_d1_tB4(address z, uint256 w, uint256 t, uint256 value, uint256 ref) public {
        _revealCase(false, 1, true, 2, 5, z, w, t, value, ref);
    }

    function check_WAS3p_1_d1_tC(address z, uint256 w, uint256 t, uint256 value, uint256 ref) public {
        _revealCase(false, 1, true, 2, 6, z, w, t, value, ref);
    }

    function check_WAS3p_2_n(address z, uint256 w, uint256 t, uint256 value, uint256 ref) public {
        _revealCase(false, 2, false, 0, 0, z, w, t, value, ref);
    }

    function check_WAS3p_2_d0(address z, uint256 w, uint256 t, uint256 value, uint256 ref) public {
        _revealCase(false, 2, true, 1, 0, z, w, t, value, ref);
    }

    function check_WAS3p_2_d1_tA(address z, uint256 w, uint256 t, uint256 value, uint256 ref) public {
        _revealCase(false, 2, true, 2, 1, z, w, t, value, ref);
    }

    function check_WAS3p_2_d1_tB1(address z, uint256 w, uint256 t, uint256 value, uint256 ref) public {
        _revealCase(false, 2, true, 2, 2, z, w, t, value, ref);
    }

    function check_WAS3p_2_d1_tB2(address z, uint256 w, uint256 t, uint256 value, uint256 ref) public {
        _revealCase(false, 2, true, 2, 3, z, w, t, value, ref);
    }

    function check_WAS3p_2_d1_tB3(address z, uint256 w, uint256 t, uint256 value, uint256 ref) public {
        _revealCase(false, 2, true, 2, 4, z, w, t, value, ref);
    }

    function check_WAS3p_2_d1_tB4(address z, uint256 w, uint256 t, uint256 value, uint256 ref) public {
        _revealCase(false, 2, true, 2, 5, z, w, t, value, ref);
    }

    function check_WAS3p_2_d1_tC(address z, uint256 w, uint256 t, uint256 value, uint256 ref) public {
        _revealCase(false, 2, true, 2, 6, z, w, t, value, ref);
    }

    function check_WAS4p_0_n(address z, uint256 w, uint256 t, uint256 value, uint256 ref) public {
        _revealCase(true, 0, false, 0, 0, z, w, t, value, ref);
    }

    function check_WAS4p_0_d0(address z, uint256 w, uint256 t, uint256 value, uint256 ref) public {
        _revealCase(true, 0, true, 1, 0, z, w, t, value, ref);
    }

    function check_WAS4p_0_d1(address z, uint256 w, uint256 t, uint256 value, uint256 ref) public {
        _revealCase(true, 0, true, 2, 0, z, w, t, value, ref);
    }

    function check_WAS4p_1_n(address z, uint256 w, uint256 t, uint256 value, uint256 ref) public {
        _revealCase(true, 1, false, 0, 0, z, w, t, value, ref);
    }

    function check_WAS4p_1_d0(address z, uint256 w, uint256 t, uint256 value, uint256 ref) public {
        _revealCase(true, 1, true, 1, 0, z, w, t, value, ref);
    }

    function check_WAS4p_1_d1(address z, uint256 w, uint256 t, uint256 value, uint256 ref) public {
        _revealCase(true, 1, true, 2, 0, z, w, t, value, ref);
    }

    function check_WAS4p_2_n(address z, uint256 w, uint256 t, uint256 value, uint256 ref) public {
        _revealCase(true, 2, false, 0, 0, z, w, t, value, ref);
    }

    function check_WAS4p_2_d0(address z, uint256 w, uint256 t, uint256 value, uint256 ref) public {
        _revealCase(true, 2, true, 1, 0, z, w, t, value, ref);
    }

    function check_WAS4p_2_d1(address z, uint256 w, uint256 t, uint256 value, uint256 ref) public {
        _revealCase(true, 2, true, 2, 0, z, w, t, value, ref);
    }
}

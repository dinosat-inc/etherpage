// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {PageCard} from "../../src/PageCard.sol";
import {PageNFT} from "../../src/PageNFT.sol";

interface SVMA {
    function enableSymbolicStorage(address) external;
    function createUint(uint256 bitSize, string memory name) external pure returns (uint256 value);
}

/// @notice PageNFT plus one view of the internal referrer payee. Test harness only.
contract AnyStateHarness is PageNFT {
    constructor(PageCard c) PageNFT(c) {}

    function h_refPayee(uint256 id) external view returns (address) {
        return _referrerPayee(referrerOf[id]);
    }
}

/// @notice Money proofs from ANY prior state. The tier money proofs (FM1, FM1rR, DP, T) start from a
/// family of built states (alpha with a deposit or held money, refer, a few accounts). Here every
/// storage slot of PageNFT is symbolic, so the start state is any state at all, reachable or not, with
/// only these facts assumed: a stored label is empty or 1 to 63 bytes in Solidity's short or long form,
/// and every ledger entry read is at most 2^128 wei.
/// For one call of release, renew, reveal or revealTrial, whether it succeeds or not:
/// the sum of the ledger entries the call may touch (the deposit and held trial money of the id, and
/// the credits of the old payee, the old referrer's payee, the burn address and the old trial payer)
/// changes by exactly what the contract's ETH balance changes by, and no other credit, deposit or
/// held trial money changes (a symbolic account z and id w). By induction over any sequence of calls
/// (the other entry points never write a ledger: FM2, MP5b, code reading), the contract always holds at
/// least the sum of all ledgers, so every credit and deposit can be paid out.
/// Halmos: FOUNDRY_PROFILE=proofs halmos --contract WideAnyStateProofsTest --forge-build-out out-proofs --loop 4 --storage-layout generic
contract WideAnyStateProofsTest is Test {
    SVMA constant svm = SVMA(0xF3993A62377BCd56AE39D773740A5390411E8BC9);
    AnyStateHarness n;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address constant CALLER = address(0xCA11E2);
    address constant TO = address(0xC0FFEE);
    bytes32 constant ROOT = 0x62460c06d95b73747abf6ea4f28aefd78b4ad2abee112e7cf15fe6a924cca3c6;
    uint256 constant CAP = 2 ** 128;

    function setUp() public {
        n = new AnyStateHarness(new PageCard());
    }

    // a stored label is empty or 1 to 63 bytes: short form (even word, length byte <= 62) or long form
    // (odd word 2 * length + 1 with length 32 to 63); records is slot 0 and label its first member
    function _assumeLabelWord(uint256 id) internal view {
        uint256 w = uint256(vm.load(address(n), keccak256(abi.encode(id, uint256(0)))));
        if (w & 1 == 0) vm.assume(w & 0xff <= 62);
        else vm.assume(w >= 65 && w <= 127);
    }

    function _o(address a) internal view returns (uint256 v) {
        v = n.owed(a);
        vm.assume(v <= CAP);
    }

    // the sum of the credits of four accounts, each counted once; before the call each is assumed at most
    // 2^128 wei (cap), after it nothing is assumed
    function _sum(address[4] memory a, bool cap) internal view returns (uint256 s) {
        s = cap ? _o(a[0]) : n.owed(a[0]);
        if (a[1] != a[0]) s += cap ? _o(a[1]) : n.owed(a[1]);
        if (a[2] != a[0] && a[2] != a[1]) s += cap ? _o(a[2]) : n.owed(a[2]);
        if (a[3] != a[0] && a[3] != a[1] && a[3] != a[2]) s += cap ? _o(a[3]) : n.owed(a[3]);
    }

    struct L {
        uint256 id;
        address[4] a;
        uint256 dep;
        uint96 held;
        uint256 total;
        uint256 bal;
        address z;
        uint256 w;
        uint256 oz;
        uint256 dw;
        uint96 hw;
    }

    // the ledger entries of id and the credits the call may touch, read before the call
    function _before(uint256 id, address z, uint256 w) internal returns (L memory l) {
        svm.enableSymbolicStorage(address(n));
        _assumeLabelWord(id);
        l.id = id;
        l.bal = svm.createUint(128, "balance");
        vm.deal(address(n), l.bal);
        (address payer, uint96 held) = n.trialPaymentOf(id);
        address payerEff = payer == address(0) || payer == address(n) ? DEAD : payer;
        l.a = [n.payee(id), n.h_refPayee(id), DEAD, payerEff];
        l.dep = n.depositOf(id);
        vm.assume(l.dep <= CAP);
        l.held = held;
        l.total = l.dep + l.held + _sum(l.a, true);
        vm.assume(z != l.a[0] && z != l.a[1] && z != l.a[2] && z != l.a[3] && w != id);
        l.z = z;
        l.w = w;
        l.oz = n.owed(z);
        l.dw = n.depositOf(w);
        (, l.hw) = n.trialPaymentOf(w);
    }

    // as _before, with only the accounts renew may credit (the trial payer, or DEAD for it): renew never
    // credits a payee or a referrer, so leaving them out of the set makes the frame stronger, not weaker
    function _beforeRenew(uint256 id, address z, uint256 w) internal returns (L memory l) {
        svm.enableSymbolicStorage(address(n));
        _assumeLabelWord(id);
        l.id = id;
        l.bal = svm.createUint(128, "balance");
        vm.deal(address(n), l.bal);
        (address payer, uint96 held) = n.trialPaymentOf(id);
        address payerEff = payer == address(0) || payer == address(n) ? DEAD : payer;
        l.a = [payerEff, DEAD, DEAD, DEAD];
        l.dep = n.depositOf(id);
        vm.assume(l.dep <= CAP);
        l.held = held;
        l.total = l.dep + l.held + _sum(l.a, true);
        vm.assume(z != payerEff && z != DEAD && w != id);
        l.z = z;
        l.w = w;
        l.oz = n.owed(z);
        l.dw = n.depositOf(w);
        (, l.hw) = n.trialPaymentOf(w);
    }

    /// @notice WAS2b: WAS2 (renew from any state) with the frame over every account but the trial payer and
    /// DEAD, which is all renew may credit; WAS2 also kept the old payee and the referrer's payee in the set.
    function check_WAS2b_renew(uint256 id, address z, uint256 w, uint256 t, uint256 value) public {
        vm.assume(value <= CAP && t < 2 ** 40);
        L memory l = _beforeRenew(id, z, w);
        vm.warp(t);
        vm.deal(CALLER, value);
        vm.prank(CALLER);
        (bool ok,) = address(n).call{value: value}(abi.encodeCall(PageNFT.renew, (id)));
        _after(l);
        assert(CALLER.balance + (address(n).balance - l.bal) == value);
        if (!ok) assert(address(n).balance == l.bal);
    }

    function _after(L memory l) internal view {
        (, uint96 held2) = n.trialPaymentOf(l.id);
        uint256 total2 = n.depositOf(l.id) + held2 + _sum(l.a, false);
        // the touched ledgers change by exactly what the balance changes by
        assert(address(n).balance >= l.bal);
        assert(total2 >= l.total);
        assert(total2 - l.total == address(n).balance - l.bal);
        // nothing else moves
        assert(n.owed(l.z) == l.oz);
        assert(n.depositOf(l.w) == l.dw);
        (, uint96 hw2) = n.trialPaymentOf(l.w);
        assert(hw2 == l.hw);
    }

    /// @notice WAS1: release from any state moves money only between the touched ledgers.
    function check_WAS1_release(uint256 id, address caller, address z, uint256 w, uint256 t) public {
        L memory l = _before(id, z, w);
        vm.warp(t);
        vm.prank(caller);
        (bool ok,) = address(n).call(abi.encodeCall(PageNFT.release, (id)));
        ok;
        _after(l);
        assert(address(n).balance == l.bal);
    }

    /// @notice WAS2: renew from any state: the ledgers rise by exactly the ETH the contract keeps, and the
    /// caller gets the rest of its payment back.
    function check_WAS2_renew(uint256 id, address z, uint256 w, uint256 t, uint256 value) public {
        vm.assume(value <= CAP && t < 2 ** 40);
        L memory l = _before(id, z, w);
        vm.warp(t);
        vm.deal(CALLER, value);
        vm.prank(CALLER);
        (bool ok,) = address(n).call{value: value}(abi.encodeCall(PageNFT.renew, (id)));
        _after(l);
        assert(CALLER.balance + (address(n).balance - l.bal) == value);
        if (!ok) assert(address(n).balance == l.bal);
    }

    function _label(uint8 k) internal pure returns (string memory) {
        uint8 m = k % 3;
        if (m == 0) return "q";
        if (m == 1) return "abc";
        return "alpha";
    }

    function _reveal(bool trial, uint8 lPick, address z, uint256 w, uint256 t, uint256 value, uint256 ref) internal {
        vm.assume(value <= CAP && t < 2 ** 40);
        string memory label = _label(lPick);
        uint256 id = uint256(keccak256(abi.encodePacked(ROOT, keccak256(bytes(label)))));
        L memory l = _before(id, z, w);
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

    /// @notice WAS3: reveal from any state, for a label of each fee class (the commitment, the old record,
    /// its deposit, held money, referrer, payees and credits are all whatever storage holds).
    function check_WAS3_reveal(uint8 lPick, address z, uint256 w, uint256 t, uint256 value, uint256 ref) public {
        _reveal(false, lPick, z, w, t, value, ref);
    }

    /// @notice WAS4: revealTrial from any state, as WAS3.
    function check_WAS4_revealTrial(uint8 lPick, address z, uint256 w, uint256 t, uint256 value, uint256 ref) public {
        _reveal(true, lPick, z, w, t, value, ref);
    }

    /// @notice WAS5: withdraw from any state pays the account exactly its credit and changes no other
    /// credit, deposit or held money; the account has no code (precompiles left out).
    function check_WAS5_withdraw(address a, address caller, address z, uint256 w) public {
        svm.enableSymbolicStorage(address(n));
        vm.assume(a != address(n) && a.code.length == 0 && (uint160(a) == 0 || uint160(a) > 0x1ff) && z != a);
        uint256 amt = n.owed(a);
        uint256 bal = svm.createUint(128, "balance");
        vm.assume(amt <= bal);
        vm.deal(address(n), bal);
        uint256 ba = a.balance;
        uint256 oz = n.owed(z);
        uint256 dw = n.depositOf(w);
        (, uint96 hw) = n.trialPaymentOf(w);
        vm.prank(caller);
        (bool ok,) = address(n).call(abi.encodeCall(PageNFT.withdraw, (a)));
        assert(ok == (amt != 0));
        if (ok) {
            assert(n.owed(a) == 0 && a.balance == ba + amt && address(n).balance == bal - amt);
        } else {
            assert(n.owed(a) == amt && address(n).balance == bal);
        }
        assert(n.owed(z) == oz && n.depositOf(w) == dw);
        (, uint96 hw2) = n.trialPaymentOf(w);
        assert(hw2 == hw);
    }
}

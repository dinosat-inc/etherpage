// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {PageCard} from "../../src/PageCard.sol";
import {PageNFT} from "../../src/PageNFT.sol";
import {DepositHarness} from "../DepositProofs.t.sol";

/// @notice Symbolic proofs of the money rules with held trial money, one call per proof. Each FM1
/// and FM3 proof calls one entry point, and FM2 picks one of seventeen other calls.
/// The start state is alpha (a deposit, held trial money or neither, never both, and a live name
/// always has exactly one of them), a live paid name refer, and symbolic credits for six accounts.
/// After one call from that state:
/// M1 the balance equals both deposits plus the held money plus the six credits, and no other
/// account's credit and no other name's deposit or held money changes;
/// M2 held money and a deposit never exist together, and a live top level name has exactly one;
/// M3 when alpha had no deposit, the only credit that rises is the trial payer's, by exactly the
/// held amount, so the trial's referrer and everyone else get nothing;
/// M4 alpha gets a deposit from no deposit only through a paid registration or a renew during the trial;
/// M5 a registration records exactly its own referrer.
/// picks chooses the payer (one of five accounts, one of them a contract), the holder of refer and
/// the recorded referrer (none, refer or any other id). The caller is a plain account.
/// WIDENED COPY of MoneyProofsTest (proofs/MoneyProofs.t.sol), helpers unchanged except the bounds:
/// deposit and credits up to 2^96 wei (tier: 1000 ether), held money any uint96 (tier: 1 ether), value up
/// to 2^96 wei (tier: 200 ether), and in the trial states all three recorded referrers (none, refer, any
/// other id) where the tier trial states fix refer.
/// Halmos: FOUNDRY_PROFILE=proofs halmos --contract WideMoneyProofsTest --forge-build-out out-proofs --loop 4 --storage-layout generic
contract WideMoneyProofsTest is Test {
    DepositHarness n;
    address cardAddr;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address constant HOLDER = address(0xB0B);
    address constant OTHER = address(0xC0FFEE);
    address constant CALLER = address(0xCA11E2);
    address constant P4 = address(0x4EF);
    bytes32 constant ROOT = 0x62460c06d95b73747abf6ea4f28aefd78b4ad2abee112e7cf15fe6a924cca3c6;
    uint256 constant FEE = 0.0001 ether;
    uint256 constant PRICE = 0.00001 ether;
    uint256 id;
    uint256 refId;

    struct Pre {
        uint256 dep;
        uint96 held;
        address payer;
        uint256 t;
        uint256 exp;
        uint256[6] owed;
        uint256 bal;
        uint256 zOwed;
        uint256 wDep;
        uint256 wHeld;
    }

    function setUp() public {
        PageCard card = new PageCard();
        cardAddr = address(card);
        n = new DepositHarness(card);
        vm.deal(address(this), 2 ** 128);
        id = uint256(keccak256(abi.encodePacked(ROOT, keccak256(bytes("alpha")))));
        refId = uint256(keccak256(abi.encodePacked(ROOT, keccak256(bytes("refer")))));
    }

    function _acct(uint256 i) internal view returns (address) {
        if (i == 0) return HOLDER;
        if (i == 1) return OTHER;
        if (i == 2) return CALLER;
        if (i == 3) return P4;
        if (i == 4) return DEAD;
        return cardAddr;
    }

    function _pick5(uint8 k) internal view returns (address) {
        uint8 m = k % 5;
        if (m == 0) return HOLDER;
        if (m == 1) return OTHER;
        if (m == 2) return CALLER;
        if (m == 3) return P4;
        return cardAddr;
    }

    function _sumOwed() internal view returns (uint256) {
        return n.owed(HOLDER) + n.owed(OTHER) + n.owed(CALLER) + n.owed(P4) + n.owed(DEAD) + n.owed(cardAddr);
    }

    function _held() internal view returns (address p, uint96 a) {
        (p, a) = n.trialPaymentOf(id);
    }

    function _notInSet(address z) internal view {
        vm.assume(z != HOLDER && z != OTHER && z != CALLER && z != P4 && z != DEAD && z != cardAddr);
    }

    // alpha held by HOLDER, refer held by refHolder, the credits funded so the balance matches the ledgers
    function _state(
        uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint8 picks, uint256 r, uint256 t, uint256[6] memory o, address z, uint256 w
    ) internal returns (Pre memory p) {
        vm.assume(t < 2 ** 40 && t > 1000);
        // widened: any deposit up to 2^96 wei and any uint96 of held money (tier: 1000 ether and 1 ether)
        vm.assume(dep <= 2 ** 96);
        vm.assume(dep == 0 || held == 0);
        // a live top level name has a deposit or held money, never neither
        if (t <= exp) vm.assume(dep != 0 || held != 0);
        vm.assume(epoch > 0 && epoch < type(uint64).max);
        for (uint256 i; i < 6; ++i) vm.assume(o[i] <= 2 ** 96);
        _notInSet(z);
        vm.assume(w != id && w != refId);
        p.payer = _pick5(picks % 5);
        n.h_setRecord(id, "alpha", 0, exp, epoch, 0);
        n.h_mint(HOLDER, id);
        n.h_setDeposit{value: dep}(id, dep);
        n.h_setHeld{value: held}(id, p.payer, held);
        uint8 rh = (picks / 5) % 4;
        address refHolder = rh == 0 ? HOLDER : rh == 1 ? OTHER : rh == 2 ? DEAD : P4;
        n.h_setRecord(refId, "refer", 0, uint64(t + 365 days), 1, 0);
        n.h_mint(refHolder, refId);
        n.h_setDeposit{value: FEE}(refId, FEE);
        uint8 k = (picks / 20) % 3;
        vm.assume(r != id);
        n.h_setReferrer(id, k == 0 ? 0 : k == 1 ? refId : r);
        for (uint256 i; i < 6; ++i) n.h_setOwed{value: o[i]}(_acct(i), o[i]);
        vm.warp(t);
        p.dep = dep;
        p.held = held;
        p.t = t;
        p.exp = exp;
        for (uint256 i; i < 6; ++i) p.owed[i] = o[i];
        p.bal = address(n).balance;
        assert(p.bal == dep + FEE + held + _sumOwed());
        p.zOwed = n.owed(z);
        p.wDep = n.depositOf(w);
        (, p.wHeld) = n.trialPaymentOf(w);
    }

    function _m1m2(Pre memory p, address z, uint256 w) internal view {
        (, uint96 hAfter) = _held();
        uint256 dAfter = n.depositOf(id);
        // M1
        assert(address(n).balance == dAfter + n.depositOf(refId) + hAfter + _sumOwed());
        assert(n.owed(z) == p.zOwed);
        assert(n.depositOf(w) == p.wDep);
        (, uint96 wh) = n.trialPaymentOf(w);
        assert(wh == p.wHeld);
        // M2
        assert(hAfter == 0 || dAfter == 0);
        if (block.timestamp <= n.expiresAt(id)) assert((dAfter == 0) == (hAfter != 0));
        // the other name holds no trial money after any call on alpha
        (, uint96 rh) = n.trialPaymentOf(refId);
        assert(rh == 0);
    }

    // M3 for any call but withdraw, which pays a credit out; refunded says whether the held money went back
    function _m3(Pre memory p, bool refunded) internal view {
        if (p.dep != 0) return;
        for (uint256 i; i < 6; ++i) {
            address a = _acct(i);
            if (a == p.payer) assert(n.owed(a) == p.owed[i] + (refunded ? p.held : 0));
            else assert(n.owed(a) == p.owed[i]);
        }
    }

    function _m4(Pre memory p, bool allowed) internal view {
        if (p.dep == 0 && n.depositOf(id) != 0) assert(allowed);
    }

    address constant ZZ = address(0x2222);
    uint256 constant WW = 0x3333;
    uint64 constant EXPC = 1_800_000_000;

    // trial states: no deposit, held money or none, the recorded referrer is refer, any payer and any
    // holder of refer; the frame account and id are fixed
    function _stateT(uint64 exp, uint64 epoch, uint96 held, uint8 picks, uint256 t, uint256[6] memory o)
        internal returns (Pre memory)
    {
        return _state(exp, epoch, 0, held, uint8(uint256(picks % 20) + 20), 0, t, o, ZZ, WW);
    }

    // paid states: a deposit, a fixed expiry, no held money, any holder of refer and any recorded
    // referrer (none, refer or another id); the frame account and id are fixed
    function _stateP(uint64 epoch, uint256 dep, uint8 picks, uint256 r, uint256 t, uint256[6] memory o)
        internal returns (Pre memory)
    {
        vm.assume(dep != 0);
        return _state(EXPC, epoch, dep, 0, uint8(uint256(picks % 12) * 5), r, t, o, ZZ, WW);
    }

    function _fm1r(Pre memory p, uint256 t, uint256 value, uint256 ref2, bool toOther) internal {
        vm.assume(value <= 2 ** 96 && ref2 != id);
        address to = toOther ? OTHER : HOLDER;
        n.h_setCommitment(n.makeCommitment("alpha", to, ref2, bytes32("s")), t - 61);
        vm.deal(CALLER, value);
        vm.prank(CALLER);
        (bool ok,) = address(n).call{value: value}(abi.encodeCall(PageNFT.reveal, ("alpha", to, ref2, bytes32("s"))));
        _m1m2(p, ZZ, WW);
        _m3(p, ok && p.held != 0);
        _m4(p, ok);
        if (ok) {
            assert(n.referrerOf(id) == ref2);
            // in the auction the buyer pays the old deposit out to the old holder and takes it over with the new
            // fee, and after the auction the old deposit goes back to the old holder first and the new fee stays
            bool released = p.dep != 0 && t > p.exp + 111 days;
            assert(n.depositOf(id) == (released ? 0 : p.dep) + FEE);
            if (released) assert(n.owed(HOLDER) == p.owed[0] + p.dep);
        }
        // a paid registration is never refused over a record with no deposit once the name has ended, nor over a
        // record with one once its auction has ended
        if (p.dep == 0 && t > p.exp && value >= FEE) assert(ok);
        if (p.dep != 0 && t > p.exp + 111 days && value >= FEE) assert(ok);
    }

    function _fm1t(Pre memory p, uint256 t, uint256 value, uint256 ref2, bool toOther) internal {
        vm.assume(value <= 2 ** 96 && ref2 != id);
        address to = toOther ? OTHER : HOLDER;
        n.makeCommitment("alpha", to, ref2, bytes32("s"));
        n.h_setCommitment(keccak256(abi.encode(bytes("alpha"), to, ref2, bytes32("s"), true)), t - 61);
        vm.deal(CALLER, value);
        vm.prank(CALLER);
        (bool ok,) =
            address(n).call{value: value}(abi.encodeCall(PageNFT.revealTrial, ("alpha", to, ref2, bytes32("s"))));
        _m1m2(p, ZZ, WW);
        _m3(p, ok && p.held != 0);
        _m4(p, false);
        // a name with a deposit takes a trial only after its auction, which first releases the deposit to the holder
        assert(ok == ((p.dep == 0 ? t > p.exp + 14 days : t > p.exp + 111 days) && value >= PRICE));
        if (ok) {
            assert(n.referrerOf(id) == ref2);
            (address hp, uint96 ha) = _held();
            assert(hp == CALLER && ha == PRICE);
            assert(n.depositOf(id) == 0);
            if (p.dep != 0) assert(n.owed(HOLDER) == p.owed[0] + p.dep);
        }
    }

    function _fm1n(Pre memory p, uint256 t, uint256 value) internal {
        vm.assume(value <= 2 ** 96);
        uint256 refBefore = n.referrerOf(id);
        vm.deal(CALLER, value);
        vm.prank(CALLER);
        (bool ok,) = address(n).call{value: value}(abi.encodeCall(PageNFT.renew, (id)));
        _m1m2(p, ZZ, WW);
        _m3(p, ok && p.held != 0);
        _m4(p, ok && t <= p.exp);
        assert(n.referrerOf(id) == refBefore);
        if (ok) assert(n.depositOf(id) == p.dep + FEE);
    }















    function _fm1w(Pre memory p, uint8 aPick) internal {
        address a = _acct(aPick % 6);
        vm.prank(CALLER);
        (bool ok,) = address(n).call(abi.encodeCall(PageNFT.withdraw, (a)));
        _m1m2(p, ZZ, WW);
        (, uint96 hAfter) = _held();
        assert(hAfter == p.held);
        assert(n.depositOf(id) == p.dep);
        // a is a fixed address on each path, so this branch never counts toward the loop bound
        for (uint256 i; i < 6; ++i) {
            if (_acct(i) == a && ok) assert(n.owed(_acct(i)) == 0);
            else assert(n.owed(_acct(i)) == p.owed[i]);
        }
    }









    function _fm1m(uint64 exp, uint64 epoch, uint96 held, uint8 picks, uint256 t, uint256[6] memory o) internal {
        Pre memory p = _stateT(exp, epoch, held, picks, t, o);
        address z = ZZ;
        uint256 w = WW;
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(PageNFT.release, (id));
        calls[1] = abi.encodeCall(PageNFT.withdraw, (p.payer));
        vm.prank(CALLER);
        (bool ok,) = address(n).call(abi.encodeCall(PageNFT.multicall, (calls)));
        _m1m2(p, z, w);
        if (p.dep == 0) {
            for (uint256 i; i < 6; ++i) {
                address a = _acct(i);
                if (a == p.payer && ok) assert(n.owed(a) == 0);
                else assert(n.owed(a) == p.owed[i]);
            }
        }
        // a trial payer with no code gets the held money and its old credit in one bundle once the trial ends
        if (p.held != 0 && t > p.exp && p.payer != cardAddr) assert(ok);
    }








    function _fm2(
        uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint8 picks, uint256 t, uint256[6] memory o, uint8 sel,
        address y, uint256 x
    ) internal {
        Pre memory p = _state(exp, epoch, dep, held, picks, 0, t, o, ZZ, WW);
        address z = ZZ;
        uint256 w = WW;
        uint8 c3 = sel % 3;
        address caller = c3 == 0 ? HOLDER : c3 == 1 ? OTHER : CALLER;
        uint8 k = (sel / 3) % 18;
        bytes memory d;
        if (k == 0) d = abi.encodeWithSignature("transferFrom(address,address,uint256)", HOLDER, OTHER, id);
        else if (k == 1) d = abi.encodeWithSignature("transferFrom(address,address,uint256)", HOLDER, DEAD, id);
        else if (k == 2) d = abi.encodeWithSignature("safeTransferFrom(address,address,uint256)", HOLDER, OTHER, id);
        else if (k == 3) d = abi.encodeCall(PageNFT.approve, (y, id));
        else if (k == 4) d = abi.encodeWithSignature("setApprovalForAll(address,bool)", y, true);
        else if (k == 5) d = abi.encodeCall(PageNFT.setSubpageMinter, (id, y));
        else if (k == 6) d = abi.encodeCall(PageNFT.registerSubpage, ("x", id));
        else if (k == 7) d = abi.encodeCall(PageNFT.registerSubpageFor, ("x", id, OTHER));
        else if (k == 8) d = abi.encodeWithSignature("setAddr(uint256,address)", id, y);
        else if (k == 9) d = abi.encodeCall(PageNFT.setAddrForCoin, (id, x, abi.encodePacked(y)));
        else if (k == 10) d = abi.encodeWithSignature("setText(uint256,string,string)", id, "k", "v");
        else if (k == 11) d = abi.encodeWithSignature("setContenthash(uint256,bytes)", id, hex"01");
        else if (k == 12) d = abi.encodeCall(PageNFT.clearRecords, (id));
        else if (k == 13) d = abi.encodeCall(PageNFT.setPrimaryPage, (id));
        else if (k == 14) d = abi.encodeCall(PageNFT.commit, (bytes32(x)));
        else if (k == 15) d = abi.encodeCall(PageNFT.setPrimaryPage, (0));
        else if (k == 16) d = abi.encodeCall(PageNFT.keepProfile, (id));
        else d = abi.encodeCall(PageNFT.setData, (id, "k", hex"01"));
        vm.prank(caller);
        (bool ok,) = address(n).call(d);
        ok;
        _m1m2(p, z, w);
        (, uint96 hAfter) = _held();
        assert(hAfter == p.held);
        assert(n.depositOf(id) == p.dep);
        assert(address(n).balance == p.bal);
        for (uint256 i; i < 6; ++i) assert(n.owed(_acct(i)) == p.owed[i]);
    }

    // trial states with every recorded referrer: none, refer, or any other id r
    function _stateTW(
        uint64 exp, uint64 epoch, uint96 held, uint8 payerPick, uint8 rh, uint8 kPick, uint256 r, uint256 t,
        uint256[6] memory o
    ) internal returns (Pre memory) {
        uint8 picks = uint8(uint256(payerPick % 5) + 5 * uint256(rh % 4) + 20 * uint256(kPick % 3));
        return _state(exp, epoch, 0, held, picks, r, t, o, ZZ, WW);
    }

    /// @notice WFM1rT1: FM1rT1 (refer held by OTHER) widened: any recorded referrer, wide amounts.
    function check_WFM1rT1(uint64 exp, uint64 epoch, uint96 held, uint8 payerPick, uint8 kPick, uint256 r, uint256 t,
        uint256[6] memory o, uint256 value, uint256 ref2, bool toOther) public {
        _fm1r(_stateTW(exp, epoch, held, payerPick, 1, kPick, r, t, o), t, value, ref2, toOther);
    }

    /// @notice WFM1rP1: FM1rP1 (recorded referrer refer, any holder of refer) with wide amounts.
    function check_WFM1rP1(uint64 epoch, uint256 dep, uint8 rhPick, uint256 r, uint256 t, uint256[6] memory o,
        uint256 value, uint256 ref2, bool toOther) public {
        _fm1r(_stateP(epoch, dep, uint8(4 + rhPick % 4), r, t, o), t, value, ref2, toOther);
    }

    /// @notice WFM1tT: FM1tT widened: any payer, any holder of refer, any recorded referrer, wide amounts.
    function check_WFM1tT(uint64 exp, uint64 epoch, uint96 held, uint8 payerPick, uint8 rhPick, uint8 kPick,
        uint256 r, uint256 t, uint256[6] memory o, uint256 value, uint256 ref2, bool toOther) public {
        _fm1t(_stateTW(exp, epoch, held, payerPick, rhPick, kPick, r, t, o), t, value, ref2, toOther);
    }

    /// @notice WFM1tP: FM1tP with wide amounts.
    function check_WFM1tP(uint64 epoch, uint256 dep, uint8 picks, uint256 r, uint256 t, uint256[6] memory o,
        uint256 value, uint256 ref2, bool toOther) public {
        _fm1t(_stateP(epoch, dep, picks, r, t, o), t, value, ref2, toOther);
    }

    /// @notice WFM1nT: FM1nT widened: any recorded referrer, wide amounts.
    function check_WFM1nT(uint64 exp, uint64 epoch, uint96 held, uint8 payerPick, uint8 rhPick, uint8 kPick,
        uint256 r, uint256 t, uint256[6] memory o, uint256 value) public {
        _fm1n(_stateTW(exp, epoch, held, payerPick, rhPick, kPick, r, t, o), t, value);
    }

    /// @notice WFM1nP: FM1nP with wide amounts.
    function check_WFM1nP(uint64 epoch, uint256 dep, uint8 picks, uint256 r, uint256 t, uint256[6] memory o,
        uint256 value) public {
        _fm1n(_stateP(epoch, dep, picks, r, t, o), t, value);
    }

    /// @notice WFM1l: FM1l (release in any state, symbolic frame account and id) with wide amounts.
    function check_WFM1l(
        uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint8 picks, uint256 r, uint256 t, uint256[6] memory o,
        address z, uint256 w
    ) public {
        Pre memory p = _state(exp, epoch, dep, held, picks, r, t, o, z, w);
        vm.prank(CALLER);
        (bool ok,) = address(n).call(abi.encodeCall(PageNFT.release, (id)));
        _m1m2(p, z, w);
        _m3(p, ok && p.held != 0);
        _m4(p, false);
        if (p.held != 0) assert(ok == (t > p.exp));
    }

    /// @notice WFM1wT: FM1wT widened: any recorded referrer, wide amounts.
    function check_WFM1wT(uint64 exp, uint64 epoch, uint96 held, uint8 payerPick, uint8 rhPick, uint8 kPick,
        uint256 r, uint256 t, uint256[6] memory o, uint8 aPick) public {
        _fm1w(_stateTW(exp, epoch, held, payerPick, rhPick, kPick, r, t, o), aPick);
    }

    /// @notice WFM1wP: FM1wP with wide amounts.
    function check_WFM1wP(uint64 epoch, uint256 dep, uint8 picks, uint256 r, uint256 t, uint256[6] memory o,
        uint8 aPick) public {
        _fm1w(_stateP(epoch, dep, picks, r, t, o), aPick);
    }

    /// @notice WFM3: FM3 widened: any payer, any holder of refer, any recorded referrer, wide amounts.
    function check_WFM3(uint64 exp, uint64 epoch, uint96 held, uint8 payerPick, uint8 rhPick, uint8 kPick,
        uint256 r, uint256 t, uint256[6] memory o, uint256 ref2) public {
        vm.assume(t > uint256(exp) + 14 days && held != 0 && ref2 != id);
        Pre memory p = _stateTW(exp, epoch, held, payerPick, rhPick, kPick, r, t, o);
        n.makeCommitment("alpha", OTHER, ref2, bytes32("s"));
        n.h_setCommitment(keccak256(abi.encode(bytes("alpha"), OTHER, ref2, bytes32("s"), true)), t - 61);
        vm.deal(CALLER, PRICE);
        vm.prank(CALLER);
        (bool ok,) =
            address(n).call{value: PRICE}(abi.encodeCall(PageNFT.revealTrial, ("alpha", OTHER, ref2, bytes32("s"))));
        assert(ok);
        _m1m2(p, ZZ, WW);
        _m3(p, true);
        assert(n.referrerOf(id) == ref2);
        assert(n.getPremium(id) == 0);
    }
}

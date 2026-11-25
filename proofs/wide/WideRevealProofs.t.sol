// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {PageCard} from "../../src/PageCard.sol";
import {PageNFT} from "../../src/PageNFT.sol";
import {WideHarness, ReentrantPayee} from "./WideHarness.sol";

interface SVMR {
    function createUint(uint256 bitSize, string memory name) external pure returns (uint256 value);
    function createAddress(string memory name) external pure returns (address value);
    function createBytes32(string memory name) external pure returns (bytes32 value);
    function createBool(string memory name) external pure returns (bool value);
}

/// @notice Widened proofs of the registration, renewal, commitment and withdrawal rules.
/// Compared with the tier proofs (T1_T5, T7, T8, DP2 to DP4, FM1, HM1, MT2), these take:
/// - a label of each fee class (1, 3 or 5 bytes; the tier proofs use alpha only), called in lower or
///   upper case;
/// - a caller that is a fresh plain account, the trial payer or the old holder, and an owner that is a fresh
///   account, the caller, the old holder, DEAD or the old main address (the tier proofs fix one of each);
///   these cover every equality the registration code can see between caller, owner and the old state. A
///   symbolic owner was tried first: Solady's mint then builds a revert offset from iszero(to) whenever the
///   1 ms branch check times out, and Halmos stops those paths (NotConcreteError), so picks are used;
/// - a stored commitment for a symbolic owner, referrer, secret and form, so a reveal whose arguments
///   differ in any way from the commitment is covered (front running), and a symbolic commitment time;
/// - amounts up to 2^96 wei, above all ETH that exists (about 2^87 wei), where the tier proofs stop
///   at 10 or 1000 ether; held trial money of any uint96 amount;
/// - an exact rule both ways (succeeds exactly when ...), the exact refund to the caller, the exact
///   credits, the epoch, record version, minter switch-off, display page and main address effects.
/// Halmos: FOUNDRY_PROFILE=proofs halmos --contract WideRevealProofsTest --forge-build-out out-proofs --loop 4 --storage-layout generic
contract WideRevealProofsTest is Test {
    SVMR constant svm = SVMR(0xF3993A62377BCd56AE39D773740A5390411E8BC9);
    WideHarness n;
    address cardAddr;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address constant HOLDER = address(0xB0B);
    address constant PAYER = address(0xFA7E5);
    address constant PTE = address(0x407);
    bytes32 constant ROOT = 0x62460c06d95b73747abf6ea4f28aefd78b4ad2abee112e7cf15fe6a924cca3c6;
    uint256 constant CAP = 2 ** 96;

    function setUp() public {
        PageCard card = new PageCard();
        cardAddr = address(card);
        n = new WideHarness(card);
        vm.deal(address(this), 2 ** 128);
    }

    // a label of each fee class: 0.01, 0.001 and 0.0001 ether a year
    function _label(uint8 k) internal pure returns (string memory l, string memory upper) {
        uint8 m = k % 3;
        if (m == 0) return ("q", "Q");
        if (m == 1) return ("abc", "aBC");
        return ("alpha", "ALPHA");
    }

    // a caller that pays: a plain account, so the change sent back to it can arrive
    // Justification: no deployed contract and no precompile, which have no or special receive code
    function _plainCaller(address a) internal view {
        vm.assume(a != address(0) && a != address(n) && a != cardAddr && a != address(this));
        vm.assume(uint160(a) > 0xffff && a.code.length == 0);
    }

    struct In {
        bool trial;
        uint8 lPick;
        bool upper;
        bool exists;
        uint64 exp;
        uint64 epoch;
        uint256 dep;
        uint96 held;
        bool deadHolder;
        bool primary;
        uint256 v0;
        uint256 oldRef;
        address m;
        uint256 t;
        uint256 value;
        address caller;
        address owner;
        uint256 ref;
        bytes32 secret;
        address o0;
        uint256 r0;
        bytes32 s0;
        bool form0;
        uint256 committedAt;
        address z;
        uint256 w;
        uint256[3] o;
        // used by the split pieces (WideRevealPieces.t.sol); all zero keeps the original behaviour:
        // savedMode 0 symbolic, 1 no saved main address, 2 saved; useKey: the stored commitment is any
        // key other than the call's own; phase 0 any time, 1 to 5 one time window (see _phase)
        uint8 savedMode;
        bool useKey;
        bytes32 key0;
        uint8 phase;
    }

    struct Pre {
        uint256 id;
        string label;
        string callLabel;
        uint256 fee;
        bool released;
        uint256 carried;
        uint256 premium;
        uint256 price;
        bool expected;
        bytes32 c0;
        address holder;
        uint256 bal;
        uint256 oH;
        uint256 oP;
        uint256 oD;
        uint256 oZ;
        uint256 dW;
        bool saved;
        address payee;
        uint256 oT;
    }

    function _setup(In memory a, Pre memory p) internal {
        string memory up;
        (p.label, up) = _label(a.lPick);
        p.callLabel = a.upper ? up : p.label;
        p.id = uint256(keccak256(abi.encodePacked(ROOT, keccak256(bytes(p.label)))));
        vm.assume(a.t > 1000 && a.t < 2 ** 40 && a.committedAt < 2 ** 40);
        vm.assume(a.value <= CAP && a.dep <= CAP);
        vm.assume(a.o[0] <= CAP && a.o[1] <= CAP && a.o[2] <= CAP);
        vm.assume(a.dep == 0 || a.held == 0);
        vm.assume(a.z != HOLDER && a.z != PAYER && a.z != DEAD && a.z != PTE);
        vm.assume(a.w != p.id);
        p.holder = a.deadHolder ? DEAD : HOLDER;
        // the old holder may have saved the main address PTE, which is then the payee
        p.saved = a.savedMode == 0 ? svm.createBool("saved") : a.savedMode == 2;
        p.payee = p.saved ? PTE : p.holder;
        if (a.exists) {
            // Justification: epochs and versions grow by one per registration
            vm.assume(a.epoch > 0 && a.epoch < type(uint64).max && a.v0 < type(uint256).max);
            vm.assume(a.oldRef != p.id);
            n.h_setRecord(p.id, p.label, 0, a.exp, a.epoch, 0);
            n.h_mint(p.holder, p.id);
            n.h_setVersion(p.id, a.v0);
            n.h_setDeposit{value: a.dep}(p.id, a.dep);
            n.h_setHeld{value: a.held}(p.id, PAYER, a.held);
            n.h_setReferrer(p.id, a.oldRef);
            if (p.saved) n.h_setResolved(p.id, PTE, p.holder);
            if (a.primary) n.h_setPrimary(p.holder, p.id, p.holder);
            n.h_setMinter(p.id, a.m, a.epoch, p.holder);
        } else {
            vm.assume(a.dep == 0 && a.held == 0);
        }
        n.h_setOwed{value: a.o[0]}(HOLDER, a.o[0]);
        n.h_setOwed{value: a.o[1]}(PAYER, a.o[1]);
        n.h_setOwed{value: a.o[2]}(DEAD, a.o[2]);
        if (a.useKey) {
            bytes32 own = a.trial
                ? keccak256(abi.encode(bytes(p.label), a.owner, a.ref, a.secret, true))
                : keccak256(abi.encode(bytes(p.label), a.owner, a.ref, a.secret));
            vm.assume(a.key0 != own);
            p.c0 = a.key0;
        } else {
            p.c0 = a.form0
                ? keccak256(abi.encode(bytes(p.label), a.o0, a.r0, a.s0, true))
                : keccak256(abi.encode(bytes(p.label), a.o0, a.r0, a.s0));
        }
        n.h_setCommitment(p.c0, a.committedAt);
        _phase(a);
        vm.warp(a.t);

        p.fee = n.getFee(bytes(p.label).length);
        if (a.trial) p.fee /= 10;
        p.released = a.exists && a.dep != 0 && a.t > uint256(a.exp) + 111 days;
        p.carried = p.released ? 0 : a.dep;
        p.premium = n.getPremium(p.id);
        p.price = p.fee + p.carried + p.premium;
        bool matches = !a.useKey && a.o0 == a.owner && a.r0 == a.ref && a.s0 == a.secret && a.form0 == a.trial;
        bool ripe = matches && a.committedAt != 0 && a.t >= a.committedAt + 20 && a.t <= a.committedAt + 86400;
        bool free = !a.exists || a.t > (a.dep != 0 ? uint256(a.exp) + 90 days : uint256(a.exp));
        bool trialOk = !a.trial || (p.carried == 0 && !(a.exists && a.t <= uint256(a.exp) + 14 days));
        p.expected = a.ref != p.id && ripe && free && trialOk && a.value >= p.price;

        p.bal = address(n).balance;
        p.oH = n.owed(HOLDER);
        p.oP = n.owed(PAYER);
        p.oD = n.owed(DEAD);
        p.oT = n.owed(PTE);
        p.oZ = n.owed(a.z);
        p.dW = n.depositOf(a.w);
    }

    // the time windows of a record: 1 live, 2 up to 14 days after the expiry (the trial pause), 3 up to the
    // grace end at 90 days, 4 the premium window up to 111 days, 5 after it, 6 windows 1 to 3 together
    function _phase(In memory a) internal pure {
        uint256 e = a.exp;
        if (a.phase == 1) vm.assume(a.t <= e);
        else if (a.phase == 2) vm.assume(a.t > e && a.t <= e + 14 days);
        else if (a.phase == 3) vm.assume(a.t > e + 14 days && a.t <= e + 90 days);
        else if (a.phase == 4) vm.assume(a.t > e + 90 days && a.t <= e + 111 days);
        else if (a.phase == 5) vm.assume(a.t > e + 111 days);
        else if (a.phase == 6) vm.assume(a.t <= e + 90 days);
    }

    function _rv(In memory a) internal {
        Pre memory p;
        _setup(a, p);
        vm.deal(a.caller, a.value);
        bytes memory d = a.trial
            ? abi.encodeCall(PageNFT.revealTrial, (p.callLabel, a.owner, a.ref, a.secret))
            : abi.encodeCall(PageNFT.reveal, (p.callLabel, a.owner, a.ref, a.secret));
        vm.prank(a.caller);
        (bool ok,) = address(n).call{value: a.value}(d);
        assert(ok == p.expected);
        if (ok) _success(a, p);
        else _failure(a, p);
    }

    function _success(In memory a, Pre memory p) internal view {
        // exactly the price stays, the rest goes back to the caller
        assert(a.caller.balance == a.value - p.price);
        assert(address(n).balance == p.bal + p.price);
        assert(n.ownerOf(p.id) == a.owner);
        assert(n.holderSince(p.id) == a.t);
        (string memory lbl, uint256 parent, uint64 e2, uint64 ep2, uint64 pe2) = n.records(p.id);
        assert(keccak256(bytes(lbl)) == keccak256(bytes(p.label)));
        assert(parent == 0 && pe2 == 0);
        assert(e2 == a.t + (a.trial ? 14 days : 365 days));
        assert(ep2 == (a.exists ? a.epoch + 1 : 1));
        assert(n.recordVersion(p.id) == (a.exists ? a.v0 + 1 : 0));
        assert(n.referrerOf(p.id) == a.ref);
        assert(n.commitments(p.c0) == 0);
        (address hp, uint96 ha) = n.trialPaymentOf(p.id);
        if (a.trial) {
            assert(hp == a.caller && ha == p.fee);
            assert(n.depositOf(p.id) == 0);
        } else {
            assert(ha == 0);
            assert(n.depositOf(p.id) == p.carried + p.fee);
        }
        // the last payee (PTE when the old holder saved it, else the old holder) gets the old deposit and 75
        // percent of the premium, the burn address the other 25 percent (the recorded referrer has no
        // record), and the trial payer its held money
        uint256 refShare = p.premium * 2500 / 10_000;
        uint256 toPayee = a.dep + (p.premium - refShare);
        uint256 wantH = p.oH + (p.payee == HOLDER ? toPayee : 0);
        uint256 wantD = p.oD + refShare + (p.payee == DEAD ? toPayee : 0);
        uint256 wantT = p.oT + (p.payee == PTE ? toPayee : 0);
        assert(n.owed(HOLDER) == wantH);
        assert(n.owed(DEAD) == wantD);
        assert(n.owed(PTE) == wantT);
        assert(n.owed(PAYER) == p.oP + a.held);
        assert(n.owed(a.z) == p.oZ);
        assert(n.depositOf(a.w) == p.dW);
        assert(n.getPremium(p.id) == 0);
        // the old main address and the old minter stop counting, the old holder drops the display page
        assert(n.resolve(p.id) == (a.owner == DEAD ? address(0) : a.owner));
        assert(n.subpageMinterOf(p.id) == address(0));
        if (a.exists && a.primary) assert(n.primaryPage(p.holder) == 0);
    }

    function _failure(In memory a, Pre memory p) internal view {
        assert(a.caller.balance == a.value);
        assert(address(n).balance == p.bal);
        assert(n.h_ownerOf(p.id) == (a.exists ? p.holder : address(0)));
        assert(n.commitments(p.c0) == a.committedAt);
        assert(n.depositOf(p.id) == a.dep);
        (, uint96 ha) = n.trialPaymentOf(p.id);
        assert(ha == a.held);
        assert(n.owed(HOLDER) == p.oH && n.owed(PAYER) == p.oP && n.owed(DEAD) == p.oD && n.owed(PTE) == p.oT);
        assert(n.recordVersion(p.id) == (a.exists ? a.v0 : 0));
        if (a.exists) {
            (,,, uint64 ep2,) = n.records(p.id);
            assert(ep2 == a.epoch);
        }
    }

    // the owner: a fresh codeless account, the caller, the old holder, DEAD or the old main address. A
    // symbolic owner makes Solady's mint build a revert offset from iszero(to) whenever the 1 ms branch
    // check times out (NotConcreteError); the registration compares the owner only with the caller (and
    // through the commitment), so these cover every case it can tell apart
    // the caller: a fresh plain account, the trial payer or the old holder (fixed for the same reason:
    // the owner may be the caller)
    function _caller(uint8 k) internal pure returns (address) {
        uint8 m = k % 3;
        if (m == 0) return address(0xCA11E2);
        if (m == 1) return PAYER;
        return HOLDER;
    }

    function _owner(uint8 k, address caller) internal pure returns (address) {
        uint8 m = k % 5;
        if (m == 0) return address(0xA11CE);
        if (m == 1) return caller;
        if (m == 2) return HOLDER;
        if (m == 3) return DEAD;
        return PTE;
    }

    function _in(
        bool trial, uint8 lPick, bool upper, bool exists, uint64 exp, uint64 epoch, uint256 dep, uint96 held,
        bool deadHolder, bool primary
    ) internal pure returns (In memory a) {
        a.trial = trial;
        a.lPick = lPick;
        a.upper = upper;
        a.exists = exists;
        a.exp = exp;
        a.epoch = epoch;
        a.dep = dep;
        a.held = held;
        a.deadHolder = deadHolder;
        a.primary = primary;
    }

    // the call's referrer and secret and the stored commitment's owner, referrer, secret, form and time
    function _symCommit(In memory a) internal pure {
        a.ref = svm.createUint(256, "ref");
        a.secret = svm.createBytes32("secret");
        a.o0 = svm.createAddress("o0");
        a.r0 = svm.createUint(256, "r0");
        a.s0 = svm.createBytes32("s0");
        a.form0 = svm.createBool("form0");
        a.committedAt = svm.createUint(256, "committedAt");
    }

    // the commitment matches the call except perhaps its form; the rest of the state is symbolic
    function _symState(In memory a) internal pure {
        a.ref = svm.createUint(256, "ref");
        a.secret = bytes32("s");
        a.o0 = a.owner;
        a.r0 = a.ref;
        a.s0 = a.secret;
        a.form0 = svm.createBool("form0");
        a.committedAt = svm.createUint(256, "committedAt");
        a.v0 = svm.createUint(256, "v0");
        a.oldRef = svm.createUint(256, "oldRef");
        a.m = svm.createAddress("m");
        a.z = svm.createAddress("z");
        a.w = svm.createUint(256, "w");
        a.o[0] = svm.createUint(256, "o0");
        a.o[1] = svm.createUint(256, "o1");
        a.o[2] = svm.createUint(256, "o2");
    }

    function _fixedRest(In memory a) internal pure {
        a.v0 = 7;
        a.oldRef = 0;
        a.m = address(0x3117);
        a.z = address(0x2222);
        a.w = 0x3333;
    }

    /// @notice WRV1: reveal succeeds exactly when the label is free (no record, past its grace, or a
    /// record with no deposit past its end), the commitment for exactly these owner, referrer, secret
    /// and form is 20 seconds to one day old, the name is not its own referrer and the value covers the
    /// price, for any caller, owner, state, time and value. Then the effects are exact.
    function check_WRV1_reveal(
        uint8 lPick, bool upper, bool exists, uint64 exp, uint64 epoch, uint256 dep, uint96 held, bool deadHolder,
        bool primary, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick
    ) public {
        In memory a = _in(false, lPick, upper, exists, exp, epoch, dep, held, deadHolder, primary);
        a.t = t;
        a.value = value;
        a.caller = _caller(callerPick);
        a.owner = _owner(ownerPick, a.caller);
        _symCommit(a);
        _fixedRest(a);
        _rv(a);
    }

    /// @notice WRV2: as WRV1, for revealTrial: also refused while a deposit is still carried and until
    /// 14 days after the last registration ended; the price is a tenth of the fee and is held for the
    /// caller, never added to the deposit.
    function check_WRV2_revealTrial(
        uint8 lPick, bool upper, bool exists, uint64 exp, uint64 epoch, uint256 dep, uint96 held, bool deadHolder,
        bool primary, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick
    ) public {
        In memory a = _in(true, lPick, upper, exists, exp, epoch, dep, held, deadHolder, primary);
        a.t = t;
        a.value = value;
        a.caller = _caller(callerPick);
        a.owner = _owner(ownerPick, a.caller);
        _symCommit(a);
        _fixedRest(a);
        _rv(a);
    }

    /// @notice WRV3: WRV1 with the remaining state symbolic too: the record version, the recorded
    /// referrer of the last registration (none or any id with no record), the minter, three credits,
    /// and a symbolic frame account and id; the commitment matches the call, so only its time and form
    /// are symbolic.
    function check_WRV3_revealState(
        uint8 lPick, bool exists, uint64 exp, uint64 epoch, uint256 dep, uint96 held, bool deadHolder, bool primary,
        uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick
    ) public {
        In memory a = _in(false, lPick, false, exists, exp, epoch, dep, held, deadHolder, primary);
        a.t = t;
        a.value = value;
        a.caller = _caller(callerPick);
        a.owner = _owner(ownerPick, a.caller);
        _symState(a);
        _rv(a);
    }

    /// @notice WRV4: WRV3 for revealTrial.
    function check_WRV4_revealTrialState(
        uint8 lPick, bool exists, uint64 exp, uint64 epoch, uint256 dep, uint96 held, bool deadHolder, bool primary,
        uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick
    ) public {
        In memory a = _in(true, lPick, false, exists, exp, epoch, dep, held, deadHolder, primary);
        a.t = t;
        a.value = value;
        a.caller = _caller(callerPick);
        a.owner = _owner(ownerPick, a.caller);
        _symState(a);
        _rv(a);
    }

    /// @notice WRN: renew succeeds exactly when the id has a top level record, its grace has not ended
    /// (a record with no deposit has none), the value covers the fee of its length and the new expiry
    /// is at most 3650 days ahead, for any caller, value, state and time. It then adds a year and the fee
    /// to the deposit, credits held trial money to its payer, sends the rest back to the caller and
    /// changes nothing else; a refusal changes nothing.
    function check_WRN_renew(
        uint8 lPick, bool exists, bool isSub, uint64 exp, uint64 epoch, uint256 dep, uint96 held, bool deadHolder,
        uint256 t, uint256 value, address caller
    ) public {
        uint256 oldRef = svm.createUint(256, "oldRef");
        address z = svm.createAddress("z");
        uint256 w = svm.createUint(256, "w");
        uint256[3] memory o = [svm.createUint(256, "o0"), svm.createUint(256, "o1"), svm.createUint(256, "o2")];
        (string memory label,) = _label(lPick);
        uint256 id = uint256(keccak256(abi.encodePacked(ROOT, keccak256(bytes(label)))));
        vm.assume(t > 1000 && t < 2 ** 40 && value <= CAP && dep <= CAP);
        vm.assume(o[0] <= CAP && o[1] <= CAP && o[2] <= CAP);
        vm.assume(dep == 0 || held == 0);
        _plainCaller(caller);
        vm.assume(z != HOLDER && z != PAYER && z != DEAD && w != id);
        address holder = deadHolder ? DEAD : HOLDER;
        if (exists) {
            vm.assume(epoch > 0);
            n.h_setRecord(id, label, isSub ? 1 : 0, exp, epoch, isSub ? 1 : 0);
            n.h_mint(holder, id);
            n.h_setDeposit{value: dep}(id, dep);
            n.h_setHeld{value: held}(id, PAYER, held);
            n.h_setReferrer(id, oldRef);
        } else {
            vm.assume(dep == 0 && held == 0);
        }
        n.h_setOwed{value: o[0]}(HOLDER, o[0]);
        n.h_setOwed{value: o[1]}(PAYER, o[1]);
        n.h_setOwed{value: o[2]}(DEAD, o[2]);
        vm.warp(t);
        uint256 fee = n.getFee(bytes(label).length);
        uint256 graceEnd = dep == 0 ? uint256(exp) : uint256(exp) + 90 days;
        bool expected = exists && !isSub && t <= graceEnd && value >= fee && uint256(exp) + 365 days <= t + 3650 days;
        uint256 bal = address(n).balance;
        uint256[5] memory b = [n.owed(HOLDER), n.owed(PAYER), n.owed(DEAD), n.owed(z), n.depositOf(w)];
        vm.deal(caller, value);
        vm.prank(caller);
        (bool ok,) = address(n).call{value: value}(abi.encodeCall(PageNFT.renew, (id)));
        assert(ok == expected);
        assert(n.owed(HOLDER) == b[0] && n.owed(DEAD) == b[2] && n.owed(z) == b[3] && n.depositOf(w) == b[4]);
        assert(n.h_ownerOf(id) == (exists ? holder : address(0)));
        if (exists) assert(n.referrerOf(id) == oldRef);
        (,, uint64 e2, uint64 ep2,) = n.records(id);
        (, uint96 ha) = n.trialPaymentOf(id);
        if (ok) {
            assert(e2 == uint256(exp) + 365 days);
            assert(ep2 == epoch);
            assert(n.depositOf(id) == dep + fee);
            assert(ha == 0);
            assert(n.owed(PAYER) == b[1] + held);
            assert(caller.balance == value - fee);
            assert(address(n).balance == bal + fee);
        } else {
            assert(e2 == (exists ? exp : 0));
            assert(n.depositOf(id) == dep);
            assert(ha == held);
            assert(n.owed(PAYER) == b[1]);
            assert(caller.balance == value);
            assert(address(n).balance == bal);
        }
    }

    /// @notice WCM: commit by any caller at any time succeeds exactly when the commitment was never made,
    /// was used, or is more than a day old; it then records the time and changes no other commitment.
    function check_WCM_commit(bytes32 c, bytes32 c2, uint256 p, uint256 p2, uint256 t, address caller) public {
        vm.assume(c != c2 && p < 2 ** 64 && t < 2 ** 64);
        n.h_setCommitment(c, p);
        n.h_setCommitment(c2, p2);
        vm.warp(t);
        vm.prank(caller);
        (bool ok,) = address(n).call(abi.encodeCall(PageNFT.commit, (c)));
        assert(ok == (p == 0 || t > p + 86400));
        assert(n.commitments(c) == (ok ? t : p));
        assert(n.commitments(c2) == p2);
    }

    /// @notice WWD: withdraw for any account with no code, by any caller, pays that account exactly its
    /// credit and nothing to anyone else, and zeroes only that credit; it fails exactly when the credit
    /// is zero. Every other credit and deposit stays.
    function check_WWD_withdraw(address a, address z, uint256 oa, uint256 oz, uint256 w, uint256 extra, address caller)
        public
    {
        // Justification: precompiles (1 to 0x1ff) have their own code paths; address 0 and DEAD are kept
        vm.assume(a != address(n) && a.code.length == 0 && (uint160(a) == 0 || uint160(a) > 0x1ff));
        vm.assume(z != a && oa <= CAP && oz <= CAP && extra <= CAP);
        n.h_setOwed{value: oa}(a, oa);
        n.h_setOwed{value: oz}(z, oz);
        n.h_setDeposit{value: extra}(w, extra);
        uint256 balA = a.balance;
        uint256 balN = address(n).balance;
        vm.prank(caller);
        (bool ok,) = address(n).call(abi.encodeCall(PageNFT.withdraw, (a)));
        assert(ok == (oa != 0));
        assert(n.owed(z) == oz && n.depositOf(w) == extra);
        if (ok) {
            assert(n.owed(a) == 0);
            assert(a.balance == balA + oa);
            assert(address(n).balance == balN - oa);
        } else {
            assert(n.owed(a) == oa);
            assert(a.balance == balA && address(n).balance == balN);
        }
    }

    /// @notice WWDr: withdraw to an account whose receive code calls withdraw again, for itself and for a
    /// victim with a credit: it is paid its credit exactly once, both inner calls fail, the victim's
    /// credit and balance stay. When it refuses the payment, the withdraw fails and its credit stays.
    function check_WWDr_reentrantPayee(uint256 oa, uint256 ov, address caller, bool refuse, address victim) public {
        ReentrantPayee pay = new ReentrantPayee(address(n));
        vm.assume(victim != address(pay) && victim != address(n) && victim.code.length == 0 && uint160(victim) > 0x1ff);
        vm.assume(oa <= CAP && ov <= CAP);
        n.h_setOwed{value: oa}(address(pay), oa);
        n.h_setOwed{value: ov}(victim, ov);
        pay.set(victim, refuse);
        uint256 bal = address(n).balance;
        uint256 vb = victim.balance;
        vm.prank(caller);
        (bool ok,) = address(n).call(abi.encodeCall(PageNFT.withdraw, (address(pay))));
        assert(ok == (oa != 0 && !refuse));
        if (ok) {
            assert(pay.received() == oa);
            assert(!pay.innerSelfOk() && !pay.innerVictimOk());
            assert(n.owed(address(pay)) == 0);
            assert(address(n).balance == bal - oa);
        } else {
            assert(n.owed(address(pay)) == oa);
            assert(address(n).balance == bal);
        }
        assert(n.owed(victim) == ov);
        assert(victim.balance == vb);
    }
}

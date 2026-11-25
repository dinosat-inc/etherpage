// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {PageCard} from "../src/PageCard.sol";
import {PageNFT} from "../src/PageNFT.sol";

/// @notice State writers for the deposit proofs. They exist only in this test harness.
contract DepositHarness is PageNFT {
    constructor(PageCard c) PageNFT(c) {}

    function h_setRecord(uint256 id, string calldata label, uint256 parent, uint64 exp, uint64 epoch, uint64 pe)
        external
    {
        records[id] = PageRecord({label: label, parent: parent, expiresAt: exp, epoch: epoch, parentEpoch: pe});
    }

    function h_mint(address to, uint256 id) external {
        _mint(to, id);
    }

    function h_setDeposit(uint256 id, uint256 amount) external payable {
        depositOf[id] = amount;
    }

    function h_setHeld(uint256 id, address payer, uint96 amount) external payable {
        trialPaymentOf[id] = TrialPayment(payer, amount);
    }

    function h_setOwed(address a, uint256 amount) external payable {
        owed[a] = amount;
    }

    function h_setReferrer(uint256 id, uint256 ref) external {
        referrerOf[id] = ref;
    }

    function h_setCommitment(bytes32 c, uint256 t) external {
        commitments[c] = t;
    }
}

/// @notice Symbolic proofs of the trial rules: release, the pause, the refund at a new
/// registration or trial, conversion, the referrer of an unpaid trial, self referral and status.
/// The trial payer is a symbolic account, the caller is a symbolic plain account that pays in DP2
/// and DP4, any account in DP1 and HOLDER in DP3, and the holder of the trial's referrer is one of
/// four accounts, so every credit is checked as a difference over all the accounts involved,
/// whichever of them coincide.
/// Halmos: FOUNDRY_PROFILE=proofs halmos --contract DepositProofsTest --function check_ --forge-build-out out-proofs --loop 4 --storage-layout generic
contract DepositProofsTest is Test {
    DepositHarness n;
    address cardAddr;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address constant HOLDER = address(0xB0B);
    address constant OTHER = address(0xC0FFEE);
    bytes32 constant ROOT = 0x62460c06d95b73747abf6ea4f28aefd78b4ad2abee112e7cf15fe6a924cca3c6;
    uint256 constant FEE = 0.0001 ether;
    uint256 constant PRICE = 0.00001 ether;
    uint256 id;
    uint256 refId;
    uint256 sub;

    function setUp() public {
        PageCard card = new PageCard();
        cardAddr = address(card);
        n = new DepositHarness(card);
        id = uint256(keccak256(abi.encodePacked(ROOT, keccak256(bytes("alpha")))));
        refId = uint256(keccak256(abi.encodePacked(ROOT, keccak256(bytes("refer")))));
        sub = uint256(keccak256(abi.encodePacked(bytes32(id), keccak256(bytes("x")))));
    }

    function _okAccount(address a) internal view {
        vm.assume(a != address(0) && a != address(n));
    }

    // a caller that pays: a plain account, so the change sent back to it can arrive
    // Justification: no deployed contract and no precompile, which have no or special receive code
    function _plainCaller(address a) internal view {
        _okAccount(a);
        vm.assume(a != cardAddr && a != address(this) && uint160(a) > 0xffff);
    }

    function _pickRefHolder(uint8 k) internal pure returns (address) {
        uint8 m = k % 4;
        if (m == 0) return HOLDER;
        if (m == 1) return OTHER;
        if (m == 2) return DEAD;
        return address(0x4EF);
    }

    // alpha held by HOLDER with a deposit or held trial money or neither, never both; the held money
    // belongs to a symbolic payer
    function _state(uint64 exp, uint64 epoch, uint256 dep, uint96 held, address payer) internal {
        _stateOf(HOLDER, exp, epoch, dep, held, payer);
    }

    function _stateOf(address holder, uint64 exp, uint64 epoch, uint256 dep, uint96 held, address payer) internal {
        _okAccount(payer);
        vm.assume(dep <= 1000 ether && held <= 1 ether);
        vm.assume(dep == 0 || held == 0);
        vm.assume(epoch > 0 && epoch < type(uint64).max);
        n.h_setRecord(id, "alpha", 0, exp, epoch, 0);
        n.h_mint(holder, id);
        n.h_setDeposit{value: dep}(id, dep);
        n.h_setHeld{value: held}(id, payer, held);
    }

    // three accounts start with symbolic credits
    function _credits(address a, address b, address c, uint256 oa, uint256 ob, uint256 oc) internal {
        vm.assume(oa <= 1000 ether && ob <= 1000 ether && oc <= 1000 ether);
        n.h_setOwed{value: oa}(a, oa);
        n.h_setOwed{value: ob}(b, ob);
        n.h_setOwed{value: oc}(c, oc);
    }

    function _held() internal view returns (address p, uint256 a) {
        (p, a) = n.trialPaymentOf(id);
    }

    // DP1: release succeeds exactly when isReleasable says so. Held money goes only to its payer, at once
    // after the end; a deposit only after grace and the auction; the balance never moves
    function check_DP1_release(
        uint64 exp, uint64 epoch, uint256 dep, uint96 held, address payer, uint256 t, address caller,
        uint256 o1, uint256 o2, uint256 o3
    ) public {
        _state(exp, epoch, dep, held, payer);
        _credits(payer, HOLDER, DEAD, o1, o2, o3);
        vm.assume(t < 2 ** 64);
        vm.warp(t);
        bool can = n.isReleasable(id);
        uint256 bal = address(n).balance;
        uint256 bp = n.owed(payer);
        uint256 bh = n.owed(HOLDER);
        uint256 bd = n.owed(DEAD);
        uint256 bc = n.owed(caller);
        vm.prank(caller);
        (bool ok,) = address(n).call(abi.encodeCall(PageNFT.release, (id)));
        assert(ok == can);
        if (held != 0) assert(ok == (t > exp));
        else assert(ok == (dep != 0 && t > uint256(exp) + 111 days));
        assert(address(n).balance == bal);
        if (ok && held != 0) {
            // only the payer's credit rises, by exactly the held amount
            assert(n.owed(payer) == bp + held);
            if (HOLDER != payer) assert(n.owed(HOLDER) == bh);
            if (DEAD != payer) assert(n.owed(DEAD) == bd);
            if (caller != payer) assert(n.owed(caller) == bc);
            (, uint256 a) = _held();
            assert(a == 0);
            assert(n.depositOf(id) == 0);
        }
        if (!ok) {
            (address p2, uint256 a2) = _held();
            assert(p2 == payer && a2 == held);
        }
    }

    // DP2: a trial over an existing top level record succeeds exactly when the pause after the end is over
    // for a record with no deposit, or the auction is over for a record with one, the price is paid and the
    // commitment is ripe. The held money from before then goes to its payer, a deposit goes to the holder,
    // the new price is held for the caller, and the deposit is 0
    function check_DP2_trialOverRecord(
        uint64 exp, uint64 epoch, uint256 dep, uint96 held, address payer, address caller, uint256 t,
        uint256 value, uint256 committedAt
    ) public {
        vm.assume(t < 2 ** 40 && committedAt < 2 ** 40 && value <= 10 ether);
        _plainCaller(caller);
        _state(exp, epoch, dep, held, payer);
        n.h_setCommitment(keccak256(abi.encode(bytes("alpha"), OTHER, uint256(0), bytes32("s"), true)), committedAt);
        vm.deal(caller, value);
        vm.warp(t);
        uint256 bal = address(n).balance;
        uint256 bp = n.owed(payer);
        uint256 bc = n.owed(caller);
        uint256 bh = n.owed(HOLDER);
        vm.prank(caller);
        (bool ok,) = address(n).call{value: value}(abi.encodeCall(PageNFT.revealTrial, ("alpha", OTHER, 0, bytes32("s"))));
        bool ended = dep == 0 ? t > uint256(exp) + 14 days : t > uint256(exp) + 111 days;
        bool expected = ended && value >= PRICE && committedAt != 0 && t >= committedAt + 20 && t <= committedAt + 86400;
        assert(ok == expected);
        if (ok) {
            assert(n.depositOf(id) == 0);
            (address p, uint256 a) = _held();
            assert(p == caller && a == PRICE);
            if (payer == HOLDER) {
                assert(n.owed(HOLDER) == bh + held + dep);
            } else {
                assert(n.owed(payer) == bp + held);
                assert(n.owed(HOLDER) == bh + dep);
            }
            if (caller != payer) assert(n.owed(caller) == bc);
            assert(address(n).balance == bal + PRICE);
            assert(n.expiresAt(id) == t + 14 days);
            assert(n.ownerOf(id) == OTHER);
        }
    }

    // DP3: a paid registration over an ended trial credits the trial payer its money, pays the trial's
    // referrer nothing, whoever holds the referrer's name, and records only its own referrer
    function check_DP3_paidOverEndedTrial(
        uint64 exp, uint64 epoch, uint96 held, address payer, uint8 refPick, uint256 t, uint256 ref,
        uint256 value
    ) public {
        vm.assume(t < 2 ** 40 && t > uint256(exp) && t > 1000 && value <= 10 ether && ref != id);
        // the payer is symbolic and may be any of these holders as well
        address refHolder = _pickRefHolder(refPick);
        _state(exp, epoch, 0, held, payer);
        // the trial's referrer is a live paid name held by one of four accounts
        n.h_setRecord(refId, "refer", 0, uint64(t + 365 days), 1, 0);
        n.h_mint(refHolder, refId);
        n.h_setDeposit{value: FEE}(refId, FEE);
        n.h_setReferrer(id, refId);
        n.h_setCommitment(n.makeCommitment("alpha", HOLDER, ref, bytes32("s")), t - 61);
        vm.deal(HOLDER, value);
        vm.warp(t);
        uint256 bal = address(n).balance;
        uint256 bp = n.owed(payer);
        uint256 br = n.owed(refHolder);
        uint256 bh = n.owed(HOLDER);
        uint256 bd = n.owed(DEAD);
        vm.prank(HOLDER);
        (bool ok,) = address(n).call{value: value}(abi.encodeCall(PageNFT.reveal, ("alpha", HOLDER, ref, bytes32("s"))));
        assert(ok == (value >= FEE));
        if (ok) {
            assert(n.owed(payer) == bp + held);
            if (refHolder != payer) assert(n.owed(refHolder) == br);
            if (HOLDER != payer) assert(n.owed(HOLDER) == bh);
            if (DEAD != payer) assert(n.owed(DEAD) == bd);
            assert(n.referrerOf(id) == ref);
            assert(n.depositOf(id) == FEE);
            (, uint256 a) = _held();
            assert(a == 0);
            assert(address(n).balance == bal + FEE);
        }
    }

    // DP4: renew during a trial converts it: the payer is credited, the referrer is kept, the year starts
    // at the trial end; after the end it fails and nothing moves
    function check_DP4_conversion(
        uint64 exp, uint64 epoch, uint96 held, address payer, address caller, uint256 t, uint256 value, uint256 ref
    ) public {
        vm.assume(t < 2 ** 40 && value <= 10 ether && exp <= t + 14 days && held != 0);
        _plainCaller(caller);
        _state(exp, epoch, 0, held, payer);
        n.h_setReferrer(id, ref);
        vm.deal(caller, value);
        vm.warp(t);
        uint256 bal = address(n).balance;
        uint256 bp = n.owed(payer);
        uint256 bc = n.owed(caller);
        vm.prank(caller);
        (bool ok,) = address(n).call{value: value}(abi.encodeCall(PageNFT.renew, (id)));
        assert(ok == (t <= exp && value >= FEE));
        if (ok) {
            assert(n.owed(payer) == bp + held);
            if (caller != payer) assert(n.owed(caller) == bc);
            (, uint256 a) = _held();
            assert(a == 0);
            assert(n.depositOf(id) == FEE);
            assert(n.referrerOf(id) == ref);
            assert(n.expiresAt(id) == uint256(exp) + 365 days);
            assert(address(n).balance == bal + FEE);
            assert(n.ownerOf(id) == HOLDER);
        } else {
            (, uint256 a) = _held();
            assert(a == held);
            assert(n.owed(payer) == bp);
        }
    }

    // DP5: status for every top level state and every subpage state, and a revert for an id with no record
    function check_DP5_status(
        uint64 exp, uint64 epoch, uint256 dep, uint96 held, address payer, uint256 t, uint64 pe, bool subDead,
        uint256 other
    ) public {
        _state(exp, epoch, dep, held, payer);
        vm.assume(t < 2 ** 64);
        n.h_setRecord(sub, "x", id, 0, 1, pe);
        n.h_mint(subDead ? DEAD : OTHER, sub);
        vm.warp(t);
        PageCard.Status s = n.status(id);
        uint256 graceEnd = dep == 0 ? uint256(exp) : uint256(exp) + 90 days;
        if (t <= exp) assert(s == (dep == 0 ? PageCard.Status.Trial : PageCard.Status.Active));
        else if (t <= graceEnd) assert(s == PageCard.Status.Grace);
        else assert(s == PageCard.Status.Expired);
        PageCard.Status ss = n.status(sub);
        if (pe != epoch || subDead) assert(ss == PageCard.Status.Invalid);
        else if (t <= exp) assert(ss == PageCard.Status.Active);
        else if (t <= uint256(exp) + 90 days) assert(ss == PageCard.Status.Grace);
        else assert(ss == PageCard.Status.Expired);
        vm.assume(other != id && other != sub);
        (bool ok,) = address(n).call(abi.encodeCall(PageNFT.status, (other)));
        assert(!ok);
    }

    // DP5d: a top level name DEAD holds is Invalid in every state, a paid one, a trial or a released one, at
    // any time. A subpage under it follows the expiry and grace of its parent, in the registration it was
    // made in, unless DEAD holds the subpage too
    function check_DP5d_deadHeldStatus(
        uint64 exp, uint64 epoch, uint256 dep, uint96 held, address payer, uint256 t, uint64 pe, bool subDead
    ) public {
        _stateOf(DEAD, exp, epoch, dep, held, payer);
        vm.assume(t < 2 ** 64);
        n.h_setRecord(sub, "x", id, 0, 1, pe);
        n.h_mint(subDead ? DEAD : OTHER, sub);
        vm.warp(t);
        assert(n.status(id) == PageCard.Status.Invalid);
        PageCard.Status ss = n.status(sub);
        if (pe != epoch || subDead) assert(ss == PageCard.Status.Invalid);
        else if (t <= exp) assert(ss == PageCard.Status.Active);
        else if (t <= uint256(exp) + 90 days) assert(ss == PageCard.Status.Grace);
        else assert(ss == PageCard.Status.Expired);
    }

    // RF2: a name as its own referrer is refused at reveal and at revealTrial with a commitment built by
    // hand, for every owner, value, time and commitment age
    function check_RF2_selfReferralRefused(address owner, uint256 value, uint256 t, uint256 committedAt, bool trial)
        public
    {
        vm.assume(t < 2 ** 40 && committedAt < 2 ** 40 && value <= 100 ether);
        bytes32 c = keccak256(abi.encode(bytes("alpha"), owner, id, bytes32("s")));
        n.h_setCommitment(trial ? keccak256(abi.encode(bytes("alpha"), owner, id, bytes32("s"), true)) : c, committedAt);
        vm.deal(OTHER, value);
        vm.warp(t);
        vm.prank(OTHER);
        (bool ok, bytes memory ret) = trial
            ? address(n).call{value: value}(abi.encodeCall(PageNFT.revealTrial, ("alpha", owner, id, bytes32("s"))))
            : address(n).call{value: value}(abi.encodeCall(PageNFT.reveal, ("alpha", owner, id, bytes32("s"))));
        assert(!ok);
        assert(bytes4(ret) == PageNFT.SelfReferral.selector);
    }
}

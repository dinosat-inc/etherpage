// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {PageCard} from "../src/PageCard.sol";
import {PageNFT} from "../src/PageNFT.sol";

/// @notice State writers for the trial proofs. They exist only in this test harness.
contract TrialHarness is PageNFT {
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

    function h_setCommitment(bytes32 c, uint256 t) external {
        commitments[c] = t;
    }

    function h_setMinter(uint256 parentId, address m, uint64 e, address s) external {
        _subpageMinter[parentId] = SubpageMinter(m, e, s);
    }
}

/// @notice Symbolic proofs of the sponsored trial rules T1 to T10 over one top level label. In T7, T8
/// and the joint T1 and T5 proof, a record with no deposit holds a symbolic price for PAYER, which may
/// be zero. In the other proofs it holds none.
/// Halmos: FOUNDRY_PROFILE=proofs halmos --contract TrialProofsTest --function check_ --forge-build-out out-proofs --loop 4 --storage-layout generic
contract TrialProofsTest is Test {
    TrialHarness n;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address constant HOLDER = address(0xB0B);
    address constant OWNER = address(0xA11CE);
    address constant OTHER = address(0xC0FFEE);
    address constant MINTER = address(0x3117);
    address constant PAYER = address(0xFA7E5);
    bytes32 constant ROOT = 0x62460c06d95b73747abf6ea4f28aefd78b4ad2abee112e7cf15fe6a924cca3c6;
    uint256 constant FEE = 0.0001 ether;
    uint256 constant PRICE = 0.00001 ether;
    uint256 id;

    function setUp() public {
        n = new TrialHarness(new PageCard());
        id = uint256(keccak256(abi.encodePacked(ROOT, keccak256(bytes("alpha")))));
    }

    function _pick(uint8 p) internal pure returns (address) {
        uint8 k = p % 4;
        if (k == 0) return DEAD;
        if (k == 1) return OWNER;
        if (k == 2) return OTHER;
        return MINTER;
    }

    // a symbolic record for alpha held by HOLDER, and the deposit or held trial price and credits behind
    // it; a record with no deposit holds held for PAYER, which may be 0 once refunded
    function _state(bool exists, uint64 exp, uint64 epoch, uint256 dep, uint256 o1, uint256 o2, uint256 o3)
        internal
    {
        _stateHeld(exists, exp, epoch, dep, 0, o1, o2, o3);
    }

    function _stateHeld(
        bool exists, uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 o1, uint256 o2, uint256 o3
    ) internal {
        vm.assume(dep <= 1000 ether && o1 <= 1000 ether && o2 <= 1000 ether && o3 <= 1000 ether && held <= 1 ether);
        vm.assume(dep == 0 || held == 0);
        if (exists) {
            vm.assume(epoch > 0 && epoch < type(uint64).max);
            n.h_setRecord(id, "alpha", 0, exp, epoch, 0);
            n.h_mint(HOLDER, id);
            n.h_setDeposit{value: dep}(id, dep);
            n.h_setHeld{value: held}(id, PAYER, held);
        } else {
            vm.assume(dep == 0 && held == 0);
        }
        n.h_setOwed{value: o1}(DEAD, o1);
        n.h_setOwed{value: o2}(HOLDER, o2);
        n.h_setOwed{value: o3 }(OTHER, o3);
    }

    // T2: no premium without a deposit
    function check_T2_noPremiumWithoutDeposit(uint64 exp, uint64 epoch, uint256 t) public {
        vm.assume(epoch > 0);
        n.h_setRecord(id, "alpha", 0, exp, epoch, 0);
        vm.warp(t);
        assert(n.getPremium(id) == 0);
    }

    // T6: the views agree with the grace end, which is the expiry itself when there is no deposit
    function check_T6_viewsAgree(bool exists, uint64 exp, uint64 epoch, uint256 dep, uint256 t) public {
        vm.assume(t < 2 ** 64);
        _state(exists, exp, epoch, dep, 0, 0, 0);
        vm.warp(t);
        uint256 graceEnd = dep == 0 ? uint256(exp) : uint256(exp) + 90 days;
        assert(n.isAvailable("alpha", 0) == (!exists || t > graceEnd));
        assert(n.isExpired(id) == (exists && t > graceEnd));
        assert(n.inGracePeriod(id) == (exists && t > exp && t <= graceEnd));
        if (dep == 0) assert(n.getPremium(id) == 0);
    }

    // T3: a live unpaid top level name moves only to the dead address: a transfer by its holder or by
    // an operator succeeds exactly when it goes to DEAD
    function check_T3_unpaidMovesOnlyToDead(uint64 exp, uint64 epoch, uint256 t, uint8 toPick, bool viaOperator) public {
        vm.assume(t <= exp);
        _state(true, exp, epoch, 0, 0, 0, 0);
        vm.warp(t);
        address to = _pick(toPick);
        address caller = HOLDER;
        if (viaOperator) {
            vm.prank(HOLDER);
            n.setApprovalForAll(OTHER, true);
            caller = OTHER;
        }
        vm.prank(caller);
        (bool ok,) = address(n).call(abi.encodeWithSignature("transferFrom(address,address,uint256)", HOLDER, to, id));
        assert(ok == (to == DEAD));
    }

    // T4: no subpage under a parent without a deposit, by the holder or its minter, and isAvailable agrees
    function check_T4_noSubpageUnderUnpaid(uint64 exp, uint64 epoch, uint256 t, bool byMinter) public {
        _state(true, exp, epoch, 0, 0, 0, 0);
        n.h_setMinter(id, MINTER, epoch, HOLDER);
        vm.warp(t);
        assert(!n.isAvailable("x", id));
        vm.prank(byMinter ? MINTER : HOLDER);
        (bool ok,) = address(n).call(abi.encodeCall(PageNFT.registerSubpageFor, ("x", id, OTHER)));
        assert(!ok);
    }

    // T1 and T5: a trial succeeds exactly when the name has no record, or a record past its end and the
    // fourteen day pause with no deposit, or past its auction with one, the price is paid and the commitment
    // is ripe; then it holds the price for the caller, credits a price held before to its payer and a deposit
    // to the holder, and moves nothing else
    function check_T1_T5_trial(
        bool exists, uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 o1, uint256 o2, uint256 o3,
        uint256 t, uint256 value, uint256 committedAt
    ) public {
        vm.assume(t < 2 ** 40 && committedAt < 2 ** 40 && value <= 10 ether);
        _stateHeld(exists, exp, epoch, dep, held, o1, o2, o3);
        // a trial consumes its own commitment, which carries a trial flag
        bytes32 c = keccak256(abi.encode(bytes("alpha"), OWNER, uint256(0), bytes32("s"), true));
        n.h_setCommitment(c, committedAt);
        vm.deal(OTHER, value);
        vm.warp(t);
        uint256 bal = address(n).balance;
        vm.prank(OTHER);
        (bool ok,) = address(n).call{value: value}(abi.encodeCall(PageNFT.revealTrial, ("alpha", OWNER, 0, bytes32("s"))));
        bool ended = !exists || (dep == 0 ? t > uint256(exp) + 14 days : t > uint256(exp) + 111 days);
        bool expected = ended && value >= PRICE && committedAt != 0 && t >= committedAt + 20 && t <= committedAt + 86400;
        assert(ok == expected);
        if (ok) {
            assert(n.depositOf(id) == 0);
            assert(n.expiresAt(id) == t + 14 days);
            assert(n.ownerOf(id) == OWNER);
            assert(n.owed(DEAD) == o1);
            assert(n.owed(HOLDER) == o2 + dep);
            assert(n.owed(OTHER) == o3);
            assert(n.owed(PAYER) == held);
            (address p, uint96 a) = n.trialPaymentOf(id);
            assert(p == OTHER && a == PRICE);
            assert(address(n).balance == bal + PRICE);
            assert(n.getPremium(id) == 0);
        }
    }

    // T10: only the trial form serves a trial. Any other ripe commitment, the bitwise NOT of the public paid
    // commitment included, leaves revealTrial failing, whatever the state, the value and the time
    function check_T10_onlyTheTrialFormServesATrial(
        bool exists, uint64 exp, uint64 epoch, uint256 dep, uint256 t, uint256 value, uint256 committedAt, bytes32 x
    ) public {
        vm.assume(t < 2 ** 40 && committedAt < 2 ** 40 && value <= 10 ether);
        _state(exists, exp, epoch, dep, 0, 0, 0);
        bytes32 paid = n.makeCommitment("alpha", OWNER, 0, bytes32("s"));
        bytes32 tf = keccak256(abi.encode(bytes("alpha"), OWNER, uint256(0), bytes32("s"), true));
        vm.assume(x != tf);
        n.h_setCommitment(x, committedAt);
        n.h_setCommitment(~paid, committedAt);
        vm.deal(OTHER, value);
        vm.warp(t);
        vm.prank(OTHER);
        (bool ok,) = address(n).call{value: value}(abi.encodeCall(PageNFT.revealTrial, ("alpha", OWNER, 0, bytes32("s"))));
        assert(!ok);
    }

    // T9: the two commitment forms never serve each other. With only the paid form committed no trial
    // succeeds, and with only the trial form committed no paid reveal succeeds, whatever the state and value
    function check_T9_commitmentFormsAreSeparate(
        bool exists, uint64 exp, uint64 epoch, uint256 dep, uint256 t, uint256 value, uint256 committedAt,
        bool trialPath, bool forOther
    ) public {
        vm.assume(t < 2 ** 40 && committedAt < 2 ** 40 && value <= 2000 ether);
        _state(exists, exp, epoch, dep, 0, 0, 0);
        bytes32 c = n.makeCommitment("alpha", OWNER, 0, bytes32("s"));
        n.h_setCommitment(trialPath ? c : keccak256(abi.encode(bytes("alpha"), OWNER, uint256(0), bytes32("s"), true)), committedAt);
        vm.deal(OTHER, value);
        vm.deal(OWNER, value);
        vm.warp(t);
        bool ok;
        if (trialPath) {
            vm.prank(OTHER);
            (ok,) = address(n).call{value: value}(abi.encodeCall(PageNFT.revealTrial, ("alpha", OWNER, 0, bytes32("s"))));
        } else if (forOther) {
            vm.prank(OTHER);
            (ok,) = address(n).call{value: value}(abi.encodeCall(PageNFT.reveal, ("alpha", OWNER, 0, bytes32("s"))));
        } else {
            vm.prank(OWNER);
            (ok,) = address(n).call{value: value}(abi.encodeCall(PageNFT.reveal, ("alpha", OWNER, 0, bytes32("s"))));
        }
        assert(!ok);
    }

    // T8: a paid registration over a lapsed trial costs exactly the fee, is never refused by the pause, and
    // credits only the trial payer, with its own held price
    function check_T8_paidOverLapsedTrial(
        uint64 exp, uint64 epoch, uint96 held, uint256 o1, uint256 o2, uint256 o3, uint256 t, uint256 value
    ) public {
        vm.assume(t < 2 ** 40 && t > exp && t > 1000 && value <= 10 ether);
        _stateHeld(true, exp, epoch, 0, held, o1, o2, o3);
        bytes32 c = n.makeCommitment("alpha", OTHER, 0, bytes32("s"));
        n.h_setCommitment(c, t - 61);
        vm.deal(OTHER, value);
        vm.warp(t);
        uint256 bal = address(n).balance;
        vm.prank(OTHER);
        (bool ok,) = address(n).call{value: value}(abi.encodeCall(PageNFT.reveal, ("alpha", OTHER, 0, bytes32("s"))));
        assert(ok == (value >= FEE));
        if (ok) {
            assert(n.depositOf(id) == FEE);
            assert(n.owed(DEAD) == o1);
            assert(n.owed(HOLDER) == o2);
            assert(n.owed(OTHER) == o3);
            assert(n.owed(PAYER) == held);
            (, uint96 a) = n.trialPaymentOf(id);
            assert(a == 0);
            assert(address(n).balance == bal + FEE);
            assert(n.expiresAt(id) == t + 365 days);
        }
    }

    // T7: renew of a trial succeeds exactly while the trial is live and at least the fee is paid; it
    // leaves a deposit of the fee, adds a year to the expiry, keeps the holder and credits the held
    // price to its payer
    function check_T7_renewOfATrial(uint64 exp, uint64 epoch, uint96 held, uint256 t, uint256 value) public {
        vm.assume(t < 2 ** 40 && value <= 10 ether && exp <= t + 14 days);
        _stateHeld(true, exp, epoch, 0, held, 0, 0, 0);
        vm.deal(OTHER, value);
        vm.warp(t);
        vm.prank(OTHER);
        (bool ok,) = address(n).call{value: value}(abi.encodeCall(PageNFT.renew, (id)));
        assert(ok == (t <= exp && value >= FEE));
        if (ok) {
            assert(n.depositOf(id) == FEE);
            assert(n.expiresAt(id) == uint256(exp) + 365 days);
            assert(n.ownerOf(id) == HOLDER);
            assert(n.owed(PAYER) == held);
        }
    }
}

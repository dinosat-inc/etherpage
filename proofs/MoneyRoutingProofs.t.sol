// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {PageCard} from "../src/PageCard.sol";
import {PageNFT} from "../src/PageNFT.sol";
import {DepositHarness} from "./DepositProofs.t.sol";

/// @notice DepositHarness with one more state writer, a main address saved by an account. It exists
/// only in this test harness.
contract RoutingHarness is DepositHarness {
    constructor(PageCard c) DepositHarness(c) {}

    function h_setResolved(uint256 id, address a, address saver) external {
        _resolvedAddress[id][recordVersion[id]] = a;
        _addrSaver[id][recordVersion[id]] = saver;
    }
}

/// @notice Symbolic proofs of who is credited and what is sent back when a paid name is registered
/// again after its grace period, one reveal per proof. The start state is the paid state of the FM1rP
/// proofs of MoneyProofs.t.sol: alpha held by HOLDER with a symbolic deposit, refer a live paid name
/// held by HOLDER, OTHER, DEAD or P4, the recorded referrer of alpha none, refer or an id with no
/// record, and symbolic credits, here for eight accounts. With saved, each holder but DEAD has also
/// saved a main address, PAYOUT for alpha and REFPAYOUT for refer, so a payee differs from its holder.
/// CALLER, an account with no code, pays the price plus an excess of 0 to 1000 ether for HOLDER, OTHER
/// or itself, with no referrer, refer or an id with no record as its own, at any second after the
/// grace period of alpha, in its premium period or after it. Then:
/// C1 the reveal succeeds;
/// C2 the payee of alpha before the call gets exactly the old deposit and 75 percent of the premium,
/// whether the deposit is bought out or released first;
/// C3 the payee of the recorded referrer before the call gets exactly the other 25 percent, and DEAD
/// gets it when there is no recorded referrer or its id has no record;
/// C4 an account that is both payees gets both amounts, and every other account gets nothing, CALLER
/// and a symbolic one among them, so no one is credited the excess;
/// C5 the deposit of alpha is the old deposit plus the fee in the premium period and the fee alone
/// after it, the balance rises by exactly the price and CALLER gets exactly the excess back as ETH.
/// The credits are checked before the balances, so an excess credited to CALLER fails C4 and an excess
/// sent to any other account fails C5.
/// The premium is the one getPremium gives at that second. These proofs check where it goes.
/// Halmos: FOUNDRY_PROFILE=proofs halmos --contract MoneyRoutingProofsTest --function check_ --forge-build-out out-proofs --loop 4 --storage-layout generic
contract MoneyRoutingProofsTest is Test {
    RoutingHarness n;
    address cardAddr;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address constant HOLDER = address(0xB0B);
    address constant OTHER = address(0xC0FFEE);
    address constant CALLER = address(0xCA11E2);
    address constant P4 = address(0x4EF);
    address constant PAYOUT = address(0xA11CE);
    address constant REFPAYOUT = address(0xBEEF);
    bytes32 constant ROOT = 0x62460c06d95b73747abf6ea4f28aefd78b4ad2abee112e7cf15fe6a924cca3c6;
    uint256 constant FEE = 0.0001 ether;
    uint64 constant EXPC = 1_800_000_000;
    uint256 id;
    uint256 refId;

    struct Sale {
        uint256 t;
        uint256 dep;
        uint256[8] owed;
        uint256 bal;
        bool released;
        uint256 prem;
        uint256 price;
        address payA;
        address payR;
        uint256 refShare;
        uint256 ownerShare;
        uint256[8] want;
    }

    function setUp() public {
        PageCard card = new PageCard();
        cardAddr = address(card);
        n = new RoutingHarness(card);
        id = uint256(keccak256(abi.encodePacked(ROOT, keccak256(bytes("alpha")))));
        refId = uint256(keccak256(abi.encodePacked(ROOT, keccak256(bytes("refer")))));
    }

    function _acct(uint256 i) internal view returns (address) {
        if (i == 0) return HOLDER;
        if (i == 1) return OTHER;
        if (i == 2) return CALLER;
        if (i == 3) return P4;
        if (i == 4) return DEAD;
        if (i == 5) return cardAddr;
        if (i == 6) return PAYOUT;
        return REFPAYOUT;
    }

    function _refHolder(uint8 k) internal pure returns (address) {
        uint8 m = k % 4;
        if (m == 0) return HOLDER;
        if (m == 1) return OTHER;
        if (m == 2) return DEAD;
        return P4;
    }

    // alpha held by HOLDER with a deposit, refer held by refHolder, the credits funded so the balance
    // matches the ledgers; payA and payR are the payees the rules name, worked out from the state
    function _state(uint64 epoch, uint256 dep, uint8 rhPick, uint8 k, uint256 r, bool saved, uint256 t,
        uint256[8] memory o) internal returns (Sale memory s)
    {
        vm.assume(t > EXPC + 90 days && t < 2 ** 40);
        vm.assume(dep != 0 && dep <= 1000 ether);
        vm.assume(epoch > 0 && epoch < type(uint64).max);
        vm.assume(r != id && r != refId);
        for (uint256 i; i < 8; ++i) vm.assume(o[i] <= 1000 ether);
        address refHolder = _refHolder(rhPick);
        n.h_setRecord(id, "alpha", 0, EXPC, epoch, 0);
        n.h_mint(HOLDER, id);
        n.h_setDeposit{value: dep}(id, dep);
        n.h_setRecord(refId, "refer", 0, uint64(t + 365 days), 1, 0);
        n.h_mint(refHolder, refId);
        n.h_setDeposit{value: FEE}(refId, FEE);
        n.h_setReferrer(id, k == 0 ? 0 : k == 1 ? refId : r);
        bool refSaved = saved && refHolder != DEAD;
        if (saved) n.h_setResolved(id, PAYOUT, HOLDER);
        if (refSaved) n.h_setResolved(refId, REFPAYOUT, refHolder);
        for (uint256 i; i < 8; ++i) n.h_setOwed{value: o[i]}(_acct(i), o[i]);
        vm.warp(t);
        s.t = t;
        s.dep = dep;
        for (uint256 i; i < 8; ++i) s.owed[i] = o[i];
        s.bal = address(n).balance;
        s.released = t > EXPC + 111 days;
        s.prem = n.getPremium(id);
        s.price = FEE + (s.released ? 0 : s.dep) + s.prem;
        s.payA = saved ? PAYOUT : HOLDER;
        bool refRecord = k == 1;
        s.payR = !refRecord ? DEAD : refSaved ? REFPAYOUT : refHolder;
        _expect(s);
    }

    // what each account should hold after the call, worked out before it in the form and order of the
    // contract, so its overflow checks are settled here and each assert compares the same sum
    function _expect(Sale memory s) internal view {
        s.refShare = s.prem * 2500 / 10_000;
        s.ownerShare = s.prem - s.refShare;
        s.want[0] = _due(s, 0);
        s.want[1] = _due(s, 1);
        s.want[2] = _due(s, 2);
        s.want[3] = _due(s, 3);
        s.want[4] = _due(s, 4);
        s.want[5] = _due(s, 5);
        s.want[6] = _due(s, 6);
        s.want[7] = _due(s, 7);
    }

    // the old deposit, released or bought out, comes first, then the referrer share, then the owner share
    function _due(Sale memory s, uint256 i) internal view returns (uint256 v) {
        address a = _acct(i);
        v = s.owed[i];
        if (a == s.payA) v += s.dep;
        if (a == s.payR) v += s.refShare;
        if (a == s.payA) v += s.ownerShare;
    }

    // each assert is written out, not looped, so none counts toward the loop bound
    // referrer ids come from fixed cases, as a symbolic id never reaches the ownership slot of refer
    function _route(Sale memory s, uint8 jPick, uint256 r2, uint8 toPick, address z, uint256 excess) internal {
        uint8 j = jPick % 3;
        if (j == 2) vm.assume(r2 != id && r2 != refId);
        uint256 ref2 = j == 0 ? 0 : j == 1 ? refId : r2;
        vm.assume(excess <= 1000 ether);
        vm.assume(
            z != HOLDER && z != OTHER && z != CALLER && z != P4 && z != DEAD && z != cardAddr && z != PAYOUT
                && z != REFPAYOUT
        );
        uint8 tk = toPick % 3;
        address to = tk == 0 ? HOLDER : tk == 1 ? OTHER : CALLER;
        n.h_setCommitment(n.makeCommitment("alpha", to, ref2, bytes32("s")), s.t - 61);
        uint256 zOwed = n.owed(z);
        // CALLER holds exactly what it sends, so all it holds after the call came back from the reveal
        uint256 value = s.price + excess;
        vm.deal(CALLER, value);
        vm.prank(CALLER);
        (bool ok,) =
            address(n).call{value: value}(abi.encodeCall(PageNFT.reveal, ("alpha", to, ref2, bytes32("s"))));
        // C1
        assert(ok);
        // C2 to C4
        assert(n.owed(HOLDER) == s.want[0]);
        assert(n.owed(OTHER) == s.want[1]);
        assert(n.owed(CALLER) == s.want[2]);
        assert(n.owed(P4) == s.want[3]);
        assert(n.owed(DEAD) == s.want[4]);
        assert(n.owed(cardAddr) == s.want[5]);
        assert(n.owed(PAYOUT) == s.want[6]);
        assert(n.owed(REFPAYOUT) == s.want[7]);
        assert(n.owed(z) == zOwed);
        // C5
        assert(n.depositOf(id) == (s.released ? 0 : s.dep) + FEE);
        assert(address(n).balance == s.bal + s.price);
        assert(CALLER.balance == excess);
    }

    /// @notice FM1rR: a paid registration of alpha after its grace period credits exactly the accounts
    /// the rules name and sends the excess back to CALLER. One part per recorded referrer: 0 none,
    /// 1 refer, 2 an id with no record.
    function check_FM1rR0(uint64 epoch, uint256 dep, uint8 rhPick, uint256 r, bool saved, uint256 t,
        uint256[8] memory o, uint8 jPick, uint256 r2, uint8 toPick, address z, uint256 excess) public {
        _route(_state(epoch, dep, rhPick, 0, r, saved, t, o), jPick, r2, toPick, z, excess);
    }

    function check_FM1rR1(uint64 epoch, uint256 dep, uint8 rhPick, uint256 r, bool saved, uint256 t,
        uint256[8] memory o, uint8 jPick, uint256 r2, uint8 toPick, address z, uint256 excess) public {
        _route(_state(epoch, dep, rhPick, 1, r, saved, t, o), jPick, r2, toPick, z, excess);
    }

    function check_FM1rR2(uint64 epoch, uint256 dep, uint8 rhPick, uint256 r, bool saved, uint256 t,
        uint256[8] memory o, uint8 jPick, uint256 r2, uint8 toPick, address z, uint256 excess) public {
        _route(_state(epoch, dep, rhPick, 2, r, saved, t, o), jPick, r2, toPick, z, excess);
    }
}

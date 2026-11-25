// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {WideRevealProofsTest} from "./WideRevealProofs.t.sol";

/// @notice WRV1-WRV4 split into pieces small enough to finish (WRV2 and WRV3 ran out of their 6 hour limit
/// on 2026-11-06). Every piece runs the same _rv as WRV1-WRV4: the rule both ways, the exact refund,
/// credits, deposit, held money, epoch, record version, minter switch-off, display page, main address and
/// holderSince, or no change at all on a refusal. A piece fixes part of the input:
/// - entry point: P reveal, T revealTrial; label: 0 q (1 byte), 1 abc (3 bytes), 2 alpha (5 bytes);
/// - n: no record (deadHolder, primary and saved have no effect then and are fixed false);
///   e{d}{p}: a record held by HOLDER (d 0) or DEAD (d 1), the old holder's display page set (p 1) or not;
///   e: a record with deadHolder and primary symbolic; saved is symbolic in every e piece;
/// - commitment, WRVq (rest of the state fixed as in WRV1/WRV2): k1 the stored commitment is the call's
///   own, at any time; k2 any other key at any time. WRV1/WRV2 store a commitment for a symbolic owner,
///   referrer, secret and form: equal to the call's it is k1, otherwise its hash is another key (k2);
/// - commitment, WRVs (rest of the state symbolic as in WRV3/WRV4: record version, recorded referrer,
///   minter, three credits, frame account and id; the secret symbolic too, so a WRVs f1 piece covers the
///   WRVq k1 piece with the same flags): f1 the call's own commitment at any time, f2 the other form;
/// - time window of the record (paid reveal only): tA up to the grace end, tB the premium window, tC after;
///   tB1-tB4 four fixed seconds of the premium window with the expiry fixed (see _instant).
/// Everything else stays symbolic: expiry, epoch, deposit, held money, time, value, the call's referrer,
/// the commitment time, the caller pick (3) and the owner pick (5).
/// The call label is lower case except in WRVq_*_upper (a new name, every label). Upper case over an
/// existing record is covered by composition: the registration reads the label only through
/// _validateAndNormalize (PageNFT.sol line 625), and WLB and extest prove normalize(Q, aBC, ALPHA) = q, abc,
/// alpha.
/// Halmos: FOUNDRY_PROFILE=proofs halmos --contract WideRevealPiecesTest --forge-build-out out-proofs --loop 4 --storage-layout generic
contract WideRevealPiecesTest is WideRevealProofsTest {
    struct Q {
        uint64 exp;
        uint64 epoch;
        uint256 dep;
        uint96 held;
        uint256 t;
        uint256 value;
        uint8 callerPick;
        uint8 ownerPick;
    }

    // the premium window at fixed seconds (phases 7 to 10): the expiry fixed at 1,800,000,000 and the time at
    // 90 days and 1 second after it (the first second of the window), 100 days, 111 days less 1 second (the
    // last second with a premium) and 111 days (the last second of the window, premium 0). With a
    // symbolic time in the window Halmos must reason about the premium division and does not finish.
    function _instant(Q memory q, uint8 phase) internal pure returns (uint8) {
        if (phase < 7) return phase;
        q.exp = 1_800_000_000;
        uint256 off = phase == 7 ? 90 days + 1 : phase == 8 ? 100 days : phase == 9 ? 111 days - 1 : 111 days;
        q.t = uint256(q.exp) + off;
        return 0;
    }

    function _base(bool trial, uint8 lPick, bool upper, bool exists, bool dh, bool pr, Q memory q)
        internal
        pure
        returns (In memory a)
    {
        a = _in(trial, lPick, upper, exists, q.exp, q.epoch, q.dep, q.held, dh, pr);
        a.t = q.t;
        a.value = q.value;
        a.caller = _caller(q.callerPick);
        a.owner = _owner(q.ownerPick, a.caller);
    }

    // WRVq: the rest of the state fixed as in WRV1/WRV2; kind 1 own commitment, kind 2 any other key
    function _pq(
        bool trial, uint8 lPick, bool upper, bool exists, bool dh, bool pr, uint8 kind, uint8 savedMode,
        uint8 phase, Q memory q
    ) internal {
        phase = _instant(q, phase);
        In memory a = _base(trial, lPick, upper, exists, dh, pr, q);
        a.savedMode = savedMode;
        a.phase = phase;
        a.ref = svm.createUint(256, "ref");
        a.secret = svm.createBytes32("secret");
        a.committedAt = svm.createUint(256, "committedAt");
        if (kind == 1) {
            a.o0 = a.owner;
            a.r0 = a.ref;
            a.s0 = a.secret;
            a.form0 = trial;
        } else {
            a.useKey = true;
            a.key0 = svm.createBytes32("key0");
        }
        _fixedRest(a);
        _rv(a);
    }

    // WRVs: the rest of the state symbolic as in WRV3/WRV4, the secret symbolic, the own form or the other
    function _ps(bool trial, uint8 lPick, bool exists, bool dh, bool pr, bool ownForm, uint8 savedMode, uint8 phase,
        Q memory q) internal {
        phase = _instant(q, phase);
        In memory a = _base(trial, lPick, false, exists, dh, pr, q);
        _symState(a);
        a.secret = svm.createBytes32("secret");
        a.s0 = a.secret;
        a.form0 = ownForm ? trial : !trial;
        a.savedMode = savedMode;
        a.phase = phase;
        _rv(a);
    }

    function check_WRVq_P0_n_k1(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 0, false, false, false, false, 1, 1, 0, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P0_n_k2(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 0, false, false, false, false, 2, 1, 0, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P0_n_f1(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 0, false, false, false, true, 1, 0, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P0_n_f2(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 0, false, false, false, false, 1, 0, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P0_e00_k1_tA(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 0, false, true, false, false, 1, 0, 6, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P0_e00_f1_tA(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 0, true, false, false, true, 0, 6, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P0_e01_k1_tA(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 0, false, true, false, true, 1, 0, 6, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P0_e01_f1_tA(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 0, true, false, true, true, 0, 6, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P0_e10_k1_tA(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 0, false, true, true, false, 1, 0, 6, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P0_e10_f1_tA(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 0, true, true, false, true, 0, 6, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P0_e11_k1_tA(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 0, false, true, true, true, 1, 0, 6, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P0_e11_f1_tA(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 0, true, true, true, true, 0, 6, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P0_e_k2_tA(bool dh, bool pr, uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 0, false, true, dh, pr, 2, 0, 6, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P0_e_f2_tA(bool dh, bool pr, uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 0, true, dh, pr, false, 0, 6, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P0_e00_k1_tB(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 0, false, true, false, false, 1, 0, 4, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P0_e00_f1_tB(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 0, true, false, false, true, 0, 4, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P0_e01_k1_tB(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 0, false, true, false, true, 1, 0, 4, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P0_e01_f1_tB(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 0, true, false, true, true, 0, 4, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P0_e10_k1_tB(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 0, false, true, true, false, 1, 0, 4, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P0_e10_f1_tB(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 0, true, true, false, true, 0, 4, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P0_e11_k1_tB(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 0, false, true, true, true, 1, 0, 4, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P0_e11_f1_tB(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 0, true, true, true, true, 0, 4, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P0_e_k2_tB(bool dh, bool pr, uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 0, false, true, dh, pr, 2, 0, 4, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P0_e_f2_tB(bool dh, bool pr, uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 0, true, dh, pr, false, 0, 4, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P0_e00_k1_tB1(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 0, false, true, false, false, 1, 0, 7, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P0_e00_f1_tB1(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 0, true, false, false, true, 0, 7, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P0_e01_k1_tB1(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 0, false, true, false, true, 1, 0, 7, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P0_e01_f1_tB1(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 0, true, false, true, true, 0, 7, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P0_e10_k1_tB1(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 0, false, true, true, false, 1, 0, 7, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P0_e10_f1_tB1(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 0, true, true, false, true, 0, 7, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P0_e11_k1_tB1(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 0, false, true, true, true, 1, 0, 7, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P0_e11_f1_tB1(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 0, true, true, true, true, 0, 7, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P0_e_k2_tB1(bool dh, bool pr, uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 0, false, true, dh, pr, 2, 0, 7, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P0_e_f2_tB1(bool dh, bool pr, uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 0, true, dh, pr, false, 0, 7, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P0_e00_k1_tB2(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 0, false, true, false, false, 1, 0, 8, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P0_e00_f1_tB2(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 0, true, false, false, true, 0, 8, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P0_e01_k1_tB2(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 0, false, true, false, true, 1, 0, 8, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P0_e01_f1_tB2(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 0, true, false, true, true, 0, 8, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P0_e10_k1_tB2(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 0, false, true, true, false, 1, 0, 8, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P0_e10_f1_tB2(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 0, true, true, false, true, 0, 8, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P0_e11_k1_tB2(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 0, false, true, true, true, 1, 0, 8, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P0_e11_f1_tB2(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 0, true, true, true, true, 0, 8, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P0_e_k2_tB2(bool dh, bool pr, uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 0, false, true, dh, pr, 2, 0, 8, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P0_e_f2_tB2(bool dh, bool pr, uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 0, true, dh, pr, false, 0, 8, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P0_e00_k1_tB3(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 0, false, true, false, false, 1, 0, 9, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P0_e00_f1_tB3(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 0, true, false, false, true, 0, 9, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P0_e01_k1_tB3(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 0, false, true, false, true, 1, 0, 9, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P0_e01_f1_tB3(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 0, true, false, true, true, 0, 9, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P0_e10_k1_tB3(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 0, false, true, true, false, 1, 0, 9, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P0_e10_f1_tB3(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 0, true, true, false, true, 0, 9, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P0_e11_k1_tB3(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 0, false, true, true, true, 1, 0, 9, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P0_e11_f1_tB3(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 0, true, true, true, true, 0, 9, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P0_e_k2_tB3(bool dh, bool pr, uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 0, false, true, dh, pr, 2, 0, 9, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P0_e_f2_tB3(bool dh, bool pr, uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 0, true, dh, pr, false, 0, 9, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P0_e00_k1_tB4(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 0, false, true, false, false, 1, 0, 10, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P0_e00_f1_tB4(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 0, true, false, false, true, 0, 10, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P0_e01_k1_tB4(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 0, false, true, false, true, 1, 0, 10, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P0_e01_f1_tB4(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 0, true, false, true, true, 0, 10, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P0_e10_k1_tB4(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 0, false, true, true, false, 1, 0, 10, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P0_e10_f1_tB4(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 0, true, true, false, true, 0, 10, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P0_e11_k1_tB4(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 0, false, true, true, true, 1, 0, 10, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P0_e11_f1_tB4(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 0, true, true, true, true, 0, 10, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P0_e_k2_tB4(bool dh, bool pr, uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 0, false, true, dh, pr, 2, 0, 10, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P0_e_f2_tB4(bool dh, bool pr, uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 0, true, dh, pr, false, 0, 10, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P0_e00_k1_tC(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 0, false, true, false, false, 1, 0, 5, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P0_e00_f1_tC(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 0, true, false, false, true, 0, 5, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P0_e01_k1_tC(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 0, false, true, false, true, 1, 0, 5, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P0_e01_f1_tC(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 0, true, false, true, true, 0, 5, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P0_e10_k1_tC(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 0, false, true, true, false, 1, 0, 5, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P0_e10_f1_tC(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 0, true, true, false, true, 0, 5, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P0_e11_k1_tC(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 0, false, true, true, true, 1, 0, 5, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P0_e11_f1_tC(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 0, true, true, true, true, 0, 5, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P0_e_k2_tC(bool dh, bool pr, uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 0, false, true, dh, pr, 2, 0, 5, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P0_e_f2_tC(bool dh, bool pr, uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 0, true, dh, pr, false, 0, 5, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P1_n_k1(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 1, false, false, false, false, 1, 1, 0, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P1_n_k2(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 1, false, false, false, false, 2, 1, 0, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P1_n_f1(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 1, false, false, false, true, 1, 0, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P1_n_f2(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 1, false, false, false, false, 1, 0, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P1_e00_k1_tA(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 1, false, true, false, false, 1, 0, 6, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P1_e00_f1_tA(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 1, true, false, false, true, 0, 6, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P1_e01_k1_tA(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 1, false, true, false, true, 1, 0, 6, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P1_e01_f1_tA(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 1, true, false, true, true, 0, 6, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P1_e10_k1_tA(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 1, false, true, true, false, 1, 0, 6, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P1_e10_f1_tA(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 1, true, true, false, true, 0, 6, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P1_e11_k1_tA(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 1, false, true, true, true, 1, 0, 6, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P1_e11_f1_tA(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 1, true, true, true, true, 0, 6, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P1_e_k2_tA(bool dh, bool pr, uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 1, false, true, dh, pr, 2, 0, 6, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P1_e_f2_tA(bool dh, bool pr, uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 1, true, dh, pr, false, 0, 6, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P1_e00_k1_tB(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 1, false, true, false, false, 1, 0, 4, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P1_e00_f1_tB(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 1, true, false, false, true, 0, 4, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P1_e01_k1_tB(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 1, false, true, false, true, 1, 0, 4, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P1_e01_f1_tB(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 1, true, false, true, true, 0, 4, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P1_e10_k1_tB(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 1, false, true, true, false, 1, 0, 4, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P1_e10_f1_tB(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 1, true, true, false, true, 0, 4, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P1_e11_k1_tB(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 1, false, true, true, true, 1, 0, 4, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P1_e11_f1_tB(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 1, true, true, true, true, 0, 4, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P1_e_k2_tB(bool dh, bool pr, uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 1, false, true, dh, pr, 2, 0, 4, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P1_e_f2_tB(bool dh, bool pr, uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 1, true, dh, pr, false, 0, 4, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P1_e00_k1_tB1(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 1, false, true, false, false, 1, 0, 7, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P1_e00_f1_tB1(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 1, true, false, false, true, 0, 7, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P1_e01_k1_tB1(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 1, false, true, false, true, 1, 0, 7, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P1_e01_f1_tB1(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 1, true, false, true, true, 0, 7, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P1_e10_k1_tB1(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 1, false, true, true, false, 1, 0, 7, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P1_e10_f1_tB1(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 1, true, true, false, true, 0, 7, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P1_e11_k1_tB1(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 1, false, true, true, true, 1, 0, 7, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P1_e11_f1_tB1(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 1, true, true, true, true, 0, 7, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P1_e_k2_tB1(bool dh, bool pr, uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 1, false, true, dh, pr, 2, 0, 7, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P1_e_f2_tB1(bool dh, bool pr, uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 1, true, dh, pr, false, 0, 7, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P1_e00_k1_tB2(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 1, false, true, false, false, 1, 0, 8, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P1_e00_f1_tB2(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 1, true, false, false, true, 0, 8, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P1_e01_k1_tB2(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 1, false, true, false, true, 1, 0, 8, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P1_e01_f1_tB2(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 1, true, false, true, true, 0, 8, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P1_e10_k1_tB2(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 1, false, true, true, false, 1, 0, 8, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P1_e10_f1_tB2(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 1, true, true, false, true, 0, 8, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P1_e11_k1_tB2(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 1, false, true, true, true, 1, 0, 8, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P1_e11_f1_tB2(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 1, true, true, true, true, 0, 8, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P1_e_k2_tB2(bool dh, bool pr, uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 1, false, true, dh, pr, 2, 0, 8, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P1_e_f2_tB2(bool dh, bool pr, uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 1, true, dh, pr, false, 0, 8, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P1_e00_k1_tB3(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 1, false, true, false, false, 1, 0, 9, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P1_e00_f1_tB3(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 1, true, false, false, true, 0, 9, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P1_e01_k1_tB3(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 1, false, true, false, true, 1, 0, 9, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P1_e01_f1_tB3(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 1, true, false, true, true, 0, 9, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P1_e10_k1_tB3(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 1, false, true, true, false, 1, 0, 9, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P1_e10_f1_tB3(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 1, true, true, false, true, 0, 9, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P1_e11_k1_tB3(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 1, false, true, true, true, 1, 0, 9, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P1_e11_f1_tB3(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 1, true, true, true, true, 0, 9, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P1_e_k2_tB3(bool dh, bool pr, uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 1, false, true, dh, pr, 2, 0, 9, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P1_e_f2_tB3(bool dh, bool pr, uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 1, true, dh, pr, false, 0, 9, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P1_e00_k1_tB4(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 1, false, true, false, false, 1, 0, 10, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P1_e00_f1_tB4(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 1, true, false, false, true, 0, 10, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P1_e01_k1_tB4(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 1, false, true, false, true, 1, 0, 10, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P1_e01_f1_tB4(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 1, true, false, true, true, 0, 10, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P1_e10_k1_tB4(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 1, false, true, true, false, 1, 0, 10, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P1_e10_f1_tB4(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 1, true, true, false, true, 0, 10, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P1_e11_k1_tB4(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 1, false, true, true, true, 1, 0, 10, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P1_e11_f1_tB4(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 1, true, true, true, true, 0, 10, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P1_e_k2_tB4(bool dh, bool pr, uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 1, false, true, dh, pr, 2, 0, 10, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P1_e_f2_tB4(bool dh, bool pr, uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 1, true, dh, pr, false, 0, 10, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P1_e00_k1_tC(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 1, false, true, false, false, 1, 0, 5, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P1_e00_f1_tC(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 1, true, false, false, true, 0, 5, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P1_e01_k1_tC(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 1, false, true, false, true, 1, 0, 5, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P1_e01_f1_tC(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 1, true, false, true, true, 0, 5, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P1_e10_k1_tC(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 1, false, true, true, false, 1, 0, 5, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P1_e10_f1_tC(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 1, true, true, false, true, 0, 5, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P1_e11_k1_tC(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 1, false, true, true, true, 1, 0, 5, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P1_e11_f1_tC(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 1, true, true, true, true, 0, 5, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P1_e_k2_tC(bool dh, bool pr, uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 1, false, true, dh, pr, 2, 0, 5, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P1_e_f2_tC(bool dh, bool pr, uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 1, true, dh, pr, false, 0, 5, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P2_n_k1(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 2, false, false, false, false, 1, 1, 0, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P2_n_k2(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 2, false, false, false, false, 2, 1, 0, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P2_n_f1(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 2, false, false, false, true, 1, 0, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P2_n_f2(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 2, false, false, false, false, 1, 0, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P2_e00_k1_tA(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 2, false, true, false, false, 1, 0, 6, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P2_e00_f1_tA(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 2, true, false, false, true, 0, 6, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P2_e01_k1_tA(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 2, false, true, false, true, 1, 0, 6, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P2_e01_f1_tA(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 2, true, false, true, true, 0, 6, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P2_e10_k1_tA(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 2, false, true, true, false, 1, 0, 6, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P2_e10_f1_tA(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 2, true, true, false, true, 0, 6, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P2_e11_k1_tA(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 2, false, true, true, true, 1, 0, 6, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P2_e11_f1_tA(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 2, true, true, true, true, 0, 6, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P2_e_k2_tA(bool dh, bool pr, uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 2, false, true, dh, pr, 2, 0, 6, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P2_e_f2_tA(bool dh, bool pr, uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 2, true, dh, pr, false, 0, 6, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P2_e00_k1_tB(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 2, false, true, false, false, 1, 0, 4, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P2_e00_f1_tB(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 2, true, false, false, true, 0, 4, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P2_e01_k1_tB(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 2, false, true, false, true, 1, 0, 4, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P2_e01_f1_tB(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 2, true, false, true, true, 0, 4, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P2_e10_k1_tB(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 2, false, true, true, false, 1, 0, 4, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P2_e10_f1_tB(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 2, true, true, false, true, 0, 4, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P2_e11_k1_tB(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 2, false, true, true, true, 1, 0, 4, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P2_e11_f1_tB(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 2, true, true, true, true, 0, 4, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P2_e_k2_tB(bool dh, bool pr, uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 2, false, true, dh, pr, 2, 0, 4, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P2_e_f2_tB(bool dh, bool pr, uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 2, true, dh, pr, false, 0, 4, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P2_e00_k1_tB1(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 2, false, true, false, false, 1, 0, 7, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P2_e00_f1_tB1(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 2, true, false, false, true, 0, 7, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P2_e01_k1_tB1(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 2, false, true, false, true, 1, 0, 7, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P2_e01_f1_tB1(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 2, true, false, true, true, 0, 7, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P2_e10_k1_tB1(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 2, false, true, true, false, 1, 0, 7, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P2_e10_f1_tB1(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 2, true, true, false, true, 0, 7, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P2_e11_k1_tB1(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 2, false, true, true, true, 1, 0, 7, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P2_e11_f1_tB1(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 2, true, true, true, true, 0, 7, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P2_e_k2_tB1(bool dh, bool pr, uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 2, false, true, dh, pr, 2, 0, 7, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P2_e_f2_tB1(bool dh, bool pr, uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 2, true, dh, pr, false, 0, 7, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P2_e00_k1_tB2(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 2, false, true, false, false, 1, 0, 8, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P2_e00_f1_tB2(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 2, true, false, false, true, 0, 8, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P2_e01_k1_tB2(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 2, false, true, false, true, 1, 0, 8, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P2_e01_f1_tB2(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 2, true, false, true, true, 0, 8, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P2_e10_k1_tB2(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 2, false, true, true, false, 1, 0, 8, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P2_e10_f1_tB2(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 2, true, true, false, true, 0, 8, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P2_e11_k1_tB2(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 2, false, true, true, true, 1, 0, 8, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P2_e11_f1_tB2(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 2, true, true, true, true, 0, 8, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P2_e_k2_tB2(bool dh, bool pr, uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 2, false, true, dh, pr, 2, 0, 8, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P2_e_f2_tB2(bool dh, bool pr, uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 2, true, dh, pr, false, 0, 8, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P2_e00_k1_tB3(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 2, false, true, false, false, 1, 0, 9, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P2_e00_f1_tB3(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 2, true, false, false, true, 0, 9, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P2_e01_k1_tB3(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 2, false, true, false, true, 1, 0, 9, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P2_e01_f1_tB3(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 2, true, false, true, true, 0, 9, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P2_e10_k1_tB3(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 2, false, true, true, false, 1, 0, 9, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P2_e10_f1_tB3(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 2, true, true, false, true, 0, 9, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P2_e11_k1_tB3(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 2, false, true, true, true, 1, 0, 9, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P2_e11_f1_tB3(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 2, true, true, true, true, 0, 9, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P2_e_k2_tB3(bool dh, bool pr, uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 2, false, true, dh, pr, 2, 0, 9, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P2_e_f2_tB3(bool dh, bool pr, uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 2, true, dh, pr, false, 0, 9, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P2_e00_k1_tB4(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 2, false, true, false, false, 1, 0, 10, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P2_e00_f1_tB4(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 2, true, false, false, true, 0, 10, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P2_e01_k1_tB4(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 2, false, true, false, true, 1, 0, 10, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P2_e01_f1_tB4(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 2, true, false, true, true, 0, 10, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P2_e10_k1_tB4(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 2, false, true, true, false, 1, 0, 10, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P2_e10_f1_tB4(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 2, true, true, false, true, 0, 10, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P2_e11_k1_tB4(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 2, false, true, true, true, 1, 0, 10, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P2_e11_f1_tB4(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 2, true, true, true, true, 0, 10, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P2_e_k2_tB4(bool dh, bool pr, uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 2, false, true, dh, pr, 2, 0, 10, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P2_e_f2_tB4(bool dh, bool pr, uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 2, true, dh, pr, false, 0, 10, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P2_e00_k1_tC(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 2, false, true, false, false, 1, 0, 5, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P2_e00_f1_tC(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 2, true, false, false, true, 0, 5, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P2_e01_k1_tC(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 2, false, true, false, true, 1, 0, 5, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P2_e01_f1_tC(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 2, true, false, true, true, 0, 5, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P2_e10_k1_tC(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 2, false, true, true, false, 1, 0, 5, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P2_e10_f1_tC(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 2, true, true, false, true, 0, 5, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P2_e11_k1_tC(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 2, false, true, true, true, 1, 0, 5, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P2_e11_f1_tC(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 2, true, true, true, true, 0, 5, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P2_e_k2_tC(bool dh, bool pr, uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, 2, false, true, dh, pr, 2, 0, 5, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_P2_e_f2_tC(bool dh, bool pr, uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(false, 2, true, dh, pr, false, 0, 5, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_P_upper(uint8 lPick, uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(false, lPick, true, false, false, false, 1, 1, 0, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_T0_n_k1(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(true, 0, false, false, false, false, 1, 1, 0, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_T0_n_k2(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(true, 0, false, false, false, false, 2, 1, 0, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_T0_n_f1(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(true, 0, false, false, false, true, 1, 0, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_T0_n_f2(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(true, 0, false, false, false, false, 1, 0, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_T0_e00_k1(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(true, 0, false, true, false, false, 1, 0, 0, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_T0_e00_f1(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(true, 0, true, false, false, true, 0, 0, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_T0_e01_k1(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(true, 0, false, true, false, true, 1, 0, 0, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_T0_e01_f1(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(true, 0, true, false, true, true, 0, 0, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_T0_e10_k1(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(true, 0, false, true, true, false, 1, 0, 0, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_T0_e10_f1(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(true, 0, true, true, false, true, 0, 0, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_T0_e11_k1(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(true, 0, false, true, true, true, 1, 0, 0, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_T0_e11_f1(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(true, 0, true, true, true, true, 0, 0, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_T0_e_k2(bool dh, bool pr, uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(true, 0, false, true, dh, pr, 2, 0, 0, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_T0_e_f2(bool dh, bool pr, uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(true, 0, true, dh, pr, false, 0, 0, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_T1_n_k1(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(true, 1, false, false, false, false, 1, 1, 0, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_T1_n_k2(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(true, 1, false, false, false, false, 2, 1, 0, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_T1_n_f1(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(true, 1, false, false, false, true, 1, 0, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_T1_n_f2(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(true, 1, false, false, false, false, 1, 0, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_T1_e00_k1(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(true, 1, false, true, false, false, 1, 0, 0, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_T1_e00_f1(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(true, 1, true, false, false, true, 0, 0, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_T1_e01_k1(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(true, 1, false, true, false, true, 1, 0, 0, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_T1_e01_f1(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(true, 1, true, false, true, true, 0, 0, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_T1_e10_k1(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(true, 1, false, true, true, false, 1, 0, 0, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_T1_e10_f1(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(true, 1, true, true, false, true, 0, 0, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_T1_e11_k1(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(true, 1, false, true, true, true, 1, 0, 0, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_T1_e11_f1(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(true, 1, true, true, true, true, 0, 0, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_T1_e_k2(bool dh, bool pr, uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(true, 1, false, true, dh, pr, 2, 0, 0, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_T1_e_f2(bool dh, bool pr, uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(true, 1, true, dh, pr, false, 0, 0, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_T2_n_k1(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(true, 2, false, false, false, false, 1, 1, 0, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_T2_n_k2(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(true, 2, false, false, false, false, 2, 1, 0, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_T2_n_f1(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(true, 2, false, false, false, true, 1, 0, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_T2_n_f2(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(true, 2, false, false, false, false, 1, 0, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_T2_e00_k1(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(true, 2, false, true, false, false, 1, 0, 0, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_T2_e00_f1(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(true, 2, true, false, false, true, 0, 0, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_T2_e01_k1(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(true, 2, false, true, false, true, 1, 0, 0, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_T2_e01_f1(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(true, 2, true, false, true, true, 0, 0, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_T2_e10_k1(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(true, 2, false, true, true, false, 1, 0, 0, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_T2_e10_f1(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(true, 2, true, true, false, true, 0, 0, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_T2_e11_k1(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(true, 2, false, true, true, true, 1, 0, 0, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_T2_e11_f1(uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(true, 2, true, true, true, true, 0, 0, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_T2_e_k2(bool dh, bool pr, uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(true, 2, false, true, dh, pr, 2, 0, 0, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVs_T2_e_f2(bool dh, bool pr, uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _ps(true, 2, true, dh, pr, false, 0, 0, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }

    function check_WRVq_T_upper(uint8 lPick, uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t, uint256 value, uint8 callerPick, uint8 ownerPick) public {
        _pq(true, lPick, true, false, false, false, 1, 1, 0, Q(exp, epoch, dep, held, t, value, callerPick, ownerPick));
    }
}

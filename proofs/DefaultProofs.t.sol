// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {PageCard} from "../src/PageCard.sol";
import {PageNFT} from "../src/PageNFT.sol";
import {DefaultHarness} from "./DefaultHarness.sol";

/// @notice Symbolic proofs for the default address of every EVM chain, coin type 0x80000000. The start state is
/// built through the harness: one top level name, any holder of three code kinds, any saved main address and saver,
/// any record version, any own entry and default entry with any savers, any time.
/// Halmos: FOUNDRY_PROFILE=proofs halmos --contract DefaultProofsTest --function test_check_DA --forge-build-out out-proofs --loop 4 --storage-layout generic
/// The start state and the model are in DefaultProofsBase, which holds no proof, so that the proof contracts built on it
/// inherit no proof of another.
abstract contract DefaultProofsBase is Test {
    PageCard card;
    DefaultHarness n;

    // a holder with no code, one with an EIP7702 designator and one with regular code
    address constant KEY = address(0xA11CE);
    address constant SEVEN = address(0x5E7E);
    address constant CODE = address(0xC0DE);
    address constant OTHER = address(0x07E2);
    uint256 constant COIN_ETH = 60;
    uint256 constant COIN_OP = 0x8000000a;
    uint256 constant DEFAULT_EVM = 0x80000000;
    bytes32 constant ROOT = 0x62460c06d95b73747abf6ea4f28aefd78b4ad2abee112e7cf15fe6a924cca3c6;

    uint256 id;

    function setUp() public {
        card = new PageCard();
        n = new DefaultHarness(card);
        id = uint256(keccak256(abi.encodePacked(ROOT, keccak256(bytes("club")))));
        vm.etch(SEVEN, abi.encodePacked(hex"ef0100", address(0xBEEF)));
        vm.etch(CODE, hex"6001600155");
    }

    function _pick(uint8 p) internal pure returns (address) {
        uint8 k = p % 4;
        if (k == 0) return KEY;
        if (k == 1) return SEVEN;
        if (k == 2) return CODE;
        return OTHER;
    }

    function _enc(address a) internal pure returns (bytes memory) {
        return a == address(0) ? bytes("") : abi.encodePacked(a);
    }

    function _eqB(bytes memory x, bytes memory y) internal pure returns (bool) {
        return keccak256(x) == keccak256(y);
    }

    struct W {
        uint64 exp;
        address holder;
        address saved;
        address addrSaver;
        uint64 rv;
        address ownSaver;
        address ownVal;
        address defSaver;
        address defVal;
    }

    function _world(W memory w, uint256 coinType) internal {
        n.h_setRecord(id, "club", 0, w.exp, 1, 0);
        n.h_setDeposit(id, 1);
        n.h_mint(w.holder, id);
        n.h_setVersion(id, w.rv);
        n.h_setResolved(id, w.saved, w.addrSaver);
        n.h_setCoin(id, DEFAULT_EVM, w.defSaver, w.defVal);
        if (coinType != DEFAULT_EVM) n.h_setCoin(id, coinType, w.ownSaver, w.ownVal);
    }

    function _main(W memory w) internal pure returns (address) {
        return (w.saved != address(0) && w.addrSaver == w.holder) ? w.saved : w.holder;
    }

    // the answer for an EVM coin type other than the home chain's, computed from the start state alone: the code at
    // the holder or at the main address never changes it
    function _model(W memory w, uint256 coinType, uint64 ts) internal pure returns (bytes memory) {
        if (ts > w.exp) return "";
        address a;
        if (coinType != DEFAULT_EVM && w.ownSaver == w.holder) a = w.ownVal;
        if (a == address(0) && w.defSaver == w.holder) a = w.defVal;
        return _enc(a);
    }

    function _w(uint64 exp, uint8 hPick, uint8 mPick, uint8 asPick, uint64 rv, uint8 osPick, address ownVal,
        uint8 dsPick, address defVal) internal pure returns (W memory)
    {
        return W(exp, _pick(hPick), _pick(mPick), _pick(asPick), rv, _pick(osPick), ownVal, _pick(dsPick), defVal);
    }

}

contract DefaultProofsTest is DefaultProofsBase {
    /// @notice DA1: for any start state, time and EVM coin type c other than the home chain's and the default, addr(c)
    /// is the holder's own entry for c, else the holder's saved default, else empty, whatever code the holder and the
    /// main address have, and empty while the page is not active. When the own entry does not count, addr(c) equals
    /// addr(0x80000000). No value saved by an account other than the holder is ever answered.
    /// @dev Technique: built symbolic state, exact characterization of a view. Classification: DIRECT.
    function test_check_DA1_answerRule(
        uint64 exp, uint8 hPick, uint8 mPick, uint8 asPick, uint64 rv, uint8 osPick, address ownVal, uint8 dsPick,
        address defVal, uint256 coinType, uint64 ts
    ) public {
        vm.assume(coinType == COIN_ETH || (coinType > DEFAULT_EVM && coinType <= 0xffffffff));
        vm.assume(coinType != COIN_OP);
        W memory w = _w(exp, hPick, mPick, asPick, rv, osPick, ownVal, dsPick, defVal);
        _world(w, coinType);
        vm.warp(ts);
        bytes memory got = n.addr(id, coinType);
        assert(_eqB(got, _model(w, coinType, ts)));
        assert(_eqB(n.addr(bytes32(id), coinType), got));
        if (w.ownSaver != w.holder || w.ownVal == address(0)) assert(_eqB(got, n.addr(id, DEFAULT_EVM)));
    }

    /// @notice DA1d: for any start state and time, addr(0x80000000) is the holder's saved default, else empty, whatever
    /// code the holder and the main address have, and empty while the page is not active.
    /// @dev Technique: built symbolic state, exact characterization of a view. Classification: DIRECT.
    function test_check_DA1d_defaultRule(
        uint64 exp, uint8 hPick, uint8 mPick, uint8 asPick, uint64 rv, uint8 dsPick, address defVal, uint64 ts
    ) public {
        W memory w = _w(exp, hPick, mPick, asPick, rv, 0, address(0), dsPick, defVal);
        _world(w, DEFAULT_EVM);
        vm.warp(ts);
        assert(_eqB(n.addr(id, DEFAULT_EVM), _model(w, DEFAULT_EVM, ts)));
    }

    /// @notice DA4: for any start state and time, the default never changes the OP answer, resolve or the payee:
    /// they are the main address whatever is saved for 0x80000000. With no entry of its own for coin type 60,
    /// addr(node) and addr(60) are the holder's saved default, else zero, and zero while the page is not active.
    /// @dev Technique: built symbolic state. Classification: DIRECT.
    function test_check_DA4_mainIgnoresDefault(
        uint64 exp, uint8 hPick, uint8 mPick, uint8 asPick, uint64 rv, uint8 dsPick, address defVal, uint64 ts
    ) public {
        W memory w = _w(exp, hPick, mPick, asPick, rv, 0, address(0), dsPick, defVal);
        _world(w, DEFAULT_EVM);
        vm.warp(ts);
        address main = ts > w.exp ? address(0) : _main(w);
        assert(_eqB(n.addr(id, COIN_OP), _enc(main)));
        assert(n.resolve(id) == main);
        address eth = ts > w.exp ? address(0) : (w.defSaver == w.holder ? w.defVal : address(0));
        assert(n.addr(bytes32(id)) == eth);
        assert(_eqB(n.addr(id, COIN_ETH), _enc(eth)));
        address p = _main(w);
        assert(n.payee(id) == p);
    }

    /// @notice DA5: for any start state and time, with an entry of its own for coin type 60 saved by any account,
    /// addr(node) is the coin type 60 answer: the holder's own entry for 60, else the holder's saved default, else
    /// zero, and zero while the page is not active. It always equals the 20 bytes of addr(id, 60).
    /// @dev Technique: built symbolic state, exact characterization of a view. Classification: DIRECT.
    function test_check_DA5_addrNodeIsCoin60(
        uint64 exp, uint8 hPick, uint8 mPick, uint8 asPick, uint64 rv, uint8 osPick, address ownVal, uint8 dsPick,
        address defVal, uint64 ts
    ) public {
        W memory w = _w(exp, hPick, mPick, asPick, rv, osPick, ownVal, dsPick, defVal);
        _world(w, COIN_ETH);
        vm.warp(ts);
        address got = n.addr(bytes32(id));
        assert(got == address(bytes20(_model(w, COIN_ETH, ts))));
        assert(got == address(bytes20(n.addr(id, COIN_ETH))));
    }

    /// @notice DA2: for any start state, time, caller and value, setAddrForCoin(id, 0x80000000, value) succeeds only
    /// when the name is active, the caller holds it and the value is 0 or 20 bytes. Then the default entry is the
    /// caller with the value, twenty zero bytes stored as empty, and these do not move: the holder, the record
    /// version, the main address, the payee, the OP answer, the profile writer and another coin type's entry. The
    /// answers that follow the default, addr(node) and coin type 60 among them, and addressesUpdatedAt can move.
    /// @dev Technique: built symbolic state, one symbolic call. Classification: DIRECT.
    function test_check_DA2_onlyHolderWrites(
        uint64 exp, uint8 hPick, uint8 mPick, uint8 asPick, uint64 rv, uint8 osPick, address ownVal, uint8 dsPick,
        address defVal, uint256 otherCoin, uint64 ts, address caller, uint8 lenPick, bytes32 raw
    ) public {
        vm.assume(otherCoin != DEFAULT_EVM);
        W memory w = _w(exp, hPick, mPick, asPick, rv, osPick, ownVal, dsPick, defVal);
        _world(w, otherCoin);
        vm.warp(ts);
        uint256 len = lenPick % 4 == 0 ? 0 : lenPick % 4 == 1 ? 20 : lenPick % 4 == 2 ? 21 : 1;
        bytes memory v = new bytes(len);
        for (uint256 i; i < len; ++i) v[i] = raw[i];
        (address oSaver, bytes memory oVal) = n.h_entry(id, otherCoin);
        (address pw, uint96 pv) = n.h_profile(id);
        bytes memory opBefore = n.addr(id, COIN_OP);
        address resolveBefore = n.resolve(id);
        address payeeBefore = n.payee(id);

        vm.prank(caller);
        (bool ok,) = address(n).call(abi.encodeCall(PageNFT.setAddrForCoin, (id, DEFAULT_EVM, v)));
        if (ok) {
            assert(ts <= w.exp && caller == w.holder && (len == 0 || len == 20));
            (address dSaver, bytes memory dVal) = n.h_entry(id, DEFAULT_EVM);
            assert(dSaver == caller);
            bool zero = len == 0 || bytes20(raw) == bytes20(0);
            assert(_eqB(dVal, zero ? bytes("") : v));
        } else {
            assert(ts > w.exp || caller != w.holder || (len != 0 && len != 20));
        }
        assert(n.h_ownerOf(id) == w.holder);
        assert(n.recordVersion(id) == w.rv);
        assert(n.resolve(id) == resolveBefore);
        assert(n.payee(id) == payeeBefore);
        assert(_eqB(n.addr(id, COIN_OP), opBefore));
        (address pw2, uint96 pv2) = n.h_profile(id);
        assert(pw2 == pw && pv2 == pv);
        (address oSaver2, bytes memory oVal2) = n.h_entry(id, otherCoin);
        assert(oSaver2 == oSaver && _eqB(oVal2, oVal));
    }

    /// @notice DA3: for any start state, caller and value, setAddrForCoin for any coin type other than 0x80000000
    /// leaves the default entry as it was.
    /// @dev Technique: built symbolic state, one symbolic call. Classification: DIRECT.
    function test_check_DA3_otherCoinsKeepTheDefault(
        uint64 exp, uint8 hPick, uint8 mPick, uint8 asPick, uint64 rv, uint8 dsPick, address defVal, uint256 coinType,
        uint64 ts, address caller, address value, bool empty
    ) public {
        vm.assume(coinType != DEFAULT_EVM);
        W memory w = _w(exp, hPick, mPick, asPick, rv, 0, address(0), dsPick, defVal);
        _world(w, DEFAULT_EVM);
        vm.warp(ts);
        (address s0, bytes memory v0) = n.h_entry(id, DEFAULT_EVM);
        vm.prank(caller);
        (bool ok,) = address(n).call(
            abi.encodeCall(PageNFT.setAddrForCoin, (id, coinType, empty ? bytes("") : abi.encodePacked(value)))
        );
        ok;
        (address s1, bytes memory v1) = n.h_entry(id, DEFAULT_EVM);
        assert(s1 == s0 && _eqB(v1, v0));
    }
}

// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {DefaultProofsBase} from "./DefaultProofs.t.sol";

/// @notice DA1 of DefaultProofsTest and DA1n of DefaultNonEvmProofsTest, written so that their result does not depend
/// on solver timing. Halmos 0.3.3 decides which earlier store a storage read meets with a solver query limited to 1 ms.
/// The start state writes the default entry, then the entry of the symbolic coin type. That second save reads the old
/// value of its entry to clean up a long one, and the read passes the default entry's stores: telling the two keys apart
/// needs the solver. If the query times out, the read stays symbolic, and the clean-up loop of a long old value has a
/// symbolic bound and hits the loop bound (DA1n did once). In this start state the entry of the coin type was never
/// written, so its two words are zero. The proofs check that and write the zeros again, which changes no state. The
/// save's reads then meet that store by its key alone, and so do the views' reads of the coin type's entry afterwards.
/// That needs the test and the harness to build the key from the same term. Once a path holds coinType == c for a
/// constant c, Halmos 0.3.3 hands c to every later call that reads coinType from its calldata, while the test still
/// holds coinType. DA1's first assumption branches on coinType == 60, so DA1 is split there into two proofs that
/// together cover its coin types: DA1r60 fixes the coin type at 60 in the test too, and DA1rHi takes 0x80000001 to
/// 0xffffffff with assumptions that hold no equality. DA1nr's assumption holds no equality either, so it needs no
/// split. In DA1r60 every key is built from constants and the record version, and keys of different coin types
/// simplify apart without the solver. In DA1rHi the views' reads of the default entry still pass the stores of the
/// coin type's entry and need the solver; each turns the value into 20 bytes with no copy and no loop, so a timeout
/// there leaves only words for the assertion solver.
/// Halmos: FOUNDRY_PROFILE=proofs halmos --contract DefaultAnswerProofsTest --function test_check_DA1 --forge-build-out out-proofs --loop 4 --storage-layout generic
contract DefaultAnswerProofsTest is DefaultProofsBase {
    // _coinAddr is slot 9 of PageNFT and of DefaultHarness (forge inspect DefaultHarness storageLayout); an entry is
    // two words: the saver, then the value
    uint256 constant COIN_ADDR_SLOT = 9;

    // the first word of the entry for coinType at the current record version, as h_setCoin and the views find it
    function _entrySlot(uint256 coinType) internal view returns (bytes32) {
        uint256 v = n.recordVersion(id);
        return keccak256(abi.encode(coinType, keccak256(abi.encode(v, keccak256(abi.encode(id, COIN_ADDR_SLOT))))));
    }

    // the two words of an entry: the saver, then the value
    function _words(bytes32 b) internal view returns (uint256 saverWord, uint256 valueWord) {
        saverWord = uint256(vm.load(address(n), b));
        unchecked {
            valueWord = uint256(vm.load(address(n), bytes32(uint256(b) + 1)));
        }
    }

    // _world of DefaultProofsBase: the same writes in the same order, with one more step before the entry of the coin
    // type is written. _world writes no entry but the default before it, so both words of that entry are zero; they
    // are checked, then written as zero again, which leaves every slot as it was. After the save, the first word of the
    // entry is checked to hold its saver, so the slot written as zero is the one the harness and the views use.
    function _worldR(W memory w, uint256 coinType) internal {
        n.h_setRecord(id, "club", 0, w.exp, 1, 0);
        n.h_setDeposit(id, 1);
        n.h_mint(w.holder, id);
        n.h_setVersion(id, w.rv);
        n.h_setResolved(id, w.saved, w.addrSaver);
        n.h_setCoin(id, DEFAULT_EVM, w.defSaver, w.defVal);
        if (coinType != DEFAULT_EVM) {
            bytes32 cs = _entrySlot(coinType);
            (uint256 c0, uint256 c1) = _words(cs);
            assert(c0 == 0 && c1 == 0);
            vm.store(address(n), cs, bytes32(0));
            unchecked {
                vm.store(address(n), bytes32(uint256(cs) + 1), bytes32(0));
            }
            n.h_setCoin(id, coinType, w.ownSaver, w.ownVal);
            assert(uint256(vm.load(address(n), cs)) == uint160(w.ownSaver));
        }
    }

    /// @notice DA1r60: DA1 for coin type 60. For any start state and time, addr(60) is the holder's own entry for 60,
    /// else the holder's saved default, else empty, whatever code the holder and the main address have, and empty while
    /// the page is not active. When the own entry does not count, addr(60) equals addr(0x80000000). No value saved by
    /// an account other than the holder is ever answered.
    /// @dev The inputs, assumptions and assertions of DA1 with coinType fixed at 60 (both assumptions of DA1 then
    /// hold), on the same start state built by _worldR. With DA1rHi it covers every coin type of DA1.
    /// Technique: built symbolic state, exact characterization of a view. Classification: DIRECT.
    function test_check_DA1r60_answerRule(
        uint64 exp, uint8 hPick, uint8 mPick, uint8 asPick, uint64 rv, uint8 osPick, address ownVal, uint8 dsPick,
        address defVal, uint64 ts
    ) public {
        uint256 coinType = COIN_ETH;
        vm.assume(coinType == COIN_ETH || (coinType > DEFAULT_EVM && coinType <= 0xffffffff));
        vm.assume(coinType != COIN_OP);
        W memory w = _w(exp, hPick, mPick, asPick, rv, osPick, ownVal, dsPick, defVal);
        _worldR(w, coinType);
        vm.warp(ts);
        bytes memory got = n.addr(id, coinType);
        assert(_eqB(got, _model(w, coinType, ts)));
        assert(_eqB(n.addr(bytes32(id), coinType), got));
        if (w.ownSaver != w.holder || w.ownVal == address(0)) assert(_eqB(got, n.addr(id, DEFAULT_EVM)));
    }

    /// @notice DA1rHi: DA1 for the EVM coin types above the default. For any start state, time and coin type c from
    /// 0x80000001 to 0xffffffff other than the home chain's, addr(c) is the holder's own entry for c, else the holder's
    /// saved default, else empty, whatever code the holder and the main address have, and empty while the page is not
    /// active. When the own entry does not count, addr(c) equals addr(0x80000000). No value saved by an account other
    /// than the holder is ever answered.
    /// @dev The inputs, assumptions and assertions of DA1 without coin type 60, on the same start state built by
    /// _worldR. Its first assumption is the second half of DA1's first one. With DA1r60 it covers every coin type of DA1.
    /// Technique: built symbolic state, exact characterization of a view. Classification: DIRECT.
    function test_check_DA1rHi_answerRule(
        uint64 exp, uint8 hPick, uint8 mPick, uint8 asPick, uint64 rv, uint8 osPick, address ownVal, uint8 dsPick,
        address defVal, uint256 coinType, uint64 ts
    ) public {
        vm.assume(coinType > DEFAULT_EVM && coinType <= 0xffffffff);
        vm.assume(coinType != COIN_OP);
        W memory w = _w(exp, hPick, mPick, asPick, rv, osPick, ownVal, dsPick, defVal);
        _worldR(w, coinType);
        vm.warp(ts);
        bytes memory got = n.addr(id, coinType);
        assert(_eqB(got, _model(w, coinType, ts)));
        assert(_eqB(n.addr(bytes32(id), coinType), got));
        if (w.ownSaver != w.holder || w.ownVal == address(0)) assert(_eqB(got, n.addr(id, DEFAULT_EVM)));
    }

    /// @notice DA1nr: for any start state, time and coin type outside the EVM (neither 60 nor 0x80000000 to
    /// 0xffffffff), addr(c) is the holder's own entry for c, else empty, and empty while the name is not active,
    /// whatever the saved default and the main address.
    /// @dev The inputs, assumptions and assertions of DA1n, on the same start state built by _worldR.
    /// Technique: built symbolic state, exact characterization of a view. Classification: DIRECT.
    function test_check_DA1nr_noFallbackOutsideTheEvm(
        uint64 exp, uint8 hPick, uint8 mPick, uint8 asPick, uint64 rv, uint8 osPick, address ownVal, uint8 dsPick,
        address defVal, uint256 coinType, uint64 ts
    ) public {
        vm.assume(coinType != COIN_ETH && (coinType < DEFAULT_EVM || coinType > 0xffffffff));
        W memory w = _w(exp, hPick, mPick, asPick, rv, osPick, ownVal, dsPick, defVal);
        _worldR(w, coinType);
        vm.warp(ts);
        bytes memory want = (ts <= w.exp && w.ownSaver == w.holder) ? _enc(w.ownVal) : bytes("");
        assert(_eqB(n.addr(id, coinType), want));
        assert(_eqB(n.addr(bytes32(id), coinType), want));
    }
}

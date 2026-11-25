// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {DefaultProofsBase} from "./DefaultProofs.t.sol";

/// @notice DA2z and DA2e (the frame of a save of the default by the holder, of 20 bytes and empty, one holder kind
/// per query), written so that their result does not depend on solver timing. Halmos 0.3.3 decides which earlier store
/// a storage read meets with a solver query limited to 1 ms. Telling the default entry from the entry of the symbolic
/// coin type needs such a query, and under load it can time out. The read then stays symbolic, and three places of
/// DA2z and DA2e turn that into a warning or an error:
/// - building the start state, the harness saves the other coin type's entry after the default entry. Its read of the
///   old value, to clean up a long one, passes the default entry's stores; if it stays symbolic, the clean-up loop has
///   a symbolic bound and hits the loop bound.
/// - inside the call, the save of the default reads its old value the same way, passing the other entry's stores.
/// - after the call, h_entry of the other coin type passes the default entry's new stores. If its read stays symbolic,
///   h_entry copies a symbolic length to memory and the run ends in NotConcreteError.
/// Here the start state is the same, built by the same harness calls in the same order, and each entry's two words
/// are written again, as the values they hold, right before the reads that would pass the other entry: the other coin
/// type's entry, never written before, as its zeros before the harness saves it, and the default entry as its words
/// before the call. Each such store is preceded by an assertion that the slot already holds that value, so no state
/// changes; a read then meets the store by its key alone. After the call the other coin type's entry is read as its two
/// storage words, which copies nothing to memory, and compared with its words before the call, which are checked to be
/// the entry h_entry reads. A read that stays symbolic now only gives the assertion solver a word. The only other reads
/// that pass the other entry are those of coin type 60 inside the call, which the other coin type may be: their result
/// is symbolic whatever the solver answers, and they decide only branches, with no loop and no copy to memory.
/// Halmos: FOUNDRY_PROFILE=proofs halmos --contract DefaultFrameWordsProofsTest --function test_check_DA2z --forge-build-out out-proofs --loop 4 --storage-layout generic
/// Halmos: FOUNDRY_PROFILE=proofs halmos --contract DefaultFrameEmptyWordsProofsTest --function test_check_DA2e --forge-build-out out-proofs --loop 4 --storage-layout generic
abstract contract DefaultFrameWordsBase is DefaultProofsBase {
    // _coinAddr is slot 9 of PageNFT and of DefaultHarness (forge inspect DefaultHarness storageLayout); an entry is
    // two words: the saver, then the value
    uint256 constant COIN_ADDR_SLOT = 9;

    // the first word of the entry for coinType at the current record version, as setAddrForCoin and h_entry find it
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

    // writes the two words of an entry
    function _put(bytes32 b, uint256 saverWord, uint256 valueWord) internal {
        vm.store(address(n), b, bytes32(saverWord));
        unchecked {
            vm.store(address(n), bytes32(uint256(b) + 1), bytes32(valueWord));
        }
    }

    struct Pre {
        address oSaver;
        bytes oVal;
        uint256 o0;
        uint256 o1;
        address pw;
        uint96 pv;
        address main;
    }

    // _world(w, otherCoin) and the reads DA2z and DA2e make before the call, with the entries written again as above.
    // Ends with the default entry's words written again, so the call must follow with no other read of an entry.
    function _before(W memory w, uint256 otherCoin, uint64 ts) internal returns (Pre memory p) {
        n.h_setRecord(id, "club", 0, w.exp, 1, 0);
        n.h_setDeposit(id, 1);
        n.h_mint(w.holder, id);
        n.h_setVersion(id, w.rv);
        n.h_setResolved(id, w.saved, w.addrSaver);
        n.h_setCoin(id, DEFAULT_EVM, w.defSaver, w.defVal);
        bytes32 ds = _entrySlot(DEFAULT_EVM);
        bytes32 os = _entrySlot(otherCoin);
        // the default entry's words, read while its own stores are the latest
        (uint256 d0, uint256 d1) = _words(ds);
        // the other coin type's entry was never written, so both of its words are zero. Writing them as zero again
        // leaves every slot as it was, and the harness's read of the old value below meets that store.
        {
            (uint256 c0, uint256 c1) = _words(os);
            assert(c0 == 0 && c1 == 0);
        }
        _put(os, 0, 0);
        n.h_setCoin(id, otherCoin, w.ownSaver, w.ownVal);
        vm.warp(ts);
        (p.oSaver, p.oVal) = n.h_entry(id, otherCoin);
        // the words are the entry h_entry reads: the saver, and a value of 0 or 20 bytes in the short form, so equal
        // words after the call mean an equal saver and equal bytes
        (p.o0, p.o1) = _words(os);
        assert(p.o0 == uint160(p.oSaver));
        assert(p.oVal.length == 0 || p.oVal.length == 20);
        assert(p.o1 == (p.oVal.length == 0 ? 0 : uint256(bytes32(bytes20(p.oVal))) | 40));
        (p.pw, p.pv) = n.h_profile(id);
        p.main = _main(w);
        // the other coin type's save left the default entry as it was; writing its words again leaves every slot as it
        // was, and the call's reads of the default entry meet that store
        {
            (uint256 e0, uint256 e1) = _words(ds);
            assert(e0 == d0 && e1 == d1);
        }
        _put(ds, d0, d1);
    }

    // the assertions of DA2z and DA2e after the call, with the other coin type's entry compared as its two words
    function _after(Pre memory p, address holder, uint64 rv, uint256 otherCoin, bytes memory want) internal view {
        assert(n.h_ownerOf(id) == holder);
        assert(n.recordVersion(id) == rv);
        assert(n.resolve(id) == p.main);
        assert(n.payee(id) == p.main);
        assert(_eqB(n.addr(id, COIN_OP), _enc(p.main)));
        (address pw2, uint96 pv2) = n.h_profile(id);
        assert(pw2 == p.pw && pv2 == p.pv);
        (uint256 o0b, uint256 o1b) = _words(_entrySlot(otherCoin));
        assert(o0b == p.o0 && o1b == p.o1);
        (address dSaver, bytes memory dVal) = n.h_entry(id, DEFAULT_EVM);
        assert(dSaver == holder && _eqB(dVal, want));
    }
}

/// @notice DA2z1r to DA2z3r: DA2z of DefaultFrameProofsTest, the frame of a 20 byte save of the default by the holder,
/// with the same inputs, assumptions and assertions, built as DefaultFrameWordsBase says.
contract DefaultFrameWordsProofsTest is DefaultFrameWordsBase {
    function _frame(address holder, bool savedMain, uint64 exp, uint64 rv, uint8 osPick, address ownVal, uint8 dsPick,
        address defVal, uint256 otherCoin, uint64 ts, address value) internal
    {
        vm.assume(otherCoin != DEFAULT_EVM);
        vm.assume(ts <= exp);
        W memory w = W(exp, holder, savedMain ? OTHER : address(0), holder, rv, _pick(osPick), ownVal, _pick(dsPick), defVal);
        Pre memory p = _before(w, otherCoin, ts);
        vm.prank(holder);
        n.setAddrForCoin(id, DEFAULT_EVM, abi.encodePacked(value));
        _after(p, holder, rv, otherCoin, value == address(0) ? bytes("") : abi.encodePacked(value));
    }

    /// @notice DA2z1r: the holder has no code.
    /// @dev Technique: built symbolic state, one symbolic call, raw slot reads checked against h_entry before the
    /// call, and each entry written again as the words it holds before the reads that pass the other entry.
    /// Classification: DIRECT.
    function test_check_DA2z1r_keyHolder(bool savedMain, uint64 exp, uint64 rv, uint8 osPick, address ownVal,
        uint8 dsPick, address defVal, uint256 otherCoin, uint64 ts, address value) public
    {
        _frame(KEY, savedMain, exp, rv, osPick, ownVal, dsPick, defVal, otherCoin, ts, value);
    }

    /// @notice DA2z2r: the holder has an EIP7702 designator.
    /// @dev Technique and classification as DA2z1r.
    function test_check_DA2z2r_sevenHolder(bool savedMain, uint64 exp, uint64 rv, uint8 osPick, address ownVal,
        uint8 dsPick, address defVal, uint256 otherCoin, uint64 ts, address value) public
    {
        _frame(SEVEN, savedMain, exp, rv, osPick, ownVal, dsPick, defVal, otherCoin, ts, value);
    }

    /// @notice DA2z3r: the holder has regular code.
    /// @dev Technique and classification as DA2z1r.
    function test_check_DA2z3r_codeHolder(bool savedMain, uint64 exp, uint64 rv, uint8 osPick, address ownVal,
        uint8 dsPick, address defVal, uint256 otherCoin, uint64 ts, address value) public
    {
        _frame(CODE, savedMain, exp, rv, osPick, ownVal, dsPick, defVal, otherCoin, ts, value);
    }
}

/// @notice DA2e1r to DA2e3r: DA2e of DefaultFrameEmptyAnyCoinProofsTest, the frame of an empty save of the default by
/// the holder, for any other coin type, with the same inputs, assumptions and assertions, built as
/// DefaultFrameWordsBase says.
contract DefaultFrameEmptyWordsProofsTest is DefaultFrameWordsBase {
    function _frame(address holder, bool savedMain, uint64 exp, uint64 rv, uint8 osPick, address ownVal, uint8 dsPick,
        address defVal, uint256 otherCoin, uint64 ts) internal
    {
        vm.assume(otherCoin != DEFAULT_EVM);
        vm.assume(ts <= exp);
        W memory w = W(exp, holder, savedMain ? OTHER : address(0), holder, rv, _pick(osPick), ownVal, _pick(dsPick), defVal);
        Pre memory p = _before(w, otherCoin, ts);
        vm.prank(holder);
        n.setAddrForCoin(id, DEFAULT_EVM, "");
        _after(p, holder, rv, otherCoin, bytes(""));
    }

    /// @notice DA2e1r: the holder has no code.
    /// @dev Technique: built symbolic state, one symbolic call, raw slot reads checked against h_entry before the
    /// call, and each entry written again as the words it holds before the reads that pass the other entry.
    /// Classification: DIRECT.
    function test_check_DA2e1r_keyHolder(bool savedMain, uint64 exp, uint64 rv, uint8 osPick, address ownVal,
        uint8 dsPick, address defVal, uint256 otherCoin, uint64 ts) public
    {
        _frame(KEY, savedMain, exp, rv, osPick, ownVal, dsPick, defVal, otherCoin, ts);
    }

    /// @notice DA2e2r: the holder has an EIP7702 designator.
    /// @dev Technique and classification as DA2e1r.
    function test_check_DA2e2r_sevenHolder(bool savedMain, uint64 exp, uint64 rv, uint8 osPick, address ownVal,
        uint8 dsPick, address defVal, uint256 otherCoin, uint64 ts) public
    {
        _frame(SEVEN, savedMain, exp, rv, osPick, ownVal, dsPick, defVal, otherCoin, ts);
    }

    /// @notice DA2e3r: the holder has regular code.
    /// @dev Technique and classification as DA2e1r.
    function test_check_DA2e3r_codeHolder(bool savedMain, uint64 exp, uint64 rv, uint8 osPick, address ownVal,
        uint8 dsPick, address defVal, uint256 otherCoin, uint64 ts) public
    {
        _frame(CODE, savedMain, exp, rv, osPick, ownVal, dsPick, defVal, otherCoin, ts);
    }
}

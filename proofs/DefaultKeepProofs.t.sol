// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {PageNFT} from "../src/PageNFT.sol";
import {DefaultProofsBase} from "./DefaultProofs.t.sol";

/// @notice DA3 of DefaultProofsTest, written so that its result does not depend on solver timing. Halmos 0.3.3 decides
/// which earlier store a storage read meets with a solver query limited to 1 ms. Under a symbolic coin type two such
/// queries can time out, and both are taken out of the path here:
/// - after the call, a read of the default entry passes the save to the symbolic entry. If it stays symbolic, h_entry,
///   which copies the stored bytes to memory, ends in NotConcreteError (a symbolic memory offset). DA3r reads the
///   default entry after the call as its two storage words, which copies nothing to memory.
/// - inside the call, the save reads the old value of the symbolic entry to clean up a long one. That read passes the
///   default entry's store from the start state. If it stays symbolic, the clean-up loop has a symbolic bound and hits
///   the loop bound. In this start state the symbolic entry was never written, so its two words are zero; DA3r checks
///   that and writes the zeros again, which changes no state. The save's read then meets that store by its key alone.
///   OP is left out of this: its save writes the main address and no entry, and the only entries it reads, coin type
///   60 and the default, have fixed keys.
/// Halmos: FOUNDRY_PROFILE=proofs halmos --contract DefaultKeepProofsTest --function test_check_DA3r --forge-build-out out-proofs --loop 4 --storage-layout generic
contract DefaultKeepProofsTest is DefaultProofsBase {
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

    /// @notice DA3r: for any start state, caller and value, setAddrForCoin for any coin type other than 0x80000000
    /// leaves the default entry as it was: both of its storage words, the saver and the value, are unchanged.
    /// @dev Technique: built symbolic state, one symbolic call, raw slot reads checked against h_entry before the call,
    /// and for a coin type other than OP the never written entry written again as the zeros it holds.
    /// Classification: DIRECT.
    function test_check_DA3r_otherCoinsKeepTheDefault(
        uint64 exp, uint8 hPick, uint8 mPick, uint8 asPick, uint64 rv, uint8 dsPick, address defVal, uint256 coinType,
        uint64 ts, address caller, address value, bool empty
    ) public {
        vm.assume(coinType != DEFAULT_EVM);
        W memory w = _w(exp, hPick, mPick, asPick, rv, 0, address(0), dsPick, defVal);
        _world(w, DEFAULT_EVM);
        vm.warp(ts);
        // the default entry is read before the coin type's words are written below, so that these reads meet the
        // default entry's own stores first
        (address s0, bytes memory v0) = n.h_entry(id, DEFAULT_EVM);
        (uint256 a0, uint256 b0) = _words(_entrySlot(DEFAULT_EVM));
        // the words are the entry h_entry reads: the saver, and a value of 0 or 20 bytes in the short form, so equal
        // words after the call mean an equal saver and equal bytes
        assert(a0 == uint160(s0));
        assert(v0.length == 0 || v0.length == 20);
        assert(b0 == (v0.length == 0 ? 0 : uint256(bytes32(bytes20(v0))) | 40));
        // _world(w, 0x80000000) writes no entry for any other coin type, so both words of this one are zero. Writing
        // them as zero again leaves every slot as it was. OP's save writes the main address and no entry. The only
        // entries it reads, coin type 60 and the default (to announce the coin type 60 answer), have fixed keys, and
        // so does the only entry stored before them, the default. So OP needs no such store, and leaving it out keeps
        // every entry key on the OP path free of the symbolic coin type.
        if (coinType != COIN_OP) {
            bytes32 cs = _entrySlot(coinType);
            (uint256 c0, uint256 c1) = _words(cs);
            assert(c0 == 0 && c1 == 0);
            vm.store(address(n), cs, bytes32(0));
            unchecked {
                vm.store(address(n), bytes32(uint256(cs) + 1), bytes32(0));
            }
        }
        vm.prank(caller);
        (bool ok,) = address(n).call(
            abi.encodeCall(PageNFT.setAddrForCoin, (id, coinType, empty ? bytes("") : abi.encodePacked(value)))
        );
        ok;
        (uint256 a1, uint256 b1) = _words(_entrySlot(DEFAULT_EVM));
        assert(a1 == a0 && b1 == b0);
    }
}

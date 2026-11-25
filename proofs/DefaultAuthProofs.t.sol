// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {PageNFT} from "../src/PageNFT.sol";
import {DefaultProofsBase} from "./DefaultProofs.t.sol";

/// @notice DA2 of DefaultProofsTest as two smaller queries: who may write the default, and what a write by the
/// holder leaves alone.
/// Halmos: FOUNDRY_PROFILE=proofs halmos --contract DefaultAuthProofsTest --function test_check_DA2 --forge-build-out out-proofs --loop 4 --storage-layout generic
contract DefaultAuthProofsTest is DefaultProofsBase {
    /// @notice DA2x: for any start state, time, caller and value, setAddrForCoin(id, 0x80000000, value) succeeds
    /// exactly when the name is active, the caller holds it and the value is 0 or 20 bytes, and a success leaves the
    /// caller as the saver of the default with the value, twenty zero bytes stored as empty.
    /// @dev Technique: built symbolic state, one symbolic call. Classification: DIRECT.
    function test_check_DA2x_whoMayWrite(
        uint64 exp, uint8 hPick, uint8 mPick, uint8 asPick, uint64 rv, uint8 dsPick, address defVal, uint64 ts,
        address caller, uint8 lenPick, bytes32 raw
    ) public {
        W memory w = _w(exp, hPick, mPick, asPick, rv, 0, address(0), dsPick, defVal);
        _world(w, DEFAULT_EVM);
        vm.warp(ts);
        uint256 len = lenPick % 4 == 0 ? 0 : lenPick % 4 == 1 ? 20 : lenPick % 4 == 2 ? 21 : 1;
        bytes memory v = new bytes(len);
        for (uint256 i; i < len; ++i) v[i] = raw[i];
        vm.prank(caller);
        (bool ok,) = address(n).call(abi.encodeCall(PageNFT.setAddrForCoin, (id, DEFAULT_EVM, v)));
        bool allowed = ts <= w.exp && caller == w.holder && (len == 0 || len == 20);
        assert(ok == allowed);
        if (ok) {
            (address dSaver, bytes memory dVal) = n.h_entry(id, DEFAULT_EVM);
            assert(dSaver == caller);
            bool zero = len == 0 || bytes20(raw) == bytes20(0);
            assert(_eqB(dVal, zero ? bytes("") : v));
        }
    }

    /// @notice DA2y: for any start state and value, a successful save of the default by the holder leaves the holder,
    /// the record version, the main address, the payee, the OP answer, the profile writer and another coin type's
    /// entry as they were.
    /// @dev Technique: built symbolic state, one symbolic call by the holder. Classification: DIRECT.
    function test_check_DA2y_holderWriteMovesNothingElse(
        uint64 exp, uint8 hPick, uint8 mPick, uint8 asPick, uint64 rv, uint8 osPick, address ownVal, uint8 dsPick,
        address defVal, uint256 otherCoin, uint64 ts, address value, bool empty
    ) public {
        vm.assume(otherCoin != DEFAULT_EVM);
        W memory w = _w(exp, hPick, mPick, asPick, rv, osPick, ownVal, dsPick, defVal);
        _world(w, otherCoin);
        vm.assume(ts <= w.exp);
        vm.warp(ts);
        (address oSaver, bytes memory oVal) = n.h_entry(id, otherCoin);
        (address pw, uint96 pv) = n.h_profile(id);
        address main = _main(w);
        vm.prank(w.holder);
        n.setAddrForCoin(id, DEFAULT_EVM, empty ? bytes("") : abi.encodePacked(value));
        assert(n.h_ownerOf(id) == w.holder);
        assert(n.recordVersion(id) == w.rv);
        assert(n.resolve(id) == main);
        assert(n.payee(id) == main);
        assert(_eqB(n.addr(id, COIN_OP), _enc(main)));
        (address pw2, uint96 pv2) = n.h_profile(id);
        assert(pw2 == pw && pv2 == pv);
        (address oSaver2, bytes memory oVal2) = n.h_entry(id, otherCoin);
        assert(oSaver2 == oSaver && _eqB(oVal2, oVal));
    }
}

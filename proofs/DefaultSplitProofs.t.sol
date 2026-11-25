// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {PageNFT} from "../src/PageNFT.sol";
import {DefaultProofsBase} from "./DefaultProofs.t.sol";

/// @notice DA2 of DefaultProofsTest split by the length of the value, so each part is a smaller query.
/// Halmos: FOUNDRY_PROFILE=proofs halmos --contract DefaultSplitProofsTest --function test_check_DA2 --forge-build-out out-proofs --loop 4 --storage-layout generic
contract DefaultSplitProofsTest is DefaultProofsBase {
    function _da2(W memory w, uint256 otherCoin, uint64 ts, address caller, bytes memory v) internal {
        vm.assume(otherCoin != DEFAULT_EVM);
        _world(w, otherCoin);
        vm.warp(ts);
        uint256 len = v.length;
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
            bool zero = len == 0 || bytes20(v) == bytes20(0);
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

    /// @notice DA2a: DA2 for a 20 byte value.
    function test_check_DA2a_twentyBytes(
        uint64 exp, uint8 hPick, uint8 mPick, uint8 asPick, uint64 rv, uint8 osPick, address ownVal, uint8 dsPick,
        address defVal, uint256 otherCoin, uint64 ts, address caller, address value
    ) public {
        _da2(_w(exp, hPick, mPick, asPick, rv, osPick, ownVal, dsPick, defVal), otherCoin, ts, caller,
            abi.encodePacked(value));
    }

    /// @notice DA2b: DA2 for an empty value.
    function test_check_DA2b_empty(
        uint64 exp, uint8 hPick, uint8 mPick, uint8 asPick, uint64 rv, uint8 osPick, address ownVal, uint8 dsPick,
        address defVal, uint256 otherCoin, uint64 ts, address caller
    ) public {
        _da2(_w(exp, hPick, mPick, asPick, rv, osPick, ownVal, dsPick, defVal), otherCoin, ts, caller, bytes(""));
    }

    /// @notice DA2c: DA2 for a value of 21 bytes, which must always be refused.
    function test_check_DA2c_wrongLength(
        uint64 exp, uint8 hPick, uint8 mPick, uint8 asPick, uint64 rv, uint8 osPick, address ownVal, uint8 dsPick,
        address defVal, uint256 otherCoin, uint64 ts, address caller, address value, bytes1 extra
    ) public {
        _da2(_w(exp, hPick, mPick, asPick, rv, osPick, ownVal, dsPick, defVal), otherCoin, ts, caller,
            abi.encodePacked(value, extra));
    }
}

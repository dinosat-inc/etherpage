// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {DefaultProofsBase} from "./DefaultProofs.t.sol";

/// @notice The frame of a 20 byte save of the default by the holder, one holder kind per query so each is small.
/// Halmos: FOUNDRY_PROFILE=proofs halmos --contract DefaultFrameProofsTest --function test_check_DA2z --forge-build-out out-proofs --loop 4 --storage-layout generic
contract DefaultFrameProofsTest is DefaultProofsBase {
    function _frame(address holder, bool savedMain, uint64 exp, uint64 rv, uint8 osPick, address ownVal, uint8 dsPick,
        address defVal, uint256 otherCoin, uint64 ts, address value) internal
    {
        vm.assume(otherCoin != DEFAULT_EVM);
        vm.assume(ts <= exp);
        W memory w = W(exp, holder, savedMain ? OTHER : address(0), holder, rv, _pick(osPick), ownVal, _pick(dsPick), defVal);
        _world(w, otherCoin);
        vm.warp(ts);
        (address oSaver, bytes memory oVal) = n.h_entry(id, otherCoin);
        (address pw, uint96 pv) = n.h_profile(id);
        address main = _main(w);
        vm.prank(holder);
        n.setAddrForCoin(id, DEFAULT_EVM, abi.encodePacked(value));
        assert(n.h_ownerOf(id) == holder);
        assert(n.recordVersion(id) == rv);
        assert(n.resolve(id) == main);
        assert(n.payee(id) == main);
        assert(_eqB(n.addr(id, COIN_OP), _enc(main)));
        (address pw2, uint96 pv2) = n.h_profile(id);
        assert(pw2 == pw && pv2 == pv);
        (address oSaver2, bytes memory oVal2) = n.h_entry(id, otherCoin);
        assert(oSaver2 == oSaver && _eqB(oVal2, oVal));
        (address dSaver, bytes memory dVal) = n.h_entry(id, DEFAULT_EVM);
        assert(dSaver == holder && _eqB(dVal, value == address(0) ? bytes("") : abi.encodePacked(value)));
    }

    /// @notice DA2z1: the holder has no code.
    function test_check_DA2z1_keyHolder(bool savedMain, uint64 exp, uint64 rv, uint8 osPick, address ownVal,
        uint8 dsPick, address defVal, uint256 otherCoin, uint64 ts, address value) public
    {
        _frame(KEY, savedMain, exp, rv, osPick, ownVal, dsPick, defVal, otherCoin, ts, value);
    }

    /// @notice DA2z2: the holder has an EIP7702 designator.
    function test_check_DA2z2_sevenHolder(bool savedMain, uint64 exp, uint64 rv, uint8 osPick, address ownVal,
        uint8 dsPick, address defVal, uint256 otherCoin, uint64 ts, address value) public
    {
        _frame(SEVEN, savedMain, exp, rv, osPick, ownVal, dsPick, defVal, otherCoin, ts, value);
    }

    /// @notice DA2z3: the holder has regular code.
    function test_check_DA2z3_codeHolder(bool savedMain, uint64 exp, uint64 rv, uint8 osPick, address ownVal,
        uint8 dsPick, address defVal, uint256 otherCoin, uint64 ts, address value) public
    {
        _frame(CODE, savedMain, exp, rv, osPick, ownVal, dsPick, defVal, otherCoin, ts, value);
    }
}

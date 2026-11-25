// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {DefaultProofsBase} from "./DefaultProofs.t.sol";

/// @notice The frame of a 20 byte save of the default by the holder, one holder kind per query, with any saved main
/// address and any account as its saver, so the saved main address counts or not. The other coin type is Ethereum,
/// another EVM chain, OP or a chain outside the EVM, picked from the four, as a symbolic coin type makes Halmos read a
/// stored length it cannot fix (NotConcreteError). With DA2b for an empty value these are the parts of DA2y.
/// Halmos: FOUNDRY_PROFILE=proofs halmos --contract DefaultFrameAnyMainProofsTest --function test_check_DA2w --forge-build-out out-proofs --loop 4 --storage-layout generic
contract DefaultFrameAnyMainProofsTest is DefaultProofsBase {
    // the other coin type: Ethereum, another EVM chain, OP or a chain outside the EVM
    function _coin(uint8 p) internal pure returns (uint256) {
        uint8 k = p % 4;
        if (k == 0) return COIN_ETH;
        if (k == 1) return 0x80002105;
        if (k == 2) return COIN_OP;
        return 0;
    }

    function _frame(address holder, uint8 mPick, uint8 asPick, uint64 exp, uint64 rv, uint8 osPick, address ownVal,
        uint8 dsPick, address defVal, uint8 cPick, uint64 ts, address value) internal
    {
        uint256 otherCoin = _coin(cPick);
        vm.assume(ts <= exp);
        W memory w = W(exp, holder, _pick(mPick), _pick(asPick), rv, _pick(osPick), ownVal, _pick(dsPick), defVal);
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

    /// @notice DA2w1: the holder has no code.
    function test_check_DA2w1_keyHolder(uint8 mPick, uint8 asPick, uint64 exp, uint64 rv, uint8 osPick, address ownVal,
        uint8 dsPick, address defVal, uint8 cPick, uint64 ts, address value) public
    {
        _frame(KEY, mPick, asPick, exp, rv, osPick, ownVal, dsPick, defVal, cPick, ts, value);
    }

    /// @notice DA2w2: the holder has an EIP7702 designator.
    function test_check_DA2w2_sevenHolder(uint8 mPick, uint8 asPick, uint64 exp, uint64 rv, uint8 osPick, address ownVal,
        uint8 dsPick, address defVal, uint8 cPick, uint64 ts, address value) public
    {
        _frame(SEVEN, mPick, asPick, exp, rv, osPick, ownVal, dsPick, defVal, cPick, ts, value);
    }

    /// @notice DA2w3: the holder has regular code.
    function test_check_DA2w3_codeHolder(uint8 mPick, uint8 asPick, uint64 exp, uint64 rv, uint8 osPick, address ownVal,
        uint8 dsPick, address defVal, uint8 cPick, uint64 ts, address value) public
    {
        _frame(CODE, mPick, asPick, exp, rv, osPick, ownVal, dsPick, defVal, cPick, ts, value);
    }

    /// @notice DA2w4: the holder is a fourth account with no code.
    function test_check_DA2w4_otherHolder(uint8 mPick, uint8 asPick, uint64 exp, uint64 rv, uint8 osPick, address ownVal,
        uint8 dsPick, address defVal, uint8 cPick, uint64 ts, address value) public
    {
        _frame(OTHER, mPick, asPick, exp, rv, osPick, ownVal, dsPick, defVal, cPick, ts, value);
    }
}

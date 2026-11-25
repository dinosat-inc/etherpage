// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {DefaultProofsBase} from "./DefaultProofs.t.sol";

/// @notice The frame of an empty save of the default by the holder, which clears it, one holder kind per query, with
/// any saved main address and any account as its saver. The other coin type is picked from four as in
/// DefaultFrameAnyMainProofsTest, whose 20 byte saves these complete.
/// Halmos: FOUNDRY_PROFILE=proofs halmos --contract DefaultFrameEmptyProofsTest --function test_check_DA2v --forge-build-out out-proofs --loop 4 --storage-layout generic
contract DefaultFrameEmptyProofsTest is DefaultProofsBase {
    // the other coin type: Ethereum, another EVM chain, OP or a chain outside the EVM
    function _coin(uint8 p) internal pure returns (uint256) {
        uint8 k = p % 4;
        if (k == 0) return COIN_ETH;
        if (k == 1) return 0x80002105;
        if (k == 2) return COIN_OP;
        return 0;
    }

    function _frame(address holder, uint8 mPick, uint8 asPick, uint64 exp, uint64 rv, uint8 osPick, address ownVal,
        uint8 dsPick, address defVal, uint8 cPick, uint64 ts) internal
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
        n.setAddrForCoin(id, DEFAULT_EVM, bytes(""));
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
        assert(dSaver == holder && dVal.length == 0);
    }

    /// @notice DA2v1: the holder has no code.
    function test_check_DA2v1_keyHolder(uint8 mPick, uint8 asPick, uint64 exp, uint64 rv, uint8 osPick, address ownVal,
        uint8 dsPick, address defVal, uint8 cPick, uint64 ts) public
    {
        _frame(KEY, mPick, asPick, exp, rv, osPick, ownVal, dsPick, defVal, cPick, ts);
    }

    /// @notice DA2v2: the holder has an EIP7702 designator.
    function test_check_DA2v2_sevenHolder(uint8 mPick, uint8 asPick, uint64 exp, uint64 rv, uint8 osPick, address ownVal,
        uint8 dsPick, address defVal, uint8 cPick, uint64 ts) public
    {
        _frame(SEVEN, mPick, asPick, exp, rv, osPick, ownVal, dsPick, defVal, cPick, ts);
    }

    /// @notice DA2v3: the holder has regular code.
    function test_check_DA2v3_codeHolder(uint8 mPick, uint8 asPick, uint64 exp, uint64 rv, uint8 osPick, address ownVal,
        uint8 dsPick, address defVal, uint8 cPick, uint64 ts) public
    {
        _frame(CODE, mPick, asPick, exp, rv, osPick, ownVal, dsPick, defVal, cPick, ts);
    }

    /// @notice DA2v4: the holder is a fourth account with no code.
    function test_check_DA2v4_otherHolder(uint8 mPick, uint8 asPick, uint64 exp, uint64 rv, uint8 osPick, address ownVal,
        uint8 dsPick, address defVal, uint8 cPick, uint64 ts) public
    {
        _frame(OTHER, mPick, asPick, exp, rv, osPick, ownVal, dsPick, defVal, cPick, ts);
    }
}

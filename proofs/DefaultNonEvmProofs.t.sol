// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {DefaultProofsBase} from "./DefaultProofs.t.sol";

/// @notice The answer for a coin type outside the EVM, which never falls back to the default address.
/// Halmos: FOUNDRY_PROFILE=proofs halmos --contract DefaultNonEvmProofsTest --function test_check_DA1n --forge-build-out out-proofs --loop 4 --storage-layout generic
contract DefaultNonEvmProofsTest is DefaultProofsBase {
    /// @notice DA1n: for any start state, time and coin type outside the EVM (neither 60 nor 0x80000000 to
    /// 0xffffffff), addr(c) is the holder's own entry for c, else empty, and empty while the name is not active,
    /// whatever the saved default and the main address.
    /// @dev Technique: built symbolic state, exact characterization of a view. Classification: DIRECT.
    function test_check_DA1n_noFallbackOutsideTheEvm(
        uint64 exp, uint8 hPick, uint8 mPick, uint8 asPick, uint64 rv, uint8 osPick, address ownVal, uint8 dsPick,
        address defVal, uint256 coinType, uint64 ts
    ) public {
        vm.assume(coinType != COIN_ETH && (coinType < DEFAULT_EVM || coinType > 0xffffffff));
        W memory w = _w(exp, hPick, mPick, asPick, rv, osPick, ownVal, dsPick, defVal);
        _world(w, coinType);
        vm.warp(ts);
        bytes memory want = (ts <= w.exp && w.ownSaver == w.holder) ? _enc(w.ownVal) : bytes("");
        assert(_eqB(n.addr(id, coinType), want));
        assert(_eqB(n.addr(bytes32(id), coinType), want));
    }
}

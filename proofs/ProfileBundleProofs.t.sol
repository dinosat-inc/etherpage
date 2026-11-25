// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {ProfileProofsTest} from "./ProfileProofs.t.sol";

/// @notice PP8 split by the first entry, for the two first entries the parts of ProfileProofsTest leave out:
/// setContenthash (k1 = 1) and clearRecords (k1 = 4), on the top level name (t) and the subpage (s). With
/// the parts for k1 = 0, 2 and 3 they cover every first entry of test_check_PP8_bundles, which picks it as
/// k1 % 5. Each part runs that same proof, unchanged, on a ProfileProofsTest deployed in setUp, so this
/// contract has no proof but its own four.
/// Halmos: FOUNDRY_PROFILE=proofs halmos --contract ProfileBundleProofsTest --function test_check_PP8 --forge-build-out out-proofs --loop 4 --storage-layout generic
contract ProfileBundleProofsTest is Test {
    ProfileProofsTest p;

    function setUp() public {
        p = new ProfileProofsTest();
        p.setUp();
    }

    // every argument of PP8 is one word, so its calldata is the selector and the two halves of its arguments;
    // a failed assertion inside comes back as this call's revert data
    function _bundles(bytes memory head, bytes memory tail) internal {
        (bool ok, bytes memory ret) =
            address(p).call(bytes.concat(ProfileProofsTest.test_check_PP8_bundles.selector, head, tail));
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }

    function test_check_PP8_k1t(uint64 exp, uint64 epoch, uint64 pe, uint8 hPick, uint8 wPick, uint96 ver, uint64 rv, bool cur, bool paid, uint64 ts, address caller, bool op, uint8 k2, uint8 toPick) public {
        _bundles(abi.encode(true, exp, epoch, pe, hPick, wPick, ver, rv), abi.encode(cur, paid, ts, caller, op, uint8(1), k2, toPick));
    }

    function test_check_PP8_k1s(uint64 exp, uint64 epoch, uint64 pe, uint8 hPick, uint8 wPick, uint96 ver, uint64 rv, bool cur, bool paid, uint64 ts, address caller, bool op, uint8 k2, uint8 toPick) public {
        _bundles(abi.encode(false, exp, epoch, pe, hPick, wPick, ver, rv), abi.encode(cur, paid, ts, caller, op, uint8(1), k2, toPick));
    }

    function test_check_PP8_k4t(uint64 exp, uint64 epoch, uint64 pe, uint8 hPick, uint8 wPick, uint96 ver, uint64 rv, bool cur, bool paid, uint64 ts, address caller, bool op, uint8 k2, uint8 toPick) public {
        _bundles(abi.encode(true, exp, epoch, pe, hPick, wPick, ver, rv), abi.encode(cur, paid, ts, caller, op, uint8(4), k2, toPick));
    }

    function test_check_PP8_k4s(uint64 exp, uint64 epoch, uint64 pe, uint8 hPick, uint8 wPick, uint96 ver, uint64 rv, bool cur, bool paid, uint64 ts, address caller, bool op, uint8 k2, uint8 toPick) public {
        _bundles(abi.encode(false, exp, epoch, pe, hPick, wPick, ver, rv), abi.encode(cur, paid, ts, caller, op, uint8(4), k2, toPick));
    }
}

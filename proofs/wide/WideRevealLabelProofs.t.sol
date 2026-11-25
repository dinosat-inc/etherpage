// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {PageCard} from "../../src/PageCard.sol";
import {PageNFT} from "../../src/PageNFT.sol";
import {WideHarness} from "./WideHarness.sol";

interface SVMB {
    function createBytes(uint256 length, string memory name) external pure returns (bytes memory value);
}

/// @notice WRV5/WRV6: reveal and revealTrial with a label of 1, 2 or 3 symbolic bytes (every byte value,
/// upper case included), where WRV1-4 use one fixed label per fee class and MC5 assumes the label valid
/// and checks only the InsufficientFee direction. Over any record of that label (none, live, in grace, in
/// the premium window or later, with a deposit, held trial money or neither) and any time and value: the
/// call succeeds exactly when the label is valid, free, and the value covers the price of its length;
/// then the caller gets exactly the rest back, the page of the lowercase label goes to the owner and the
/// fee goes to the deposit (reveal) or is held (trial). A ripe commitment for the lowercase label is in
/// place, so the commitment rules are WRV1-4's.
/// Halmos: FOUNDRY_PROFILE=proofs halmos --contract WideRevealLabelProofsTest --forge-build-out out-proofs --loop 8 --storage-layout generic
contract WideRevealLabelProofsTest is Test {
    SVMB constant svm = SVMB(0xF3993A62377BCd56AE39D773740A5390411E8BC9);
    WideHarness n;
    address constant HOLDER = address(0xB0B);
    address constant OWNER = address(0xA11CE);
    address constant CALLER = address(0xCA11E2);
    address constant PAYER = address(0xFA7E5);
    bytes32 constant ROOT = 0x62460c06d95b73747abf6ea4f28aefd78b4ad2abee112e7cf15fe6a924cca3c6;

    function setUp() public {
        n = new WideHarness(new PageCard());
        vm.deal(address(this), 2 ** 128);
    }

    function _raw(uint8 k) internal pure returns (bytes memory) {
        uint8 m = k % 3;
        if (m == 0) return svm.createBytes(1, "r1");
        if (m == 1) return svm.createBytes(2, "r2");
        return svm.createBytes(3, "r3");
    }

    function _go(bool trial, uint8 lenPick, bool exists, uint64 exp, uint64 epoch, uint256 dep, uint96 held, uint256 t,
        uint256 value) internal {
        vm.assume(t > 1000 && t < 2 ** 40 && value <= 2 ** 96 && dep <= 2 ** 96);
        vm.assume(dep == 0 || held == 0);
        bytes memory raw = _raw(lenPick);
        string memory label = string(raw);
        (bool valid, bytes memory r) = address(n).staticcall(abi.encodeCall(PageNFT.normalize, (label)));
        string memory norm = valid ? abi.decode(r, (string)) : "";
        uint256 id = uint256(keccak256(abi.encodePacked(ROOT, keccak256(bytes(norm)))));
        if (valid && exists) {
            vm.assume(epoch > 0 && epoch < type(uint64).max);
            n.h_setRecord(id, norm, 0, exp, epoch, 0);
            n.h_mint(HOLDER, id);
            n.h_setDeposit{value: dep}(id, dep);
            n.h_setHeld{value: held}(id, PAYER, held);
        } else {
            vm.assume(!exists && dep == 0 && held == 0);
        }
        bytes32 c = trial
            ? keccak256(abi.encode(bytes(norm), OWNER, uint256(0), bytes32("s"), true))
            : keccak256(abi.encode(bytes(norm), OWNER, uint256(0), bytes32("s")));
        n.h_setCommitment(c, t - 61);
        vm.warp(t);
        uint256 fee = n.getFee(raw.length);
        if (trial) fee /= 10;
        bool released = exists && dep != 0 && t > uint256(exp) + 111 days;
        uint256 carried = released ? 0 : dep;
        uint256 price = fee + carried + n.getPremium(id);
        bool free = !exists || t > (dep != 0 ? uint256(exp) + 90 days : uint256(exp));
        bool trialOk = !trial || (carried == 0 && !(exists && t <= uint256(exp) + 14 days));
        bool expected = valid && free && trialOk && value >= price;
        uint256 bal = address(n).balance;
        vm.deal(CALLER, value);
        bytes memory d = trial
            ? abi.encodeCall(PageNFT.revealTrial, (label, OWNER, 0, bytes32("s")))
            : abi.encodeCall(PageNFT.reveal, (label, OWNER, 0, bytes32("s")));
        vm.prank(CALLER);
        (bool ok,) = address(n).call{value: value}(d);
        assert(ok == expected);
        if (ok) {
            assert(CALLER.balance == value - price);
            assert(address(n).balance == bal + price);
            assert(n.ownerOf(id) == OWNER);
            (string memory stored,,,,) = n.records(id);
            assert(keccak256(bytes(stored)) == keccak256(bytes(norm)));
            if (trial) assert(n.depositOf(id) == 0);
            else assert(n.depositOf(id) == carried + fee);
        } else {
            assert(CALLER.balance == value);
            assert(address(n).balance == bal);
        }
    }

    function check_WRV5_revealSymbolicLabel(uint8 lenPick, bool exists, uint64 exp, uint64 epoch, uint256 dep,
        uint96 held, uint256 t, uint256 value) public {
        _go(false, lenPick, exists, exp, epoch, dep, held, t, value);
    }

    function check_WRV6_revealTrialSymbolicLabel(uint8 lenPick, bool exists, uint64 exp, uint64 epoch, uint256 dep,
        uint96 held, uint256 t, uint256 value) public {
        _go(true, lenPick, exists, exp, epoch, dep, held, t, value);
    }
}

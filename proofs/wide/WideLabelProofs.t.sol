// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {PageCard} from "../../src/PageCard.sol";
import {PageNFT} from "../../src/PageNFT.sol";
import {DepositHarness} from "../DepositProofs.t.sol";

interface SVML {
    function createBytes(uint256 length, string memory name) external pure returns (bytes memory value);
}

/// @notice Widened label proofs.
/// WLB: for every byte string of a fixed length L (all 256^L values), normalize succeeds exactly when a
/// reference rule written here says the label is valid, returns exactly its lowercase form, reverts
/// InvalidLength for lengths 0 and above 63 and InvalidLabel otherwise, and isAvailable and quote
/// agree. No tier proof checks normalize itself for symbolic bytes; MC5 assumes validity and RF1 covers
/// only self referral at 3 bytes. The reference is written in assembly without branches, so the only
/// symbolic branches are the contract's.
/// WRF1 / WRF2s: RF1 and RF2s (proofs/StatusProofs.t.sol, 3 bytes only) for labels of 1 to 6 bytes,
/// and RF2s with values up to 2^96 wei (tier: 100 ether).
/// Halmos: FOUNDRY_PROFILE=proofs halmos --contract WideLabelProofsTest --forge-build-out out-proofs --loop <L+3> --storage-layout generic
contract WideLabelProofsTest is Test {
    SVML constant svm = SVML(0xF3993A62377BCd56AE39D773740A5390411E8BC9);
    DepositHarness n;

    function setUp() public {
        n = new DepositHarness(new PageCard());
    }

    // the reference rule: every byte A-Z, a-z, 0-9 or the hyphen; length 1 to 63; no hyphen first or
    // last; not hyphens in both the third and the fourth place; not 0x and then 40 digits 0-9 or a-f
    // (after lowercasing). lower is the label with A-Z lowercased.
    function _ref(bytes memory b) internal pure returns (bool valid, bytes memory lower) {
        uint256 len = b.length;
        lower = new bytes(len);
        uint256 ok = 1;
        assembly {
            let src := add(b, 32)
            let dst := add(lower, 32)
            for { let i := 0 } lt(i, len) { i := add(i, 1) } {
                let c := byte(0, mload(add(src, i)))
                let isU := and(gt(c, 0x40), lt(c, 0x5b))
                let isL := and(gt(c, 0x60), lt(c, 0x7b))
                let isD := and(gt(c, 0x2f), lt(c, 0x3a))
                let isH := eq(c, 0x2d)
                ok := and(ok, or(or(isU, isL), or(isD, isH)))
                mstore8(add(dst, i), add(c, mul(isU, 32)))
            }
        }
        if (len == 0 || len > 63) return (false, lower);
        assembly {
            let dst := add(lower, 32)
            ok := and(ok, iszero(eq(byte(0, mload(dst)), 0x2d)))
            ok := and(ok, iszero(eq(byte(0, mload(add(dst, sub(len, 1)))), 0x2d)))
        }
        if (len >= 4) {
            assembly {
                let dst := add(lower, 32)
                ok := and(ok, iszero(and(eq(byte(0, mload(add(dst, 2))), 0x2d), eq(byte(0, mload(add(dst, 3))), 0x2d))))
            }
        }
        if (len == 42) {
            assembly {
                let dst := add(lower, 32)
                let allHex := 1
                for { let j := 2 } lt(j, 42) { j := add(j, 1) } {
                    let h := byte(0, mload(add(dst, j)))
                    allHex := and(allHex, or(and(gt(h, 0x2f), lt(h, 0x3a)), and(gt(h, 0x60), lt(h, 0x67))))
                }
                let pre := and(eq(byte(0, mload(dst)), 0x30), eq(byte(0, mload(add(dst, 1))), 0x78))
                ok := and(ok, iszero(and(pre, allHex)))
            }
        }
        valid = ok == 1;
    }

    function _wlb(bytes memory raw) internal view {
        string memory label = string(raw);
        (bool valid, bytes memory lower) = _ref(raw);
        (bool okN, bytes memory r) = address(n).staticcall(abi.encodeCall(PageNFT.normalize, (label)));
        assert(okN == valid);
        if (okN) {
            assert(keccak256(bytes(abi.decode(r, (string)))) == keccak256(lower));
        } else {
            bool badLen = raw.length == 0 || raw.length > 63;
            assert(r.length == 4);
            assert(bytes4(r) == (badLen ? PageNFT.InvalidLength.selector : PageNFT.InvalidLabel.selector));
        }
        assert(n.isAvailable(label, 0) == valid);
        (uint256 fee,,, uint256 total) = n.quote(label);
        if (valid) assert(fee == n.getFee(raw.length) && total == fee);
        else assert(fee == 0 && total == 0);
    }

    // no dot, as in RF1: computeId reads a dot as a label separator
    function _noDot(bytes memory b) internal pure {
        uint256 len = b.length;
        uint256 dot;
        assembly {
            let src := add(b, 32)
            for { let i := 0 } lt(i, len) { i := add(i, 1) } { dot := or(dot, eq(byte(0, mload(add(src, i))), 0x2e)) }
        }
        vm.assume(dot == 0);
    }

    function _rf1(bytes memory raw, address owner, bytes32 secret) internal view {
        _noDot(raw);
        string memory label = string(raw);
        uint256 self = n.computeId(label);
        (bool okN,) = address(n).staticcall(abi.encodeCall(PageNFT.normalize, (label)));
        (bool ok, bytes memory ret) =
            address(n).staticcall(abi.encodeCall(PageNFT.makeCommitment, (label, owner, self, secret)));
        assert(!ok);
        if (okN) assert(bytes4(ret) == PageNFT.SelfReferral.selector);
        else assert(bytes4(ret) == PageNFT.InvalidLabel.selector);
    }

    function _rf2s(bytes memory raw, address owner, uint256 value, uint256 t, bool trial) internal {
        vm.assume(t < 2 ** 40 && t > 100 && value <= 2 ** 96);
        _noDot(raw);
        string memory label = string(raw);
        uint256 self = n.computeId(label);
        (bool okN, bytes memory nret) = address(n).staticcall(abi.encodeCall(PageNFT.normalize, (label)));
        vm.assume(okN);
        bytes memory normalized = bytes(abi.decode(nret, (string)));
        bytes32 c = keccak256(abi.encode(normalized, owner, self, bytes32("s")));
        n.h_setCommitment(trial ? keccak256(abi.encode(normalized, owner, self, bytes32("s"), true)) : c, t - 61);
        address payer = address(0xC0FFEE);
        vm.deal(payer, value);
        vm.warp(t);
        vm.prank(payer);
        (bool ok, bytes memory ret) = trial
            ? address(n).call{value: value}(abi.encodeCall(PageNFT.revealTrial, (label, owner, self, bytes32("s"))))
            : address(n).call{value: value}(abi.encodeCall(PageNFT.reveal, (label, owner, self, bytes32("s"))));
        assert(!ok);
        assert(bytes4(ret) == PageNFT.SelfReferral.selector);
    }

    /// @notice WLB_len0: the label rule for every byte string of length 0.
    function check_WLB_len0() public view {
        _wlb(svm.createBytes(0, "lbl0"));
    }

    /// @notice WLB_len1: the label rule for every byte string of length 1.
    function check_WLB_len1() public view {
        _wlb(svm.createBytes(1, "lbl1"));
    }

    /// @notice WLB_len2: the label rule for every byte string of length 2.
    function check_WLB_len2() public view {
        _wlb(svm.createBytes(2, "lbl2"));
    }

    /// @notice WLB_len3: the label rule for every byte string of length 3.
    function check_WLB_len3() public view {
        _wlb(svm.createBytes(3, "lbl3"));
    }

    /// @notice WLB_len4: the label rule for every byte string of length 4.
    function check_WLB_len4() public view {
        _wlb(svm.createBytes(4, "lbl4"));
    }

    /// @notice WLB_len5: the label rule for every byte string of length 5.
    function check_WLB_len5() public view {
        _wlb(svm.createBytes(5, "lbl5"));
    }

    /// @notice WLB_len6: the label rule for every byte string of length 6.
    function check_WLB_len6() public view {
        _wlb(svm.createBytes(6, "lbl6"));
    }

    /// @notice WLB_len7: the label rule for every byte string of length 7.
    function check_WLB_len7() public view {
        _wlb(svm.createBytes(7, "lbl7"));
    }

    /// @notice WLB_len8: the label rule for every byte string of length 8.
    function check_WLB_len8() public view {
        _wlb(svm.createBytes(8, "lbl8"));
    }

    /// @notice WLB_len10: the label rule for every byte string of length 10.
    function check_WLB_len10() public view {
        _wlb(svm.createBytes(10, "lbl10"));
    }

    /// @notice WLB_len12: the label rule for every byte string of length 12.
    function check_WLB_len12() public view {
        _wlb(svm.createBytes(12, "lbl12"));
    }

    /// @notice WLB_len64: the label rule for every byte string of length 64.
    function check_WLB_len64() public view {
        _wlb(svm.createBytes(64, "lbl64"));
    }

    /// @notice WRF1_len1: RF1 (makeCommitment refuses self referral) for every dot free label of 1 bytes.
    function check_WRF1_len1(address owner, bytes32 secret) public view {
        _rf1(svm.createBytes(1, "rf1"), owner, secret);
    }

    /// @notice WRF1_len2: RF1 (makeCommitment refuses self referral) for every dot free label of 2 bytes.
    function check_WRF1_len2(address owner, bytes32 secret) public view {
        _rf1(svm.createBytes(2, "rf2"), owner, secret);
    }

    /// @notice WRF1_len4: RF1 (makeCommitment refuses self referral) for every dot free label of 4 bytes.
    function check_WRF1_len4(address owner, bytes32 secret) public view {
        _rf1(svm.createBytes(4, "rf4"), owner, secret);
    }

    /// @notice WRF1_len5: RF1 (makeCommitment refuses self referral) for every dot free label of 5 bytes.
    function check_WRF1_len5(address owner, bytes32 secret) public view {
        _rf1(svm.createBytes(5, "rf5"), owner, secret);
    }

    /// @notice WRF1_len6: RF1 (makeCommitment refuses self referral) for every dot free label of 6 bytes.
    function check_WRF1_len6(address owner, bytes32 secret) public view {
        _rf1(svm.createBytes(6, "rf6"), owner, secret);
    }

    /// @notice WRF2s_len1: RF2s (reveal and revealTrial refuse self referral) for every valid label of 1
    /// bytes, any owner, any value up to 2^96 wei and any time.
    function check_WRF2s_len1(address owner, uint256 value, uint256 t, bool trial) public {
        _rf2s(svm.createBytes(1, "rs1"), owner, value, t, trial);
    }

    /// @notice WRF2s_len2: RF2s (reveal and revealTrial refuse self referral) for every valid label of 2
    /// bytes, any owner, any value up to 2^96 wei and any time.
    function check_WRF2s_len2(address owner, uint256 value, uint256 t, bool trial) public {
        _rf2s(svm.createBytes(2, "rs2"), owner, value, t, trial);
    }

    /// @notice WRF2s_len3: RF2s (reveal and revealTrial refuse self referral) for every valid label of 3
    /// bytes, any owner, any value up to 2^96 wei and any time.
    function check_WRF2s_len3(address owner, uint256 value, uint256 t, bool trial) public {
        _rf2s(svm.createBytes(3, "rs3"), owner, value, t, trial);
    }

    /// @notice WRF2s_len4: RF2s (reveal and revealTrial refuse self referral) for every valid label of 4
    /// bytes, any owner, any value up to 2^96 wei and any time.
    function check_WRF2s_len4(address owner, uint256 value, uint256 t, bool trial) public {
        _rf2s(svm.createBytes(4, "rs4"), owner, value, t, trial);
    }

    /// @notice WRF2s_len5: RF2s (reveal and revealTrial refuse self referral) for every valid label of 5
    /// bytes, any owner, any value up to 2^96 wei and any time.
    function check_WRF2s_len5(address owner, uint256 value, uint256 t, bool trial) public {
        _rf2s(svm.createBytes(5, "rs5"), owner, value, t, trial);
    }

    /// @notice WRF2s_len6: RF2s (reveal and revealTrial refuse self referral) for every valid label of 6
    /// bytes, any owner, any value up to 2^96 wei and any time.
    function check_WRF2s_len6(address owner, uint256 value, uint256 t, bool trial) public {
        _rf2s(svm.createBytes(6, "rs6"), owner, value, t, trial);
    }
}

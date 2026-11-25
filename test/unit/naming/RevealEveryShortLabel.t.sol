// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

// Reveals for real every 1 and 2 byte label, and every 3 byte label made of 22 bytes at the edges of the
// character classes, as a paid page and as a trial. A label is accepted exactly when it is valid and its
// lowercase form is not taken yet; then the caller pays exactly the price of its length (a tenth for a
// trial), the page of the lowercase label goes to the owner, and the fee is in the deposit or held for the
// caller. A refusal moves no ETH. It stands in for the Halmos proofs WRV5 and WRV6, which Halmos 0.3.3
// cannot run (tools/proofs/umbrella.txt).

import {Test} from "forge-std/Test.sol";
import {PageNFT} from "../../../src/PageNFT.sol";
import {PageCard} from "../../../src/PageCard.sol";

contract RevealEveryShortLabelTest is Test {
    PageNFT n;
    address constant OWNER = address(0xA11CE);
    address constant CALLER = address(0xCA11E2);
    bytes32 constant ROOT = 0x62460c06d95b73747abf6ea4f28aefd78b4ad2abee112e7cf15fe6a924cca3c6;
    bytes32 constant SECRET = bytes32("s");
    uint256 constant T = 1_800_000_000;
    mapping(uint256 => bool) seen;
    uint256 accepted;
    uint256 registered;

    function setUp() public {
        vm.warp(T);
        n = new PageNFT(new PageCard());
        vm.deal(CALLER, 1e30);
    }

    function _one(bytes memory raw, bool trial) internal {
        string memory label = string(raw);
        bool valid;
        bytes memory norm;
        try n.normalize(label) returns (string memory s) {
            valid = true;
            norm = bytes(s);
        } catch {}
        uint256 id;
        uint256 price;
        if (valid) {
            accepted++;
            id = uint256(keccak256(abi.encodePacked(ROOT, keccak256(norm))));
            bytes32 c = trial
                ? keccak256(abi.encode(norm, OWNER, uint256(0), SECRET, true))
                : n.makeCommitment(label, OWNER, 0, SECRET);
            // an upper case twin of a taken name may have left the same commitment in place: that is fine
            try n.commit(c) {} catch {}
            vm.warp(T + 60);
            price = n.getFee(norm.length);
            if (trial) price /= 10;
            assertEq(norm.length, raw.length, "normalizing keeps the length");
        }
        bool expected = valid && !seen[id];
        uint256 cb = CALLER.balance;
        uint256 nb = address(n).balance;
        bytes memory d = trial
            ? abi.encodeCall(PageNFT.revealTrial, (label, OWNER, 0, SECRET))
            : abi.encodeCall(PageNFT.reveal, (label, OWNER, 0, SECRET));
        vm.prank(CALLER);
        (bool ok,) = address(n).call{value: 1 ether}(d);
        assertEq(ok, expected, string(abi.encodePacked("outcome for label 0x", vm.toString(raw))));
        if (ok) {
            seen[id] = true;
            registered++;
            assertEq(CALLER.balance, cb - price, "caller pays exactly the price");
            assertEq(address(n).balance, nb + price, "contract keeps exactly the price");
            assertEq(n.ownerOf(id), OWNER);
            (string memory stored,,,,) = n.records(id);
            assertEq(keccak256(bytes(stored)), keccak256(norm), "lowercase label stored");
            if (trial) {
                (address p, uint96 a) = n.trialPaymentOf(id);
                assertEq(p, CALLER);
                assertEq(uint256(a), price);
                assertEq(n.depositOf(id), 0);
            } else {
                assertEq(n.depositOf(id), price);
            }
        } else {
            assertEq(CALLER.balance, cb, "a refusal moves no ETH");
            assertEq(address(n).balance, nb, "a refusal moves no ETH");
        }
        vm.warp(T);
    }

    function _all12(bool trial) internal {
        for (uint256 a; a < 256; ++a) _one(abi.encodePacked(uint8(a)), trial);
        assertEq(accepted, 62, "1 byte accepted");
        assertEq(registered, 36, "1 byte registered (a-z, 0-9)");
        for (uint256 a; a < 256; ++a) {
            for (uint256 b; b < 256; ++b) _one(abi.encodePacked(uint8(a), uint8(b)), trial);
        }
        assertEq(accepted, 62 + 3844, "2 byte accepted");
        assertEq(registered, 36 + 1296, "2 byte registered");
    }

    function _edges() internal pure returns (uint8[22] memory e) {
        e = [
            0x00, 0x09, 0x20, 0x2c, 0x2d, 0x2e, 0x2f, 0x30, 0x39, 0x3a, 0x40,
            0x41, 0x5a, 0x5b, 0x5f, 0x60, 0x61, 0x7a, 0x7b, 0x7f, 0x80, 0xff
        ];
    }

    function _three(bool trial) internal {
        uint8[22] memory e = _edges();
        for (uint256 i; i < 22; ++i) {
            for (uint256 j; j < 22; ++j) {
                for (uint256 k; k < 22; ++k) _one(abi.encodePacked(e[i], e[j], e[k]), trial);
            }
        }
        // letters and digits among the edges: 0x30 0x39 0x41 0x5a 0x61 0x7a (6), the hyphen 0x2d in the middle only
        // 6*7*6 accepted (the middle byte may also be a hyphen); lowercase forms: 4 (0,9,a,z) by 5 by 4
        assertEq(accepted, 252, "3 byte edge labels accepted");
        assertEq(registered, 80, "3 byte edge labels registered");
    }

    function test_revealEvery1And2ByteLabel() public {
        _all12(false);
    }

    function test_revealTrialEvery1And2ByteLabel() public {
        _all12(true);
    }

    function test_revealEvery3ByteEdgeLabel() public {
        _three(false);
    }

    function test_revealTrialEvery3ByteEdgeLabel() public {
        _three(true);
    }
}

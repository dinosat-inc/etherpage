// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {PageCard} from "../../../src/PageCard.sol";
import {PageNFT} from "../../../src/PageNFT.sol";

/// @notice Exhaustive label checks against a reference rule written from the documented label rules:
/// length 1 to 63; every byte A-Z (lowercased), a-z, 0-9 or the hyphen; no hyphen first or last; not
/// hyphens in both the third and fourth place; not 0x followed by exactly 40 digits 0-9 or a-f (after
/// lowercasing). For each input: normalize succeeds exactly when the rule says valid and returns the
/// lowercase form, reverting InvalidLength for a wrong length and InvalidLabel otherwise; isAvailable
/// (no records exist) is true exactly for valid labels; quote is all zero for invalid labels and the fee
/// of the length for valid ones; makeCommitment succeeds exactly for valid labels; computeId of a valid
/// label is the id of its lowercase form.
/// Covered: every 1-byte and every 2-byte string (65,792 inputs); every 3-byte string over 22 bytes at
/// and around each class boundary (10,648); every single-byte change at each of the 42 positions of three
/// 0x-address-like labels (32,256); every hyphen placement in labels of 4 to 6 bytes; lengths 0 to 70.
/// Run: forge test --match-path test/unit/naming/LabelExhaustive.t.sol
contract LabelExhaustiveTest is Test {
    PageNFT n;
    bytes32 constant ROOT = 0x62460c06d95b73747abf6ea4f28aefd78b4ad2abee112e7cf15fe6a924cca3c6;
    uint256 checked;
    uint256 validCount;

    function setUp() public {
        n = new PageNFT(new PageCard());
    }

    function _class(uint8 c) internal pure returns (bool ok, uint8 lower) {
        if (c >= 65 && c <= 90) return (true, c + 32);
        if ((c >= 97 && c <= 122) || (c >= 48 && c <= 57) || c == 45) return (true, c);
        return (false, c);
    }

    function _ref(bytes memory b) internal pure returns (bool valid, bool badLength, bytes memory lower) {
        uint256 len = b.length;
        lower = new bytes(len);
        if (len == 0 || len > 63) return (false, true, lower);
        valid = true;
        for (uint256 i; i < len; ++i) {
            (bool ok, uint8 l) = _class(uint8(b[i]));
            if (!ok) valid = false;
            lower[i] = bytes1(l);
        }
        if (lower[0] == "-" || lower[len - 1] == "-") valid = false;
        if (len >= 4 && lower[2] == "-" && lower[3] == "-") valid = false;
        if (len == 42 && lower[0] == "0" && lower[1] == "x") {
            bool allHex = true;
            for (uint256 j = 2; j < 42; ++j) {
                uint8 h = uint8(lower[j]);
                if (!((h >= 48 && h <= 57) || (h >= 97 && h <= 102))) allHex = false;
            }
            if (allHex) valid = false;
        }
    }

    function _check(bytes memory raw) internal {
        uint256 fmp;
        assembly {
            fmp := mload(0x40)
        }
        (bool valid, bool badLength, bytes memory lower) = _ref(raw);
        string memory label = string(raw);
        try n.normalize(label) returns (string memory out) {
            assertTrue(valid, "normalize accepted an invalid label");
            assertEq(keccak256(bytes(out)), keccak256(lower), "normalize output");
        } catch (bytes memory err) {
            assertFalse(valid, "normalize refused a valid label");
            assertEq(bytes4(err), badLength ? PageNFT.InvalidLength.selector : PageNFT.InvalidLabel.selector, "error");
        }
        assertEq(n.isAvailable(label, 0), valid, "isAvailable");
        (uint256 fee, uint256 carried, uint256 premium, uint256 total) = n.quote(label);
        assertEq(fee, valid ? n.getFee(raw.length) : 0, "quote fee");
        assertEq(carried + premium, 0, "quote extras");
        assertEq(total, fee, "quote total");
        try n.makeCommitment(label, address(0xB0B), 0, bytes32(0)) {
            assertTrue(valid, "makeCommitment accepted an invalid label");
        } catch {
            assertFalse(valid, "makeCommitment refused a valid label");
        }
        if (valid) {
            assertEq(n.computeId(label), uint256(keccak256(abi.encodePacked(ROOT, keccak256(lower)))), "computeId");
        }
        ++checked;
        if (valid) ++validCount;
        assembly {
            mstore(0x40, fmp)
        }
    }

    function test_everyLabelOfOneAndTwoBytes() public {
        bytes memory one = new bytes(1);
        for (uint256 a; a < 256; ++a) {
            one[0] = bytes1(uint8(a));
            _check(one);
        }
        bytes memory two = new bytes(2);
        for (uint256 a; a < 256; ++a) {
            for (uint256 b; b < 256; ++b) {
                two[0] = bytes1(uint8(a));
                two[1] = bytes1(uint8(b));
                _check(two);
            }
        }
        assertEq(checked, 256 + 65536);
        // 62 one-byte labels (no hyphen alone) and 62 * 62 two-byte labels (no hyphen first or last)
        assertEq(validCount, 62 + 62 * 62);
    }

    function _edges() internal pure returns (uint8[22] memory e) {
        e = [0x00, 0x20, 0x2c, 0x2d, 0x2e, 0x2f, 0x30, 0x39, 0x3a, 0x40, 0x41, 0x5a, 0x5b, 0x60, 0x61, 0x66, 0x67,
            0x7a, 0x7b, 0x7f, 0x80, 0xff];
    }

    function test_threeByteLabelsAtEveryClassEdge() public {
        uint8[22] memory e = _edges();
        bytes memory three = new bytes(3);
        for (uint256 a; a < 22; ++a) {
            for (uint256 b; b < 22; ++b) {
                for (uint256 c; c < 22; ++c) {
                    three[0] = bytes1(e[a]);
                    three[1] = bytes1(e[b]);
                    three[2] = bytes1(e[c]);
                    _check(three);
                }
            }
        }
        assertEq(checked, 22 * 22 * 22);
    }

    function test_addressLikeLabelsEverySingleChange() public {
        bytes[3] memory bases = [
            bytes("0x0123456789abcdef0123456789abcdef01234567"),
            bytes("0XABCDEF0123456789ABCDEF0123456789ABCDEF01"),
            bytes("0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef")
        ];
        for (uint256 k; k < 3; ++k) {
            bytes memory b = bases[k];
            assertEq(b.length, 42);
            _check(b);
            for (uint256 j; j < 42; ++j) {
                bytes1 keep = b[j];
                for (uint256 v; v < 256; ++v) {
                    b[j] = bytes1(uint8(v));
                    _check(b);
                }
                b[j] = keep;
            }
        }
        assertEq(checked, 3 + 3 * 42 * 256);
        // each base is refused. Per base, a single change gives a valid label: at position 0 any valid
        // non-hyphen byte but 0 (61); at 1 any valid byte but x and X (61); at 2 to 40 any valid byte that
        // is not a hex digit in either case (63 - 22 = 41, 39 positions); at 41 the same without the
        // hyphen (40). 61 + 61 + 39 * 41 + 40 = 1761 per base.
        assertEq(validCount, 3 * 1761);
    }

    function test_hyphenPlacements() public {
        for (uint256 len = 4; len <= 6; ++len) {
            for (uint256 mask; mask < (1 << len); ++mask) {
                bytes memory b = new bytes(len);
                for (uint256 i; i < len; ++i) {
                    b[i] = (mask >> i) & 1 == 1 ? bytes1("-") : bytes1("a");
                }
                _check(b);
            }
        }
    }

    function test_everyLength() public {
        for (uint256 len; len <= 70; ++len) {
            bytes memory b = new bytes(len);
            for (uint256 i; i < len; ++i) b[i] = bytes1(uint8(97 + (i % 26)));
            _check(b);
            if (len > 0) {
                b[len - 1] = "Z";
                _check(b);
            }
        }
        bytes memory big = new bytes(1024);
        for (uint256 i; i < 1024; ++i) big[i] = "a";
        _check(big);
    }
}

// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {PageNFT} from "../../../src/PageNFT.sol";
import {LabelPathsBase} from "../../utils/LabelPathsBase.sol";

// Exhaustive runs of the label rule against an independent model, on all six view paths: normalize, which
// gives the error kind and the stored bytes, quote, isAvailable as a top level name and under a parent,
// makeCommitment and makeSubpageCommitment. The 8,192 case choices of one address go through normalize and
// both branches of isAvailable. The exact counts come from the rule itself. Each row runs in its own call
// frame, so memory stays small.
contract LabelEnumerationTest is LabelPathsBase {
    bytes constant ADDR_LOWER = "0xd8da6bf26964af9d7eed9e03e53415d37aa96045";
    bytes constant ADDR_CHECKSUM = "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045";
    bytes constant ADDR_UPPER = "0XD8DA6BF26964AF9D7EED9E03E53415D37AA96045";
    bytes constant HEX22 = "0123456789abcdefABCDEF";

    // normalize and isAvailable against the model; returns the verdict
    function _check(bytes memory raw) internal view returns (uint8 want) {
        bytes memory low;
        (want, low) = _model(raw);
        (bool ok, bytes memory ret) = address(nft).staticcall(abi.encodeCall(PageNFT.normalize, (string(raw))));
        if (want == OK) {
            assertTrue(ok, "normalize accepts what the model accepts");
            assertEq(bytes(abi.decode(ret, (string))), low, "normalize gives the model's bytes");
        } else {
            _assertReverted(ok, ret, _err(want), "normalize refuses what the model refuses");
        }
        assertEq(nft.isAvailable(string(raw), 0), want == OK, "isAvailable agrees");
    }

    // all two byte labels whose first byte is first; returns how many pass
    function twoByteRow(uint256 first) external view returns (uint256 accepted) {
        bytes memory raw = new bytes(2);
        raw[0] = bytes1(uint8(first));
        for (uint256 b; b < 256; ++b) {
            raw[1] = bytes1(uint8(b));
            (uint8 want,) = _model(raw);
            _viewPaths(raw, want);
            if (want == OK) ++accepted;
        }
    }

    // every byte value at one position of base; returns how many variants are refused
    function positionRow(bytes calldata base, uint256 pos) external view returns (uint256 refused) {
        bytes memory raw = base;
        for (uint256 b; b < 256; ++b) {
            raw[pos] = bytes1(uint8(b));
            (uint8 want,) = _model(raw);
            _viewPaths(raw, want);
            if (b >= 0x80) assertTrue(want != OK, "no byte from 0x80 up is accepted");
            if (want != OK) ++refused;
        }
    }

    function _positions(bytes memory base) internal view returns (uint256 refused) {
        for (uint256 pos; pos < base.length; ++pos) refused += this.positionRow(base, pos);
    }

    // all 65,536 two byte labels: exactly the 3,844 made of two letters or digits are accepted
    function test_everyTwoByteLabel() public view {
        uint256 accepted;
        for (uint256 first; first < 256; ++first) accepted += this.twoByteRow(first);
        assertEq(accepted, 3844);
    }

    // each byte value at each position of 63 times a: 194 refused at the first and last position and
    // 193 at every other
    function test_everyByteAtEveryPosition_repeatedLetter() public view {
        assertEq(_positions(_rep("a", 63)), 12161);
    }

    // the same for ab-cd, where a hyphen at the 4th position makes ab--d
    function test_everyByteAtEveryPosition_hyphenBase() public view {
        assertEq(_positions("ab-cd"), 968);
    }

    // the same for an address in lower case, in its checksum form and in upper case with 0X: 195 refused at
    // each of the first two positions, 215 at each of the next 39 and 216 at the last, in each form
    function test_everyByteAtEveryPosition_addressForms() public view {
        assertEq(_positions(ADDR_LOWER), 8991, "lower case");
        assertEq(_positions(ADDR_CHECKSUM), 8991, "checksum form");
        assertEq(_positions(ADDR_UPPER), 8991, "upper case");
    }

    // each of the 22 hex characters at each of the 40 places after 0x, in the three forms of an address,
    // is still an address and is refused on every view path, with InvalidLabel, except zeros from quote and
    // false from isAvailable
    function test_everyHexAtEveryPlace() public view {
        bytes[3] memory forms = [ADDR_LOWER, ADDR_CHECKSUM, ADDR_UPPER];
        uint256 n;
        for (uint256 f; f < 3; ++f) {
            bytes memory raw = bytes.concat(forms[f]);
            for (uint256 place = 2; place < 42; ++place) {
                bytes1 kept = raw[place];
                for (uint256 h; h < 22; ++h) {
                    raw[place] = HEX22[h];
                    (uint8 model,) = _model(raw);
                    assertEq(model, BAD_NAME, "the model refuses it");
                    _viewPaths(raw, BAD_NAME);
                    ++n;
                }
                raw[place] = kept;
            }
        }
        assertEq(n, 3 * 880);
    }

    // every label of 1 to 10 characters made of a and the hyphen, 2,046 labels, on every view path: exactly
    // 386 are accepted; the same patterns with A give the same verdicts and the lowered bytes
    function test_everyHyphenPattern() public view {
        uint256 acceptedLower;
        uint256 acceptedUpper;
        uint256 n;
        for (uint256 len = 1; len <= 10; ++len) {
            for (uint256 mask; mask < (1 << len); ++mask) {
                bytes memory lo = new bytes(len);
                bytes memory up = new bytes(len);
                for (uint256 i; i < len; ++i) {
                    bool hyphen = (mask >> i) & 1 == 1;
                    lo[i] = hyphen ? bytes1("-") : bytes1("a");
                    up[i] = hyphen ? bytes1("-") : bytes1("A");
                }
                (uint8 want,) = _model(lo);
                (uint8 wantUp,) = _model(up);
                assertEq(wantUp, want, "A gives the verdict of a");
                bool pass = lo[0] != "-" && lo[len - 1] != "-" && !(len >= 4 && lo[2] == "-" && lo[3] == "-");
                assertEq(want == OK, pass, "the model reads the hyphen rule");
                _viewPaths(lo, want);
                _viewPaths(up, want);
                if (want == OK) {
                    ++acceptedLower;
                    ++acceptedUpper;
                }
                ++n;
            }
        }
        assertEq(n, 2046);
        assertEq(acceptedLower, 386);
        assertEq(acceptedUpper, 386);
    }

    // the case choices of the 12 letters of one address, for each mask at least from and below to, after 0X
    // when bigX and 0x otherwise, as a top level name and under a parent; returns how many were refused
    function caseRow(uint256 from, uint256 to, bool bigX) external view returns (uint256 refused) {
        bytes memory base = "0xa1234b5678c90d12e34f567a890123b45c6d78ef";
        if (bigX) base[1] = "X";
        for (uint256 mask = from; mask < to; ++mask) {
            bytes memory raw = bytes.concat(base);
            uint256 letter;
            for (uint256 i = 2; i < 42; ++i) {
                if (raw[i] >= "a" && raw[i] <= "f") {
                    if ((mask >> letter) & 1 == 1) raw[i] = bytes1(uint8(raw[i]) - 32);
                    ++letter;
                }
            }
            assertEq(letter, 12);
            assertEq(_check(raw), BAD_NAME);
            assertFalse(nft.isAvailable(string(raw), club), "refused as a subpage too");
            ++refused;
        }
    }

    // every upper and lower case choice of the 12 letters, with 0x and with 0X, is refused, top level and
    // subpage alike; a sample of them, the checksum form of a real address, the zero address, forty f, forty
    // F, forty letters a to f, forty digits and the dead address are refused on all fourteen paths
    function test_addressRefusedInEveryCase() public {
        uint256 refused;
        for (uint256 k; k < 16; ++k) {
            refused += this.caseRow(k * 256, (k + 1) * 256, false);
            refused += this.caseRow(k * 256, (k + 1) * 256, true);
        }
        assertEq(refused, 8192);
        bytes[] memory raws = new bytes[](11);
        raws[0] = ADDR_CHECKSUM;
        raws[1] = "0x0000000000000000000000000000000000000000";
        raws[2] = "0xffffffffffffffffffffffffffffffffffffffff";
        raws[3] = "0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF";
        raws[4] = "0xabcdefabcdefabcdefabcdefabcdefabcdefabcd";
        raws[5] = "0x1234567890123456789012345678901234567890";
        raws[6] = "0x000000000000000000000000000000000000dEaD";
        raws[7] = "0xa1234b5678c90d12e34f567a890123b45c6d78ef";
        raws[8] = "0XA1234B5678C90D12E34F567A890123B45C6D78EF";
        raws[9] = "0xA1234b5678C90d12E34f567A890123b45C6d78Ef";
        raws[10] = "0Xa1234B5678c90D12e34F567a890123B45c6D78eF";
        _prepare(raws);
        for (uint256 i; i < raws.length; ++i) {
            (uint8 model,) = _model(raws[i]);
            assertEq(model, BAD_NAME, "the model refuses it");
            _everyPath(raws[i], BAD_NAME);
        }
    }
}

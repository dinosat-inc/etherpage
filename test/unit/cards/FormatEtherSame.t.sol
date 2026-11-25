// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {LibString} from "solady/utils/LibString.sol";
import {PageCard} from "../../../src/PageCard.sol";
import {PageNFT} from "../../../src/PageNFT.sol";

contract FormatHarness is PageNFT {
    constructor(PageCard c) PageNFT(c) {}

    function formatEther(uint256 w) external pure returns (string memory) {
        return _formatEther(w);
    }
}

// The deposit text of the metadata against the earlier code of _formatEther, kept here unchanged. The text after
// the point depends only on the fraction, which takes 10,000 values, so the walk over every one of them with several
// whole parts and cut digits covers every case, and the fuzz test adds any amount at all.
contract FormatEtherSameTest is Test {
    FormatHarness nft;

    function setUp() public {
        nft = new FormatHarness(new PageCard());
    }

    // the earlier code of _formatEther, unchanged
    function _before(uint256 weiAmount) internal pure returns (string memory) {
        uint256 whole = weiAmount / 1e18;
        uint256 frac = (weiAmount % 1e18) / 1e14;
        if (frac == 0) return LibString.toString(whole);
        bytes memory digits = bytes(LibString.toString(frac));
        bytes memory padded = new bytes(4);
        uint256 pad = 4 - digits.length;
        for (uint256 i; i < pad; ++i) padded[i] = "0";
        for (uint256 i; i < digits.length; ++i) padded[pad + i] = digits[i];
        uint256 end = 4;
        while (padded[end - 1] == "0") --end;
        bytes memory out = new bytes(end);
        for (uint256 i; i < end; ++i) out[i] = padded[i];
        return string.concat(LibString.toString(whole), ".", string(out));
    }

    function test_everyFractionSameAsBefore() public view {
        uint256[4] memory wholes = [uint256(0), 1, 1234567, type(uint256).max / 1e18 - 1];
        uint256[3] memory cut = [uint256(0), 1, 1e14 - 1];
        for (uint256 f; f < 10_000; ++f) {
            for (uint256 w; w < wholes.length; ++w) {
                uint256 amount = wholes[w] * 1e18 + f * 1e14 + cut[f % 3];
                assertEq(nft.formatEther(amount), _before(amount));
            }
        }
    }

    function testFuzz_sameAsBefore(uint256 amount) public view {
        assertEq(nft.formatEther(amount), _before(amount));
    }

    // a few fixed answers, so the test does not rest on the earlier code alone
    function test_fixedAnswers() public view {
        assertEq(nft.formatEther(0), "0");
        assertEq(nft.formatEther(1e14 - 1), "0");
        assertEq(nft.formatEther(1e14), "0.0001");
        assertEq(nft.formatEther(1e15), "0.001");
        assertEq(nft.formatEther(1e16), "0.01");
        assertEq(nft.formatEther(1e17), "0.1");
        assertEq(nft.formatEther(1001e14), "0.1001");
        assertEq(nft.formatEther(9999e14 + 1e14 - 1), "0.9999");
        assertEq(nft.formatEther(1e18), "1");
        assertEq(nft.formatEther(12e18 + 3e17), "12.3");
        assertEq(nft.formatEther(type(uint256).max), "115792089237316195423570985008687907853269984665640564039457.584");
    }
}

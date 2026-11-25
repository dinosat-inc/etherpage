// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {LibString} from "solady/utils/LibString.sol";
import {PageCard} from "../../../src/PageCard.sol";
import {CardReader} from "../../utils/CardReader.sol";

// The date of an active top level card against a calendar computed another way, the method of Fliegel and Van
// Flandern, which shares no step with the card's: any expiry PageNFT can store gives the same day, month and year,
// in at most 19 characters, and any uint256 expiry in at most 77. A month index above 11, past February in the card's
// table that starts in March, is the case the card's clamp guards and would show as a wrong date here. The date is
// read back from the shapes of the left pill, which also checks where each of its letters is drawn.
contract CardDateOracleTest is Test {
    PageCard card;
    CardReader reader;

    bytes constant MONTHS = "JanFebMarAprMayJunJulAugSepOctNovDec";

    function setUp() public {
        card = new PageCard();
        reader = new CardReader();
    }

    // the date the left pill of an active top level card shows after Until
    function _date(uint256 expiry) internal view returns (string memory) {
        CardReader.Card memory c =
            reader.read(card.render("a", "", bytes32(0), PageCard.Status.Active, expiry));
        assertEq(c.dot, "", "a date has no dot");
        assertTrue(LibString.startsWith(c.left, "Until "), "an active top level card shows Until and its date");
        return LibString.slice(c.left, 6);
    }

    // D Mon Y for the day of unix time t, by Fliegel and Van Flandern: the day without a leading zero and the
    // whole year
    function _oracle(uint256 t) internal pure returns (string memory) {
        int256 l = int256(t / 86400) + 68569 + 2440588;
        int256 n = 4 * l / 146097;
        l = l - (146097 * n + 3) / 4;
        int256 y = 4000 * (l + 1) / 1461001;
        l = l - 1461 * y / 4 + 31;
        int256 m = 80 * l / 2447;
        int256 d = l - 2447 * m / 80;
        l = m / 11;
        m = m + 2 - 12 * l;
        y = 100 * (n - 49) + y + l;
        uint256 o = 3 * (uint256(m) - 1);
        string memory month = LibString.slice(string(MONTHS), o, o + 3);
        return string.concat(LibString.toString(uint256(d)), " ", month, " ", LibString.toString(uint256(y)));
    }

    // the card and the oracle both give dates DateRowsTest pins, so the oracle can stand as the reference
    function test_cardAndOracleGiveTheWorkedRows() public view {
        uint256[6] memory t = [uint256(0), 1821312000, 253402300799, 253402300800, type(uint64).max, type(uint256).max];
        string[5] memory want = ["1 Jan 1970", "19 Sep 2027", "31 Dec 9999", "1 Jan 10000", "9 Nov 584554051223"];
        for (uint256 i; i < 5; ++i) {
            assertEq(_oracle(t[i]), want[i], "the oracle");
            assertEq(_date(t[i]), want[i], "the card");
        }
        assertEq(_date(t[5]), _oracle(t[5]));
        assertEq(bytes(_oracle(t[5])).length, 77);
    }

    function testFuzz_cardDateMatchesTheOracleForEveryStoredExpiry(uint64 t) public view {
        string memory got = _date(t);
        assertEq(got, _oracle(t));
        assertLe(bytes(got).length, 19, "a uint64 expiry gives at most 19 characters");
        assertGe(bytes(got).length, 10);
    }

    function testFuzz_cardDateMatchesTheOracleForAnyExpiry(uint256 t) public view {
        string memory got = _date(t);
        assertEq(got, _oracle(t));
        assertLe(bytes(got).length, 77, "any uint256 expiry gives at most 77 characters");
    }

    // the four digit years, 1970 to 9999, where every real expiry falls for thousands of years: 10 characters for
    // the first nine days of a month and 11 for the others
    function testFuzz_cardDateMatchesTheOracleForFourDigitYears(uint256 t) public view {
        t = bound(t, 0, 253402300799);
        string memory got = _date(t);
        assertEq(got, _oracle(t));
        uint256 n = bytes(got).length;
        assertTrue(n == 10 || n == 11, "a day of one or two digits, a month and a year");
        assertEq(bytes(got)[n - 5], " ", "the year has four digits");
    }
}

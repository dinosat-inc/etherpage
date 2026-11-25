// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {LibString} from "solady/utils/LibString.sol";
import {PageCard} from "../../../src/PageCard.sol";
import {CardReader} from "../../utils/CardReader.sol";

// The worked examples of the date formatter, each read back as the whole left pill of an active top level card, so a
// date with a stray letter before or after it fails too.
contract DateRowsTest is Test {
    PageCard card;
    CardReader reader;

    function setUp() public {
        card = new PageCard();
        reader = new CardReader();
    }

    function _row(uint256 expiry, string memory want, uint256 len) internal view {
        CardReader.Card memory c =
            reader.read(card.render("a", "", bytes32(0), PageCard.Status.Active, expiry));
        assertEq(c.left, string.concat("Until ", want), LibString.toString(expiry));
        assertEq(c.dot, "", "a date has no dot");
        assertEq(bytes(want).length, len, "date length");
    }

    // each pinned date, with the length of its text: the day has no leading zero and the year is written whole
    function test_workedExampleRows() public view {
        _row(0, "1 Jan 1970", 10);
        _row(1821312000, "19 Sep 2027", 11);
        _row(1798761600, "1 Jan 2027", 10);
        _row(1830211200, "31 Dec 2027", 11);
        _row(1835395200, "29 Feb 2028", 11);
        _row(253370764800, "1 Jan 9999", 10);
        // the last date with a four digit year and the first with five
        _row(253402300799, "31 Dec 9999", 11);
        _row(253402300800, "1 Jan 10000", 11);
        _row(type(uint64).max, "9 Nov 584554051223", 18);
        _row(
            type(uint256).max, "19 Feb 3669305236998687180674831492239425019668248843096144521164705134005822", 77
        );
    }

    // the rows of 1 Jan 2027, 31 Dec 2027 and 1 Jan 9999 start their day at midnight: the second before is the day
    // before, and the last second of the day still prints the row, as it does for 1 Jan 10000
    function test_rowsStartTheirDay() public view {
        _row(1798761599, "31 Dec 2026", 11);
        _row(1798761600 + 86399, "1 Jan 2027", 10);
        _row(1830211199, "30 Dec 2027", 11);
        _row(1830211200 + 86399, "31 Dec 2027", 11);
        _row(1830211200 + 86400, "1 Jan 2028", 10);
        _row(253370764799, "31 Dec 9998", 11);
        _row(253370764800 + 86399, "1 Jan 9999", 10);
        _row(253402300800 + 86399, "1 Jan 10000", 11);
    }
}

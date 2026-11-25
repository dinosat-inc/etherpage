// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {PageCard} from "../../../src/PageCard.sol";
import {CardReader} from "../../utils/CardReader.sol";

// The card of any label the validator accepts, under any such parent or none, with any id, in any status and with
// any expiry PageNFT can store, stays within the widest card of its kind, 19060 bytes for a top level page and 18862
// for a subpage, and reads back as its own letters and code. 8 has the longest outline in both faces, so no card
// PageNFT can produce is wider than the card of a page of 18 eights whose code is all eights, active until 28 Sep
// 388888888888, the widest date a uint64 expiry reaches. The widest subpage card is an active subpage of 17 eights or
// more under 88888888888aaaa88 whose code is all eights: its name shows 17 eights and the ellipsis, and its left pill
// the dot and the whole parent, which draws the most outline within the 1089 units of the pill (it takes 1086), as an
// a is narrower than an 8 and almost as long to draw; any other order of its thirteen eights and four a draws as much.
// The id changes the length only through its code, the first 14 and the last 6 of its hex digits, as every card draws
// all 32 squares, and an exact search over every code, its kerning and the digits of each pen included, finds that the
// code of twenty eights draws the most, 5848 bytes of paths in a pill of 5984; gate G-48 runs that search. A token id
// is a hash, so a real card is at most this wide (test_widestPageCards). The website test, test/svgCard.test.ts, and
// MetadataSize.t.sol use the same numbers.
contract CardBoundFuzzTest is Test {
    PageCard card;
    CardReader reader;

    uint256 constant MAX_TOP_LEVEL_CARD = 19060;
    uint256 constant MAX_SUBPAGE_CARD = 18862;
    uint64 constant WIDEST_EXPIRY = 12272147937828201600;
    // the id whose code is all eights, the code that draws the most; only its first 14 and last 6 hex digits are
    // shown
    bytes32 constant WIDEST_ID = 0x8888888888888888888888888888888888888888888888888888888888888888;
    // the hex digits the code leaves out, 14 to 57
    uint256 constant HIDDEN = 0x00000000000000ffffffffffffffffffffffffffffffffffffffffffff000000;
    string constant E18 = "888888888888888888";
    string constant WIDEST_PARENT = "88888888888aaaa88";

    bytes constant ENDS = "abcdefghijklmnopqrstuvwxyz0123456789";
    bytes constant BODY = "abcdefghijklmnopqrstuvwxyz0123456789-";

    function setUp() public {
        card = new PageCard();
        reader = new CardReader();
    }

    // a label the validator accepts: no hyphen first or last, never hyphens in both the 3rd and 4th place, and
    // never 0x followed by 40 hex digits. With eights, most of its letters are 8, and with all, every one.
    function _plain(uint256 seed, uint256 len, bool eights, bool all) internal pure returns (string memory) {
        bytes memory b = new bytes(len);
        for (uint256 i; i < len; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            if (all || (eights && seed % 4 != 0)) b[i] = "8";
            else b[i] = (i == 0 || i == len - 1) ? ENDS[(seed >> 8) % 36] : BODY[(seed >> 8) % 37];
        }
        if (len >= 4 && b[2] == "-" && b[3] == "-") b[3] = "a";
        if (len == 42 && b[0] == "0" && b[1] == "x") b[1] = "y";
        return string(b);
    }

    /// forge-config: default.fuzz.runs = 5000

    /// forge-config: deep.fuzz.runs = 5000
    function testFuzz_plainLabelCardBound(
        uint256 seedL,
        uint8 lenL,
        uint256 seedP,
        uint8 lenP,
        bool hasParent,
        bytes32 id,
        uint8 status,
        uint64 expiry,
        bool widest
    ) public view {
        // in half the runs the card is drawn near its widest: labels of eights, all of them in half of those runs and
        // most of them otherwise, a label of 18 letters in half of them and a parent of 18 in half, the code of
        // eights with any hidden digits, and an expiry that is the widest one or in the year before it
        uint256 nl = 1 + uint256(lenL) % 63;
        uint256 np = hasParent ? 1 + uint256(lenP) % 63 : 0;
        if (widest) {
            if (lenL % 2 == 0) nl = 18;
            if (hasParent) np = lenP % 2 == 0 ? 18 : 1 + uint256(lenP >> 1) % 18;
            id = (id & bytes32(HIDDEN)) | (WIDEST_ID & ~bytes32(HIDDEN));
            expiry = expiry % 2 == 0 ? WIDEST_EXPIRY : WIDEST_EXPIRY - expiry % 400 days;
        }
        bool allEights = widest && seedL % 2 == 0;
        string memory label = _plain(seedL >> 1, nl, widest, allEights);
        string memory parent = hasParent ? _plain(seedP >> 1, np, widest, widest && seedP % 2 == 0) : "";
        // and in a quarter of the runs that draw a parent of 18, the widest parent, of 17 letters, in its place
        if (widest && np == 18 && seedP % 4 == 1) parent = WIDEST_PARENT;
        PageCard.Status st = PageCard.Status(status % 5);
        string memory svg = card.render(label, parent, id, st, expiry);
        assertLe(
            bytes(svg).length, hasParent ? MAX_SUBPAGE_CARD : MAX_TOP_LEVEL_CARD, "within the widest card of its kind"
        );

        // a plain label draws itself letter for letter, its parent dimmed after a dot, and the whole cut over 18
        CardReader.Card memory c = reader.read(svg);
        string memory full = hasParent ? string.concat(label, ".", parent) : label;
        if (bytes(full).length <= 18) {
            assertEq(c.name, full, "the full name");
            assertEq(c.dimmed, hasParent ? string.concat(".", parent) : "", "the parent dimmed");
        } else {
            assertEq(c.name, string.concat(string(_head(bytes(full), 17)), unicode"…"), "the name cut");
            assertEq(c.dimmed, "", "nothing dimmed once cut");
        }
        assertEq(c.right, reader.code(id), "the code");
        if (allEights && st == PageCard.Status.Active) {
            if (nl >= 17 && keccak256(bytes(parent)) == keccak256(bytes(WIDEST_PARENT))) {
                assertEq(bytes(svg).length, MAX_SUBPAGE_CARD, "the widest subpage card");
            }
            if (nl == 18 && !hasParent && expiry == WIDEST_EXPIRY) {
                assertEq(bytes(svg).length, MAX_TOP_LEVEL_CARD, "the widest top level card");
            }
        }
    }

    function _head(bytes memory b, uint256 n) internal pure returns (bytes memory out) {
        out = new bytes(n);
        for (uint256 i; i < n; ++i) out[i] = b[i];
    }

    // the length of the card of 18 eights active until the widest date, with the code of id
    function _widestTop(bytes32 id) internal view returns (uint256) {
        return bytes(card.render(E18, "", id, PageCard.Status.Active, WIDEST_EXPIRY)).length;
    }

    // the widest subpage card, the widest top level card, a bound on every card PageNFT can produce, and the widest of
    // the other kinds next to them
    function test_widestPageCards() public view {
        PageCard.Status active = PageCard.Status.Active;
        // an active subpage of 17 eights or more under the widest parent whose code is all eights, with any expiry, as
        // it shows no date
        string memory e17 = "88888888888888888";
        string memory svg = card.render(e17, WIDEST_PARENT, WIDEST_ID, active, 0);
        assertEq(bytes(svg).length, MAX_SUBPAGE_CARD, "the widest subpage card");
        CardReader.Card memory c = reader.read(svg);
        assertEq(c.name, unicode"88888888888888888…", "17 eights and the ellipsis");
        assertEq(c.dimmed, "", "cut, so nothing dimmed");
        assertEq(c.left, string.concat(".", WIDEST_PARENT), "the dot and the whole parent");
        assertEq(c.right, unicode"88888888888888…888888", "the code of eights");
        string memory e63 = "888888888888888888888888888888888888888888888888888888888888888";
        svg = card.render(e63, WIDEST_PARENT, WIDEST_ID | bytes32(HIDDEN), active, type(uint64).max);
        assertEq(bytes(svg).length, MAX_SUBPAGE_CARD, "63 eights, other hidden digits and another expiry");
        // the same letters of the parent in another order draw as much
        assertEq(bytes(card.render(e63, "88888888888aaa88a", WIDEST_ID, active, 0)).length, MAX_SUBPAGE_CARD, "a tie");
        // 16 eights keep the dot of the parent in the name, which is narrower
        svg = card.render("8888888888888888", WIDEST_PARENT, WIDEST_ID, active, 0);
        assertLt(bytes(svg).length, MAX_SUBPAGE_CARD, "16 eights");
        // 18 eights are too wide for the pill, which keeps 15 and the ellipsis
        svg = card.render(e17, E18, WIDEST_ID, active, 0);
        assertEq(bytes(svg).length, 18487, "under 18 eights");
        assertEq(reader.read(svg).left, unicode".888888888888888…", "15 eights and the ellipsis");
        // the widest subpage card stays below the widest top level card
        assertLt(MAX_SUBPAGE_CARD, MAX_TOP_LEVEL_CARD);

        // the widest top level card: 18 eights whose code is all eights, active until the widest date
        svg = card.render(E18, "", WIDEST_ID, active, WIDEST_EXPIRY);
        assertEq(bytes(svg).length, MAX_TOP_LEVEL_CARD, "the widest top level card");
        c = reader.read(svg);
        assertEq(c.name, E18, "18 eights");
        assertEq(c.left, "Until 28 Sep 388888888888", "the widest date");
        // the hidden digits change only the colours of squares 14 to 31, never the length
        assertEq(_widestTop(WIDEST_ID ^ bytes32(HIDDEN)), MAX_TOP_LEVEL_CARD, "other hidden digits");
        // a shown digit other than 8 draws less, at either end of the code, and so does the code of zeros, the widest
        // pill, 451 pixels, and the code of the largest id
        assertEq(_widestTop(WIDEST_ID ^ bytes32(uint256(1) << 252)), 18996, "a 9 first");
        assertEq(_widestTop(WIDEST_ID ^ bytes32(uint256(1))), 18996, "a 9 last");
        assertEq(_widestTop(bytes32(0)), 17081, "the code of zeros");
        assertEq(_widestTop(bytes32(type(uint256).max)), 15554, "the code of f");
        // the latest date of all is narrower
        svg = card.render(E18, "", WIDEST_ID, active, type(uint64).max);
        assertLt(bytes(svg).length, MAX_TOP_LEVEL_CARD, "the latest date");

        // a subpage of 8 under 18 eights, cut, and under 16 eights, dimmed
        assertEq(bytes(card.render("8", E18, WIDEST_ID, active, 0)).length, 18252, "a cut subpage of 8");
        assertEq(bytes(card.render("8", "8888888888888888", WIDEST_ID, active, 0)).length, 18520, "a dimmed subpage");
        // the page of 18 eights in each other status, which shows no date
        uint256[5] memory size = [uint256(0), 15912, 15008, 14988, 14713];
        for (uint256 s = 1; s < 5; ++s) {
            assertEq(bytes(card.render(E18, "", WIDEST_ID, PageCard.Status(s), 0)).length, size[s], "another status");
        }
    }
}

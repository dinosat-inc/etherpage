// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {LibString} from "solady/utils/LibString.sol";
import {PageCard} from "../../src/PageCard.sol";
import {CardReader} from "../utils/CardReader.sol";

// Reaches every branch of PageCard, the ones PageNFT never takes included, as its labels hold only a to z, 0 to 9
// and the hyphen. render is external, so any app can call it with any bytes. Each card is read back with the
// reader, which checks the whole drawing on the way.
contract PageCardCoverageTest is Test {
    PageCard card;
    CardReader reader;

    function setUp() public {
        card = new PageCard();
        reader = new CardReader();
    }

    function _card(string memory label, string memory parent) internal view returns (CardReader.Card memory) {
        return reader.read(card.render(label, parent, bytes32(0), PageCard.Status.Active, 0));
    }

    function _has(string memory s, string memory part) internal pure {
        assertTrue(LibString.contains(s, part), part);
    }

    // the start of a right pill from x, w wide, with its text from tx, in the muted ink
    function _rightPill(string memory x, string memory w, string memory tx) internal pure returns (string memory) {
        return string.concat(
            '<rect x="', x, '" y="840" width="', w, '" height="62" rx="31" fill="#f6f6f8"/>',
            '<g transform="translate(', tx, ' 881) scale(0.280)" fill="#6a6a70">'
        );
    }

    // _letter in the name: a to z, 0 to 9, the hyphen and the dot draw themselves, and the bytes just outside each
    // range, the space and the capitals draw the box
    function test_everyLetterOfTheName() public view {
        assertEq(_card("abcdefghijklm", "").name, "abcdefghijklm", "a to m");
        assertEq(_card("nopqrstuvwxyz", "").name, "nopqrstuvwxyz", "n to z");
        assertEq(_card("0123456789-.", "").name, "0123456789-.", "digits, hyphen and dot");
        // ` and { around a to z, / and : around 0 to 9, , before the hyphen, then a space and two capitals
        assertEq(_card("`{/:, AZ", "").name, "????????", "every other byte is the box");
    }

    // _letter in the small text, the left pill of an active subpage: the space and the capitals ADEFGIJMNOSTU too,
    // from the first capital to the last, and the box for the other capitals and the bytes around them
    function test_everyLetterOfTheSmallText() public view {
        assertEq(_card("x", "ADEFGIJMNOSTU").left, ".ADEFGIJMNOSTU", "its capitals");
        assertEq(_card("x", "BCHKLPQRVWXYZ").left, ".?????????????", "the other capitals");
        assertEq(_card("x", "@[`{").left, ".????", "the bytes around them");
        assertEq(_card("x", "az09-.").left, ".az09-.", "the letters of the name");
        // the space draws no outline at all, so the pill holds a path for each letter but the space
        string memory svg = card.render("x", "a b", bytes32(0), PageCard.Status.Active, 0);
        assertEq(reader.read(svg).left, ".a b", "a space between two letters");
        string memory pill = LibString.slice(svg, LibString.indexOf(svg, '<rect x="90" y="840"'));
        pill = LibString.slice(pill, 0, LibString.indexOf(pill, '<rect x="', 1));
        assertEq(LibString.split(pill, "<path").length - 1, 3, "three paths for four letters");
        // in the name the space and the capital are boxes
        assertEq(_card("x", "a bA").name, "x.a?b?", "boxes in the name");
    }

    // _cut and the name: 18 letters are drawn whole, 19 are cut to 17 and the ellipsis
    function test_cutAtEighteenAndNineteenLetters() public view {
        assertEq(_card("abcdefghijklmnopqr", "").name, "abcdefghijklmnopqr", "18 letters");
        assertEq(_card("abcdefghijklmnopqrs", "").name, unicode"abcdefghijklmnopq…", "19 letters");
        // a subpage counts its dot and its parent
        CardReader.Card memory c = _card("abcdefgh", "ijklmnopq");
        assertEq(c.name, "abcdefgh.ijklmnopq", "a subpage of 18 letters");
        assertEq(c.dimmed, ".ijklmnopq", "dimmed");
        c = _card("abcdefgh", "ijklmnopqr");
        assertEq(c.name, unicode"abcdefgh.ijklmnop…", "a subpage of 19 letters");
        assertEq(c.dimmed, "", "cut, so nothing is dimmed");
        // the parent in the left pill is cut on its own
        assertEq(_card("x", "abcdefghijklmnopqr").left, ".abcdefghijklmnopqr", "a parent of 18 letters");
        assertEq(_card("x", "abcdefghijklmnopqrs").left, unicode".abcdefghijklmnopq…", "a parent of 19 letters");
    }

    // _kern: a pair found, and pairs missing below the first pair and above the last one of each face. The reader
    // checks every pen against the kerning of the JSON.
    function test_kerningFoundAndMissing() public view {
        // - and n are kerned by 20 in the name: n starts at -133 + 116 - 6 + 20
        string memory svg = card.render("-n", "", bytes32(0), PageCard.Status.Active, 0);
        _has(svg, '<path transform="translate(-133)" d="M25-86h90v33h-90z"/><path transform="translate(-3)" d="M11 0v-112');
        assertEq(reader.read(svg).name, "-n", "found");
        // a a is below the first pair of the name, a -, and two boxes are above the last
        assertEq(_card("aa", "").name, "aa", "missing below");
        assertEq(_card("<>", "").name, "??", "missing above");
        // T r is the last pair of the small text and is kerned by -5; a a is below its first pair, a t, and U a above
        // its last
        CardReader.Card memory c = reader.read(card.render("x", "", bytes32(0), PageCard.Status.Trial, 0));
        assertEq(c.left, "Trial", "found in the small text");
        assertEq(_card("x", "aa").left, ".aa", "missing below in the small text");
        assertEq(_card("x", "Ua").left, ".Ua", "missing above in the small text");
    }

    // the scale on both sides of W * 750 == 820000, which no whole width meets: subpage16 is 1093 units wide and
    // keeps 0.750, subpage15 is 1094 and gets 820000 / 1094 = 749
    function test_scaleOnBothSidesOfTheLimit() public view {
        string memory a = card.render("subpage16", "", bytes32(0), PageCard.Status.Active, 0);
        _has(a, '<g transform="translate(500 784) scale(0.750)"');
        string memory b = card.render("subpage15", "", bytes32(0), PageCard.Status.Active, 0);
        _has(b, '<g transform="translate(500 784) scale(0.749)"');
        assertEq(reader.read(a).name, "subpage16");
        assertEq(reader.read(b).name, "subpage15");
    }

    // the dimmed part: there for a subpage, and not for a top level page or a cut subpage
    function test_dimmedPartPresentAndAbsent() public view {
        assertEq(_card("bob", "alice").dimmed, ".alice", "a subpage");
        assertEq(_card("bob", "").dimmed, "", "a top level page");
        assertEq(_card("bob", "abcdefghijklmnop").dimmed, "", "a cut subpage");
        string memory svg = card.render("bob", "", bytes32(0), PageCard.Status.Active, 0);
        assertFalse(LibString.contains(svg, '<g fill="#a3a2aa">'), "no dimmed group");
    }

    // _footer and _pill: every status, an active top level page and an active subpage, with a dot and without
    function test_footerOfEveryStatus() public view {
        string[5] memory word = ["Until 1 Jan 1970", "Grace period", "Expired", "Invalid", "Trial"];
        string[5] memory dot = ["", "#ffc94a", "#e5484d", "#e5484d", "#7193f2"];
        for (uint256 i; i < 5; ++i) {
            string memory svg = card.render("a", "", bytes32(0), PageCard.Status(i), 0);
            CardReader.Card memory c = reader.read(svg);
            assertEq(c.left, word[i], "the word");
            assertEq(c.dot, dot[i], "the dot");
            assertEq(LibString.contains(svg, "<circle"), i != 0, "a dot for every status but Active");
        }
        assertEq(_card("a", "alice").left, ".alice", "an active subpage");
        assertEq(_card("a", "alice").dot, "", "without a dot");
    }

    // _codeLetters and the right pill, which ends at 910 whatever its width: the code 00000000000000…000000 is 451
    // wide from 459, and ffffffffffffff…ffffff 285 wide from 625
    function test_rightPill() public view {
        string memory svg = card.render("a", "", bytes32(0), PageCard.Status.Active, 0);
        _has(svg, _rightPill("459", "451", "485"));
        assertEq(reader.read(svg).right, unicode"00000000000000…000000", "the code of zeros");
        svg = card.render("a", "", bytes32(type(uint256).max), PageCard.Status.Active, 0);
        _has(svg, _rightPill("625", "285", "651"));
        assertEq(reader.read(svg).right, unicode"ffffffffffffff…ffffff", "the code of f");
    }

    // an empty name has no letters, a width of 0 and the full scale
    function test_emptyName() public view {
        string memory svg = card.render("", "", bytes32(0), PageCard.Status.Active, 0);
        _has(svg, '<g transform="translate(500 784) scale(0.750)" fill="#19171c"></g>');
        assertEq(reader.read(svg).name, "", "no name");
    }

    // render and _fingerprint: the background and every colour of a live card and a dead one, and squares in both
    // groups, from high and low nibbles
    function test_liveAndDeadColours() public view {
        bytes32 id = bytes32(uint256(0x1200) << 240);
        for (uint256 i; i < 5; ++i) {
            bool dead = i == 2 || i == 3;
            string memory svg = card.render("a", "", id, PageCard.Status(i), 0);
            _has(svg, string.concat('<rect width="1000" height="1000" fill="', dead ? "#f6f6f8" : "#f1f4fe", '"/>'));
            _has(svg, string.concat('<g fill="', dead ? "#ebebef" : "#dce4fc", '">'));
            _has(svg, string.concat('</g><g fill="', dead ? "#a3a2aa" : "#7193f2", '">'));
            _has(svg, string.concat('scale(0.750)" fill="', dead ? "#6a6a70" : "#19171c", '">'));
            _has(svg, string.concat('<g transform="translate(', i == 0 ? "116" : "140", ' 881) scale(0.280)" fill="', dead ? "#6a6a70" : "#19171c", '">'));
            CardReader.Card memory c = reader.read(svg);
            assertEq(c.dead, dead, "dead only when Expired or Invalid");
            // the high nibble 1 of the first byte is odd and its low nibble 2 is even
            assertTrue(c.on[0] && !c.on[1], "squares from both nibbles");
        }
    }

    // every expiry gives Until, a day from 1 to 31 without a leading zero, one of the twelve months and a year from
    // 1970 on
    function testFuzz_dateIsAlwaysValid(uint256 expiry) public view {
        string memory left = reader.read(card.render("a", "", bytes32(0), PageCard.Status.Active, expiry)).left;
        string[] memory part = LibString.split(left, " ");
        assertEq(part.length, 4, "four words");
        assertEq(part[0], "Until");
        assertTrue(bytes(part[1])[0] != "0", "no leading zero");
        uint256 day = vm.parseUint(part[1]);
        assertGe(day, 1);
        assertLe(day, 31);
        assertTrue(LibString.contains("JanFebMarAprMayJunJulAugSepOctNovDec", part[2]) && bytes(part[2]).length == 3, part[2]);
        assertGe(vm.parseUint(part[3]), 1970, "a year from 1970");
    }

    // _formatDate: a leap day that ends a 400 year era of the date math, the first day of the next era, the last
    // day of a year, and January, where the year of the date math is one behind
    function test_dateEdges() public view {
        assertEq(_until(951782400), "Until 29 Feb 2000");
        assertEq(_until(951868800), "Until 1 Mar 2000");
        assertEq(_until(978220800), "Until 31 Dec 2000");
        assertEq(_until(0), "Until 1 Jan 1970");
    }

    function _until(uint256 expiry) internal view returns (string memory) {
        return reader.read(card.render("a", "", bytes32(0), PageCard.Status.Active, expiry)).left;
    }
}

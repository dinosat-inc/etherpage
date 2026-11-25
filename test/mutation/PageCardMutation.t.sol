// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {LibString} from "solady/utils/LibString.sol";
import {PageCard} from "../../src/PageCard.sol";
import {CardReader} from "../utils/CardReader.sol";

// Pins the parts of the card that the drawn fixtures leave open: every fingerprint square in both groups, the
// background and colours of live and dead cards, dates across months, years, leap days and the 400 year era, the
// pill of each status, the code and the short address, the cut of a long name and of a parent too wide for the left
// pill, the box for other bytes, the kerning and tracking of the name, its scale and baseline, the rounding of a
// pill's width and the place of its dot. The numbers are written out, and every card is also read back with the
// reader.
contract PageCardMutationTest is Test {
    using LibString for uint256;

    PageCard card;
    CardReader reader;

    function setUp() public {
        card = new PageCard();
        reader = new CardReader();
    }

    function _svg(bytes32 id) internal view returns (string memory) {
        return card.render("a", "", id, PageCard.Status.Active, 0);
    }

    function _name(string memory label, string memory parent) internal view returns (string memory) {
        return card.render(label, parent, bytes32(0), PageCard.Status.Active, 0);
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

    // the fingerprint of the squares in on: the light group of the others and the blue group of these, each in order
    function _fingerprint(uint256 on) internal pure returns (string memory light, string memory blue) {
        uint16[8] memory x = [uint16(90), 194, 298, 402, 506, 610, 714, 818];
        uint16[4] memory y = [uint16(90), 194, 298, 402];
        for (uint256 i; i < 32; ++i) {
            string memory sq = string.concat(
                '<rect x="', uint256(x[i % 8]).toString(), '" y="', uint256(y[i / 8]).toString(), '" width="92" height="92" rx="26"/>'
            );
            if (on >> i & 1 == 1) blue = string.concat(blue, sq);
            else light = string.concat(light, sq);
        }
        light = string.concat('<g fill="#dce4fc">', light, "</g>");
        blue = string.concat('<g fill="#7193f2">', blue, "</g>");
    }

    // nibble i alone odd: square i alone blue, at column i % 8 and row i / 8; bytes 16 to 28 of the id draw nothing,
    // as the squares show its first 16 bytes and the code its first 7 and its last 3
    function test_fingerprintSquares() public view {
        for (uint256 i; i < 32; ++i) {
            bytes32 id = bytes32(uint256(1) << (252 - 4 * i));
            string memory s = _svg(id);
            (string memory light, string memory blue) = _fingerprint(1 << i);
            _has(s, string.concat('<rect width="1000" height="1000" fill="#f1f4fe"/>', light, blue, '<rect x="40" y="560"'));
            CardReader.Card memory c = reader.read(s);
            for (uint256 k; k < 32; ++k) assertEq(c.on[k], k == i, "only square i");
            assertEq(_svg(id | bytes32(uint256(type(uint104).max) << 24)), s, "bytes 16 to 28 change nothing");
        }
        // all odd, all even, and nibbles 9 and 6 for odd and even past the lowest bit
        (string memory l0, string memory b0) = _fingerprint(type(uint32).max);
        _has(_svg(bytes32(type(uint256).max << 128)), string.concat(l0, b0));
        (l0, b0) = _fingerprint(0);
        _has(_svg(bytes32(0)), string.concat(l0, b0));
        (l0, b0) = _fingerprint(0x55555555);
        _has(_svg(bytes32(uint256(0x96969696969696969696969696969696) << 128)), string.concat(l0, b0));
    }

    // the background, the squares, the name and the left pill are grey on a dead card, Expired or Invalid; the panel
    // is white and the code muted on every card: 10000000000000…000000 is 1400 units, a pill of 444 from 466
    function test_backgroundAndColoursOfLiveAndDeadCards() public view {
        bytes32 id = bytes32(uint256(0x10) << 248);
        for (uint256 i; i < 5; ++i) {
            bool dead = i == 2 || i == 3;
            string memory s = card.render("a", "x", id, PageCard.Status(i), 0);
            _has(s, string.concat('<rect width="1000" height="1000" fill="', dead ? "#f6f6f8" : "#f1f4fe", '"/><g fill="', dead ? "#ebebef" : "#dce4fc", '">'));
            _has(s, string.concat('</g><g fill="', dead ? "#a3a2aa" : "#7193f2", '"><rect x="90" y="90" width="92" height="92" rx="26"/></g>'));
            _has(s, '<rect x="40" y="560" width="920" height="400" rx="56" fill="#ffffff"/>');
            _has(s, string.concat('scale(0.750)" fill="', dead ? "#6a6a70" : "#19171c", '">'));
            _has(s, string.concat('881) scale(0.280)" fill="', dead ? "#6a6a70" : "#19171c", '">'));
            _has(s, '<g transform="translate(492 881) scale(0.280)" fill="#6a6a70">');
            _has(s, '<g fill="#a3a2aa">');
            assertEq(reader.read(s).dead, dead, "dead");
        }
    }

    function _date(uint256 t) internal view returns (string memory) {
        return reader.read(card.render("a", "", bytes32(0), PageCard.Status.Active, t)).left;
    }

    // the left pill of an active top level page shows its expiry as a UTC date
    function test_datesAcrossMonthsYearsAndLeapDays() public view {
        uint256[22] memory t = [
            uint256(86399), 951868799, 978307199, 1709337599, 4102531199, 4107542399, 4107628799, 13574649599,
            253402300799, 1804291199, 988675199, 1685577599, 1686873599, 1688515199, 1693526399, 1696118399,
            1696204799, 1699747199, 1769903999, 0, type(uint64).max, type(uint256).max
        ];
        string[22] memory want = [
            "1 Jan 1970", "29 Feb 2000", "31 Dec 2000", "1 Mar 2024", "1 Jan 2100", "28 Feb 2100", "1 Mar 2100",
            "29 Feb 2400", "31 Dec 9999", "5 Mar 2027", "30 Apr 2001", "31 May 2023", "15 Jun 2023", "4 Jul 2023",
            "31 Aug 2023", "30 Sep 2023", "1 Oct 2023", "11 Nov 2023", "31 Jan 2026", "1 Jan 1970",
            "9 Nov 584554051223", "19 Feb 3669305236998687180674831492239425019668248843096144521164705134005822"
        ];
        for (uint256 i; i < 22; ++i) {
            assertEq(_date(t[i]), string.concat("Until ", want[i]));
        }
    }

    // the first and the last day of every month of a common year and of a leap year, and the first day of an era
    function test_firstAndLastDayOfEveryMonth() public view {
        uint256[48] memory t = [
            uint256(1672531200), 1675209599, 1675209600, 1677628799, 1677628800, 1680307199, 1680307200, 1682899199,
            1682899200, 1685577599, 1685577600, 1688169599, 1688169600, 1690847999, 1690848000, 1693526399,
            1693526400, 1696118399, 1696118400, 1698796799, 1698796800, 1701388799, 1701388800, 1704067199,
            1704067200, 1706745599, 1706745600, 1709251199, 1709251200, 1711929599, 1711929600, 1714521599,
            1714521600, 1717199999, 1717200000, 1719791999, 1719792000, 1722470399, 1722470400, 1725148799,
            1725148800, 1727740799, 1727740800, 1730419199, 1730419200, 1733011199, 1733011200, 1735689599
        ];
        string[48] memory want = [
            "1 Jan 2023", "31 Jan 2023", "1 Feb 2023", "28 Feb 2023", "1 Mar 2023", "31 Mar 2023",
            "1 Apr 2023", "30 Apr 2023", "1 May 2023", "31 May 2023", "1 Jun 2023", "30 Jun 2023",
            "1 Jul 2023", "31 Jul 2023", "1 Aug 2023", "31 Aug 2023", "1 Sep 2023", "30 Sep 2023",
            "1 Oct 2023", "31 Oct 2023", "1 Nov 2023", "30 Nov 2023", "1 Dec 2023", "31 Dec 2023",
            "1 Jan 2024", "31 Jan 2024", "1 Feb 2024", "29 Feb 2024", "1 Mar 2024", "31 Mar 2024",
            "1 Apr 2024", "30 Apr 2024", "1 May 2024", "31 May 2024", "1 Jun 2024", "30 Jun 2024",
            "1 Jul 2024", "31 Jul 2024", "1 Aug 2024", "31 Aug 2024", "1 Sep 2024", "30 Sep 2024",
            "1 Oct 2024", "31 Oct 2024", "1 Nov 2024", "30 Nov 2024", "1 Dec 2024", "31 Dec 2024"
        ];
        for (uint256 i; i < 48; ++i) {
            assertEq(_date(t[i]), string.concat("Until ", want[i]));
        }
        // 1 March 2000 is the first day of a 400 year era of the date math
        assertEq(_date(951868800), "Until 1 Mar 2000");
        assertEq(_date(951868799), "Until 29 Feb 2000");
    }

    // each status draws its own pill: its word, its dot colour, a width that holds both, and an active page no dot
    function test_footerOfEachStatus() public view {
        string[5] memory word = ["Until 1 Jan 1970", "Grace period", "Expired", "Invalid", "Trial"];
        string[5] memory dot = ["", "#ffc94a", "#e5484d", "#e5484d", "#7193f2"];
        uint16[5] memory width = [uint16(261), 250, 180, 167, 135];
        for (uint256 i; i < 5; ++i) {
            string memory s = card.render("a", "", bytes32(0), PageCard.Status(i), 0);
            string memory ink = i == 2 || i == 3 ? "#6a6a70" : "#19171c";
            string memory pill = string.concat('<rect x="90" y="840" width="', uint256(width[i]).toString(), '" height="62" rx="31" fill="#f6f6f8"/>');
            if (i == 0) {
                _has(s, string.concat(pill, '<g transform="translate(116 881) scale(0.280)" fill="', ink, '">'));
                assertFalse(LibString.contains(s, "<circle"), "no dot");
            } else {
                _has(s, string.concat(pill, '<circle cx="124" cy="871" r="8" fill="', dot[i], '"/><g transform="translate(140 881) scale(0.280)" fill="', ink, '">'));
            }
            CardReader.Card memory c = reader.read(s);
            assertEq(c.left, word[i], "the word");
            assertEq(c.dot, dot[i], "the dot");
        }
    }

    // the code in the right pill, which ends at 910: the first 14 and the last 6 of the 64 hex digits of the id, in
    // lower case, with the ellipsis between. 00112233445566…ddeeff is 1246 units, a pill of 401 from 509
    function test_codeAndShortAddress() public view {
        bytes32 id = 0x00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff;
        string memory s = _svg(id);
        _has(s, _rightPill("509", "401", "535"));
        assertEq(reader.read(s).right, unicode"00112233445566…ddeeff", "the code");
        assertEq(reader.code(id), unicode"00112233445566…ddeeff", "as the reader writes it");
        // zero digits at both ends stay, and so do letters next to them
        bytes32 ends = 0x00abcdef0123456789abcdef0123456789abcdef0123456789abcdef01abcd00;
        assertEq(reader.read(_svg(ends)).right, unicode"00abcdef012345…abcd00", "zeros at both ends");
        // all zeros, the widest code, 1425 units and a pill of 451 from 459; all f, 829 units with the kerning of each
        // pair of f and of f and the ellipsis, a pill of 285 from 625; all eights, 1345 units, a pill of 429 from 481
        s = _svg(bytes32(0));
        _has(s, _rightPill("459", "451", "485"));
        assertEq(reader.read(s).right, unicode"00000000000000…000000", "all zeros");
        s = _svg(bytes32(type(uint256).max));
        _has(s, _rightPill("625", "285", "651"));
        assertEq(reader.read(s).right, unicode"ffffffffffffff…ffffff", "all f");
        s = _svg(0x8888888888888888888888888888888888888888888888888888888888888888);
        _has(s, _rightPill("481", "429", "507"));
        assertEq(reader.read(s).right, unicode"88888888888888…888888", "all eights");
        // a dead card shows the code too, in the same ink
        s = card.render("a", "", id, PageCard.Status.Expired, 0);
        assertEq(reader.read(s).right, unicode"00112233445566…ddeeff", "a dead card's code");
        // one shown digit more or less gives another card: the last of the first 14 and the first of the last 6; a
        // digit the code leaves out past the squares, 32 to 57, gives the same card
        string memory base = _svg(id);
        string memory d13 = _svg(id ^ bytes32(uint256(1) << 200));
        string memory d58 = _svg(id ^ bytes32(uint256(1) << 20));
        assertFalse(keccak256(bytes(d13)) == keccak256(bytes(base)), "digit 13");
        assertFalse(keccak256(bytes(d58)) == keccak256(bytes(base)), "digit 58");
        assertEq(reader.read(d13).right, unicode"00112233445567…ddeeff", "digit 13 read back");
        assertEq(reader.read(d58).right, unicode"00112233445566…cdeeff", "digit 58 read back");
        assertEq(_svg(id ^ bytes32(uint256(type(uint104).max) << 24)), base, "digits 32 to 57");

        // the short form of an address, which the description of the metadata prints
        address p = 0x00112233445566778899AABbCCdDeeFf00112233;
        assertEq(card.shortAddress(p), unicode"0x001122334455…112233");
        assertEq(card.shortAddress(address(0)), unicode"0x000000000000…000000");
        assertEq(card.shortAddress(address(type(uint160).max)), unicode"0xffffffffffff…ffffff");
    }

    // a name of exactly 18 letters is drawn whole, 19 letters is cut to 17 and the ellipsis
    function test_cutAtTheLimit() public view {
        assertEq(reader.read(_name("abcdefghijklmnopqr", "")).name, "abcdefghijklmnopqr");
        assertEq(reader.read(_name("abcdefghijklmnopqrs", "")).name, unicode"abcdefghijklmnopq…");
        // a subpage counts the dot and the parent
        CardReader.Card memory c = reader.read(_name("abcdefgh", "ijklmnopq"));
        assertEq(c.name, "abcdefgh.ijklmnopq");
        assertEq(c.dimmed, ".ijklmnopq");
        c = reader.read(_name("abcdefgh", "ijklmnopqr"));
        assertEq(c.name, unicode"abcdefgh.ijklmnop…");
        assertEq(c.dimmed, "");
        // the parent in the left pill is cut on its own, as it is, in lower case
        assertEq(reader.read(_name("a", "abcdefghijklmnopqrs")).left, unicode".abcdefghijklmnopq…");
        assertEq(reader.read(_name("a", "a-z09")).left, ".a-z09");
        assertEq(reader.read(_name("a", "abcdefghijklmnopqr")).left, ".abcdefghijklmnopqr");
        // the bytes just outside a to z are boxes
        assertEq(reader.read(_name("a", "`az{")).left, ".?az?");
    }

    // the width in units of the small text of a run of a to z, 0 to 9, the hyphen and the dot, with the ellipsis
    // after it when ellipsis, as the reader takes it from tools/card-glyphs.json
    function _textWidth(string memory s, bool ellipsis) internal view returns (int256) {
        bytes memory letters = "abcdefghijklmnopqrstuvwxyz0123456789-.";
        bytes memory b = bytes(s);
        bytes memory n = new bytes(b.length + (ellipsis ? 1 : 0));
        for (uint256 i; i < b.length; ++i) {
            uint8 j;
            while (letters[j] != b[i]) ++j;
            n[i] = bytes1(j);
        }
        // the ellipsis is the letter after the dot
        if (ellipsis) n[b.length] = bytes1(uint8(letters.length));
        return reader.textWidth(n);
    }

    // the dot and the parent in the left pill of an active subpage take at most 1089 units, so that pill is at most
    // (1089 * 7 + 24) / 25 + 52 = 357 wide and ends at x 447, 12 before the widest code pill, the code of zeros, 1425
    // units and 451 wide from 459: no code is wider, as 0 has the largest advance of the 16 digits and no pair of the
    // letters of a code is kerned apart. .8888888888888888t is exactly 1089 units and stays whole, while .mmmmmmmmmmmm
    // is 1090 and is cut to .mmmmmmmmmmm and the ellipsis, 1066 units and a pill of 351
    function test_pillLimitIsExactly1089() public view {
        assertEq(_textWidth(".8888888888888888t", false), 1089, "1089 units");
        string memory s = _name("a", "8888888888888888t");
        _has(s, '<rect x="90" y="840" width="357" height="62"');
        _has(s, '<rect x="459" y="840" width="451" height="62"');
        assertEq(reader.read(s).left, ".8888888888888888t", "1089 units stay whole");
        assertEq(_textWidth(".mmmmmmmmmmmm", false), 1090, "1090 units");
        assertEq(_textWidth(".mmmmmmmmmmm", true), 1066, "1066 units");
        s = _name("a", "mmmmmmmmmmmm");
        _has(s, '<rect x="90" y="840" width="351" height="62"');
        assertEq(reader.read(s).left, unicode".mmmmmmmmmmm…", "1090 units are cut");
        // the code of zeros: 14 zeros, the ellipsis and 6 zeros
        bytes memory zeros = new bytes(21);
        for (uint256 i; i < 21; ++i) zeros[i] = bytes1(i == 14 ? 38 : 26);
        assertEq(reader.textWidth(zeros), 1425, "1425 units");
        // the letters of a code: 0 to 9 are 26 to 35, a to f are 0 to 5, and the ellipsis is 38
        bytes memory code = new bytes(17);
        for (uint256 i; i < 17; ++i) code[i] = bytes1(uint8(i < 10 ? 26 + i : i < 16 ? i - 10 : 38));
        assertEq(reader.textWidth(abi.encodePacked(code[0])), 68, "the advance of 0");
        for (uint256 i; i < 17; ++i) {
            int256 wi = reader.textWidth(abi.encodePacked(code[i]));
            if (i != 0 && i != 16) assertLt(wi, 68, "0 has the largest advance");
            for (uint256 j; j < 17; ++j) {
                int256 wj = reader.textWidth(abi.encodePacked(code[j]));
                assertLe(reader.textWidth(abi.encodePacked(code[i], code[j])), wi + wj, "no pair kerned apart");
            }
        }
    }

    // the cut drops one letter at a time from the end and stops at the first width that fits: .wwwwwwwwwwwww is 1110
    // units and the dot, twelve w and the ellipsis 1085, a pill of 356, so one w is enough; .stuvwxyz0123456789 is
    // 1095 units and its first 17 letters and the ellipsis still 1098, so it takes two, for 1025 units
    function test_fitDropsOneLetterWhenOneIsEnough() public view {
        assertEq(_textWidth(".wwwwwwwwwwwww", false), 1110, "1110 units");
        assertEq(_textWidth(".wwwwwwwwwwww", true), 1085, "1085 units");
        string memory s = _name("a", "wwwwwwwwwwwww");
        _has(s, '<rect x="90" y="840" width="356" height="62"');
        assertEq(reader.read(s).left, unicode".wwwwwwwwwwww…", "twelve w and the ellipsis");
        assertEq(_textWidth(".stuvwxyz0123456789", false), 1095, "1095 units");
        assertEq(_textWidth(".stuvwxyz012345678", true), 1098, "1098 units");
        assertEq(_textWidth(".stuvwxyz01234567", true), 1025, "1025 units");
        assertEq(reader.read(_name("a", "stuvwxyz0123456789")).left, unicode".stuvwxyz01234567…", "two dropped");
    }

    // every byte is one letter, whatever UTF 8 would make of it: 20 bytes from any first byte draw 17 letters and
    // the ellipsis in the name, and as many as fit and the ellipsis in the left pill
    function test_everyByteIsOneLetter() public view {
        uint8[9] memory lead = [0x00, 0x7f, 0x80, 0xc2, 0xdf, 0xe0, 0xef, 0xf0, 0xff];
        uint256[9] memory len = [uint256(1), 1, 2, 2, 2, 3, 3, 4, 4];
        for (uint256 i; i < 9; ++i) {
            // characters of len bytes, the first one lead and the rest 0x80, 20 bytes in all
            bytes memory s = new bytes(20);
            for (uint256 j; j < 20; ++j) s[j] = j % len[i] == 0 ? bytes1(lead[i]) : bytes1(0x80);
            assertEq(reader.read(_name(string(s), "")).name, unicode"?????????????????…", "17 boxes and the ellipsis");
            // the box is wide, so the left pill has room for 16 of them before its ellipsis
            assertEq(reader.read(_name("a", string(s))).left, unicode".????????????????…", "in the pill too");
        }
    }

    // each of the 256 bytes, 16 at a time: in the name only a to z, 0 to 9, the hyphen and the dot draw themselves;
    // in the small text also the space and the capitals ADEFGIJMNOSTU; every other byte draws the box
    function test_everyOtherByteDrawsTheBox() public view {
        string[16] memory name;
        string[16] memory small;
        for (uint256 r; r < 16; ++r) (name[r], small[r]) = ("????????????????", "????????????????");
        (name[2], small[2]) = ("?????????????-.?", " ????????????-.?");
        (name[3], small[3]) = ("0123456789??????", "0123456789??????");
        small[4] = "?A??DEFG?IJ??MNO";
        small[5] = "???STU??????????";
        (name[6], small[6]) = ("?abcdefghijklmno", "?abcdefghijklmno");
        (name[7], small[7]) = ("pqrstuvwxyz?????", "pqrstuvwxyz?????");
        for (uint256 r; r < 16; ++r) {
            bytes memory row = new bytes(16);
            for (uint256 j; j < 16; ++j) row[j] = bytes1(uint8(r * 16 + j));
            assertEq(reader.read(_name(string(row), "")).name, name[r], "a row of bytes in the name");
            assertEq(reader.read(_name("a", string(row))).left, string.concat(".", small[r]), "a row of bytes in the pill");
        }
    }

    // kerning and tracking of the name: each letter moves on by its advance less 6, and a kerned pair by its kerning.
    // n is 137 wide: nnn is 399 units, so it starts at -199 and steps by 131. - is 116 wide and kerned by 20 before n:
    // -n is 267 units, n at -133 + 110 + 20. n and o are not kerned: no is 258 units, o at -129 + 131.
    function test_kerningAndTrackingOfTheName() public view {
        string memory n = '" d="M11 0v-112h39v24c5-16';
        _has(_name("nnn", ""), string.concat('<path transform="translate(-199)', n));
        _has(_name("nnn", ""), string.concat('<path transform="translate(-68)', n));
        _has(_name("nnn", ""), string.concat('<path transform="translate(63)', n));
        _has(_name("-n", ""), string.concat('<path transform="translate(-133)" d="M25-86h90v33h-90z"/><path transform="translate(-3)', n));
        _has(_name("no", ""), string.concat('<path transform="translate(-129)', n));
        _has(_name("no", ""), '<path transform="translate(2)" d="M63 1c-33 0-58-22');
        // the small text has no tracking, and T and r are kerned by -5: r at 58 - 5
        string memory t = card.render("a", "", bytes32(0), PageCard.Status.Trial, 0);
        _has(
            t,
            string.concat(
                '<g transform="translate(140 881) scale(0.280)" fill="#19171c"><path transform="translate(0)" ',
                'd="M23 0v-60h-22v-11h56v11h-21v60z"/><path transform="translate(53)" d="M7 0v-53h12v14h-1q2-7 5-11'
            )
        );
        // the dimmed part starts at the dot: bob.alice is 923 units, the dot at -78
        _has(_name("bob", "alice"), '<g fill="#a3a2aa"><path transform="translate(-78)" d="M30 1c-21');
        assertEq(reader.read(_name("bob", "alice")).dimmed, ".alice");
    }

    // the scale is 820000 / W thousandths, rounded down, when the name is wider than 820 pixels at 0.750, and the
    // baseline 732 + scale * 70 / 1000, rounded down; the first pen is -W / 2, rounded toward zero
    function test_scaleAndBaseline() public view {
        string[7] memory label = ["mmmmmmmmmm", "mmmmmmmmmmmmmmmmmm", "abcdefghijklmnopqr", "subpage15", "subpage16", "", "alice"];
        // 820000 / 2076 = 394.99, 820000 / 3732 = 219.7 and 820000 / 2065 = 397.09, then 1094 and 1093 units
        string[7] memory scale = ["394", "219", "397", "749", "750", "750", "750"];
        // 732 + 27.58, 732 + 15.33, 732 + 27.79, 732 + 52.43 and 732 + 52.5
        string[7] memory base = ["759", "747", "759", "784", "784", "784", "784"];
        for (uint256 i; i < 7; ++i) {
            string memory s = _name(label[i], "");
            _has(s, string.concat('<g transform="translate(500 ', base[i], ") scale(0.", scale[i], ')" fill="#19171c">'));
            assertEq(reader.read(s).name, label[i]);
        }
        // m is 213 wide: 10 of them are 2076 units, so the first pen is -1038; alice is 487, so -243
        _has(_name("mmmmmmmmmm", ""), 'fill="#19171c"><path transform="translate(-1038)"');
        _has(_name("alice", ""), 'fill="#19171c"><path transform="translate(-243)"');
    }

    // a pill is (W * 7 + 24) / 25 pixels of text, the width at 0.280 rounded up, and 52 around it. .docs is 257
    // units, 1823 / 25 = 72.92 and a pill of 124; Expired is 368, 2600 / 25 = 104, and 180 with its dot, where 23 in
    // place of 24 would give 179; .88 is 150 units, exactly 42 pixels, 1074 / 25 = 42.96 and a pill of 94, where 25
    // in place of 24 would give 95
    function test_pillWidthRounding() public view {
        _has(_name("a", "docs"), '<rect x="90" y="840" width="124" height="62"');
        string memory expired = card.render("a", "", bytes32(0), PageCard.Status.Expired, 0);
        _has(expired, '<rect x="90" y="840" width="180" height="62"');
        // a space at the end draws nothing but widens the pill by 24 units: .docs and a space is 281, a pill of 131
        _has(_name("a", "docs "), '<rect x="90" y="840" width="131" height="62"');
        // only a text width of a whole number of pixels, a multiple of 25 units, tells 24 from 25
        assertEq(_textWidth(".88", false), 150, "150 units");
        string memory s = _name("a", "88");
        _has(s, '<rect x="90" y="840" width="94" height="62"');
        assertEq(reader.read(s).left, ".88");
    }

    // the dot is 34 to the right of the pill's left edge, and the text starts 26 in, after 24 more for a dot
    function test_dotOffset() public view {
        string memory grace = card.render("a", "", bytes32(0), PageCard.Status.Grace, 0);
        _has(grace, '<circle cx="124" cy="871" r="8" fill="#ffc94a"/><g transform="translate(140 881)');
        _has(_name("a", ""), '<g transform="translate(116 881)');
        _has(_name("a", ""), _rightPill("459", "451", "485"));
    }
}

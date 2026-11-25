// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {LibString} from "solady/utils/LibString.sol";
import {PageCard} from "../../../src/PageCard.sol";
import {CardReader} from "../../utils/CardReader.sol";

// render over any label and parent bytes, invalid UTF 8 included, as a direct caller may pass them, and any id. It
// never reverts, stays within the 35777 bytes of the widest card, and is well formed XML of printable ASCII with no
// text in it. A byte only picks a letter: the reader reads back exactly the letters the spec gives for the bytes, cut
// at 18 letters and with the dimmed part only when not cut, the left pill also cut to its width, and the code of the
// id, and no byte of the input reaches the card, so other bytes that draw the same letters draw the same card.
contract CardAnyTextTest is Test {
    using LibString for uint256;

    PageCard card;
    CardReader reader;

    // the widest card over the whole ABI domain (test_widestCard): 8 has the longest outline in both faces, so it is
    // a page of 18 eights whose code is all eights, active until 28 Sep of a 70 digit year that is mostly eights. The
    // code of eights draws the most of any code (gate G-48). The website test, test/svgCard.test.ts, uses
    // the same number.
    uint256 constant MAX_CARD = 35777;

    // the letters by number: a to z, 0 to 9, the hyphen and the dot are 0 to 37 in both faces, then the ellipsis
    // and the box, and the small text adds the space and its capitals from 41
    bytes constant LETTERS = "abcdefghijklmnopqrstuvwxyz0123456789-.";
    bytes constant CAPITALS = "ADEFGIJMNOSTU";
    uint8 constant DOT = 37;
    uint8 constant ELLIPSIS = 38;
    uint8 constant BOX = 39;
    uint8 constant SPACE = 40;
    uint8 constant CAPITALS_FROM = 41;

    bytes constant HEX = "0123456789abcdef";
    // the id whose code is all eights, and the hex digits the code leaves out, 14 to 57
    bytes32 constant WIDEST_ID = 0x8888888888888888888888888888888888888888888888888888888888888888;
    bytes32 constant HIDDEN = 0x00000000000000ffffffffffffffffffffffffffffffffffffffffffff000000;
    string constant DIM_OPEN = '<g fill="#a3a2aa">';
    string constant LEFT_PILL = '<rect x="90" y="840" width="';

    function setUp() public {
        card = new PageCard();
        reader = new CardReader();
    }

    // the spec side of the comparison

    function _slice(bytes memory b, uint256 from, uint256 to) internal pure returns (bytes memory out) {
        out = new bytes(to - from);
        for (uint256 i; i < out.length; ++i) out[i] = b[from + i];
    }

    // the letter of each byte: itself for a to z, 0 to 9, the hyphen and the dot, and in the small text also for the
    // space and its capitals; the box for every other byte. One byte is one letter.
    function _numbers(bytes memory b, bool small) internal pure returns (bytes memory out) {
        bytes memory letters = LETTERS;
        bytes memory capitals = CAPITALS;
        out = new bytes(b.length);
        for (uint256 i; i < b.length; ++i) {
            uint8 n = BOX;
            for (uint8 j; j < letters.length && n == BOX; ++j) if (letters[j] == b[i]) n = j;
            if (small && b[i] == " ") n = SPACE;
            for (uint8 j; small && j < capitals.length && n == BOX; ++j) if (capitals[j] == b[i]) n = CAPITALS_FROM + j;
            out[i] = bytes1(n);
        }
    }

    // over 18 letters, the first 17 and the ellipsis
    function _cut(bytes memory numbers) internal pure returns (bytes memory) {
        if (numbers.length <= 18) return numbers;
        return bytes.concat(_slice(numbers, 0, 17), bytes1(ELLIPSIS));
    }

    // the left pill of a parent: while its letters are wider than 1089 units of the small text, it keeps one letter
    // fewer and ends with the ellipsis, so the pill ends at x 447 at most
    function _fit(bytes memory numbers) internal view returns (bytes memory out) {
        out = numbers;
        for (uint256 k = numbers.length - 1; reader.textWidth(out) > 1089; --k) {
            out = bytes.concat(_slice(numbers, 0, k), bytes1(ELLIPSIS));
        }
    }

    // the letters as the reader writes them: the box as ?, the ellipsis as the UTF 8 …
    function _show(bytes memory numbers) internal pure returns (string memory out) {
        bytes memory letters = LETTERS;
        bytes memory capitals = CAPITALS;
        for (uint256 i; i < numbers.length; ++i) {
            uint8 n = uint8(numbers[i]);
            bytes memory c = n <= DOT
                ? abi.encodePacked(letters[n])
                : n == ELLIPSIS ? bytes(unicode"…") : n == BOX ? bytes("?") : n == SPACE ? bytes(" ") : abi.encodePacked(capitals[n - CAPITALS_FROM]);
            out = string.concat(out, string(c));
        }
    }

    // nibble i of the id, the high nibble of each byte first
    function _nibble(bytes32 id, uint256 i) internal pure returns (uint8) {
        uint8 b = uint8(id[i / 2]);
        return i % 2 == 0 ? b >> 4 : b & 0x0f;
    }

    // the code of the id: its first 14 and last 6 hex digits, in lower case, with the ellipsis between
    function _code(bytes32 id) internal pure returns (string memory) {
        bytes memory h = new bytes(64);
        for (uint256 i; i < 64; ++i) h[i] = HEX[_nibble(id, i)];
        return string(bytes.concat(_slice(h, 0, 14), unicode"…", _slice(h, 58, 64)));
    }

    // what the card shows by the spec. date is the left pill of an active top level page, which no string changes.
    function _want(bytes memory label, bytes memory parent, bytes32 id, PageCard.Status st, string memory date)
        internal
        view
        returns (CardReader.Card memory w)
    {
        w.dead = st == PageCard.Status.Expired || st == PageCard.Status.Invalid;
        for (uint256 i; i < 32; ++i) w.on[i] = _nibble(id, i) % 2 == 1;
        bytes memory full = _numbers(label, false);
        if (parent.length != 0) full = bytes.concat(full, bytes1(DOT), _numbers(parent, false));
        w.name = _show(_cut(full));
        if (parent.length != 0 && full.length <= 18) w.dimmed = _show(_slice(full, label.length, full.length));
        if (st == PageCard.Status.Grace) (w.left, w.dot) = ("Grace period", "#ffc94a");
        else if (st == PageCard.Status.Trial) (w.left, w.dot) = ("Trial", "#7193f2");
        else if (st == PageCard.Status.Expired) (w.left, w.dot) = ("Expired", "#e5484d");
        else if (st == PageCard.Status.Invalid) (w.left, w.dot) = ("Invalid", "#e5484d");
        else if (parent.length == 0) w.left = date;
        else w.left = _show(_fit(bytes.concat(bytes1(DOT), _cut(_numbers(parent, true)))));
        w.right = _code(id);
    }

    // every byte that draws the box swapped for another byte that draws the box; the parent also shows in the small
    // text, so only its bytes that are boxes there too are swapped
    function _swapBoxes(bytes memory b, bool small) internal pure returns (bytes memory out) {
        bytes memory numbers = _numbers(b, small);
        out = new bytes(b.length);
        for (uint256 i; i < b.length; ++i) {
            out[i] = uint8(numbers[i]) != BOX ? b[i] : b[i] == 0xff ? bytes1(0x00) : bytes1(0xff);
        }
    }

    // the card side

    function _render(bytes memory label, bytes memory parent, bytes32 id, PageCard.Status st, uint256 expiry)
        internal
        view
        returns (bytes memory)
    {
        // a 30 million gas cap, so a loop that never ends fails here instead of running to the profile gas limit
        try card.render{gas: 30_000_000}(string(label), string(parent), id, st, expiry) returns (string memory svg) {
            return bytes(svg);
        } catch {
            assertTrue(false, "render reverted");
        }
    }

    function _assertCard(CardReader.Card memory got, CardReader.Card memory want) internal pure {
        assertEq(got.dead, want.dead, "dead");
        for (uint256 i; i < 32; ++i) assertEq(got.on[i], want.on[i], "a square of the fingerprint");
        assertEq(got.name, want.name, "the name");
        assertEq(got.dimmed, want.dimmed, "the dimmed part");
        assertEq(got.left, want.left, "the left pill");
        assertEq(got.dot, want.dot, "the dot");
        assertEq(got.right, want.right, "the right pill");
    }

    // draws the card and checks it: the size bound, the markup, that no byte of the input reaches it, and that it
    // reads as the spec says. The date of an active top level page is read from the card of two empty strings, as
    // no string changes it.
    function _check(bytes memory label, bytes memory parent, bytes32 id, uint8 status, uint256 expiry)
        internal
        view
        returns (bytes memory svg)
    {
        PageCard.Status st = PageCard.Status(status % 5);
        svg = _render(label, parent, id, st, expiry);
        assertLe(svg.length, MAX_CARD, "within the widest card");
        _checkMarkup(svg);
        assertEq(
            _render(_swapBoxes(label, false), _swapBoxes(parent, true), id, st, expiry),
            svg,
            "other bytes with the same letters draw the same card"
        );
        string memory date;
        if (st == PageCard.Status.Active && parent.length == 0) {
            date = reader.read(string(_render("", "", id, st, expiry))).left;
            assertTrue(LibString.startsWith(date, "Until "), "a date");
        }
        _assertCard(reader.read(string(svg)), _want(label, parent, id, st, date));
    }

    // a markup check that knows nothing of the card: printable ASCII only, one root svg holding only g, rect, path
    // and circle, tags close in order, every value quoted and free of < and &, and no text at all, as every letter
    // is a shape. It reads every byte of the card on every run, so the byte reads are in assembly and the checks
    // use require, which builds its message only when it fails.

    function _c(bytes memory s, uint256 i) internal pure returns (uint256 c) {
        require(i < s.length, "read past the end");
        assembly {
            c := byte(0, mload(add(add(s, 0x20), i)))
        }
    }

    function _isNameChar(uint256 c) internal pure returns (bool) {
        return (c >= 0x61 && c <= 0x7a) || (c >= 0x41 && c <= 0x5a) || c == 0x2d || c == 0x3a;
    }

    function _nameEnd(bytes memory s, uint256 i) internal pure returns (uint256 j) {
        j = i;
        while (j < s.length && _isNameChar(_c(s, j))) ++j;
        require(j > i, "a name");
    }

    // the index of the closing quote of a value that starts at k, which must hold no < or &
    function _valueEnd(bytes memory s, uint256 k) internal pure returns (uint256 e) {
        bool clean = true;
        assembly {
            let p := add(s, 0x20)
            let n := mload(s)
            for { e := k } lt(e, n) { e := add(e, 1) } {
                let c := byte(0, mload(add(p, e)))
                if eq(c, 0x22) { break }
                if or(eq(c, 0x3c), eq(c, 0x26)) { clean := 0 }
            }
        }
        require(clean, "no < or & in a value");
        require(e < s.length, "the value closes");
    }

    // reads the attributes of a start tag and returns the index after it and whether it closed itself
    function _attributes(bytes memory s, uint256 j) internal pure returns (uint256, bool) {
        while (true) {
            uint256 c = _c(s, j);
            if (c == 0x3e) return (j + 1, false);
            if (c == 0x2f) {
                require(_c(s, j + 1) == 0x3e, "a slash ends the tag");
                return (j + 2, true);
            }
            require(c == 0x20, "a space before each attribute");
            uint256 k = _nameEnd(s, j + 1);
            require(_c(s, k) == 0x3d && _c(s, k + 1) == 0x22, "a quoted value");
            j = _valueEnd(s, k + 2) + 1;
        }
        return (j, false);
    }

    function _tagHash(bytes memory s, uint256 i, uint256 j) internal pure returns (bytes32 h) {
        assembly {
            h := keccak256(add(add(s, 0x20), i), sub(j, i))
        }
    }

    function _checkAscii(bytes memory s) internal pure {
        bool ok = true;
        assembly {
            let p := add(s, 0x20)
            let n := mload(s)
            for { let i := 0 } lt(i, n) { i := add(i, 1) } {
                let c := byte(0, mload(add(p, i)))
                if or(lt(c, 0x20), gt(c, 0x7e)) {
                    ok := 0
                    break
                }
            }
        }
        require(ok, "printable ASCII only");
    }

    function _checkMarkup(bytes memory s) internal pure {
        _checkAscii(s);
        bytes32[8] memory open;
        uint256 depth;
        bool root;
        uint256 i;
        while (i < s.length) {
            require(_c(s, i) == 0x3c, "no text, only tags");
            if (_c(s, i + 1) == 0x2f) {
                uint256 j = _nameEnd(s, i + 2);
                require(_c(s, j) == 0x3e, "an end tag ends");
                require(depth > 0 && open[depth - 1] == _tagHash(s, i + 2, j), "tags close in order");
                --depth;
                i = j + 1;
            } else {
                uint256 j = _nameEnd(s, i + 1);
                require(depth > 0 || !root, "one root element");
                bytes32 name = _tagHash(s, i + 1, j);
                if (!root) require(name == keccak256("svg"), "the root is svg");
                else require(
                    name == keccak256("g") || name == keccak256("rect") || name == keccak256("path") || name == keccak256("circle"),
                    "only g, rect, path and circle in the root"
                );
                root = true;
                bool selfClosing;
                (i, selfClosing) = _attributes(s, j);
                if (!selfClosing) {
                    require(depth < 8, "nesting");
                    open[depth++] = name;
                }
            }
        }
        require(root && depth == 0, "every tag closed");
    }

    // input makers

    // in half the runs the expiry is one PageNFT can pass, at most type(uint64).max
    function _expiry(uint256 expiry, bool narrow) internal pure returns (uint256) {
        return narrow ? uint64(expiry) : expiry;
    }

    // in half the runs the code is all eights, the code that draws the most, with any hidden digits
    function _id(bytes32 id, bool widest) internal pure returns (bytes32) {
        return widest ? (id & HIDDEN) | (WIDEST_ID & ~HIDDEN) : id;
    }

    // mostly near the cut, sometimes long
    function _len(uint256 seed) internal pure returns (uint256) {
        return seed % 8 == 0 ? (seed >> 3) % 300 : (seed >> 3) % 25;
    }

    // bytes from the groups that matter to the card: its letters, the five characters XML reserves, the space and
    // the capitals of the small text, other printable ASCII, control bytes, continuation bytes, any first byte,
    // other upper case and whole multibyte characters
    function _mixed(uint256 seed, uint256 len) internal pure returns (bytes memory b) {
        b = new bytes(len);
        bytes memory plain = LETTERS;
        bytes memory reserved = "&<>\"'";
        bytes memory small = " ADEFGIJMNOSTU";
        bytes[5] memory whole = [bytes(hex"c3a9"), hex"e282ac", hex"f09f9880", hex"efbfbe", hex"e280a6"];
        uint256 i;
        while (i < len) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            uint256 r = seed >> 8;
            uint256 group = seed % 10;
            if (group < 2) b[i++] = plain[r % plain.length];
            else if (group == 2) b[i++] = reserved[r % 5];
            else if (group == 3) b[i++] = small[r % small.length];
            else if (group == 4) b[i++] = bytes1(uint8(0x20 + r % 95));
            else if (group == 5) b[i++] = bytes1(uint8(r % 2 == 0 ? r % 32 : 0x7f));
            else if (group == 6) b[i++] = bytes1(uint8(0x80 + r % 64));
            else if (group == 7) b[i++] = bytes1(uint8(0xc0 + r % 64));
            else if (group == 8) b[i++] = bytes1(uint8(0x41 + r % 26));
            else {
                // a whole character, cut short when it does not fit
                bytes memory w = whole[r % 5];
                for (uint256 k; k < w.length && i < len; ++k) b[i++] = w[k];
            }
        }
    }

    function _utf8(uint256 cp) internal pure returns (bytes memory) {
        if (cp < 0x80) return abi.encodePacked(uint8(cp));
        if (cp < 0x800) return abi.encodePacked(uint8(0xc0 | (cp >> 6)), uint8(0x80 | (cp & 0x3f)));
        if (cp < 0x10000) {
            return abi.encodePacked(uint8(0xe0 | (cp >> 12)), uint8(0x80 | ((cp >> 6) & 0x3f)), uint8(0x80 | (cp & 0x3f)));
        }
        return abi.encodePacked(
            uint8(0xf0 | (cp >> 18)), uint8(0x80 | ((cp >> 12) & 0x3f)), uint8(0x80 | ((cp >> 6) & 0x3f)), uint8(0x80 | (cp & 0x3f))
        );
    }

    // count characters XML allows, in every UTF 8 length, the five reserved ones often
    function _text(uint256 seed, uint256 count) internal pure returns (bytes memory b) {
        bytes memory reserved = "&<>\"'";
        for (uint256 i; i < count; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            uint256 r = seed >> 8;
            uint256 group = seed % 8;
            uint256 cp;
            if (group == 0) cp = 0x61 + r % 26;
            else if (group == 1) cp = uint8(reserved[r % 5]);
            else if (group == 2) cp = 0x20 + r % 95;
            else if (group == 3) cp = [uint256(0x9), 0xa, 0xd][r % 3];
            else if (group == 4) cp = 0x80 + r % 0x780;
            else if (group == 5) cp = r % 2 == 0 ? 0x800 + r % 0xd000 : 0xe000 + r % 0x1ffe;
            else if (group == 6) cp = 0x10000 + r % 0x100000;
            else cp = 0x41 + r % 26;
            b = bytes.concat(b, _utf8(cp));
        }
    }

    // the campaigns

    /// forge-config: default.fuzz.runs = 5000
    /// forge-config: deep.fuzz.runs = 5000
    function testFuzz_anyBytes(
        bytes memory label,
        bytes memory parent,
        bytes32 id,
        uint8 status,
        uint256 expiry,
        bool narrow
    ) public view {
        _check(label, parent, id, status, _expiry(expiry, narrow));
    }

    /// forge-config: default.fuzz.runs = 5000
    /// forge-config: deep.fuzz.runs = 5000
    function testFuzz_mixedBytesAroundTheCut(
        uint256 seedL,
        uint256 seedP,
        bool hasParent,
        bytes32 id,
        bool widest,
        uint8 status,
        uint256 expiry,
        bool narrow
    ) public view {
        bytes memory label = _mixed(seedL, _len(seedL));
        bytes memory parent = hasParent ? _mixed(seedP, _len(seedP)) : bytes("");
        _check(label, parent, _id(id, widest), status, _expiry(expiry, narrow));
    }

    // text a viewer would take as it is, multibyte characters included: each of its bytes is still one letter, so
    // a character of two to four bytes draws as many boxes
    /// forge-config: default.fuzz.runs = 5000
    /// forge-config: deep.fuzz.runs = 5000
    function testFuzz_xmlTextGivesAWellFormedCard(
        uint256 seedL,
        uint256 seedP,
        bool hasParent,
        bytes32 id,
        bool widest,
        uint8 status,
        uint256 expiry,
        bool narrow
    ) public view {
        bytes memory label = _text(seedL, _len(seedL) % 22);
        bytes memory parent = hasParent ? _text(seedP, _len(seedP) % 22) : bytes("");
        _check(label, parent, _id(id, widest), status, _expiry(expiry, narrow));
    }

    // pinned cases of bytes XML refuses: the call succeeds, none of the bytes reaches the card, and each byte draws
    // the box
    function test_bytesXmlRefusesDrawBoxes() public view {
        bytes[6] memory raw = [
            bytes(hex"610162"), // a control byte
            hex"efbfbe", // U+FFFE
            hex"efbfbf", // U+FFFF
            hex"eda080", // a surrogate, which is invalid UTF 8
            hex"c080", // an overlong form
            hex"fffe80" // two bytes that never occur in UTF 8, then a continuation byte
        ];
        string[6] memory name = ["a?b", "???", "???", "???", "??", "???"];
        for (uint256 i; i < raw.length; ++i) {
            bytes memory svg = _check(raw[i], "", bytes32(0), 0, 0);
            assertEq(reader.read(string(svg)).name, name[i], "a box for each byte");
            // the same bytes as a parent, in the name and in the left pill
            svg = _check("x", raw[i], bytes32(0), 0, 0);
            assertEq(reader.read(string(svg)).left, string.concat(".", name[i]), "a box for each byte in the pill");
        }
    }

    // the cut counts bytes, as each byte is one letter, and never looks at UTF 8: the first two bytes of a euro sign
    // after a stray continuation byte are kept as boxes, and so is the first byte of a 4 byte character cut short
    function test_cutCountsBytesNotCharacters() public view {
        bytes memory a15 = bytes("aaaaaaaaaaaaaaa");
        bytes memory stray = bytes.concat(a15, hex"80", hex"e282ac", "b");
        bytes memory svg = _check(stray, "", bytes32(0), 0, 0);
        assertEq(reader.read(string(svg)).name, unicode"aaaaaaaaaaaaaaa??…", "17 letters, two of them boxes");
        bytes memory short4 = bytes.concat(a15, "a", hex"f09f", "bb");
        svg = _check(short4, "", bytes32(0), 0, 0);
        assertEq(reader.read(string(svg)).name, unicode"aaaaaaaaaaaaaaaa?…", "half a character kept as a box");
        // 18 bytes of a 6 byte run of characters are drawn whole, as 18 boxes
        svg = _check(bytes(unicode"ééééééééé"), "", bytes32(0), 0, 0);
        assertEq(reader.read(string(svg)).name, "??????????????????", "18 bytes, 18 boxes");
    }

    // A, < and 0xff all draw the box in the name, so they draw the same card; in the left pill A is a capital
    function test_sameLettersSameCard() public view {
        bytes memory a = _check("A", "", bytes32(0), 0, 0);
        assertEq(_check("<", "", bytes32(0), 0, 0), a, "A and <");
        assertEq(_check(hex"ff", "", bytes32(0), 0, 0), a, "A and 0xff");
        bytes memory sub = _check("x", "A", bytes32(0), 0, 0);
        assertEq(reader.read(string(sub)).name, "x.?", "a box in the name");
        assertEq(reader.read(string(sub)).left, ".A", "a capital in the pill");
        assertFalse(keccak256(_check("x", "<", bytes32(0), 0, 0)) == keccak256(sub), "< is a box in the pill");
    }

    // spaces at the end of a parent draw nothing but widen the left pill of an active subpage by 24 units each:
    // .a is 80 units, a pill of (80 * 7 + 24) / 25 + 52 = 75, and .a and a space 104 units, a pill of 82
    function test_spacesAtTheEndOfTheParent() public view {
        bytes memory svg = _check("x", "a ", bytes32(0), 0, 0);
        assertTrue(LibString.contains(string(svg), string.concat(LEFT_PILL, '82" height="62"')), "82 wide");
        assertEq(reader.read(string(svg)).left, ".a ", "the reader reads the space from the width");
        svg = _check("x", "a", bytes32(0), 0, 0);
        assertTrue(LibString.contains(string(svg), string.concat(LEFT_PILL, '75" height="62"')), "75 wide");
        _check("x", "a   ", bytes32(0), 0, 0);
        _check("x", " ", bytes32(0), 0, 0);
        _check("", "  ", bytes32(0), 0, 0);
    }

    // an empty label under a parent dims the whole name, from its dot
    function test_emptyLabelUnderAParent() public view {
        bytes memory svg = _check("", "alice", bytes32(0), 0, 0);
        assertTrue(LibString.contains(string(svg), string.concat('fill="#19171c">', DIM_OPEN, '<path')), "dimmed from the first letter");
        assertEq(reader.read(string(svg)).dimmed, ".alice", "the whole name is dimmed");
        // over 18 letters it is cut and nothing is dimmed
        svg = _check("", "abcdefghijklmnopqr", bytes32(0), 0, 0);
        assertFalse(LibString.contains(string(svg), DIM_OPEN), "cut, so not dimmed");
    }

    // the widest card over the whole ABI domain is exactly MAX_CARD: 18 eights, active until 28 Sep of a 70 digit
    // year, with the code of eights. The hidden digits of the id do not change the length, as every card draws all 32
    // squares, and another code draws less.
    function test_widestCard() public view {
        uint256 expiry = 106943003999999999999999999999999999999999999999999999999999999999937828201600;
        bytes memory svg = _check("888888888888888888", "", WIDEST_ID, 0, expiry);
        assertEq(svg.length, MAX_CARD, "the widest card");
        assertEq(
            reader.read(string(svg)).left,
            "Until 28 Sep 3388888888888888888888888888888888888888888888888888888888888888888888",
            "a date of eights"
        );
        PageCard.Status active = PageCard.Status.Active;
        bytes memory e18 = "888888888888888888";
        assertEq(_render(e18, "", WIDEST_ID ^ HIDDEN, active, expiry).length, MAX_CARD, "any hidden digits");
        assertLt(_render(e18, "", bytes32(type(uint256).max), active, expiry).length, MAX_CARD, "another code");
    }
}

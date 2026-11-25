// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Vm} from "forge-std/Vm.sol";

// Reads a card back into what it shows, the way a person reads it: the name and its dimmed part, the text and dot
// of the left pill, the code of the page in the right pill, which fingerprint squares are on and whether the card is
// dead. It knows the letters only from tools/card-glyphs.json, never from PageCard, and it checks the whole drawing
// on the way: the fixed markup, every square once, every letter a known outline, every letter where the advances,
// kerning and tracking of the JSON put it, with the name centred and scaled and each pill as wide as its text, and a
// code of 14 hex digits, the ellipsis and 6 more whose first 14 digits are odd exactly where their squares are blue.
// Spaces are drawn as nothing, so a space is read from the gap it leaves, or at the end of a pill from the width it
// adds. A card it cannot read reverts with the reason, so a test that reads a card also checks it.
contract CardReader {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    struct Card {
        bool dead;
        bool[32] on;
        string name;
        string dimmed;
        string left;
        string dot;
        string right;
    }

    struct Face {
        string[] chars;
        uint256[] advances;
        uint256 space;
    }

    // the letter of an outline, plus one, for each face
    mapping(bytes32 => uint256) private nameLetter;
    mapping(bytes32 => uint256) private textLetter;
    // the kerning of a pair, first * 256 + second, for each face
    mapping(uint256 => int256) private nameKern;
    mapping(uint256 => int256) private textKern;
    Face private nameFace;
    Face private textFace;

    bytes private constant HEAD =
        '<svg xmlns="http://www.w3.org/2000/svg" width="1000" height="1000" viewBox="0 0 1000 1000"><rect width="1000" height="1000" fill="';

    constructor() {
        string memory json = vm.readFile("tools/card-glyphs.json");
        _load(json, ".name", nameFace, nameLetter, nameKern);
        _load(json, ".text", textFace, textLetter, textKern);
    }

    function _load(
        string memory json,
        string memory key,
        Face storage face,
        mapping(bytes32 => uint256) storage letterOf,
        mapping(uint256 => int256) storage kernOf
    ) private {
        face.space = type(uint256).max;
        for (uint256 i; vm.keyExistsJson(json, _item(key, ".glyphs", i)); ++i) {
            string memory g = _item(key, ".glyphs", i);
            string memory ch = vm.parseJsonString(json, string.concat(g, ".char"));
            string memory d = vm.parseJsonString(json, string.concat(g, ".d"));
            // the box stands for any byte the face has no letter for
            face.chars.push(keccak256(bytes(ch)) == keccak256(hex"00") ? "?" : ch);
            face.advances.push(vm.parseJsonUint(json, string.concat(g, ".advance")));
            if (bytes(d).length == 0) face.space = i;
            else letterOf[keccak256(bytes(d))] = i + 1;
        }
        for (uint256 i; vm.keyExistsJson(json, _item(key, ".kern", i)); ++i) {
            int256[] memory k = vm.parseJsonIntArray(json, _item(key, ".kern", i));
            kernOf[uint256(k[0]) * 256 + uint256(k[1])] = k[2];
        }
    }

    function _item(string memory key, string memory list, uint256 i) private pure returns (string memory) {
        return string.concat(key, list, "[", vm.toString(i), "]");
    }

    // ------------------------------------------------------------------------------------------------- reading

    // the code of a page as the right pill shows it: the first 14 and the last 6 of the 64 hex digits of its id, in
    // lower case, with the ellipsis between
    function code(bytes32 id) external pure returns (string memory) {
        bytes memory h = "0123456789abcdef";
        bytes memory head = new bytes(14);
        bytes memory tail = new bytes(6);
        for (uint256 i; i < 14; ++i) head[i] = h[uint256(id) >> (252 - 4 * i) & 0xf];
        for (uint256 i; i < 6; ++i) tail[i] = h[uint256(id) >> (20 - 4 * i) & 0xf];
        return string.concat(string(head), unicode"…", string(tail));
    }

    // the width of a run of small text letters, as the JSON gives it: their advances and the kerning of each pair
    function textWidth(bytes memory letters) external view returns (int256 w) {
        for (uint256 i; i < letters.length; ++i) {
            w += int256(textFace.advances[uint8(letters[i])]);
            if (i != 0) w += textKern[uint256(uint8(letters[i - 1])) * 256 + uint8(letters[i])];
        }
    }

    function read(string memory svg) external view returns (Card memory c) {
        bytes memory b = bytes(svg);
        uint256 p = _lit(b, 0, HEAD);
        string memory bg;
        (bg, p) = _colour(b, p);
        c.dead = _eq(bg, "#f6f6f8");
        require(c.dead || _eq(bg, "#f1f4fe"), "background");
        p = _lit(b, p, '"/>');
        uint256 even;
        uint256 odd;
        (even, p) = _squares(b, p, c.dead, false);
        (odd, p) = _squares(b, p, c.dead, true);
        require(even & odd == 0 && even | odd == 0xffffffff, "each of the 32 squares once");
        for (uint256 i; i < 32; ++i) c.on[i] = odd >> i & 1 == 1;
        p = _lit(b, p, '<rect x="40" y="560" width="920" height="400" rx="56" fill="#ffffff"/>');
        p = _name(b, p, c);
        uint256 x;
        uint256 w;
        string memory ink;
        (c.left, c.dot, ink, x, w, p) = _pill(b, p);
        require(x == 90, "the left pill starts at 90");
        require(_eq(ink, c.dead ? "#6a6a70" : "#19171c"), "the ink of the left pill");
        string memory noDot;
        (c.right, noDot, ink, x, w, p) = _pill(b, p);
        require(x + w == 910, "the right pill ends at 910");
        require(bytes(noDot).length == 0 && _eq(ink, "#6a6a70"), "the right pill");
        _code(c);
        p = _lit(b, p, "</svg>");
        require(p == b.length, "the card ends with </svg>");
    }

    // the right pill holds a code: 14 hex digits in lower case, the ellipsis and 6 more. Its first 14 digits are the
    // first 14 nibbles of the id, so each is odd exactly where its square of the fingerprint is blue
    function _code(Card memory c) private pure {
        bytes memory r = bytes(c.right);
        require(
            r.length == 23 && r[14] == 0xe2 && r[15] == 0x80 && r[16] == 0xa6, "a code of 14 digits, the ellipsis and 6"
        );
        for (uint256 i; i < 23; ++i) {
            if (i == 14) i = 17;
            uint8 ch = uint8(r[i]);
            require((ch >= 0x30 && ch <= 0x39) || (ch >= 0x61 && ch <= 0x66), "a hex digit of the code");
            uint8 v = ch <= 0x39 ? ch - 0x30 : ch - 0x57;
            if (i < 14) require((v % 2 == 1) == c.on[i], "a digit of the code odd exactly where its square is blue");
        }
    }

    // one group of squares, the even nibbles first and then the odd ones, each square in order of its nibble; returns
    // the squares it holds as bits
    function _squares(bytes memory b, uint256 p, bool dead, bool odd) private pure returns (uint256 mask, uint256) {
        p = _lit(b, p, odd ? bytes('</g><g fill="') : bytes('<g fill="'));
        string memory fill;
        (fill, p) = _colour(b, p);
        string memory want = odd ? (dead ? "#a3a2aa" : "#7193f2") : (dead ? "#ebebef" : "#dce4fc");
        require(_eq(fill, want), "the colour of a group of squares");
        p = _lit(b, p, '">');
        int256 last = -1;
        while (_at(b, p, '<rect x="')) {
            uint256 x;
            uint256 y;
            (x, p) = _uint(b, p + 9);
            p = _lit(b, p, '" y="');
            (y, p) = _uint(b, p);
            p = _lit(b, p, '" width="92" height="92" rx="26"/>');
            require(x >= 90 && (x - 90) % 104 == 0 && x <= 818 && y >= 90 && (y - 90) % 104 == 0 && y <= 402, "a square");
            uint256 i = (y - 90) / 104 * 8 + (x - 90) / 104;
            require(int256(i) > last, "squares in order");
            last = int256(i);
            mask |= 1 << i;
        }
        if (odd) p = _lit(b, p, "</g>");
        return (mask, p);
    }

    function _name(bytes memory b, uint256 p, Card memory c) private view returns (uint256) {
        uint256 base;
        uint256 scale;
        p = _lit(b, p, '<g transform="translate(500 ');
        (base, p) = _uint(b, p);
        p = _lit(b, p, ") scale(0.");
        require(p + 3 <= b.length, "scale");
        for (uint256 i; i < 3; ++i) {
            require(b[p + i] >= "0" && b[p + i] <= "9", "scale");
            scale = scale * 10 + (uint8(b[p + i]) - 48);
        }
        p = _lit(b, p + 3, ')" fill="');
        string memory ink;
        (ink, p) = _colour(b, p);
        require(_eq(ink, c.dead ? "#6a6a70" : "#19171c"), "the ink of the name");
        p = _lit(b, p, '">');
        uint256[] memory letters = new uint256[](64);
        int256[] memory pens = new int256[](64);
        uint256 n;
        uint256 dimFrom = type(uint256).max;
        bool dimClosed;
        while (true) {
            if (_at(b, p, "<path")) {
                require(!dimClosed, "no letter after the dimmed part");
                (letters[n], pens[n], p) = _letter(b, p, true);
                ++n;
            } else if (_at(b, p, '<g fill="#a3a2aa">')) {
                // an empty label under a parent leaves the whole name dimmed
                require(dimFrom == type(uint256).max, "one dimmed part");
                dimFrom = n;
                p += 18;
            } else {
                p = _lit(b, p, "</g>");
                if (dimFrom != type(uint256).max && !dimClosed) {
                    dimClosed = true;
                    continue;
                }
                break;
            }
        }
        // the width, as the JSON gives it: advances, tracking of -6 and kerning between letters
        int256 width;
        for (uint256 i; i < n; ++i) {
            width += int256(nameFace.advances[letters[i]]);
            if (i != 0) width += -6 + nameKern[letters[i - 1] * 256 + letters[i]];
        }
        int256 pen = -(width / 2);
        for (uint256 i; i < n; ++i) {
            if (i != 0) pen += nameKern[letters[i - 1] * 256 + letters[i]];
            require(pens[i] == pen, "a letter of the name where the advances put it");
            pen += int256(nameFace.advances[letters[i]]) - 6;
        }
        uint256 wantScale = width > 0 && uint256(width) * 750 > 820_000 ? 820_000 / uint256(width) : 750;
        require(scale == wantScale, "the name as large as fits");
        require(base == 732 + scale * 70 / 1000, "the baseline of the name");
        for (uint256 i; i < n; ++i) {
            if (i < dimFrom) c.name = string.concat(c.name, nameFace.chars[letters[i]]);
            else c.dimmed = string.concat(c.dimmed, nameFace.chars[letters[i]]);
        }
        c.name = string.concat(c.name, c.dimmed);
        require(dimFrom == type(uint256).max || _eq(nameFace.chars[letters[dimFrom]], "."), "the dimmed part starts at the dot");
        return p;
    }

    function _pill(bytes memory b, uint256 p)
        private
        view
        returns (string memory text, string memory dot, string memory ink, uint256 x, uint256 w, uint256)
    {
        p = _lit(b, p, '<rect x="');
        (x, p) = _uint(b, p);
        p = _lit(b, p, '" y="840" width="');
        (w, p) = _uint(b, p);
        p = _lit(b, p, '" height="62" rx="31" fill="#f6f6f8"/>');
        uint256 dotWidth;
        if (_at(b, p, '<circle cx="')) {
            uint256 cx;
            (cx, p) = _uint(b, p + 12);
            require(cx == x + 34, "the dot");
            p = _lit(b, p, '" cy="871" r="8" fill="');
            (dot, p) = _colour(b, p);
            p = _lit(b, p, '"/>');
            dotWidth = 24;
        }
        p = _lit(b, p, '<g transform="translate(');
        uint256 textX;
        (textX, p) = _uint(b, p);
        require(textX == x + 26 + dotWidth, "the text of a pill");
        p = _lit(b, p, ' 881) scale(0.280)" fill="');
        (ink, p) = _colour(b, p);
        p = _lit(b, p, '">');
        int256 pen;
        int256 space = int256(textFace.advances[textFace.space]);
        (text, pen, p) = _pillLetters(b, p, space);
        p = _lit(b, p, "</g>");
        // spaces at the end draw nothing but widen the pill
        while ((uint256(pen) * 7 + 24) / 25 + 52 + dotWidth < w) {
            pen += space;
            text = string.concat(text, " ");
        }
        require(w == (uint256(pen) * 7 + 24) / 25 + 52 + dotWidth, "a pill as wide as its text");
        return (text, dot, ink, x, w, p);
    }

    // the letters of a pill and the pen after them, apart from _pill so that the coverage build fits the stack
    function _pillLetters(bytes memory b, uint256 p, int256 space)
        private
        view
        returns (string memory text, int256 pen, uint256)
    {
        uint256 last = type(uint256).max;
        while (_at(b, p, "<path")) {
            uint256 l;
            int256 drawnAt;
            (l, drawnAt, p) = _letter(b, p, false);
            if (last != type(uint256).max) pen += textKern[last * 256 + l];
            // a gap of whole spaces before the letter; a space kerns with nothing
            int256 gap = drawnAt - pen;
            require(gap >= 0, "a letter of a pill where the advances put it");
            if (gap != 0) {
                if (last != type(uint256).max) pen -= textKern[last * 256 + l];
                gap = drawnAt - pen;
                require(gap > 0 && gap % space == 0, "a gap of whole spaces");
                for (int256 s; s < gap / space; ++s) text = string.concat(text, " ");
                pen = drawnAt;
            }
            text = string.concat(text, textFace.chars[l]);
            pen += int256(textFace.advances[l]);
            last = l;
        }
        return (text, pen, p);
    }

    // one <path transform="translate(PEN)" d="OUTLINE"/>, read as the letter of the outline in its face
    function _letter(bytes memory b, uint256 p, bool name) private view returns (uint256 letter, int256 pen, uint256) {
        p = _lit(b, p, '<path transform="translate(');
        bool neg = p < b.length && b[p] == "-";
        uint256 v;
        (v, p) = _uint(b, neg ? p + 1 : p);
        pen = neg ? -int256(v) : int256(v);
        p = _lit(b, p, ')" d="');
        uint256 end = p;
        while (end < b.length && b[end] != '"') ++end;
        bytes memory d = new bytes(end - p);
        for (uint256 i; i < d.length; ++i) d[i] = b[p + i];
        uint256 found = name ? nameLetter[keccak256(d)] : textLetter[keccak256(d)];
        require(found != 0, "an outline that is no letter of its face");
        letter = found - 1;
        p = _lit(b, end, '"/>');
        return (letter, pen, p);
    }

    // ------------------------------------------------------------------------------------------------- bytes

    function _at(bytes memory b, uint256 p, bytes memory lit) private pure returns (bool) {
        if (p + lit.length > b.length) return false;
        for (uint256 i; i < lit.length; ++i) if (b[p + i] != lit[i]) return false;
        return true;
    }

    function _lit(bytes memory b, uint256 p, bytes memory lit) private pure returns (uint256) {
        require(_at(b, p, lit), string.concat("expected ", string(lit)));
        return p + lit.length;
    }

    function _uint(bytes memory b, uint256 p) private pure returns (uint256 v, uint256) {
        uint256 start = p;
        while (p < b.length && b[p] >= "0" && b[p] <= "9") v = v * 10 + (uint8(b[p++]) - 48);
        require(p > start && (b[start] != "0" || p == start + 1), "a number");
        return (v, p);
    }

    function _colour(bytes memory b, uint256 p) private pure returns (string memory c, uint256) {
        require(p + 7 <= b.length && b[p] == "#", "a colour");
        bytes memory out = new bytes(7);
        for (uint256 i; i < 7; ++i) out[i] = b[p + i];
        return (string(out), p + 7);
    }

    function _eq(string memory a, string memory b) private pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}

// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {LibString} from "solady/utils/LibString.sol";
import {PageCard} from "../../../src/PageCard.sol";
import {RulesBase} from "../../utils/RulesBase.sol";
import {trialCommitment} from "../../utils/TrialCommitment.sol";

// How long tokenURI gets. The JSON is fixed text, the name twice, for a subpage its parent's label once more, the
// shortened payee, which is always 23 bytes, the card in base64 and the property values, so its length follows from
// the card's. A subpage has no Length, Expires or Deposit. The largest, while expiries have ten digits, is the
// metadata of an active subpage of 63 eights under 88888888888aaaa88 whose code is all eights, which draws the widest
// subpage card. A token id is a hash, so a real token reaches it only if the 80 bits of its code are all eights, and
// the bounds hold for every id. The widest card of all is a top level page dated in a year of twelve digits, which no
// registration reaches, and its metadata stays inside the bounds.
contract MetadataSizeTest is RulesBase {
    // the bound on every card PageNFT can produce, a top level page of 18 eights until 28 Sep 388888888888 with the
    // code of eights, and the widest subpage card, that subpage's (WorkedExamplesTest.test_cardBounds), also with the
    // code of eights; the id changes the length of a card only through its code
    uint256 constant CARD_MAX = 19060;
    uint256 constant SUBPAGE_MAX = 18862;
    // the bounds for any card of at most CARD_MAX bytes with every property at its widest: the fixed parts of both
    // kinds of name, 390, Subpage and Invalid, 14, a Length of two digits, a full name of 127 twice and a parent label
    // of 63, 317, the payee, 23, a uint64 expiry and the widest deposit, 85, and 25416 for the card in base64
    uint256 constant JSON_BOUND = 26247;
    uint256 constant URI_BOUND = 35025;
    // the largest JSON and tokenURI of any name, while expiries have ten digits and deposits stay under 10 ether: the
    // fixed parts of a subpage, 219, Subpage and Active, 13, a full name of 81 twice and the parent's 17, 179, the
    // payee, 23, and the widest subpage card in base64, 25152
    uint256 constant JSON_MAX = 25586;
    uint256 constant URI_MAX = 34145;
    // the JSON bytes every name has, the ones only a top level name adds, its Length, Expires and Deposit with their
    // values left out, and the ones only a subpage adds, the sentence about its parent's holder with the parent's
    // label left out
    uint256 constant FIXED = 162;
    uint256 constant TOP_FIXED = 171;
    uint256 constant SUB_FIXED = 57;
    // data:application/json;base64,
    uint256 constant PREFIX = 29;
    // 0x, twelve hex digits, an ellipsis of three bytes and six hex digits
    uint256 constant PAYEE = 23;
    // an expiry before the year 2286 has ten digits, and a deposit under 10 ether takes at most six characters,
    // which a name of 63 characters reaches only after 100000 paid years
    uint256 constant EXPIRY_DIGITS = 10;
    uint256 constant DEPOSIT_CHARS = 6;
    // the widest values of the types: a uint64 expiry, and a deposit of 60 digits, a dot and four decimals
    uint256 constant EXPIRY_DIGITS_TYPE = 20;
    uint256 constant DEPOSIT_CHARS_TYPE = 65;
    // 8 has the longest outline of every letter a label or a code can hold, so the widest cards are drawn with eights
    // in the name, the code and the year, though the widest parent mixes eights with narrower letters. The code of this
    // id, twenty eights, draws the most of any code
    bytes32 constant WIDEST_ID = 0x8888888888888888888888888888888888888888888888888888888888888888;
    // the parent whose left pill draws the most within its 1089 units, and the widest pill that ends with the
    // ellipsis, as test/svgCard.test.ts finds them by searching every parent and gate G-48 checks with the same search
    string constant WIDEST_PARENT = "88888888888aaaa88";
    string constant WIDEST_CUT = "88888888888aaaa8";
    // 28 Sep 2088, the date of ten digits whose letters draw the widest left pill, and 28 Sep 388888888888, the
    // latest date of eights a uint64 expiry reaches
    uint256 constant WIDEST_TEN_DIGITS = 3747168000;
    uint256 constant WIDEST_UINT64 = 12272147937828201600;

    // who commits and pays a year of label for itself
    function _register(address who, string memory label) internal returns (uint256 id) {
        bytes32 c = nft.makeCommitment(label, who, 0, _s(label, who, 0));
        vm.prank(who);
        nft.commit(c);
        vm.warp(vm.getBlockTimestamp() + 61);
        (,,, uint256 total) = nft.quote(label);
        vm.prank(who);
        id = nft.reveal{value: total}(label, who, 0, _s(label, who, 0));
    }

    // payer commits and pays a trial of label for owner
    function _startTrial(address payer, string memory label, address owner) internal returns (uint256 id) {
        bytes32 c = trialCommitment(address(nft), label, owner, 0, _s(label, owner, 0));
        vm.prank(payer);
        nft.commit(c);
        vm.warp(vm.getBlockTimestamp() + 61);
        uint256 price = nft.getFee(bytes(label).length) / 10;
        vm.prank(payer);
        id = nft.revealTrial{value: price}(label, owner, 0, _s(label, owner, 0));
    }

    function _rep(bytes1 c, uint256 n) internal pure returns (string memory) {
        bytes memory b = new bytes(n);
        for (uint256 i; i < n; ++i) b[i] = c;
        return string(b);
    }

    function _b64(uint256 n) internal pure returns (uint256) {
        return 4 * ((n + 2) / 3);
    }

    function _digits(uint256 v) internal pure returns (uint256) {
        return bytes(LibString.toString(v)).length;
    }

    // the deposit as the metadata writes it, in ether with up to four decimals and no trailing zeros
    function _etherText(uint256 amount) internal pure returns (string memory) {
        string memory whole = LibString.toString(amount / 1 ether);
        uint256 frac = (amount % 1 ether) / 1e14;
        if (frac == 0) return whole;
        bytes memory f = bytes(LibString.toString(frac + 10_000));
        uint256 end = 5;
        while (f[end - 1] == "0") --end;
        return string.concat(whole, ".", LibString.slice(string(f), 1, end));
    }

    // the length of the card of a page of eights with the code of eights
    function _cardLength(uint256 labelLength, uint256 parentLength, PageCard.Status s, uint256 expiry)
        internal
        view
        returns (uint256)
    {
        return _cardOf(_rep("8", labelLength), _rep("8", parentLength), s, expiry);
    }

    // the length of the card of a label under a parent with the code of eights
    function _cardOf(string memory label, string memory parent, PageCard.Status s, uint256 expiry)
        internal
        view
        returns (uint256)
    {
        return bytes(card.render(label, parent, WIDEST_ID, s, expiry)).length;
    }

    // the length of a subpage's JSON for a card of r bytes
    function _subJson(uint256 labelLength, uint256 fullLength, PageCard.Status s, uint256 r)
        internal
        view
        returns (uint256)
    {
        return FIXED + SUB_FIXED + bytes("Subpage").length + bytes(statusNames[uint256(s)]).length + 2 * fullLength
            + (fullLength - labelLength - 1) + PAYEE + _b64(r);
    }

    // the length of a top level name's JSON for a card of r bytes
    function _topJson(uint256 labelLength, PageCard.Status s, uint256 r, uint256 expiryDigits, uint256 depositChars)
        internal
        view
        returns (uint256)
    {
        return FIXED + TOP_FIXED + bytes("Page").length + bytes(statusNames[uint256(s)]).length + _digits(labelLength)
            + 2 * labelLength + PAYEE + _b64(r) + expiryDigits + depositChars;
    }

    // the JSON of a real token is exactly its parts, its name is written out unescaped, and it fits every bound
    function _checkSize(uint256 id, string memory fullName) internal view returns (uint256 len) {
        string memory json = _json(id);
        (string memory label, uint256 parent,,,) = nft.records(id);
        PageCard.Status s = nft.status(id);
        uint256 r = bytes(_svg(id)).length;
        len = parent == 0
            ? _topJson(
                bytes(label).length, s, r, _digits(nft.expiresAt(id)), bytes(_etherText(nft.depositOf(id))).length
            )
            : _subJson(bytes(label).length, bytes(fullName).length, s, r);
        assertEq(bytes(json).length, len, "the JSON is the sum of its parts");
        uint256 uri = bytes(nft.tokenURI(id)).length;
        assertEq(uri, PREFIX + _b64(len), "the data URI is the JSON in base64");
        assertEq(LibString.slice(json, 9, LibString.indexOf(json, '","description":"')), fullName, "the name");
        assertLe(len, JSON_MAX);
        assertLe(uri, URI_MAX);
        assertLe(len, JSON_BOUND);
        assertLe(uri, URI_BOUND);
    }

    // a 63 character subpage under a 63 character parent in every state, a deleted one, a 63 character top level name
    // as a trial and in every state of a paid name, and the token with the largest metadata but for its code
    function test_tokenURISizeBound() public {
        string memory p63 = _rep("p", 63);
        string memory s63 = _rep("s", 63);
        string memory full = string.concat(s63, ".", p63);
        uint256 parent = _register(bob, p63);
        vm.prank(bob);
        uint256 sub = nft.registerSubpage(s63, parent);
        assertEq(bytes(nft.getPageName(sub)).length, 127);
        assertEq(nft.getPageName(sub), full);
        uint256 trial = _startTrial(relayer, _rep("t", 63), carol);

        // a deleted subpage keeps its full name
        vm.prank(bob);
        uint256 gone = nft.registerSubpage(_rep("d", 63), parent);
        vm.prank(bob);
        nft.transferFrom(bob, DEAD, gone);
        _assertStatus(gone, PageCard.Status.Invalid);
        _checkSize(gone, string.concat(_rep("d", 63), ".", p63));

        _assertStatus(sub, PageCard.Status.Active);
        _checkSize(sub, full);
        _checkSize(parent, p63);
        _assertStatus(trial, PageCard.Status.Trial);
        _checkSize(trial, _rep("t", 63));

        vm.warp(nft.expiresAt(parent) + 1);
        _assertStatus(sub, PageCard.Status.Grace);
        _checkSize(sub, full);
        _checkSize(parent, p63);

        vm.warp(nft.expiresAt(parent) + 90 days + 1);
        _assertStatus(sub, PageCard.Status.Expired);
        _assertStatus(parent, PageCard.Status.Expired);
        _checkSize(sub, full);
        _checkSize(parent, p63);

        // once the parent is registered again the old subpage is stale; the metadata keeps its full name, while
        // getPageName answers empty
        _register(carol, p63);
        _assertStatus(sub, PageCard.Status.Invalid);
        assertEq(nft.getPageName(sub), "");
        _checkSize(sub, full);

        // the largest metadata of all but for its code: 63 eights under the widest parent. Its card is the widest
        // subpage card with the code of its own id, a hash, in place of the code of eights, and its JSON is JSON_MAX
        // with that card in place of the widest one
        uint256 eights = _register(dave, WIDEST_PARENT);
        vm.prank(dave);
        uint256 widest = nft.registerSubpage(_rep("8", 63), eights);
        _assertStatus(widest, PageCard.Status.Active);
        PageCard.Status active = PageCard.Status.Active;
        string memory svg = _svg(widest);
        assertEq(svg, card.render(_rep("8", 63), WIDEST_PARENT, bytes32(widest), active, 0), "its own code");
        assertEq(_cardOf(_rep("8", 63), WIDEST_PARENT, active, 0), SUBPAGE_MAX, "the widest subpage card");
        assertLt(bytes(svg).length, SUBPAGE_MAX, "a code of a hash draws less than the code of eights");
        uint256 len = _checkSize(widest, string.concat(_rep("8", 63), ".", WIDEST_PARENT));
        assertEq(len + _b64(SUBPAGE_MAX) - _b64(bytes(svg).length), JSON_MAX, "JSON_MAX with the code of eights");
    }

    // A subpage's card grows with its label up to 17 eights, the most its name shows before the ellipsis. The dot and
    // the parent in its left pill take at most 1089 units of letters, and 88888888888aaaa88 draws the most outline
    // within them (it takes 1086), while its JSON grows by two bytes for each character of the full name and by one
    // more for each of the parent's. A pill that ends with the ellipsis draws less: the widest, 88888888888aaaa8 and
    // the ellipsis, loses more card than a parent of 63 adds characters. So an active subpage of 63 eights under
    // 88888888888aaaa88 is the largest while expiries have ten digits, and every other status draws a word in the left
    // pill. The code of eights draws the most of any code, so each card here takes it. A top level name stays below
    // with a date of ten digits, and inside the bounds even with the widest card it can draw and the widest values of
    // its types.
    function test_largestTokenURIIsTheActiveSubpageOf63EightsUnderTheWidestParent() public view {
        assertEq(
            JSON_BOUND,
            FIXED + TOP_FIXED + SUB_FIXED + bytes("Subpage").length + bytes("Invalid").length + 2 + 2 * 127 + 63 + PAYEE
                + EXPIRY_DIGITS_TYPE + DEPOSIT_CHARS_TYPE + _b64(CARD_MAX),
            "the JSON bound is the sum of its widest parts"
        );
        assertEq(URI_BOUND, PREFIX + _b64(JSON_BOUND));
        PageCard.Status active = PageCard.Status.Active;
        string memory e63 = _rep("8", 63);
        assertEq(_cardOf(e63, WIDEST_PARENT, active, 0), SUBPAGE_MAX, "the widest subpage card");
        uint256 best = _subJson(63, 81, active, SUBPAGE_MAX);
        assertEq(best, JSON_MAX);
        assertEq(PREFIX + _b64(best), URI_MAX);

        // a parent of 63 whose pill is the widest one that ends with the ellipsis gives less
        uint256 cut = _cardOf(e63, string.concat(WIDEST_CUT, _rep("m", 47)), active, 0);
        assertEq(cut, 18660, "the widest card under a parent of 63");
        assertLt(_subJson(63, 127, active, cut), JSON_MAX, "a parent of 63");
        // and so does a parent of eights of each length from 1 to 63
        for (uint256 p = 1; p <= 63; ++p) {
            assertLt(_subJson(63, 64 + p, active, _cardLength(63, p, active, 0)), JSON_MAX, "a parent of eights");
        }

        // under the widest parent a shorter label gives less
        for (uint256 a = 1; a < 63; ++a) {
            assertLt(_subJson(a, a + 18, active, _cardOf(_rep("8", a), WIDEST_PARENT, active, 0)), JSON_MAX);
        }
        // and so does every other status a subpage can have, even under a parent of 63: its left pill holds a word, so
        // once the name is cut the parent changes nothing on the card and only adds characters to the JSON
        for (uint256 s = 1; s < 4; ++s) {
            PageCard.Status st = PageCard.Status(s);
            uint256 r = _cardOf(e63, e63, st, 0);
            assertEq(r, _cardOf(e63, WIDEST_PARENT, st, 0), "the parent changes nothing on the card");
            assertLt(_subJson(63, 127, st, r), JSON_MAX, "a parent of 63");
        }

        // a top level name of each length in each state, with the widest date of ten digits and a six character
        // deposit
        uint256 bestTop;
        for (uint256 n = 1; n <= 63; ++n) {
            for (uint256 s; s < 5; ++s) {
                uint256 r = _cardLength(n, 0, PageCard.Status(s), WIDEST_TEN_DIGITS);
                uint256 j = _topJson(n, PageCard.Status(s), r, EXPIRY_DIGITS, DEPOSIT_CHARS);
                if (j > bestTop) bestTop = j;
            }
        }
        assertEq(bestTop, JSON_MAX - 3020, "a top level name stays 3020 bytes below");

        // the widest card a top level name of 63 draws, with the latest uint64 date of eights, together with the
        // widest expiry and deposit the types allow, passes JSON_MAX, as that date needs a year of twelve digits no
        // registration reaches, and stays inside the bounds
        uint256 r63 = _cardLength(63, 0, active, WIDEST_UINT64);
        assertEq(r63, 19017);
        uint256 widest = _topJson(63, active, r63, EXPIRY_DIGITS_TYPE, DEPOSIT_CHARS_TYPE);
        assertEq(widest, 25935);
        assertEq(PREFIX + _b64(widest), 34609);
        assertGt(widest, JSON_MAX);
        assertLe(widest, JSON_BOUND);
        assertLe(PREFIX + _b64(widest), URI_BOUND);
    }
}

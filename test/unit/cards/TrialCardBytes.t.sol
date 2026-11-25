// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {trialCommitment} from "../../utils/TrialCommitment.sol";

import {Test} from "forge-std/Test.sol";
import {Base64} from "solady/utils/Base64.sol";
import {LibString} from "solady/utils/LibString.sol";
import {PageNFT} from "../../../src/PageNFT.sol";
import {PageCard} from "../../../src/PageCard.sol";
import {CardReader} from "../../utils/CardReader.sol";

// The bytes of a Trial card, written out element by element: with a parent label and without one, drawn by
// PageCard alone and through the real PageNFT, which draws Trial only for a top level name. Each letter is its
// outline from tools/card-glyphs.json at the pen written next to it, and the pens are the advances, kerning and
// tracking of that file added up by hand.
contract TrialCardBytesTest is Test {
    using LibString for uint256;

    PageCard card;
    PageNFT nft;
    CardReader reader;
    string json;

    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address aliceW = 0x7a3F0C9b1E2d4a5B6C7D8e9F0a1B2c3d4e5F6a7B;
    address bobW = makeAddr("bob wallet");
    address carolW = makeAddr("carol wallet");
    address relayer = makeAddr("relayer");

    string constant HEAD = '<svg xmlns="http://www.w3.org/2000/svg" width="1000" height="1000" viewBox="0 0 1000 1000">';
    string constant LIVE_BG = '<rect width="1000" height="1000" fill="#f1f4fe"/>';
    string constant PANEL = '<rect x="40" y="560" width="920" height="400" rx="56" fill="#ffffff"/>';
    // the name at its full scale of 0.750, the baseline at 732 + 750 * 70 / 1000
    string constant NAME_OPEN = '<g transform="translate(500 784) scale(0.750)" fill="#19171c">';
    string constant DIM_OPEN = '<g fill="#a3a2aa">';

    // id 0x8f3a1c followed by zeros: of its nibbles 8 f 3 a 1 c 0 0 ..., only f, 3 and 1 are odd, so squares 1, 2
    // and 4 of the top row are blue and the other 29 light blue, and its code is 8f3a1c00000000…000000
    bytes32 constant ID = bytes32(uint256(0x8f3a1c) << 232);
    string constant ID_ON =
        '<g fill="#7193f2"><rect x="194" y="90" width="92" height="92" rx="26"/><rect x="298" y="90" width="92" height="92" rx="26"/><rect x="506" y="90" width="92" height="92" rx="26"/></g>';

    // the token id of the top level name alice
    uint256 constant ALICE_ID = 0xbd0888be4fc21a23d82616269103328d0cc8ab2697e8da7ad4c2d0d47a6cfa22;

    function setUp() public {
        vm.warp(1790424000);
        card = new PageCard();
        nft = new PageNFT(card);
        reader = new CardReader();
        json = vm.readFile("tools/card-glyphs.json");
        vm.deal(aliceW, 10 ether);
        vm.deal(carolW, 10 ether);
        vm.deal(relayer, 10 ether);
    }

    // the letter a character of the card is, by its place in the JSON: a to z, 0 to 9, the hyphen, the dot and the
    // ellipsis, then in the small text the space and the capitals ADEFGIJMNOSTU from 41
    function _glyph(string memory c) internal pure returns (uint256) {
        if (keccak256(bytes(c)) == keccak256(bytes(unicode"…"))) return 38;
        bytes1 b = bytes(c)[0];
        bytes memory letters = "abcdefghijklmnopqrstuvwxyz0123456789-.";
        for (uint256 i; i < letters.length; ++i) if (letters[i] == b) return i;
        bytes memory capitals = "ADEFGIJMNOSTU";
        for (uint256 i; i < capitals.length; ++i) if (capitals[i] == b) return 41 + i;
        revert("no such letter");
    }

    function _path(string memory face, string memory c, int256 pen) internal view returns (string memory) {
        string memory d = vm.parseJsonString(json, string.concat(".", face, ".glyphs[", _glyph(c).toString(), "].d"));
        return string.concat('<path transform="translate(', vm.toString(pen), ')" d="', d, '"/>');
    }

    // a letter of the name, at pen
    function _n(string memory c, int256 pen) internal view returns (string memory) {
        return _path("name", c, pen);
    }

    // a letter of the small text, at pen
    function _t(string memory c, int256 pen) internal view returns (string memory) {
        return _path("text", c, pen);
    }

    // every square not in on, in order, in the light group
    function _offSquares(uint256 on) internal pure returns (string memory out) {
        out = '<g fill="#dce4fc">';
        for (uint256 i; i < 32; ++i) {
            if (on >> i & 1 == 1) continue;
            out = string.concat(
                out, '<rect x="', (90 + (i % 8) * 104).toString(), '" y="', (90 + (i / 8) * 104).toString(),
                '" width="92" height="92" rx="26"/>'
            );
        }
        out = string.concat(out, "</g>");
    }

    // bob.alice is 923 units wide with the tracking of -6 between letters and no kerned pair, so its pen starts at
    // -461 and the parent part is dimmed from the dot
    function _bobAlice() internal view returns (string memory) {
        return string.concat(
            NAME_OPEN, _n("b", -461), _n("o", -329), _n("b", -208), DIM_OPEN,
            string.concat(_n(".", -78), _n("a", -25), _n("l", 105), _n("i", 171), _n("c", 224), _n("e", 338)), "</g></g>"
        );
    }

    // alice is 487 units wide, so its pen starts at -243
    function _alice() internal view returns (string memory) {
        return string.concat(NAME_OPEN, _n("a", -243), _n("l", -113), _n("i", -47), _n("c", 6), _n("e", 120), "</g>");
    }

    // Trial is 209 units after the kerning of T and r, a pill of (209 * 7 + 24) / 25 + 52 and 24 for the blue dot
    function _trialPill() internal view returns (string memory) {
        return string.concat(
            '<rect x="90" y="840" width="135" height="62" rx="31" fill="#f6f6f8"/>',
            '<circle cx="124" cy="871" r="8" fill="#7193f2"/>',
            '<g transform="translate(140 881) scale(0.280)" fill="#19171c">',
            string.concat(_t("T", 0), _t("r", 53), _t("i", 94), _t("a", 121), _t("l", 179)), "</g>"
        );
    }

    // Grace period is 619 units with its space, which draws nothing, and has a mustard dot
    function _gracePill() internal view returns (string memory) {
        return string.concat(
            '<rect x="90" y="840" width="250" height="62" rx="31" fill="#f6f6f8"/>',
            '<circle cx="124" cy="871" r="8" fill="#ffc94a"/>',
            '<g transform="translate(140 881) scale(0.280)" fill="#19171c">',
            string.concat(_t("G", 0), _t("r", 72), _t("a", 109), _t("c", 167), _t("e", 225)),
            string.concat(_t("p", 308), _t("e", 370), _t("r", 429), _t("i", 470), _t("o", 497), _t("d", 557)), "</g>"
        );
    }

    // the code of ID, 8f3a1c00000000…000000, is 1347 units with no kerned pair, a pill of (1347 * 7 + 24) / 25 + 52 =
    // 430 that ends at 910, in the muted ink and without a dot
    function _codePill() internal view returns (string memory) {
        return string.concat(
            '<rect x="480" y="840" width="430" height="62" rx="31" fill="#f6f6f8"/>',
            '<g transform="translate(506 881) scale(0.280)" fill="#6a6a70">',
            string.concat(_t("8", 0), _t("f", 64), _t("3", 107), _t("a", 171), _t("1", 229), _t("c", 272)),
            string.concat(_t("0", 330), _t("0", 398), _t("0", 466), _t("0", 534), _t("0", 602), _t("0", 670)),
            string.concat(_t("0", 738), _t("0", 806), _t(unicode"…", 874), _t("0", 939), _t("0", 1007)),
            string.concat(_t("0", 1075), _t("0", 1143), _t("0", 1211), _t("0", 1279)),
            "</g>"
        );
    }

    // a live card of ID
    function _idCard(string memory name, string memory left) internal view returns (string memory) {
        return string.concat(
            HEAD, LIVE_BG, _offSquares(1 << 1 | 1 << 2 | 1 << 4), ID_ON, PANEL, name, left, _codePill(), "</svg>"
        );
    }

    function _json(uint256 id) internal view returns (string memory) {
        return string(Base64.decode(LibString.slice(nft.tokenURI(id), 29)));
    }

    function _svg(uint256 id) internal view returns (string memory) {
        string memory j = _json(id);
        uint256 a = LibString.indexOf(j, "base64,") + 7;
        uint256 b = LibString.indexOf(j, '","attributes');
        return string(Base64.decode(LibString.slice(j, a, b)));
    }

    function _secret(string memory label, address owner) internal pure returns (bytes32) {
        return keccak256(abi.encode(label, owner));
    }

    function _buy(address who, string memory label) internal returns (uint256 id) {
        bytes32 c = nft.makeCommitment(label, who, 0, _secret(label, who));
        vm.prank(who);
        nft.commit(c);
        vm.warp(vm.getBlockTimestamp() + 61);
        (,,, uint256 total) = nft.quote(label);
        vm.prank(who);
        id = nft.reveal{value: total}(label, who, 0, _secret(label, who));
    }

    // a relayer starts the trial for owner and pays a tenth of the yearly fee
    function _trial(string memory label, address owner) internal returns (uint256 id) {
        bytes32 c = trialCommitment(address(nft), label, owner, 0, _secret(label, owner));
        vm.prank(relayer);
        nft.commit(c);
        vm.warp(vm.getBlockTimestamp() + 61);
        uint256 p = nft.getFee(bytes(label).length) / 10;
        vm.prank(relayer);
        id = nft.revealTrial{value: p}(label, owner, 0, _secret(label, owner));
    }

    // a case PageNFT never passes: a non empty parent label with Trial, which is the Grace card with another pill
    function test_trialCardWithAParentByPageCardAlone() public view {
        string memory t = card.render("bob", "alice", ID, PageCard.Status.Trial, 1821312000);
        assertEq(t, _idCard(_bobAlice(), _trialPill()), "Trial card with a parent label");
        assertEq(bytes(t).length, 8480, "its length");
        string memory g = card.render("bob", "alice", ID, PageCard.Status.Grace, 1821312000);
        assertEq(g, _idCard(_bobAlice(), _gracePill()), "Grace card with a parent label");
        assertEq(LibString.replace(g, _gracePill(), _trialPill()), t, "the Grace card with the Trial pill");
    }

    // the case PageNFT passes, drawn by a direct call
    function test_trialCardWithoutParentByPageCardAlone() public view {
        string memory t = card.render("alice", "", ID, PageCard.Status.Trial, 1821312000);
        assertEq(t, _idCard(_alice(), _trialPill()), "Trial card without a parent label");
        assertEq(bytes(t).length, 7753, "its length");
        string memory g = card.render("alice", "", ID, PageCard.Status.Grace, 1821312000);
        assertEq(LibString.replace(g, _gracePill(), _trialPill()), t, "the Grace card with the Trial pill");
        // the expiry is never shown on a Trial card
        assertEq(card.render("alice", "", ID, PageCard.Status.Trial, type(uint256).max), t, "no date");
    }

    // an unpaid trial drawn by the real PageNFT, held by its owner, which is the reference card of a trial, and the
    // Invalid card once DEAD holds it
    function test_trialCardDrawnByPageNFT() public {
        uint256 t = _trial("alice", aliceW);
        assertEq(t, ALICE_ID, "token id of alice");
        assertEq(uint256(nft.status(t)), uint256(PageCard.Status.Trial), "status view");
        string memory svg = _svg(t);
        assertEq(svg, vm.readFile("test/fixtures/cards/2-trial-alice.svg"), "the reference Trial card");
        assertEq(
            svg, card.render("alice", "", bytes32(t), PageCard.Status.Trial, nft.expiresAt(t)), "same as a direct call"
        );
        CardReader.Card memory c = reader.read(svg);
        assertEq(c.name, "alice", "the name");
        assertEq(c.left, "Trial", "Trial");
        assertEq(c.dot, "#7193f2", "a blue dot");
        assertEq(c.right, unicode"bd0888be4fc21a…6cfa22", "the code of its id");
        assertFalse(c.dead, "live");
        // its first 16 bytes bd0888be4fc21a23d82616269103328d have 13 odd nibbles
        bool[32] memory on;
        uint8[13] memory odd = [0, 1, 6, 9, 12, 15, 16, 20, 24, 25, 27, 28, 31];
        for (uint256 i; i < odd.length; ++i) on[odd[i]] = true;
        for (uint256 i; i < 32; ++i) assertEq(c.on[i], on[i], "a square of the fingerprint");

        // thrown to DEAD it is deleted, so it is drawn Invalid, with the same code
        vm.prank(aliceW);
        nft.transferFrom(aliceW, DEAD, t);
        assertEq(uint256(nft.status(t)), uint256(PageCard.Status.Invalid), "status view held by DEAD");
        svg = _svg(t);
        assertEq(svg, card.render("alice", "", bytes32(t), PageCard.Status.Invalid, 0), "held by DEAD");
        c = reader.read(svg);
        assertTrue(c.dead, "dead");
        assertEq(c.left, "Invalid", "Invalid, never Trial");
        assertEq(c.dot, "#e5484d", "a red dot");
        assertEq(c.right, unicode"bd0888be4fc21a…6cfa22", "the same code");
    }

    // PageNFT never draws a subpage as Trial: no subpage can be made under a running trial, and a subpage made
    // under an earlier paid registration is stale once its parent's label is a trial, so it is drawn Invalid
    function test_subpageIsNeverDrawnTrialByPageNFT() public {
        uint256 alice = _buy(aliceW, "alice");
        vm.prank(aliceW);
        uint256 bob = nft.registerSubpageFor("bob", alice, bobW);
        assertEq(uint256(nft.status(bob)), uint256(PageCard.Status.Active), "a live subpage is Active");
        CardReader.Card memory c = reader.read(_svg(bob));
        assertEq(c.left, ".alice", "with its parent in the left pill");
        assertEq(c.dot, "", "and no dot");

        // the paid registration ends, its deposit is released, and the label is taken as a trial
        vm.warp(nft.expiresAt(alice) + 90 days + 21 days + 1);
        nft.release(alice);
        uint256 t = _trial("alice", carolW);
        assertEq(t, alice, "the same token id");
        assertEq(uint256(nft.status(t)), uint256(PageCard.Status.Trial), "the parent label is a running trial");

        assertEq(uint256(nft.status(bob)), uint256(PageCard.Status.Invalid), "the old subpage is Invalid");
        string memory svg = _svg(bob);
        assertEq(svg, card.render("bob", "alice", bytes32(bob), PageCard.Status.Invalid, 0), "drawn as Invalid");
        c = reader.read(svg);
        assertEq(c.name, "bob.alice", "full name");
        assertEq(c.dimmed, ".alice", "its parent dimmed");
        assertTrue(c.dead, "dead");
        assertEq(c.left, "Invalid", "Invalid, never Trial");
        assertEq(c.dot, "#e5484d", "a red dot");

        // and no new subpage can be made under the running trial
        vm.expectRevert(PageNFT.Unpaid.selector);
        vm.prank(carolW);
        nft.registerSubpageFor("dan", t, carolW);
    }
}

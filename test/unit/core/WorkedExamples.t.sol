// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Test, Vm} from "forge-std/Test.sol";
import {Base64} from "solady/utils/Base64.sol";
import {LibString} from "solady/utils/LibString.sol";
import {PageCard} from "../../../src/PageCard.sol";
import {PageNFT} from "../../../src/PageNFT.sol";
import {SubpageRegistrar, IPageNFT} from "../../../src/SubpageRegistrar.sol";
import {CardReader} from "../../utils/CardReader.sol";

contract Harness is PageNFT {
    constructor(PageCard c) PageNFT(c) {}

    function formatEther(uint256 w) external pure returns (string memory) {
        return _formatEther(w);
    }

    function tryNormalize(bytes memory b) external pure returns (uint256, bytes memory) {
        return _tryNormalize(b);
    }
}

contract Receiver {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}

contract WorkedExamplesTest is Test {
    PageCard card;
    Harness nft;
    SubpageRegistrar reg;
    CardReader reader;

    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address carol = address(0xCA201);
    address dave = address(0xDA7E);
    address DEAD = 0x000000000000000000000000000000000000dEaD;

    uint256 constant COIN_OP = 0x8000000a;
    // the id whose code is all eights, the code that draws the most
    bytes32 constant WIDEST_ID = 0x8888888888888888888888888888888888888888888888888888888888888888;

    function setUp() public {
        vm.warp(1_800_000_000);
        card = new PageCard();
        nft = new Harness(card);
        reg = new SubpageRegistrar(IPageNFT(address(nft)));
        vm.deal(alice, 1000 ether);
        vm.deal(bob, 1000 ether);
        vm.deal(carol, 1000 ether);
        vm.deal(dave, 1000 ether);
        reader = new CardReader();
    }

    function _id(string memory label) internal view returns (uint256) {
        return uint256(keccak256(abi.encodePacked(nft.ROOT(), keccak256(bytes(label)))));
    }

    function _register(address who, string memory label, uint256 ref) internal returns (uint256 id) {
        bytes32 secret = keccak256(abi.encode(who, label, block.timestamp));
        bytes32 commitment = nft.makeCommitment(label, who, ref, secret);
        vm.prank(who);
        nft.commit(commitment);
        vm.warp(block.timestamp + 61);
        (,,, uint256 total) = nft.quote(label);
        vm.prank(who);
        id = nft.reveal{value: total}(label, who, ref, secret);
    }

    // normalize lowers case and keeps double hyphens; tryNormalize answers 2 for a reserved shape
    // and 1 for a wrong length, which it checks before any byte
    function test_normalizeExamples() public view {
        assertEq(nft.normalize("Alice"), "alice");
        assertEq(nft.normalize("0XDEAD"), "0xdead");
        assertEq(nft.normalize("a--b"), "a--b");
        assertEq(nft.normalize("ciia--o"), "ciia--o");
        (uint256 e,) = nft.tryNormalize(bytes("ci--ao"));
        assertEq(e, 2);
        (e,) = nft.tryNormalize(bytes("0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045"));
        assertEq(e, 2);
        (e,) = nft.tryNormalize(bytes("0xd8da6bf26964af9d7eed9e03e53415d37aa9604g"));
        assertEq(e, 0);
        bytes memory d64 = new bytes(64);
        for (uint256 i; i < 64; ++i) d64[i] = "$";
        (e,) = nft.tryNormalize(d64);
        assertEq(e, 1);
    }

    // computeNamehash matches the subpage id, maps the empty string to ROOT and refuses bad dotted names
    function test_computeNamehash() public {
        uint256 a = _register(alice, "alice", 0);
        vm.prank(alice);
        uint256 s = nft.registerSubpage("bob", a);
        assertEq(uint256(nft.computeNamehash("bob.alice")), s);
        assertEq(nft.computeNamehash(""), nft.ROOT());
        vm.expectRevert(PageNFT.EmptyLabel.selector);
        nft.computeNamehash("a..b");
        vm.expectRevert(PageNFT.InvalidLabel.selector);
        nft.computeNamehash("a.b.c");
    }

    // formatEther drops trailing zeros and the point of a whole number
    function test_formatEther() public view {
        assertEq(nft.formatEther(0), "0");
        assertEq(nft.formatEther(5e14), "0.0005");
        assertEq(nft.formatEther(15e14), "0.0015");
        assertEq(nft.formatEther(2e15), "0.002");
        assertEq(nft.formatEther(5e16), "0.05");
        assertEq(nft.formatEther(15e17), "1.5");
        assertEq(nft.formatEther(1e18), "1");
    }

    // the premium along the auction, then a purchase: the last payee gets the carried deposit and
    // 75 percent of the premium, the dead address gets the referrer share
    function test_premiumTableAndWorkedAuction() public {
        uint256 id = _register(alice, "vault", 0);
        for (uint256 i; i < 3; ++i) {
            vm.prank(alice);
            nft.renew{value: 0.0001 ether}(id);
        }
        assertEq(nft.depositOf(id), 4e14);
        uint256 E = nft.expiresAt(id);
        uint256 G = 90 days;
        vm.warp(E + G);
        assertEq(nft.getPremium(id), 0);
        vm.warp(E + G + 1);
        assertEq(nft.getPremium(id), 9999994488536155202);
        vm.warp(E + G + 1 hours);
        assertEq(nft.getPremium(id), 9980158730158730158);
        vm.warp(E + G + 21 days - 1);
        assertEq(nft.getPremium(id), 5511463844797);
        vm.warp(E + G + 21 days);
        assertEq(nft.getPremium(id), 0);

        vm.warp(E + G + 1 - 61);
        bytes32 secret = bytes32("s");
        bytes32 commitment = nft.makeCommitment("vault", carol, 0, secret);
        vm.prank(carol);
        nft.commit(commitment);
        vm.warp(E + G + 1);
        (uint256 fee, uint256 carried, uint256 premium, uint256 total) = nft.quote("vault");
        assertEq(fee, 1e14);
        assertEq(carried, 4e14);
        assertEq(total, 10000494488536155202);
        vm.prank(carol);
        nft.reveal{value: total + 1}("vault", carol, 0, secret);
        assertEq(nft.owed(alice), 7500395866402116402);
        assertEq(nft.owed(DEAD), 2499998622134038800);
        assertEq(nft.depositOf(id), 500000000000000);
        assertEq(premium, 9999994488536155202);
        assertEq(address(nft).balance, nft.owed(alice) + nft.owed(DEAD) + nft.depositOf(id));
    }

    // the order of the logs when an auction takes a name that has a premium and a primary name
    function test_auctionLogOrder() public {
        uint256 id = _register(alice, "vault", 0);
        vm.prank(alice);
        nft.setPrimaryPage(id);
        uint256 E = nft.expiresAt(id);
        vm.warp(E + 90 days + 1 - 61);
        bytes32 secret = bytes32("s");
        bytes32 commitment = nft.makeCommitment("vault", carol, 0, secret);
        vm.prank(carol);
        nft.commit(commitment);
        vm.warp(E + 90 days + 1);
        (,,, uint256 total) = nft.quote("vault");
        vm.recordLogs();
        vm.prank(carol);
        nft.reveal{value: total}("vault", carol, 0, secret);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32[15] memory want = [
            PageNFT.DepositBoughtOut.selector,
            PageNFT.ReferrerPremiumCredited.selector,
            PageNFT.OwnerPremiumCredited.selector,
            PageNFT.PrimaryPageSet.selector,
            keccak256("Transfer(address,address,uint256)"),
            PageNFT.AddressChanged.selector,
            PageNFT.AddressChanged.selector,
            PageNFT.AddrChanged.selector,
            PageNFT.VersionChanged.selector,
            PageNFT.ReferrerSet.selector,
            PageNFT.DepositAdded.selector,
            keccak256("Transfer(address,address,uint256)"),
            PageNFT.AddressChanged.selector,
            PageNFT.AddressChanged.selector,
            PageNFT.AddrChanged.selector
        ];
        assertEq(logs.length, 17);
        for (uint256 i; i < 15; ++i) assertEq(logs[i].topics[0], want[i]);
        assertEq(logs[15].topics[0], PageNFT.PageRegistered.selector);
        assertEq(logs[16].topics[0], PageNFT.MetadataUpdate.selector);
    }

    // renewals may reach at most ten years ahead, for a live name and for one in its grace period
    function test_renewHorizon() public {
        uint256 id = _register(alice, "alice", 0);
        for (uint256 i; i < 9; ++i) nft.renew{value: 0.0001 ether}(id);
        vm.expectRevert(PageNFT.RenewalTooFar.selector);
        nft.renew{value: 0.0001 ether}(id);

        uint256 id2 = _register(bob, "bobby", 0);
        uint256 E = nft.expiresAt(id2);
        vm.warp(E + 1 days);
        for (uint256 i; i < 10; ++i) nft.renew{value: 0.0001 ether}(id2);
        assertEq(nft.expiresAt(id2), E + 3650 days);
        vm.expectRevert(PageNFT.RenewalTooFar.selector);
        nft.renew{value: 0.0001 ether}(id2);
    }

    // a transfer points the main address at the buyer, announces the buyer's coin type 60 answer, which is empty
    // as the buyer saved nothing, with AddrChanged, clears the seller's display name and logs MetadataUpdate last;
    // each log is checked in full, its emitter, every topic and its data
    function test_saleEvents() public {
        uint256 id = _register(alice, "vault", 0);
        vm.startPrank(alice);
        nft.setAddr(id, alice);
        nft.setPrimaryPage(id);
        vm.recordLogs();
        nft.transferFrom(alice, bob, id);
        vm.stopPrank();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 6);
        uint256[6] memory topicCount = [uint256(4), 2, 2, 2, 3, 1];
        for (uint256 i; i < 6; ++i) {
            assertEq(logs[i].emitter, address(nft));
            assertEq(logs[i].topics.length, topicCount[i]);
        }
        bytes32 node = bytes32(id);
        assertEq(logs[0].topics[0], keccak256("Transfer(address,address,uint256)"));
        assertEq(logs[0].topics[1], bytes32(uint256(uint160(alice))));
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(bob))));
        assertEq(logs[0].topics[3], node);
        assertEq(logs[0].data.length, 0);
        // the home chain answer names the buyer, and the coin type 60 answer goes out empty, then as zero in
        // AddrChanged
        assertEq(logs[1].topics[0], PageNFT.AddressChanged.selector);
        assertEq(logs[1].topics[1], node);
        assertEq(logs[1].data, abi.encode(COIN_OP, abi.encodePacked(bob)));
        assertEq(logs[2].topics[0], PageNFT.AddressChanged.selector);
        assertEq(logs[2].topics[1], node);
        assertEq(logs[2].data, abi.encode(uint256(60), bytes("")));
        assertEq(logs[3].topics[0], PageNFT.AddrChanged.selector);
        assertEq(logs[3].topics[1], node);
        assertEq(logs[3].data, abi.encode(address(0)));
        // the seller's display name is cleared before MetadataUpdate
        assertEq(logs[4].topics[0], PageNFT.PrimaryPageSet.selector);
        assertEq(logs[4].topics[1], bytes32(uint256(uint160(alice))));
        assertEq(logs[4].topics[2], bytes32(0));
        assertEq(logs[4].data.length, 0);
        assertEq(logs[5].topics[0], PageNFT.MetadataUpdate.selector);
        assertEq(logs[5].data, abi.encode(id));
        assertEq(nft.resolve(id), bob);
        assertEq(nft.payee(id), bob);
        assertEq(nft.primaryPage(alice), 0);
        assertEq(nft.reverseResolve(alice), "");
    }

    // setAddrForCoin refuses an EVM address of the wrong length, the default EVM coin type included, and the OP
    // coin type works like setAddr
    function test_setAddrForCoin() public {
        uint256 id = _register(alice, "alice", 0);
        vm.startPrank(alice);
        vm.expectRevert(PageNFT.InvalidLength.selector);
        nft.setAddrForCoin(id, 0x80000000, hex"01");
        vm.expectRevert(PageNFT.InvalidLength.selector);
        nft.setAddrForCoin(id, 60, hex"01");
        vm.recordLogs();
        nft.setAddrForCoin(id, COIN_OP, abi.encodePacked(bob));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 4);
        assertEq(nft.resolve(id), bob);
        nft.setAddrForCoin(id, 60, abi.encodePacked(address(0)));
        // zero clears the entry, and with no default saved coin type 60 answers empty
        assertEq(nft.addr(id, 60), "");
        // with a default saved, a cleared entry falls back to the default
        nft.setAddrForCoin(id, 0x80000000, abi.encodePacked(carol));
        nft.setAddrForCoin(id, 60, abi.encodePacked(dave));
        assertEq(nft.addr(id, 60), abi.encodePacked(dave));
        nft.setAddrForCoin(id, 60, abi.encodePacked(address(0)));
        assertEq(nft.addr(id, 60), abi.encodePacked(carol));
        nft.setAddrForCoin(id, 0, hex"aabbcc");
        assertEq(nft.addr(id, 0), hex"aabbcc");
        vm.stopPrank();
    }

    // the code at an address changes no answer: with an account with no code, a 7702 account or a contract as
    // the main address, the name answers only on the home chain coin type until the holder saves an entry or a
    // default, and then exactly that
    function test_codeChangesNoAnswer() public {
        uint256 id = _register(alice, "alice", 0);
        assertEq(nft.addr(id, COIN_OP), abi.encodePacked(alice));
        assertEq(nft.addr(id, 60), "");
        address d = address(0xD1);
        vm.etch(d, abi.encodePacked(hex"ef0100", address(0xBEEF)));
        vm.prank(alice);
        nft.setAddr(id, d);
        assertEq(nft.addr(id, 60), "");
        assertEq(nft.addr(id, COIN_OP), abi.encodePacked(d));
        address k = address(new Receiver());
        vm.prank(alice);
        nft.setAddr(id, k);
        assertEq(nft.addr(id, 60), "");
        assertEq(nft.addr(id, COIN_OP), abi.encodePacked(k));
        // a saved default answers on every other EVM chain, whatever the main address is
        vm.prank(alice);
        nft.setAddrForCoin(id, 0x80000000, abi.encodePacked(d));
        assertEq(nft.addr(id, 60), abi.encodePacked(d));
        assertEq(nft.addr(id, 0x80002105), abi.encodePacked(d));
        assertEq(nft.addr(id, COIN_OP), abi.encodePacked(k));
        // an entry for one chain wins over the default there
        vm.prank(alice);
        nft.setAddrForCoin(id, 60, abi.encodePacked(k));
        assertEq(nft.addr(id, 60), abi.encodePacked(k));
        assertEq(nft.addr(id, 0x80002105), abi.encodePacked(d));
    }

    // release refuses a token that does not exist, a name inside its grace and premium periods, and a name with no
    // deposit left
    function test_release() public {
        vm.expectRevert(bytes4(keccak256("TokenDoesNotExist()")));
        nft.release(1);
        uint256 id = _register(alice, "alice", 0);
        uint256 E = nft.expiresAt(id);
        vm.warp(E + 111 days);
        vm.expectRevert(PageNFT.NotReleasable.selector);
        nft.release(id);
        vm.warp(E + 111 days + 1);
        assertTrue(nft.isReleasable(id));
        nft.release(id);
        assertEq(nft.owed(alice), 1e14);
        vm.expectRevert(PageNFT.NothingToRelease.selector);
        nft.release(id);
    }

    // the full token JSON of a name with a deposit of four years
    function test_tokenURIWorkedExample() public {
        vm.warp(1790000000 - 4 * 365 days - 61);
        uint256 id = _register(alice, "alice", 0);
        for (uint256 i; i < 3; ++i) nft.renew{value: 0.0001 ether}(id);
        assertEq(nft.expiresAt(id), 1790000000);
        address p = 0x1234567890AbcdEF1234567890aBcdef12345678;
        vm.prank(alice);
        nft.setAddr(id, p);
        assertEq(card.shortAddress(p), unicode"0x1234567890ab…345678");
        string memory img =
            Base64.encode(bytes(card.render("alice", "", bytes32(id), PageCard.Status.Active, 1790000000)));
        string memory json = string.concat(
            unicode'{"name":"alice","description":"Etherpage: alice (0x1234567890ab…345678)","image":"data:image/svg+xml;base64,',
            img,
            '","attributes":[{"trait_type":"Type","value":"Page"},{"trait_type":"Status","value":"Active"},{"trait_type":"Length","display_type":"number","value":5},{"trait_type":"Expires","display_type":"date","value":1790000000},{"trait_type":"Deposit","display_type":"number","value":0.0004}]}'
        );
        assertEq(nft.tokenURI(id), string.concat("data:application/json;base64,", Base64.encode(bytes(json))));
    }

    // the left pill of an active top level page with expiry e
    function _until(uint256 e) internal view returns (string memory) {
        return reader.read(card.render("a", "", bytes32(0), PageCard.Status.Active, e)).left;
    }

    // the card of an active page with this label and parent label, read back
    function _read(string memory label, string memory parentLabel) internal view returns (CardReader.Card memory) {
        return reader.read(card.render(label, parentLabel, bytes32(0), PageCard.Status.Active, 0));
    }

    // the position of the background, every letter of both typefaces drawn with the outline and advance
    // tools/card-glyphs.json gives it, and dates up to the largest expiry
    function test_cardConstants() public view {
        string memory svg = card.render("a", "", bytes32(0), PageCard.Status.Active, 1821312000);
        assertEq(vm.indexOf(svg, '<rect width="1000"'), 91, "the background follows the svg tag");
        assertEq(reader.read(svg).left, "Until 19 Sep 2027");
        assertEq(_until(type(uint64).max), "Until 9 Nov 584554051223");
        assertEq(_until(253402300800), "Until 1 Jan 10000");

        // the name: a to z, 0 to 9, the hyphen, the dot, the box that stands for any other byte and the ellipsis
        assertEq(_read("abcdefghijklmnopqr", "").name, "abcdefghijklmnopqr");
        assertEq(_read("stuvwxyz0123456789", "").name, "stuvwxyz0123456789");
        CardReader.Card memory c = _read("a-b", "A");
        assertEq(c.name, "a-b.?");
        assertEq(c.dimmed, ".?");
        assertEq(_read("stuvwxyz0123456789", "a").name, unicode"stuvwxyz012345678…");

        // the small text: the parent's label in the left pill of an active subpage has the same letters, and the
        // space and the capitals of the fixed words besides
        assertEq(_read("a", "abcdefghijklmnopqr").left, ".abcdefghijklmnopqr");
        // with the dot these 18 letters are 1095 units, wider than the pill's 1089, and the first 17 and the ellipsis
        // still 1098, so it keeps 16 and the ellipsis
        assertEq(_read("a", "stuvwxyz0123456789").left, unicode".stuvwxyz01234567…");
        assertEq(_read("a", "ADEFGIJMNOSTU -B").left, ".ADEFGIJMNOSTU -?");
        c = _read("a", "abcdefghijklmnopqrs");
        assertEq(c.left, unicode".abcdefghijklmnopq…");
        // the right pill shows the code of the id: its first 14 and last 6 hex digits
        assertEq(c.right, unicode"00000000000000…000000");
    }

    function _rep(string memory c, uint256 n) internal pure returns (string memory s) {
        for (uint256 i; i < n; ++i) s = string.concat(s, c);
    }

    // whether 8 has a longer outline than every other letter a label or a code can hold, a to z, 0 to 9 and the
    // hyphen, in one typeface of tools/card-glyphs.json
    function _eightIsTheLongestLetter(string memory json, string memory face) internal view returns (bool) {
        uint256 eight;
        uint256 other;
        for (uint256 i;; ++i) {
            string memory g = string.concat(face, ".glyphs[", vm.toString(i), "]");
            if (!vm.keyExistsJson(json, g)) break;
            bytes memory ch = bytes(vm.parseJsonString(json, string.concat(g, ".char")));
            if (ch.length != 1) continue;
            bytes1 b = ch[0];
            if ((b < "a" || b > "z") && (b < "0" || b > "9") && b != "-") continue;
            uint256 n = bytes(vm.parseJsonString(json, string.concat(g, ".d"))).length;
            if (b == "8") eight = n;
            else if (n > other) other = n;
        }
        return eight > other;
    }

    function _cardLength(string memory label, string memory parentLabel, PageCard.Status s, uint256 expiry)
        internal
        view
        returns (uint256)
    {
        return bytes(card.render(label, parentLabel, WIDEST_ID, s, expiry)).length;
    }

    // the card length in its longest cases. 8 has the longest outline of every letter a label or a code can hold in
    // both typefaces, so the widest cards are drawn with eights in the name, the code and the year. The dot and the
    // parent in the left pill of a subpage take at most 1089 units of letters, so its widest parent mixes eights with
    // narrower letters. The id changes the length only through its code, the first 14 and the last 6 of its hex digits,
    // as each of the 32 squares is drawn once whatever its colour, and the code of eights draws the most of any code.
    // The website keeps the same numbers in test/svgCard.test.ts, which also searches every parent for the widest pill
    function test_cardBounds() public view {
        string memory json = vm.readFile("tools/card-glyphs.json");
        assertTrue(_eightIsTheLongestLetter(json, ".name"), "8 is the longest letter of the name");
        assertTrue(_eightIsTheLongestLetter(json, ".text"), "8 is the longest letter of the small text");
        string memory e16 = _rep("8", 16);
        string memory e17 = _rep("8", 17);
        string memory e18 = _rep("8", 18);
        string memory e63 = _rep("8", 63);
        PageCard.Status active = PageCard.Status.Active;
        // the hex digits the code leaves out, 14 to 57, change only the colours of squares 14 to 31
        bytes32 hidden = 0x00000000000000ffffffffffffffffffffffffffffffffffffffffffff000000;
        assertEq(
            bytes(card.render(e63, e18, WIDEST_ID ^ hidden, active, 0)).length,
            _cardLength(e63, e18, active, 0),
            "the hidden digits change no length"
        );

        // the widest card of all, MAX_CARD: 18 eights, the most a name shows uncut, until 28 Sep of a 70 digit year
        // of 33 and 68 eights, the latest such date a uint256 expiry reaches
        uint256 latest = 106943003999999999999999999999999999999999999999999999999999999999937828201600;
        assertEq(_until(latest), string.concat("Until 28 Sep 33", _rep("8", 68)));
        assertEq(_cardLength(e18, "", active, latest), 35777, "35777");
        // the largest expiry has a year of fewer eights
        assertEq(_cardLength(e18, "", active, type(uint256).max), 28486, "28486");

        // the bound on every card PageNFT can produce: 18 eights with the code of eights until 28 Sep 388888888888,
        // the latest date of eights a uint64 expiry reaches
        uint256 latest64 = 12272147937828201600;
        assertEq(_until(latest64), "Until 28 Sep 388888888888");
        assertEq(_cardLength(e18, "", active, latest64), 19060, "19060");
        assertEq(_cardLength(e63, "", active, type(uint64).max), 17182, "the largest uint64 expiry");

        // the widest subpage card: an active subpage of 17 eights or more under 88888888888aaaa88. Its name shows 17
        // eights and the ellipsis, and its left pill a dot and the whole parent: an a is narrower than an 8 and almost
        // as long to draw, so this parent draws the most in the room of the pill. A shorter label leaves the dot in
        // the name
        string memory widest = "88888888888aaaa88";
        assertEq(_cardLength(e63, widest, active, 0), 18862, "18862");
        assertEq(_cardLength(e17, widest, active, 0), 18862, "17 eights are as wide");
        assertEq(_cardLength(e63, e16, active, 0), 18689, "16 eights fit the pill");
        assertEq(_cardLength(e63, e17, active, 0), 18487, "17 eights do not, so the pill keeps 15 and the ellipsis");
        assertEq(_cardLength(e63, e18, active, 0), 18487, "nor do 18");
        assertEq(_cardLength(e63, e63, active, 0), 18487, "a parent of 63 eights is cut as 17 are");
        assertEq(_cardLength("8", e18, active, 0), 18252, "a label of one eight");
        assertEq(_cardLength("8", e16, active, 0), 18520, "the widest uncut name, with its parent part dimmed");

        // the 18 eights in the other states, whose left pills hold a word and a dot
        assertEq(_cardLength(e18, "", PageCard.Status.Grace, 0), 15912, "15912");
        assertEq(_cardLength(e18, "", PageCard.Status.Expired, 0), 15008, "15008");
        assertEq(_cardLength(e18, "", PageCard.Status.Invalid, 0), 14988, "14988");
        assertEq(_cardLength(e18, "", PageCard.Status.Trial, 0), 14713, "14713");
    }
}

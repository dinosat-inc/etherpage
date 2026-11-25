// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {trialCommitment} from "../../utils/TrialCommitment.sol";

import {Test} from "forge-std/Test.sol";
import {Base64} from "solady/utils/Base64.sol";
import {LibString} from "solady/utils/LibString.sol";
import {PageNFT} from "../../../src/PageNFT.sol";
import {PageCard} from "../../../src/PageCard.sol";
import {CardReader} from "../../utils/CardReader.sol";

// draws the card of every state, saves each SVG to the logs folder and compares it byte for byte with
// the reference drawing in the fixtures folder, made with the same scenario, addresses and clock
contract CardsTest is Test {
    PageNFT nft;
    PageCard card;
    CardReader reader;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address aliceW = 0x7a3F0C9b1E2d4a5B6C7D8e9F0a1B2c3d4e5F6a7B;
    address bobW = makeAddr("bob wallet");
    address carolW = makeAddr("carol wallet");
    address relayer = makeAddr("relayer");
    uint256 constant T0 = 1790424000;
    string[5] names = ["Active", "Grace", "Expired", "Invalid", "Trial"];

    function setUp() public {
        vm.warp(T0);
        card = new PageCard();
        nft = new PageNFT(card);
        vm.deal(aliceW, 10 ether);
        vm.deal(carolW, 10 ether);
        vm.deal(relayer, 10 ether);
        reader = new CardReader();
    }

    function _secret(string memory label, address owner) internal pure returns (bytes32) {
        return keccak256(abi.encode(label, owner));
    }

    function _buy(address who, string memory label) internal returns (uint256 id) {
        bytes32 commitment = nft.makeCommitment(label, who, 0, _secret(label, who));
        vm.prank(who);
        nft.commit(commitment);
        vm.warp(vm.getBlockTimestamp() + 61);
        (,,, uint256 total) = nft.quote(label);
        vm.prank(who);
        id = nft.reveal{value: total}(label, who, 0, _secret(label, who));
    }

    function _json(uint256 id) internal view returns (string memory) {
        return string(Base64.decode(LibString.slice(nft.tokenURI(id), 29)));
    }

    function _svg(uint256 id) internal view returns (string memory) {
        string memory json = _json(id);
        uint256 a = LibString.indexOf(json, "base64,") + 7;
        uint256 b = LibString.indexOf(json, '","attributes');
        return string(Base64.decode(LibString.slice(json, a, b)));
    }

    // saves the SVG, checks the metadata Status against the status view and the expected one, and
    // compares with the reference drawing when one exists for this state
    function _save(uint256 id, string memory file, PageCard.Status want, bool hasRef) internal returns (uint256) {
        string memory svg = _svg(id);
        vm.createDir("logs/cards", true);
        vm.writeFile(string.concat("logs/cards/", file, ".svg"), svg);
        assertEq(uint256(nft.status(id)), uint256(want), "status view");
        assertTrue(
            LibString.contains(_json(id), string.concat('"Status","value":"', names[uint256(want)], '"')),
            "metadata Status"
        );
        if (hasRef) {
            string memory ref = vm.readFile(string.concat("test/fixtures/cards/", file, ".svg"));
            assertEq(keccak256(bytes(svg)), keccak256(bytes(ref)), string.concat("differs from the preview: ", file));
            return 1;
        }
        return 0;
    }

    function test_drawEveryState() public {
        // counted in a local, which a state revert does not undo
        uint256 n;
        uint256 s0 = vm.snapshotState();

        uint256 alice = _buy(aliceW, "alice");
        vm.prank(aliceW);
        uint256 bob = nft.registerSubpageFor("bob", alice, bobW);
        n += _save(alice, "1-active-alice", PageCard.Status.Active, true);
        n += _save(bob, "5-active-bob-alice", PageCard.Status.Active, true);

        uint256 s1 = vm.snapshotState();
        vm.prank(bobW);
        nft.transferFrom(bobW, DEAD, bob);
        n += _save(bob, "9-deleted-bob-alice", PageCard.Status.Invalid, true);
        vm.revertToState(s1);

        uint256 e = nft.expiresAt(alice);
        vm.warp(e + 1);
        n += _save(alice, "3-grace-alice", PageCard.Status.Grace, true);
        n += _save(bob, "6-grace-bob-alice", PageCard.Status.Grace, true);
        vm.warp(e + 90 days + 1);
        n += _save(alice, "4-expired-alice", PageCard.Status.Expired, true);
        n += _save(bob, "7-expired-bob-alice", PageCard.Status.Expired, true);

        vm.warp(e + 90 days + 21 days + 1);
        _buy(carolW, "alice");
        n += _save(bob, "8-invalid-bob-alice", PageCard.Status.Invalid, true);
        assertTrue(LibString.contains(_json(bob), '"name":"bob.alice"'));

        vm.revertToState(s0);
        bytes32 commitment = trialCommitment(address(nft), "alice", aliceW, 0, _secret("alice", aliceW));
        vm.prank(relayer);
        nft.commit(commitment);
        vm.warp(vm.getBlockTimestamp() + 61);
        uint256 p = nft.getFee(5) / 10;
        vm.prank(relayer);
        uint256 t = nft.revealTrial{value: p}("alice", aliceW, 0, _secret("alice", aliceW));
        n += _save(t, "2-trial-alice", PageCard.Status.Trial, true);
        uint256 s2 = vm.snapshotState();
        uint256 fee = nft.getFee(5);
        vm.prank(relayer);
        nft.renew{value: fee}(t);
        n += _save(t, "2b-trial-paid-alice", PageCard.Status.Active, true);
        vm.revertToState(s2);
        vm.warp(nft.expiresAt(t) + 1);
        n += _save(t, "4b-trial-ended-alice", PageCard.Status.Expired, true);
        // released and inside the pause: still the same expired card
        nft.release(t);
        _save(t, "4c-trial-ended-released-alice", PageCard.Status.Expired, false);
        assertEq(
            keccak256(bytes(vm.readFile("logs/cards/4c-trial-ended-released-alice.svg"))),
            keccak256(bytes(vm.readFile("logs/cards/4b-trial-ended-alice.svg")))
        );
        emit log_named_uint("cards equal to the earlier preview", n);
        assertEq(n, 11);
    }

    // a trial thrown to DEAD is deleted, so it shows Invalid, with the code of its id, before its end and after
    function test_trialHeldByDead() public {
        bytes32 commitment = trialCommitment(address(nft), "alice", aliceW, 0, _secret("alice", aliceW));
        vm.prank(relayer);
        nft.commit(commitment);
        vm.warp(vm.getBlockTimestamp() + 61);
        uint256 p = nft.getFee(5) / 10;
        vm.prank(relayer);
        uint256 t = nft.revealTrial{value: p}("alice", aliceW, 0, _secret("alice", aliceW));
        vm.prank(aliceW);
        nft.transferFrom(aliceW, DEAD, t);
        _save(t, "2c-trial-dead-alice", PageCard.Status.Invalid, false);
        string memory svg = _svg(t);
        CardReader.Card memory c = reader.read(svg);
        assertTrue(c.dead, "a dead card");
        assertEq(c.name, "alice");
        assertEq(c.left, "Invalid", "Invalid, not Trial");
        assertEq(c.dot, "#e5484d", "the red dot");
        assertEq(c.right, reader.code(bytes32(t)), "the code of its id");
        assertEq(svg, card.render("alice", "", bytes32(t), PageCard.Status.Invalid, 0), "the Invalid card");
        vm.warp(nft.expiresAt(t) + 1);
        assertEq(uint256(nft.status(t)), uint256(PageCard.Status.Invalid), "still Invalid once the trial has ended");
        assertEq(_svg(t), svg, "the same card once the trial has ended");
    }

    // the card before the left pill, and from the right pill on
    function _aroundLeftPill(string memory svg) internal pure returns (string memory before, string memory rest) {
        uint256 a = LibString.indexOf(svg, '<rect x="90" y="840"');
        uint256 b = LibString.indexOf(svg, '<rect x="', a + 1);
        assertTrue(b != LibString.NOT_FOUND, "a left pill and a right pill");
        return (LibString.slice(svg, 0, a), LibString.slice(svg, b));
    }

    // the renderer draws the Trial card exactly as the Grace card with another word and dot in the left pill, and
    // refuses a status past the last one
    function test_trialPillIsTheGracePillWithAnotherWordAndDot() public {
        string memory g = card.render("alice", "", bytes32(uint256(1)), PageCard.Status.Grace, 0);
        string memory t = card.render("alice", "", bytes32(uint256(1)), PageCard.Status.Trial, 0);
        CardReader.Card memory rg = reader.read(g);
        CardReader.Card memory rt = reader.read(t);
        assertEq(rg.left, "Grace period");
        assertEq(rg.dot, "#ffc94a", "the mustard dot of Grace");
        assertEq(rt.left, "Trial");
        assertEq(rt.dot, "#7193f2", "the blue dot of a trial");
        // the same live card around the pill: name, fingerprint and code
        assertFalse(rg.dead || rt.dead, "both live");
        assertEq(rt.name, "alice");
        assertEq(rg.name, "alice");
        assertEq(rt.dimmed, rg.dimmed);
        assertEq(rt.right, unicode"00000000000000…000001");
        assertEq(rg.right, unicode"00000000000000…000001");
        for (uint256 i; i < 32; ++i) assertEq(rt.on[i], rg.on[i]);
        (string memory gBefore, string memory gRest) = _aroundLeftPill(g);
        (string memory tBefore, string memory tRest) = _aroundLeftPill(t);
        assertEq(tBefore, gBefore, "the same bytes before the left pill");
        assertEq(tRest, gRest, "and from the right pill on");
        (bool ok,) = address(card).call(
            abi.encodeWithSelector(PageCard.render.selector, "a", "", bytes32(0), uint256(5), uint256(0))
        );
        assertFalse(ok);
    }
}

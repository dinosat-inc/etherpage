// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Vm} from "forge-std/Test.sol";
import {LibString} from "solady/utils/LibString.sol";
import {PageCard} from "../../src/PageCard.sol";
import {SubpageRegistrar} from "../../src/SubpageRegistrar.sol";
import {MinterBase} from "../utils/MinterBase.sol";
import {CardReader} from "../utils/CardReader.sol";

// What the comments of SubpageRegistrar and PageCard state that other tests pin only in part: names left in the
// registrar by a plain transfer, the four slots of the sale terms, the terms each ParentConfigured logs, what a sale
// commitment binds and when it can be made again, whose gate balance a reveal for another account reads, and the
// first and last date of every month of an era of the card's date math.
contract RegistrarAndCardClaimsTest is MinterBase {
    uint256 constant PRICE = 0.01 ether;

    // 1 March 2000, the first day of a 400 year era of the card's date math, and the number of days in an era
    uint256 constant ERA_START = 951868800;
    uint256 constant ERA_DAYS = 146097;
    bytes constant MONTHS = "JanFebMarAprMayJunJulAugSepOctNovDec";
    // where the left pill of a card starts
    string constant LEFT_PILL = '<rect x="90" y="840"';

    uint256 club;

    function setUp() public override {
        super.setUp();
        club = _reg(alice, "club");
    }

    // alice sells under club, and two names sit in the registrar after plain transfers: gold, whose holder had
    // approved hot2 for it and made hot its operator, and kept, a live subpage of club
    function _strand() internal returns (uint256 gold, uint256 kept) {
        _sellSetup(club, PRICE);
        gold = _reg(alice, "gold");
        vm.startPrank(alice);
        nft.setApprovalForAll(hot, true);
        nft.approve(hot2, gold);
        nft.transferFrom(alice, address(reg), gold);
        kept = nft.registerSubpageFor("kept", club, alice);
        nft.transferFrom(alice, address(reg), kept);
        vm.stopPrank();
        assertEq(nft.ownerOf(gold), address(reg));
        assertEq(nft.ownerOf(kept), address(reg));
        assertEq(nft.balanceOf(address(reg)), 2);
    }

    // the PageNFT logs hold n mints, no other Transfer and no approval
    function _assertOnlyMints(Vm.Log[] memory logs, uint256 n) internal view {
        uint256 mints;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(nft)) continue;
            bytes32 topic = logs[i].topics[0];
            assertTrue(topic != T_APPROVAL && topic != T_APPROVAL_ALL, "an approval");
            if (topic == T_TRANSFER) {
                assertEq(logs[i].topics[1], bytes32(0), "a Transfer that is not a mint");
                ++mints;
            }
        }
        assertEq(mints, n);
    }

    // the one Transfer out of the registrar is the burn of id, and id is then minted to the new holder
    function _assertBurnedThenMinted(Vm.Log[] memory logs, uint256 id, address to) internal view {
        uint256 burns;
        uint256 mints;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(nft) || logs[i].topics[0] != T_TRANSFER) continue;
            address from = address(uint160(uint256(logs[i].topics[1])));
            address dest = address(uint160(uint256(logs[i].topics[2])));
            assertEq(uint256(logs[i].topics[3]), id);
            assertTrue(dest != address(reg), "a Transfer into the registrar");
            if (from == address(reg)) {
                assertEq(dest, address(0), "out of the registrar other than by a burn");
                assertEq(mints, 0, "burned before the mint");
                ++burns;
            } else {
                assertEq(from, address(0));
                assertEq(dest, to);
                ++mints;
            }
        }
        assertEq(burns, 1);
        assertEq(mints, 1);
        assertEq(nft.ownerOf(id), to);
    }

    // the registrar holds two names, is an operator of alice and of the buyer and is approved for club, and every
    // entry point runs, the direct sales on the ETH path and the reveals on the ERC20 path: the only Transfer logs are
    // the mints of the subpages sold, no approval is logged, and nobody is approved for a name the registrar holds
    function test_registrarNeverTransfersOrApprovesAName() public {
        (uint256 gold, uint256 kept) = _strand();
        uint256 zoo = _reg(bob, "zoo");
        uint256 own = _reg(buyer, "buyer");
        vm.startPrank(alice);
        nft.setApprovalForAll(address(reg), true);
        nft.approve(address(reg), club);
        vm.stopPrank();
        vm.prank(buyer);
        nft.setApprovalForAll(address(reg), true);
        // bob sells under zoo for the ERC20, with commit and reveal, to holders of a name
        _setMinter(zoo, address(reg));
        vm.prank(bob);
        reg.configure(zoo, bob, address(usd), 5, true, address(nft), 1, true);
        usd.mint(buyer, 100);
        vm.prank(buyer);
        usd.approve(address(reg), type(uint256).max);
        bytes32 s = keccak256("s");

        vm.recordLogs();
        vm.prank(alice);
        reg.configure(club, payout, address(0), PRICE, true, address(0), 0, false);
        vm.startPrank(buyer);
        reg.registerSubpage{value: PRICE}(club, "one", PRICE, address(0));
        reg.registerSubpageFor{value: PRICE + 1}(club, "two", carol, PRICE, address(0));
        reg.commitSubpage(reg.makeSubpageCommitment(zoo, "three", buyer, s));
        reg.commitSubpage(reg.makeSubpageCommitment(zoo, "four", carol, s));
        vm.warp(vm.getBlockTimestamp() + 20);
        reg.revealSubpage(zoo, "three", s, 5, address(usd));
        reg.revealSubpageFor(zoo, "four", carol, s, 5, address(usd));
        vm.stopPrank();
        vm.prank(payout);
        reg.claimProceeds(dave);
        vm.prank(buyer);
        reg.registerSubpage{value: PRICE}(club, "five", PRICE, address(0));
        vm.prank(stranger);
        reg.claimProceedsFor(payout);
        vm.startPrank(alice);
        // PageNFT is never the token a sale pulls, which would make the pull an ERC721 transferFrom
        vm.expectRevert(SubpageRegistrar.BadFeeToken.selector);
        reg.configure(club, payout, address(nft), 1, true, address(0), 0, false);
        reg.disable(club);
        vm.stopPrank();
        vm.prank(bob);
        reg.disable(zoo);
        _assertOnlyMints(vm.getRecordedLogs(), 5);

        assertEq(nft.ownerOf(gold), address(reg));
        assertEq(nft.ownerOf(kept), address(reg));
        assertEq(nft.balanceOf(address(reg)), 2);
        assertEq(nft.getApproved(gold), address(0));
        assertEq(nft.getApproved(kept), address(0));
        assertEq(nft.ownerOf(club), alice);
        assertEq(nft.getApproved(club), address(reg));
        assertEq(nft.ownerOf(zoo), bob);
        assertEq(nft.ownerOf(own), buyer);
        address[9] memory who = [alice, bob, carol, dave, hot, hot2, buyer, stranger, payout];
        for (uint256 i; i < who.length; ++i) assertFalse(nft.isApprovedForAll(address(reg), who[i]));
    }

    // nobody can move or approve a name the registrar holds: not its last holder, the operator or the account that
    // holder had approved, nor anyone else; the registrar calls that name it are refused and leave it in place
    function test_strandedNameCannotBeSentBack() public {
        (uint256 gold, uint256 kept) = _strand();
        uint256[2] memory ids = [gold, kept];
        address[6] memory who = [alice, hot, hot2, stranger, buyer, payout];
        for (uint256 i; i < ids.length; ++i) {
            for (uint256 j; j < who.length; ++j) {
                vm.startPrank(who[j]);
                vm.expectRevert(NOT_OWNER_NOR_APPROVED);
                nft.transferFrom(address(reg), who[j], ids[i]);
                vm.expectRevert(NOT_OWNER_NOR_APPROVED);
                nft.safeTransferFrom(address(reg), who[j], ids[i]);
                vm.expectRevert(NOT_OWNER_NOR_APPROVED);
                nft.safeTransferFrom(address(reg), who[j], ids[i], "");
                vm.expectRevert(NOT_OWNER_NOR_APPROVED);
                nft.approve(who[j], ids[i]);
                vm.stopPrank();
            }
        }
        vm.startPrank(alice);
        vm.expectRevert(SubpageRegistrar.NotAuthorized.selector);
        reg.configure(gold, alice, address(0), 0, true, address(0), 0, false);
        vm.expectRevert(SubpageRegistrar.NotAuthorized.selector);
        reg.disable(gold);
        vm.stopPrank();
        bytes32 s = keccak256("s");
        vm.startPrank(buyer);
        vm.expectRevert(SubpageRegistrar.NotEnabled.selector);
        reg.registerSubpage(gold, "x", 0, address(0));
        vm.expectRevert(SubpageRegistrar.NotAvailable.selector);
        reg.registerSubpageFor{value: PRICE}(club, "KEPT", alice, PRICE, address(0));
        reg.commitSubpage(reg.makeSubpageCommitment(club, "kept", alice, s));
        vm.warp(vm.getBlockTimestamp() + 20);
        vm.expectRevert(SubpageRegistrar.NotAvailable.selector);
        reg.revealSubpageFor{value: PRICE}(club, "kept", alice, s, PRICE, address(0));
        vm.stopPrank();

        for (uint256 i; i < ids.length; ++i) {
            assertEq(nft.ownerOf(ids[i]), address(reg));
            assertEq(nft.getApproved(ids[i]), address(0));
        }
        assertEq(nft.balanceOf(address(reg)), 2);
        for (uint256 j; j < who.length; ++j) assertFalse(nft.isApprovedForAll(address(reg), who[j]));
    }

    // a stranded name leaves the registrar only when PageNFT burns it: kept when the holder of club mints it again,
    // gold when it lapses and is registered again
    function test_strandedNameLeavesOnlyWhenBurned() public {
        (uint256 gold, uint256 kept) = _strand();
        vm.recordLogs();
        vm.prank(alice);
        nft.registerSubpageFor("kept", club, carol);
        _assertBurnedThenMinted(vm.getRecordedLogs(), kept, carol);
        assertEq(nft.balanceOf(address(reg)), 1);
        vm.recordLogs();
        _lapseAndRegister(gold, dave);
        _assertBurnedThenMinted(vm.getRecordedLogs(), gold, dave);
        assertEq(nft.balanceOf(address(reg)), 0);
    }

    // the terms of a name fill exactly four slots of the config mapping, which is slot 0 as the guard uses transient
    // storage and name is immutable
    function test_termsPackIntoFourSlots() public {
        uint64 epoch = nft.epochOf(club);
        address gate = address(0xBEEF);
        uint256 price = uint256(type(uint96).max) - 1;
        uint256 minGate = 0x123456;
        vm.record();
        vm.prank(alice);
        reg.configure(club, payout, address(usd), price, false, gate, minGate, true);
        (, bytes32[] memory writes) = vm.accesses(address(reg));
        vm.stopRecord();
        uint256 base = uint256(keccak256(abi.encode(club, uint256(0))));
        assertGt(writes.length, 0);
        for (uint256 i; i < writes.length; ++i) {
            assertTrue(uint256(writes[i]) >= base && uint256(writes[i]) < base + 4, "a write outside the four slots");
        }
        // controller with enabled at byte 20 and commitReveal at byte 21, feeToken and price, gateToken and
        // minGateBalance, payout and parentEpoch
        assertEq(uint256(vm.load(address(reg), bytes32(base))), uint256(uint160(alice)) | (uint256(1) << 168));
        assertEq(uint256(vm.load(address(reg), bytes32(base + 1))), uint256(uint160(address(usd))) | (price << 160));
        assertEq(uint256(vm.load(address(reg), bytes32(base + 2))), uint256(uint160(gate)) | (minGate << 160));
        assertEq(
            uint256(vm.load(address(reg), bytes32(base + 3))), uint256(uint160(payout)) | (uint256(epoch) << 160)
        );
        assertEq(vm.load(address(reg), bytes32(base + 4)), bytes32(0));
        // the two flags the other way round
        vm.prank(alice);
        reg.configure(club, payout, address(usd), price, true, gate, minGate, false);
        assertEq(uint256(vm.load(address(reg), bytes32(base))), uint256(uint160(alice)) | (uint256(1) << 160));
    }

    // configure logs a zero payout as the caller, and a later holder's disable logs the terms alice set with sales
    // off, both as they are stored
    function test_parentConfiguredLogsTheStoredTerms() public {
        uint64 epoch = nft.epochOf(club);
        address gate = address(0xBEEF);
        vm.expectEmit(true, true, true, true, address(reg));
        emit SubpageRegistrar.ParentConfigured(club, alice, alice, address(usd), 7, gate, 3, true, true, epoch);
        vm.prank(alice);
        reg.configure(club, address(0), address(usd), 7, true, gate, 3, true);
        (,,,,,,, address stored,) = reg.config(club);
        assertEq(stored, alice);

        vm.prank(alice);
        nft.transferFrom(alice, bob, club);
        vm.expectEmit(true, true, true, true, address(reg));
        emit SubpageRegistrar.ParentConfigured(club, alice, alice, address(usd), 7, gate, 3, false, true, epoch);
        vm.prank(bob);
        reg.disable(club);
        (address controller, bool enabled,,,,,, address payoutAfter,) = reg.config(club);
        assertEq(controller, alice);
        assertFalse(enabled);
        assertEq(payoutAfter, alice);
    }

    // a reveal finds the commitment only with the parent, the label, the receiver and the secret it was made with,
    // the label in any case, and the commitment stays until those values buy the subpage
    function testFuzz_subCommitmentBindsParentLabelReceiverAndSecret(address other, bytes32 secret, bytes32 secret2)
        public
    {
        vm.assume(other != carol && other != address(reg) && secret2 != secret);
        uint256 zoo = _reg(bob, "zoo");
        _setMinter(club, address(reg));
        _configure(club, payout, address(0), PRICE, true);
        _setMinter(zoo, address(reg));
        _configure(zoo, payout, address(0), PRICE, true);
        bytes32 c = reg.makeSubpageCommitment(club, "kid", carol, secret);
        vm.prank(buyer);
        reg.commitSubpage(c);
        uint256 t = vm.getBlockTimestamp();
        vm.warp(t + 20);

        vm.startPrank(stranger);
        vm.expectRevert(SubpageRegistrar.CommitmentNotFound.selector);
        reg.revealSubpageFor{value: PRICE}(zoo, "kid", carol, secret, PRICE, address(0));
        vm.expectRevert(SubpageRegistrar.CommitmentNotFound.selector);
        reg.revealSubpageFor{value: PRICE}(club, "kids", carol, secret, PRICE, address(0));
        vm.expectRevert(SubpageRegistrar.CommitmentNotFound.selector);
        reg.revealSubpageFor{value: PRICE}(club, "kid", other, secret, PRICE, address(0));
        vm.expectRevert(SubpageRegistrar.CommitmentNotFound.selector);
        reg.revealSubpageFor{value: PRICE}(club, "kid", carol, secret2, PRICE, address(0));
        vm.stopPrank();
        assertEq(reg.subCommitments(c), t, "the commitment is still there");
        assertTrue(nft.isAvailable("kid", club));
        assertTrue(nft.isAvailable("kid", zoo));

        vm.prank(stranger);
        uint256 id = reg.revealSubpageFor{value: PRICE}(club, "KID", carol, secret, PRICE, address(0));
        assertEq(id, _subId("kid", club));
        assertEq(nft.ownerOf(id), carol);
        assertEq(reg.subCommitments(c), 0, "used up");
    }

    // a used commitment can be made again at once, well inside its day, and it counts from the new time
    function test_usedCommitmentCanBeMadeAgainAtOnce() public {
        _setMinter(club, address(reg));
        _configure(club, payout, address(0), 0, true);
        bytes32 s = keccak256("s");
        bytes32 c = reg.makeSubpageCommitment(club, "kid", buyer, s);
        vm.prank(buyer);
        reg.commitSubpage(c);
        uint256 t = vm.getBlockTimestamp();
        vm.warp(t + 20);
        vm.prank(buyer);
        uint256 id = reg.revealSubpage(club, "kid", s, 0, address(0));
        assertEq(reg.subCommitments(c), 0, "used");

        vm.expectEmit(true, true, false, true, address(reg));
        emit SubpageRegistrar.Committed(c, stranger);
        vm.prank(stranger);
        reg.commitSubpage(c);
        assertEq(reg.subCommitments(c), t + 20);
        vm.prank(buyer);
        vm.expectRevert(SubpageRegistrar.AlreadyCommitted.selector);
        reg.commitSubpage(c);
        vm.prank(buyer);
        vm.expectRevert(SubpageRegistrar.CommitmentTooNew.selector);
        reg.revealSubpage(club, "kid", s, 0, address(0));

        // once the label is free again the new commitment buys it
        vm.prank(buyer);
        nft.transferFrom(buyer, DEAD, id);
        vm.warp(t + 40);
        vm.prank(buyer);
        uint256 again = reg.revealSubpage(club, "kid", s, 0, address(0));
        assertEq(again, id);
        assertEq(nft.ownerOf(id), buyer);
        assertEq(reg.subCommitments(c), 0);
    }

    // revealSubpageFor reads the gate balance of the caller, not of the receiver
    function test_revealForChecksTheCallersGate() public {
        _setMinter(club, address(reg));
        vm.prank(alice);
        reg.configure(club, payout, address(0), 0, true, address(usd), 5, true);
        usd.mint(carol, 5);
        usd.mint(buyer, 4);
        bytes32 s = keccak256("s");
        bytes32 c = reg.makeSubpageCommitment(club, "kid", carol, s);
        bytes32 c2 = reg.makeSubpageCommitment(club, "kid2", stranger, s);
        vm.startPrank(buyer);
        reg.commitSubpage(c);
        reg.commitSubpage(c2);
        uint256 t = vm.getBlockTimestamp();
        vm.warp(t + 20);
        // carol holds enough and the buyer one too few
        vm.expectRevert(SubpageRegistrar.GateFailed.selector);
        reg.revealSubpageFor(club, "kid", carol, s, 0, address(0));
        assertEq(reg.subCommitments(c), t);
        usd.mint(buyer, 1);
        uint256 id = reg.revealSubpageFor(club, "kid", carol, s, 0, address(0));
        // the stranger holds none and still receives one the buyer's balance passes
        uint256 id2 = reg.revealSubpageFor(club, "kid2", stranger, s, 0, address(0));
        vm.stopPrank();
        assertEq(nft.ownerOf(id), carol);
        assertEq(nft.ownerOf(id2), stranger);
        assertEq(usd.balanceOf(buyer), 5, "the gate is only read");
        assertEq(usd.balanceOf(stranger), 0);
    }

    // a reveal must name the receiver of the commitment: the committer taking it for itself and a stranger naming
    // itself find nothing, and a stranger naming carol pays and carol gets the subpage
    function test_revealMustNameTheCommittedReceiver() public {
        _setMinter(club, address(reg));
        _configure(club, payout, address(0), PRICE, true);
        bytes32 s = keccak256("s");
        bytes32 c = reg.makeSubpageCommitment(club, "kid", carol, s);
        vm.prank(buyer);
        reg.commitSubpage(c);
        uint256 t = vm.getBlockTimestamp();
        vm.warp(t + 20);
        vm.startPrank(buyer);
        vm.expectRevert(SubpageRegistrar.CommitmentNotFound.selector);
        reg.revealSubpage{value: PRICE}(club, "kid", s, PRICE, address(0));
        vm.expectRevert(SubpageRegistrar.CommitmentNotFound.selector);
        reg.revealSubpageFor{value: PRICE}(club, "kid", buyer, s, PRICE, address(0));
        vm.stopPrank();
        vm.prank(stranger);
        vm.expectRevert(SubpageRegistrar.CommitmentNotFound.selector);
        reg.revealSubpageFor{value: PRICE}(club, "kid", stranger, s, PRICE, address(0));
        assertEq(reg.subCommitments(c), t);

        uint256 before = stranger.balance;
        vm.prank(stranger);
        uint256 id = reg.revealSubpageFor{value: PRICE}(club, "kid", carol, s, PRICE, address(0));
        assertEq(nft.ownerOf(id), carol);
        assertEq(nft.balanceOf(stranger), 0);
        assertEq(before - stranger.balance, PRICE, "the caller paid");
    }

    // the card of the sweep: an active top level page, which shows its expiry in the left pill
    function _eraCard(uint256 t) internal view returns (string memory) {
        return card.render("a", "", bytes32(0), PageCard.Status.Active, t);
    }

    // the day, the month from 1 and the year of unix time t, by the method of Fliegel and Van Flandern, which shares
    // no step with the card's
    function _calendar(uint256 t) internal pure returns (uint256 day, uint256 month, uint256 year) {
        int256 l = int256(t / 86400) + 68569 + 2440588;
        int256 n = 4 * l / 146097;
        l = l - (146097 * n + 3) / 4;
        int256 i = 4000 * (l + 1) / 1461001;
        l = l - 1461 * i / 4 + 31;
        int256 j = 80 * l / 2447;
        day = uint256(l - 2447 * j / 80);
        l = j / 11;
        month = uint256(j + 2 - 12 * l);
        year = uint256(100 * (n - 49) + i + l);
    }

    // the left pill of the card of t by the calendar, Until and the date, with the spaces left out when spaced is false
    function _calendarPill(uint256 t, bool spaced) internal pure returns (string memory) {
        (uint256 d, uint256 m, uint256 y) = _calendar(t);
        string memory s = spaced ? " " : "";
        string memory month = LibString.slice(string(MONTHS), 3 * m - 3, 3 * m);
        return string.concat("Until", s, LibString.toString(d), s, month, s, LibString.toString(y));
    }

    // the hash of the outline of each letter of the small text, by its byte, from the letters the card is drawn with
    function _textOutlines() internal view returns (bytes32[128] memory outline) {
        string memory json = vm.readFile("tools/card-glyphs.json");
        for (uint256 i;; ++i) {
            string memory g = string.concat(".text.glyphs[", vm.toString(i), "]");
            if (!vm.keyExistsJson(json, g)) break;
            bytes memory c = bytes(vm.parseJsonString(json, string.concat(g, ".char")));
            if (c.length == 1 && uint8(c[0]) < 128) {
                outline[uint8(c[0])] = keccak256(bytes(vm.parseJsonString(json, string.concat(g, ".d"))));
            }
        }
    }

    // the hash of the bytes of s from a to b, copied nowhere
    function _hash(string memory s, uint256 a, uint256 b) internal pure returns (bytes32 h) {
        assembly ("memory-safe") {
            h := keccak256(add(add(s, 0x20), a), sub(b, a))
        }
    }

    // whether the left pill of svg, which starts at pill, draws the outlines of the letters of want one after another
    // and no others, and where the pill's letters end
    function _drawsLetters(string memory svg, uint256 pill, bytes memory want, bytes32[128] memory outline)
        internal
        pure
        returns (bool ok, uint256 end)
    {
        end = LibString.indexOf(svg, "</g>", pill);
        uint256 k;
        for (uint256 p = LibString.indexOf(svg, ' d="', pill); p < end; p = LibString.indexOf(svg, ' d="', p)) {
            uint256 q = LibString.indexOf(svg, '"', p + 4);
            if (k == want.length || _hash(svg, p + 4, q) != outline[uint8(want[k])]) return (false, end);
            ++k;
            p = q;
        }
        ok = k == want.length;
    }

    // over one era of the card's date math the first and the last day of every month, at a second of the day that
    // moves from day to day, print the date an independent calendar gives, so every month index and every leap day is
    // drawn and the month cap never fires. The calendar runs for every day and the card only on those days. The first
    // card and the two at the turn of the era are read in full; on the others the left pill draws the letters of
    // Until and the date one after another, and the card around them is the first card's. CardDateOracleTest and
    // DateRowsTest check where those letters sit
    function test_everyMonthOfAnEraPrintsItsFirstAndLastDate() public {
        CardReader reader = new CardReader();
        assertEq((ERA_START / 86400 + 719468) % ERA_DAYS, 0, "the sweep starts an era");
        assertEq(_calendarPill(ERA_START, true), "Until 1 Mar 2000");
        string memory first = _eraCard(ERA_START);
        assertEq(reader.read(first).left, "Until 1 Mar 2000");
        // only the left pill changes with the date: the same bytes come before it and after its letters
        uint256 pill = LibString.indexOf(first, LEFT_PILL);
        uint256 firstEnd = LibString.indexOf(first, "</g>", pill);
        bytes32 head = _hash(first, 0, pill);
        bytes32 tail = _hash(first, firstEnd, bytes(first).length);
        bytes32[128] memory outline = _textOutlines();
        uint256 drawn;
        (uint256 today,,) = _calendar(ERA_START);
        for (uint256 k; k < ERA_DAYS; ++k) {
            uint256 t = ERA_START + k * 86400 + (k * 7919) % 86400;
            (uint256 tomorrow,,) = _calendar(ERA_START + (k + 1) * 86400);
            if (today == 1 || tomorrow == 1) {
                // each card is let go before the next, so memory stays the size of one card
                uint256 free;
                assembly ("memory-safe") {
                    free := mload(0x40)
                }
                string memory svg = _eraCard(t);
                (bool ok, uint256 end) = _drawsLetters(svg, pill, bytes(_calendarPill(t, false)), outline);
                if (!ok || _hash(svg, 0, pill) != head || _hash(svg, end, bytes(svg).length) != tail) {
                    assertEq(reader.read(svg).left, _calendarPill(t, true), vm.toString(t));
                    assertTrue(ok, string.concat(vm.toString(t), ": the letters of the left pill"));
                    assertEq(_hash(svg, 0, pill), head, string.concat(vm.toString(t), ": the card before the pill"));
                    assertEq(_hash(svg, end, bytes(svg).length), tail, string.concat(vm.toString(t), ": after it"));
                }
                ++drawn;
                assembly ("memory-safe") {
                    mstore(0x40, free)
                }
            }
            today = tomorrow;
        }
        assertEq(drawn, 400 * 12 * 2, "the first and last day of 4800 months");
        assertEq(reader.read(_eraCard(ERA_START + ERA_DAYS * 86400 - 1)).left, "Until 29 Feb 2400");
        assertEq(reader.read(_eraCard(ERA_START + ERA_DAYS * 86400)).left, "Until 1 Mar 2400");
    }
}

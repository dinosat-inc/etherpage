// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Vm} from "forge-std/Test.sol";
import {LibString} from "solady/utils/LibString.sol";
import {PageNFT} from "../../src/PageNFT.sol";
import {PageCard} from "../../src/PageCard.sol";
import {RulesBase} from "../utils/RulesBase.sol";

// a renderer whose card is too short to be a real one
contract ShortCard {
    uint256 public immutable len;

    constructor(uint256 n) {
        len = n;
    }

    function render(string memory, string memory, bytes32, PageCard.Status, uint256)
        external
        view
        returns (string memory)
    {
        return string(new bytes(len));
    }
}

// Reaches the PageNFT lines and branches that the rest of the suite leaves out.
contract PageNFTCoverageTest is RulesBase {
    // the interfaces the resolver and the token announce, and nothing else
    function test_supportsInterface() public view {
        bytes4[8] memory yes = [
            bytes4(0x3b3b57de), // addr(bytes32)
            0xf1cb7e06, // addr(bytes32,uint256)
            0x59d1d43c, // text(bytes32,string)
            0xbc1c58d1, // contenthash(bytes32)
            0x49064906, // ERC4906
            0x01ffc9a7, // ERC165
            0x80ac58cd, // ERC721
            0x5b5e139f // ERC721 metadata
        ];
        for (uint256 i; i < yes.length; ++i) assertTrue(nft.supportsInterface(yes[i]), "announced");
        bytes4[4] memory no = [bytes4(0xffffffff), 0x00000000, 0x12345678, 0xd9b67a26];
        for (uint256 i; i < no.length; ++i) assertFalse(nft.supportsInterface(no[i]), "not announced");
    }

    function test_constructorRefusesZeroCard() public {
        vm.expectRevert(PageNFT.InvalidRenderer.selector);
        new PageNFT(PageCard(address(0)));
    }

    // A card under 100 bytes is refused. Outside a try, a test runs new PageNFT as a deployCode cheatcode, and a
    // deployment that reverts there ends the test, so the card of 100 bytes has a test of its own.
    function test_constructorRefusesShortCard() public {
        ShortCard s = new ShortCard(99);
        vm.expectRevert(PageNFT.InvalidRenderer.selector);
        new PageNFT(PageCard(address(s)));
    }

    // a card of exactly 100 bytes is enough
    function test_constructorAcceptsCardOf100Bytes() public {
        ShortCard s = new ShortCard(100);
        PageNFT ok = new PageNFT(PageCard(address(s)));
        assertGt(address(ok).code.length, 0, "deployed");
        assertEq(address(ok.card()), address(s), "bound to the card of 100 bytes");
    }

    // a failing call in a bundle reverts the bundle with that call's own error
    function test_multicallBubblesTheRevert() public {
        uint256 id = _buy(bob, "bubble");
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(nft.setPrimaryPage, (id));
        calls[1] = abi.encodeCall(nft.setAddr, (id, address(nft)));
        vm.prank(bob);
        vm.expectRevert(PageNFT.InvalidRecipient.selector);
        nft.multicall(calls);
        assertEq(nft.primaryPage(bob), 0, "the first call was undone");

        calls[1] = abi.encodeCall(nft.setAddr, (id, carol));
        vm.prank(bob);
        bytes[] memory out = nft.multicall(calls);
        assertEq(out.length, 2);
        assertEq(nft.primaryPage(bob), id);
        assertEq(nft.resolve(id), carol);
    }

    // an invalid label quotes all zeros
    function test_quoteOfInvalidLabelIsZero() public view {
        string[5] memory bad = ["", "a_b", "-ab", "ab-", "0x0000000000000000000000000000000000000000"];
        for (uint256 i; i < bad.length; ++i) {
            (uint256 f, uint256 c, uint256 p, uint256 t) = nft.quote(bad[i]);
            assertEq(f + c + p + t, 0, bad[i]);
        }
        (uint256 f2,,, uint256 t2) = nft.quote(string(new bytes(64)));
        assertEq(f2 + t2, 0, "64 bytes");
        (uint256 f3,,, uint256 t3) = nft.quote("ABCDE");
        assertEq(f3, FEE5);
        assertEq(t3, FEE5);
    }

    // a commitment can be revealed up to one day after it was made, and not one second later
    function test_commitmentTooOld() public {
        _commitPaid(bob, "olden", bob, 0);
        uint256 t0 = vm.getBlockTimestamp();
        vm.warp(t0 + 86400 + 1);
        vm.prank(bob);
        vm.expectRevert(PageNFT.CommitmentTooOld.selector);
        nft.reveal{value: FEE5}("olden", bob, 0, _s("olden", bob, 0));

        // a trial commitment ages out the same way
        _commitTrial(carol, "trialx", carol, 0);
        uint256 t1 = vm.getBlockTimestamp();
        vm.warp(t1 + 86401);
        uint256 price = _price("trialx");
        vm.prank(carol);
        vm.expectRevert(PageNFT.CommitmentTooOld.selector);
        nft.revealTrial{value: price}("trialx", carol, 0, _s("trialx", carol, 0));

        // at exactly one day it still works
        _commitPaid(bob, "edged", bob, 0);
        uint256 t2 = vm.getBlockTimestamp();
        vm.warp(t2 + 86400);
        vm.prank(bob);
        uint256 id = nft.reveal{value: FEE5}("edged", bob, 0, _s("edged", bob, 0));
        assertEq(nft.ownerOf(id), bob);
    }

    // a subpage named as referrer earns nothing: its share of the premium goes to the dead address
    function test_subpageReferrerShareGoesToDead() public {
        uint256 club = _buy(bob, "club");
        vm.prank(bob);
        uint256 sub = nft.registerSubpage("s", club);
        uint256 x = _buy(carol, "xname", carol, sub);
        assertEq(nft.referrerOf(x), sub);

        // one day into the premium
        vm.warp(nft.expiresAt(x) + 90 days + 1 days);
        _commitPaid(dave, "xname", dave, 0);
        vm.warp(vm.getBlockTimestamp() + 61);
        (, uint256 carried, uint256 premium, uint256 total) = nft.quote("xname");
        assertGt(premium, 0, "premium");
        assertEq(carried, FEE5, "carried");
        uint256 refShare = premium * 2500 / 10_000;
        uint256 deadBefore = nft.owed(DEAD);
        uint256 carolBefore = nft.owed(carol);
        uint256 bobBefore = nft.owed(bob);

        vm.recordLogs();
        vm.prank(dave);
        nft.reveal{value: total}("xname", dave, 0, _s("xname", dave, 0));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(nft.owed(DEAD) - deadBefore, refShare, "the referrer share went to DEAD");
        assertEq(nft.owed(carol) - carolBefore, carried + premium - refShare, "the last payee got the rest");
        assertEq(nft.owed(bob), bobBefore, "the holder of the parent got nothing");

        uint256 seen;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(nft) || logs[i].topics[0] != T_REF_PREMIUM) continue;
            ++seen;
            assertEq(logs[i].topics[1], bytes32(x));
            assertEq(logs[i].topics[2], bytes32(sub));
            assertEq(logs[i].topics[3], bytes32(uint256(uint160(DEAD))));
            assertEq(abi.decode(logs[i].data, (uint256)), refShare);
        }
        assertEq(seen, 1, "one referrer premium event");
    }

    // a subpage is never releasable, and release refuses it
    function test_subpageIsNotReleasable() public {
        uint256 club = _buy(bob, "club");
        vm.prank(bob);
        uint256 sub = nft.registerSubpage("s", club);
        vm.warp(nft.expiresAt(club) + 90 days + 21 days + 1);
        assertTrue(nft.isReleasable(club), "the parent is");
        assertFalse(nft.isReleasable(sub), "the subpage is not");
        vm.expectRevert(PageNFT.NotTopLevel.selector);
        nft.release(sub);
    }

    // approve refuses ETH and works without it
    function test_approveRefusesValue() public {
        uint256 id = _buy(bob, "appro");
        vm.prank(bob);
        vm.expectRevert(PageNFT.UnexpectedValue.selector);
        nft.approve{value: 1}(carol, id);
        assertEq(nft.getApproved(id), address(0));
        vm.prank(bob);
        nft.approve(carol, id);
        assertEq(nft.getApproved(id), carol);
    }

    // Trial money paid from the zero address is credited to the dead address. No real transaction comes
    // from the zero address, so only a test can make this call.
    function test_trialPaidFromZeroIsCreditedToDead() public {
        vm.deal(address(0), 1 ether);
        uint256 id = _trial(address(0), "zerop", bob, 0);
        (address payer, uint96 amount) = nft.trialPaymentOf(id);
        assertEq(payer, address(0));
        assertEq(amount, FEE5 / 10);

        vm.warp(nft.expiresAt(id) + 1);
        uint256 deadBefore = nft.owed(DEAD);
        vm.recordLogs();
        nft.release(id);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(nft.owed(DEAD) - deadBefore, FEE5 / 10, "credited to DEAD");
        assertEq(nft.owed(address(0)), 0, "never to zero");
        assertEq(_count(logs, T_REFUNDED), 1);
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == T_REFUNDED) {
                assertEq(logs[i].topics[2], bytes32(uint256(uint160(DEAD))), "the event names DEAD");
            }
        }
    }

    // No kind of code at the main address changes an answer: coin type 60 answers empty while nothing is saved for
    // it, then the saved default, and the home chain answers the main address. The kinds of code still decide the
    // receiver check of a mint to x from another account: no code and the 23 byte delegation skip it, and any other
    // code must take the token
    function test_keyWalletKinds() public {
        uint256 id = _buy(bob, "keyed");
        address x = makeAddr("x");
        vm.prank(bob);
        nft.setAddr(id, x);
        // KeyWalletLookalike mints to the delegation prefix in code of 22 and 24 bytes and with another version;
        // these use a first byte vm.etch accepts
        bytes[5] memory kinds = [
            bytes(""),
            abi.encodePacked(hex"ef0100", address(0xBEEF)),
            abi.encodePacked(hex"5f5f00", address(0xBEEF)),
            abi.encodePacked(hex"5f5f00", address(0xBEEF), hex"00"),
            abi.encodePacked(hex"5f5f00", bytes19(0))
        ];
        string[5] memory what = ["no code", "delegation", "other 23 bytes", "24 bytes", "22 bytes"];

        // nothing saved for coin type 60 and no default
        for (uint256 i; i < 5; ++i) {
            vm.etch(x, kinds[i]);
            assertEq(nft.addr(id, 60), bytes(""), what[i]);
            assertEq(nft.addr(id, 0x8000000a), abi.encodePacked(x), what[i]);
        }

        // a saved default answers whatever the code
        vm.prank(bob);
        nft.setAddrForCoin(id, 0x80000000, abi.encodePacked(x));
        for (uint256 i; i < 5; ++i) {
            vm.etch(x, kinds[i]);
            assertEq(nft.addr(id, 60), abi.encodePacked(x), what[i]);
            assertEq(nft.addr(id, 0x8000000a), abi.encodePacked(x), what[i]);
        }

        // a mint from bob to x: the first two kinds take the name without a hook, the others have none that answers
        for (uint256 i; i < 5; ++i) {
            vm.etch(x, kinds[i]);
            string memory l = string.concat("kind", vm.toString(i));
            _commitPaid(bob, l, x, 0);
            vm.warp(vm.getBlockTimestamp() + 61);
            (,,, uint256 total) = nft.quote(l);
            vm.prank(bob);
            if (i < 2) {
                assertEq(nft.ownerOf(nft.reveal{value: total}(l, x, 0, _s(l, x, 0))), x, what[i]);
            } else {
                vm.expectRevert(bytes4(0xd1a57ed6)); // TransferToNonERC721ReceiverImplementer()
                nft.reveal{value: total}(l, x, 0, _s(l, x, 0));
            }
        }
    }

    // the deposit is shown in ETH with up to four decimals and no trailing zeros
    function test_depositFormatting() public {
        uint256 one = _buy(bob, "a");
        uint256 four = _buy(bob, "abcd");
        uint256 five = _buy(bob, "abcde");
        uint256 tr = _trial("trial", carol);
        assertTrue(LibString.contains(_json(one), '"Deposit","display_type":"number","value":0.01}'), "0.01");
        assertTrue(LibString.contains(_json(four), '"Deposit","display_type":"number","value":0.001}'), "0.001");
        assertTrue(LibString.contains(_json(five), '"Deposit","display_type":"number","value":0.0001}'), "0.0001");
        assertTrue(LibString.contains(_json(tr), '"Deposit","display_type":"number","value":0}'), "0");
        // nine renewals bring the one letter name to 0.1
        for (uint256 i; i < 9; ++i) {
            vm.prank(bob);
            nft.renew{value: FEE1}(one);
            vm.warp(vm.getBlockTimestamp() + 1);
        }
        assertEq(nft.depositOf(one), 0.1 ether);
        assertTrue(LibString.contains(_json(one), '"Deposit","display_type":"number","value":0.1}'), "0.1");
        vm.prank(bob);
        nft.renew{value: FEE5}(five);
        assertTrue(LibString.contains(_json(five), '"Deposit","display_type":"number","value":0.0002}'), "0.0002");
    }
}

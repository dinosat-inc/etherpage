// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {trialCommitment, trialCommitmentRaw} from "../../utils/TrialCommitment.sol";

import {Vm} from "forge-std/Test.sol";
import {ERC721} from "solady/tokens/ERC721.sol";
import {LibString} from "solady/utils/LibString.sol";
import {PageNFT} from "../../../src/PageNFT.sol";
import {PageCard} from "../../../src/PageCard.sol";
import {SubpageRegistrar} from "../../../src/SubpageRegistrar.sol";
import {RulesBase} from "../../utils/RulesBase.sol";
import {CardReader} from "../../utils/CardReader.sol";

// a sponsor contract: pays trials for others; when burn is set its receive burns all gas, otherwise
// it refuses ETH
contract Sponsor {
    PageNFT immutable nft;
    bool immutable burn;

    constructor(PageNFT n, bool b) payable {
        nft = n;
        burn = b;
    }

    function commit(bytes32 c) external {
        nft.commit(c);
    }

    function trial(string calldata l, address owner, bytes32 s, uint256 value) external returns (uint256) {
        return nft.revealTrial{value: value}(l, owner, 0, s);
    }

    receive() external payable {
        if (burn) {
            uint256 x;
            while (true) ++x;
        }
        revert("no ETH");
    }
}

// the core rules of PageNFT: prices, the two entry points, the refundable trial, the pause, the
// referrer of an unpaid trial, conversion, and the status view
contract RulesTest is RulesBase {
    CardReader reader;

    function setUp() public override {
        super.setUp();
        reader = new CardReader();
    }

    // 1. prices
    function test_P1_feeForEveryLength() public view {
        assertEq(nft.getFee(0), FEE5, "length 0 falls to the default");
        assertEq(nft.getFee(1), FEE1);
        assertEq(nft.getFee(2), FEE1);
        assertEq(nft.getFee(3), FEE3);
        assertEq(nft.getFee(4), FEE3);
        for (uint256 n = 5; n <= 70; ++n) assertEq(nft.getFee(n), FEE5);
        assertEq(nft.getFee(type(uint256).max), FEE5);
    }

    function test_P2_trialPriceIsATenthWithNoRounding() public view {
        for (uint256 n = 1; n <= 63; ++n) {
            uint256 f = nft.getFee(n);
            assertEq((f / 10) * 10, f, "no rounding");
        }
        assertEq(nft.getFee(1) / 10, PRICE1);
        assertEq(nft.getFee(3) / 10, PRICE3);
        assertEq(nft.getFee(5) / 10, PRICE5);
        assertEq(PRICE1, 0.001 ether);
        assertEq(PRICE3, 0.0001 ether);
        assertEq(PRICE5, 0.00001 ether);
    }

    function test_P3_paidRevealKeepsTheFeeAndReturnsTheRest() public {
        vm.deal(user, 1 ether);
        _commitPaid(user, "alpha", user, 0);
        vm.warp(vm.getBlockTimestamp() + 61);
        vm.prank(user);
        uint256 id = nft.reveal{value: 1 ether}("alpha", user, 0, _s("alpha", user, 0));
        assertEq(user.balance, 1 ether - FEE5);
        assertEq(nft.depositOf(id), FEE5);
        assertEq(address(nft).balance, FEE5);
        (uint256 fee,,, uint256 total) = nft.quote("ab");
        assertEq(fee, FEE1);
        assertEq(total, FEE1);
        (fee,,, total) = nft.quote("abcd");
        assertEq(fee, FEE3);
        assertEq(total, FEE3);
    }

    // 2. entry points
    function test_E1_revealToOwnWallet() public {
        uint256 id = _buy(bob, "alpha");
        assertEq(nft.ownerOf(id), bob);
        assertEq(nft.depositOf(id), FEE5);
        assertEq(nft.expiresAt(id), vm.getBlockTimestamp() + 365 days);
    }

    // a relayer pays the year for a user: the name and its deposit are the user's
    function test_E2_revealToAnotherWallet() public {
        _commitPaid(relayer, "alpha", user, 0);
        vm.warp(vm.getBlockTimestamp() + 61);
        vm.recordLogs();
        vm.prank(relayer);
        uint256 id = nft.reveal{value: FEE5}("alpha", user, 0, _s("alpha", user, 0));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(nft.ownerOf(id), user);
        assertEq(user.balance, 0);
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == T_DEPOSIT) assertEq(logs[i].topics[2], bytes32(uint256(uint160(relayer))));
        }
        vm.warp(nft.expiresAt(id) + 111 days + 1);
        nft.release(id);
        assertEq(nft.owed(user), FEE5, "the deposit comes back to the name's payee");
        assertEq(nft.owed(relayer), 0);
    }

    // anyone who knows the secret can complete a committed paid reveal, only for the committed owner
    function test_E3_anyoneCompletesACommittedReveal() public {
        _commitPaid(user, "alpha", user, 0);
        vm.warp(vm.getBlockTimestamp() + 61);
        vm.prank(bob);
        vm.expectRevert(PageNFT.CommitmentNotFound.selector);
        nft.reveal{value: FEE5}("alpha", bob, 0, _s("alpha", user, 0));
        vm.prank(bob);
        uint256 id = nft.reveal{value: FEE5}("alpha", user, 0, _s("alpha", user, 0));
        assertEq(nft.ownerOf(id), user);
    }

    // reveal and revealTrial take four arguments; a three argument reveal matches no function and reverts empty,
    // while the revealFor call goes out before user holds any ETH, so it fails whatever its selector
    function test_E4_otherRevealShapesDoNotExist() public {
        bytes4 revealFor = bytes4(keccak256("revealFor(string,address,uint256,bytes32)"));
        bytes4 reveal3 = bytes4(keccak256("reveal(string,uint256,bytes32)"));
        _commitPaid(user, "alpha", user, 0);
        vm.warp(vm.getBlockTimestamp() + 61);
        vm.prank(user);
        (bool ok, bytes memory ret) = address(nft).call{value: FEE5}(
            abi.encodeWithSelector(revealFor, "alpha", user, 0, _s("alpha", user, 0))
        );
        assertFalse(ok);
        assertEq(ret.length, 0);
        vm.deal(user, 1 ether);
        vm.prank(user);
        (ok, ret) = address(nft).call{value: FEE5}(abi.encodeWithSelector(reveal3, "alpha", 0, _s("alpha", user, 0)));
        assertFalse(ok);
        assertEq(ret.length, 0);
        assertEq(PageNFT.reveal.selector, bytes4(0x2c3a6954));
        assertEq(PageNFT.revealTrial.selector, bytes4(keccak256("revealTrial(string,address,uint256,bytes32)")));
        assertEq(PageNFT.status.selector, bytes4(0x42d21ef7));
        assertEq(nft.trialPaymentOf.selector, bytes4(0x0b9a67b9));
    }

    // a trial for one's own wallet: the owner pays and gets the price back when it pays the year
    function test_E5_trialForOwnWallet() public {
        vm.deal(user, 1 ether);
        uint256 id = _trial(user, "alpha", user, 0);
        (address p, uint256 a) = _held(id);
        assertEq(p, user);
        assertEq(a, PRICE5);
        vm.prank(user);
        nft.renew{value: FEE5}(id);
        assertEq(nft.owed(user), PRICE5);
        vm.prank(user);
        nft.withdraw(user);
        assertEq(user.balance, 1 ether - FEE5, "net cost is the refundable deposit");
    }

    // a name as its own referrer is refused by makeCommitment, and at reveal and revealTrial with a
    // commitment built by hand
    function test_E6_selfReferralRefusedForBothEntryPoints() public {
        uint256 id = nft.computeId("alpha");
        vm.expectRevert(PageNFT.SelfReferral.selector);
        nft.makeCommitment("alpha", user, id, bytes32("s"));
        bytes32 c = keccak256(abi.encode(bytes("alpha"), user, id, bytes32("s")));
        vm.startPrank(relayer);
        nft.commit(c);
        nft.commit(trialCommitmentRaw("alpha", user, id, bytes32("s")));
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + 61);
        vm.prank(relayer);
        vm.expectRevert(PageNFT.SelfReferral.selector);
        nft.reveal{value: 1 ether}("alpha", user, id, bytes32("s"));
        vm.prank(relayer);
        vm.expectRevert(PageNFT.SelfReferral.selector);
        nft.revealTrial{value: 1 ether}("alpha", user, id, bytes32("s"));
        // the same name, upper case, is the same id
        vm.prank(relayer);
        vm.expectRevert(PageNFT.SelfReferral.selector);
        nft.revealTrial{value: 1 ether}("ALPHA", user, id, bytes32("s"));
    }

    // a leaked paid commitment and secret cannot be turned into a trial, and a trial commitment
    // cannot be used for a paid reveal
    function test_E7_trialOnlyCommitmentBlocksDowngrade() public {
        vm.deal(user, 1 ether);
        _commitPaid(user, "alpha", user, 0);
        vm.warp(vm.getBlockTimestamp() + 61);
        vm.prank(bob);
        vm.expectRevert(PageNFT.CommitmentNotFound.selector);
        nft.revealTrial{value: PRICE5}("alpha", user, 0, _s("alpha", user, 0));
        vm.prank(user);
        uint256 id = nft.reveal{value: FEE5}("alpha", user, 0, _s("alpha", user, 0));
        assertEq(nft.depositOf(id), FEE5);
        assertEq(_heldAmount(id), 0);
        _commitTrial(relayer, "bravo", user, 0);
        vm.warp(vm.getBlockTimestamp() + 61);
        vm.prank(relayer);
        vm.expectRevert(PageNFT.CommitmentNotFound.selector);
        nft.reveal{value: FEE5}("bravo", user, 0, _s("bravo", user, 0));
    }

    // 3. the trial
    function test_T1_startState() public {
        _commitTrial(relayer, "alpha", user, 0);
        vm.warp(vm.getBlockTimestamp() + 61);
        uint256 before = relayer.balance;
        vm.recordLogs();
        vm.prank(relayer);
        uint256 id = nft.revealTrial{value: 1 ether}("alpha", user, 0, _s("alpha", user, 0));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(before - relayer.balance, PRICE5, "the change comes back");
        assertEq(nft.ownerOf(id), user);
        assertEq(nft.expiresAt(id), vm.getBlockTimestamp() + TRIAL);
        assertEq(nft.depositOf(id), 0);
        (address p, uint256 a) = _held(id);
        assertEq(p, relayer);
        assertEq(a, PRICE5);
        assertEq(address(nft).balance, PRICE5);
        assertEq(nft.owed(DEAD) + nft.owed(relayer) + nft.owed(user), 0);
        assertEq(_count(logs, T_STARTED), 1);
        assertEq(_count(logs, T_DEPOSIT), 0);
        _assertStatus(id, PageCard.Status.Trial);
    }

    function test_T2_underpaidTrialRefused() public {
        string[3] memory ls = ["a", "abc", "alpha"];
        for (uint256 i; i < 3; ++i) {
            _commitTrial(relayer, ls[i], user, 0);
            vm.warp(vm.getBlockTimestamp() + 61);
            uint256 price = _price(ls[i]);
            vm.prank(relayer);
            vm.expectRevert(PageNFT.InsufficientFee.selector);
            nft.revealTrial{value: price - 1}(ls[i], user, 0, _s(ls[i], user, 0));
            vm.prank(relayer);
            uint256 id = nft.revealTrial{value: price}(ls[i], user, 0, _s(ls[i], user, 0));
            assertEq(_heldAmount(id), price);
        }
    }

    function test_T3_trialWorksFully() public {
        uint256 id = _trial("alpha", user);
        assertEq(nft.resolve(id), user);
        assertEq(nft.addr(bytes32(id), 0x8000000a), abi.encodePacked(user));
        // nothing is saved yet, so coin type 60 answers empty until the holder saves an entry or a default
        assertEq(nft.addr(bytes32(id), 60), "");
        vm.startPrank(user);
        nft.setText(id, "avatar", "eip155:1/erc721:0xabc/1");
        nft.setContenthash(id, hex"e301");
        nft.setAddr(id, carol);
        nft.setAddrForCoin(id, 0x80002105, abi.encodePacked(dave));
        nft.setAddrForCoin(id, 0x80000000, abi.encodePacked(user));
        nft.setPrimaryPage(id);
        vm.stopPrank();
        vm.prank(carol);
        nft.setPrimaryPage(id);
        assertEq(nft.text(id, "avatar"), "eip155:1/erc721:0xabc/1");
        assertEq(nft.contenthash(id), hex"e301");
        assertEq(nft.resolve(id), carol);
        assertEq(nft.addr(bytes32(id), 0x80002105), abi.encodePacked(dave));
        assertEq(nft.addr(bytes32(id), 60), abi.encodePacked(user), "the default the trial holder saved");
        assertEq(nft.reverseResolve(carol), "alpha");
        assertEq(nft.payee(id), carol);
    }

    function test_T4_trialIsExclusive() public {
        uint256 id = _trial("alpha", user);
        uint256 e = nft.expiresAt(id);
        vm.warp(e - 2 minutes);
        _commitPaid(bob, "alpha", bob, 0);
        _commitTrial(carol, "alpha", carol, 0);
        vm.warp(e);
        vm.prank(bob);
        vm.expectRevert(PageNFT.AlreadyRegistered.selector);
        nft.reveal{value: 1 ether}("alpha", bob, 0, _s("alpha", bob, 0));
        vm.prank(carol);
        vm.expectRevert(PageNFT.AlreadyRegistered.selector);
        nft.revealTrial{value: 1 ether}("alpha", carol, 0, _s("alpha", carol, 0));
        assertFalse(nft.isAvailable("alpha", 0));
    }

    function test_T5_trialMovesOnlyToDead() public {
        uint256 id = _trial("alpha", user);
        vm.startPrank(user);
        vm.expectRevert(PageNFT.Unpaid.selector);
        nft.transferFrom(user, bob, id);
        vm.expectRevert(PageNFT.Unpaid.selector);
        nft.safeTransferFrom(user, bob, id);
        vm.expectRevert(PageNFT.Unpaid.selector);
        nft.safeTransferFrom(user, bob, id, "data");
        vm.expectRevert(PageNFT.Unpaid.selector);
        nft.multicall(_one(abi.encodeCall(ERC721.transferFrom, (user, bob, id))));
        nft.approve(carol, id);
        nft.setApprovalForAll(dave, true);
        vm.stopPrank();
        vm.prank(carol);
        vm.expectRevert(PageNFT.Unpaid.selector);
        nft.transferFrom(user, carol, id);
        vm.prank(dave);
        vm.expectRevert(PageNFT.Unpaid.selector);
        nft.safeTransferFrom(user, dave, id);
        vm.prank(dave);
        nft.transferFrom(user, DEAD, id);
        assertEq(nft.ownerOf(id), DEAD);
    }

    function test_T6_noSubpagesUntilPaid() public {
        uint256 id = _trial("alpha", user);
        vm.prank(user);
        vm.expectRevert(PageNFT.Unpaid.selector);
        nft.registerSubpage("sub", id);
        vm.prank(user);
        vm.expectRevert(PageNFT.Unpaid.selector);
        nft.registerSubpageFor("sub", id, bob);
        assertFalse(nft.isAvailable("sub", id));
        vm.startPrank(user);
        nft.setSubpageMinter(id, address(shop));
        shop.configure(id, user, address(0), 0.001 ether, true, address(0), 0, false);
        vm.stopPrank();
        vm.prank(bob);
        vm.expectRevert(SubpageRegistrar.NotAvailable.selector);
        shop.registerSubpage{value: 0.001 ether}(id, "sub", 0.001 ether, address(0));
        // paid in the same epoch, everything works at once
        vm.prank(carol);
        nft.renew{value: FEE5}(id);
        assertTrue(nft.isAvailable("sub", id));
        vm.prank(bob);
        uint256 sub = shop.registerSubpage{value: 0.001 ether}(id, "sub", 0.001 ether, address(0));
        assertEq(nft.ownerOf(sub), bob);
        vm.prank(user);
        nft.registerSubpage("own", id);
    }

    // anyone converts with the full fee: the year starts at the trial end, the referrer stays, the trial
    // price is credited back to its payer in the same call, and the name can move
    function test_T7_conversionByAnyone() public {
        uint256 ref = _buy(carol, "carol-ref");
        uint256 id = _trial(relayer, "alpha", user, ref);
        uint256 e = nft.expiresAt(id);
        vm.warp(e - 3 days);
        vm.recordLogs();
        vm.prank(dave);
        nft.renew{value: 1 ether}(id);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 4);
        assertEq(logs[0].topics[0], T_REFUNDED);
        assertEq(logs[0].topics[1], bytes32(id));
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(relayer))));
        assertEq(abi.decode(logs[0].data, (uint256)), PRICE5);
        assertEq(logs[1].topics[0], T_DEPOSIT);
        assertEq(logs[2].topics[0], T_RENEWED);
        assertEq(logs[3].topics[0], T_META);
        assertEq(nft.expiresAt(id), e + 365 days);
        assertEq(nft.depositOf(id), FEE5);
        assertEq(nft.referrerOf(id), ref);
        assertEq(nft.owed(relayer), PRICE5);
        assertEq(nft.owed(dave) + nft.owed(user), 0);
        assertEq(_heldAmount(id), 0);
        _assertStatus(id, PageCard.Status.Active);
        vm.prank(user);
        nft.transferFrom(user, bob, id);
        assertEq(nft.ownerOf(id), bob);
    }

    function test_T8_conversionBoundaries() public {
        uint256 id = _trial("alpha", user);
        uint256 e = nft.expiresAt(id);
        vm.prank(carol);
        vm.expectRevert(PageNFT.InsufficientFee.selector);
        nft.renew{value: FEE5 - 1}(id);
        uint256 snap = vm.snapshotState();
        vm.warp(e);
        vm.prank(carol);
        nft.renew{value: FEE5}(id);
        assertEq(nft.expiresAt(id), e + 365 days);
        vm.revertToState(snap);
        vm.warp(e + 1);
        vm.prank(carol);
        vm.expectRevert(PageNFT.Expired.selector);
        nft.renew{value: FEE5}(id);
    }

    function test_T9_unpaidEndAnswersNothingAndFreesTheName() public {
        uint256 id = _trial("alpha", user);
        vm.startPrank(user);
        nft.setText(id, "avatar", "x");
        nft.setPrimaryPage(id);
        vm.stopPrank();
        uint256 e = nft.expiresAt(id);
        vm.warp(e + 1);
        assertEq(nft.resolve(id), address(0));
        assertEq(nft.text(id, "avatar"), "");
        assertEq(nft.reverseResolve(user), "");
        assertTrue(nft.isAvailable("alpha", 0));
        assertTrue(nft.isExpired(id));
        assertFalse(nft.inGracePeriod(id));
        _assertStatus(id, PageCard.Status.Expired);
        CardReader.Card memory c = reader.read(_svg(id));
        assertTrue(c.dead, "a dead card");
        assertEq(c.left, "Expired");
        assertEq(c.dot, "#e5484d", "the red dot");
        uint256[5] memory offsets = [uint256(1), 10 days, 90 days + 1, 100 days, 111 days + 1];
        for (uint256 i; i < 5; ++i) {
            vm.warp(e + offsets[i]);
            assertEq(nft.getPremium(id), 0);
            (, uint256 carried, uint256 premium, uint256 total) = nft.quote("alpha");
            assertEq(carried + premium, 0);
            assertEq(total, FEE5);
        }
        vm.warp(e + 1);
        _buy(bob, "alpha");
        assertEq(nft.ownerOf(id), bob);
    }

    // 4. the refund
    function test_R1_releaseBoundaries() public {
        uint256 id = _trial("alpha", user);
        uint256 e = nft.expiresAt(id);
        vm.warp(e);
        assertFalse(nft.isReleasable(id));
        vm.expectRevert(PageNFT.NotReleasable.selector);
        nft.release(id);
        vm.warp(e + 1);
        assertTrue(nft.isReleasable(id));
        vm.recordLogs();
        vm.prank(bob);
        nft.release(id);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "only TrialRefunded, the metadata does not change");
        assertEq(logs[0].topics[0], T_REFUNDED);
        assertEq(nft.owed(relayer), PRICE5);
        assertEq(nft.owed(bob) + nft.owed(user) + nft.owed(DEAD), 0);
        assertEq(nft.depositOf(id), 0);
        assertEq(_heldAmount(id), 0);
        // released once: nothing more until the paid rule's window, then nothing to release
        assertFalse(nft.isReleasable(id));
        vm.expectRevert(PageNFT.NotReleasable.selector);
        nft.release(id);
        vm.warp(e + 111 days);
        vm.expectRevert(PageNFT.NotReleasable.selector);
        nft.release(id);
        vm.warp(e + 111 days + 1);
        assertFalse(nft.isReleasable(id));
        vm.expectRevert(PageNFT.NothingToRelease.selector);
        nft.release(id);
    }

    // a registration during the pause credits the trial payer first, and nothing else
    function test_R2_automaticAtRegistration() public {
        uint256 id = _trial("alpha", user);
        vm.warp(nft.expiresAt(id) + 5 days);
        _commitPaid(bob, "alpha", bob, 0);
        vm.warp(vm.getBlockTimestamp() + 61);
        vm.recordLogs();
        vm.prank(bob);
        nft.reveal{value: FEE5}("alpha", bob, 0, _s("alpha", bob, 0));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs[0].topics[0], T_REFUNDED, "the refund comes first");
        assertEq(_count(logs, T_REFUNDED), 1);
        assertEq(_count(logs, T_BOUGHT) + _count(logs, T_REF_PREMIUM) + _count(logs, T_OWNER_PREMIUM), 0);
        assertEq(nft.owed(relayer), PRICE5);
        assertEq(nft.owed(user) + nft.owed(DEAD) + nft.owed(bob), 0);
        assertEq(nft.depositOf(id), FEE5);
        assertEq(_heldAmount(id), 0);
        assertEq(address(nft).balance, PRICE5 + FEE5);
    }

    // a new trial after the pause credits the old payer and holds the new price
    function test_R3_automaticAtANewTrial() public {
        uint256 id = _trial("alpha", user);
        uint256 e = nft.expiresAt(id);
        vm.warp(e + PAUSE - 1 hours);
        _commitTrial(carol, "alpha", bob, 0);
        vm.warp(e + PAUSE + 1);
        vm.recordLogs();
        vm.prank(carol);
        nft.revealTrial{value: PRICE5}("alpha", bob, 0, _s("alpha", bob, 0));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs[0].topics[0], T_REFUNDED);
        assertEq(nft.owed(relayer), PRICE5);
        (address p, uint256 a) = _held(id);
        assertEq(p, carol);
        assertEq(a, PRICE5);
        assertEq(nft.ownerOf(id), bob);
        assertEq(nft.depositOf(id), 0);
        // the new payer gets its price back when the name is paid
        vm.prank(bob);
        vm.deal(bob, 1 ether);
        nft.renew{value: FEE5}(id);
        assertEq(nft.owed(carol), PRICE5);
    }

    // the same payer trials a name again after the pause: it gets the old price back and locks one price
    function test_R4_samePayerAgain() public {
        uint256 id = _trial("alpha", user);
        uint256 e = nft.expiresAt(id);
        vm.warp(e + PAUSE - 1 hours);
        _commitTrial(relayer, "alpha", user, 0);
        vm.warp(e + PAUSE + 1);
        vm.prank(relayer);
        nft.revealTrial{value: PRICE5}("alpha", user, 0, _s("alpha", user, 0));
        assertEq(nft.owed(relayer), PRICE5);
        assertEq(_heldAmount(id), PRICE5);
        assertEq(address(nft).balance, 2 * PRICE5);
    }

    function test_R5_depositStaysZeroForATrial() public {
        uint256 id = _trial("alpha", user);
        assertEq(nft.depositOf(id), 0);
        vm.warp(nft.expiresAt(id) + 1);
        assertEq(nft.depositOf(id), 0);
        nft.release(id);
        assertEq(nft.depositOf(id), 0);
        assertTrue(LibString.contains(_json(id), '"Deposit","display_type":"number","value":0}'));
    }

    // a payer bundles the release of two ended trials and its withdrawal in one multicall
    function test_R6_bundleOfReleasesAndWithdraw() public {
        uint256 a1 = _trial(relayer, "alpha", user, 0);
        uint256 a2 = _trial(relayer, "bravo", bob, 0);
        vm.warp(nft.expiresAt(a2) + 1);
        bytes[] memory calls = new bytes[](3);
        calls[0] = abi.encodeCall(PageNFT.release, (a1));
        calls[1] = abi.encodeCall(PageNFT.release, (a2));
        calls[2] = abi.encodeCall(PageNFT.withdraw, (relayer));
        uint256 before = relayer.balance;
        vm.prank(relayer);
        bytes[] memory res = nft.multicall(calls);
        assertEq(abi.decode(res[2], (uint256)), 2 * PRICE5);
        assertEq(relayer.balance, before + 2 * PRICE5);
        assertEq(nft.owed(relayer), 0);
        assertEq(address(nft).balance, 0);
        // any caller may run the same bundle for the payer
        uint256 b1 = _trial(relayer, "charlie", user, 0);
        vm.warp(nft.expiresAt(b1) + 1);
        calls = new bytes[](2);
        calls[0] = abi.encodeCall(PageNFT.release, (b1));
        calls[1] = abi.encodeCall(PageNFT.withdraw, (relayer));
        before = relayer.balance;
        vm.prank(dave);
        nft.multicall(calls);
        assertEq(relayer.balance, before + PRICE5);
    }

    // someone who releases one of the names first makes the payer's bundle fail; nothing is lost and
    // the payer retries without that name
    function test_R7_frontRunReleaseMakesTheBundleFail() public {
        uint256 a1 = _trial(relayer, "alpha", user, 0);
        uint256 a2 = _trial(relayer, "bravo", bob, 0);
        vm.warp(nft.expiresAt(a2) + 1);
        vm.prank(dave);
        nft.release(a1);
        bytes[] memory calls = new bytes[](3);
        calls[0] = abi.encodeCall(PageNFT.release, (a1));
        calls[1] = abi.encodeCall(PageNFT.release, (a2));
        calls[2] = abi.encodeCall(PageNFT.withdraw, (relayer));
        vm.prank(relayer);
        vm.expectRevert(PageNFT.NotReleasable.selector);
        nft.multicall(calls);
        assertEq(nft.owed(relayer), PRICE5);
        calls = new bytes[](2);
        calls[0] = abi.encodeCall(PageNFT.release, (a2));
        calls[1] = abi.encodeCall(PageNFT.withdraw, (relayer));
        uint256 before = relayer.balance;
        vm.prank(relayer);
        nft.multicall(calls);
        assertEq(relayer.balance, before + 2 * PRICE5);
    }

    // a payer that cannot take ETH: every refund is a credit, so no path can be blocked by it; only its
    // own withdrawal fails, and the credit stays its own
    function test_R8_payerThatRefusesEth() public {
        Sponsor sp = new Sponsor{value: 1 ether}(nft, false);
        _payerContractFlow(sp);
        vm.expectRevert();
        nft.withdraw(address(sp));
        assertEq(nft.owed(address(sp)), 3 * PRICE5);
    }

    function test_R9_payerThatBurnsGas() public {
        Sponsor sp = new Sponsor{value: 1 ether}(nft, true);
        _payerContractFlow(sp);
        vm.expectRevert();
        nft.withdraw{gas: 5_000_000}(address(sp));
        assertEq(nft.owed(address(sp)), 3 * PRICE5);
    }

    // three trials paid by the contract: one converted, one released, one taken by a registration
    function _payerContractFlow(Sponsor sp) internal {
        string[3] memory ls = ["alpha", "bravo", "charlie"];
        uint256[3] memory ids;
        for (uint256 i; i < 3; ++i) {
            sp.commit(trialCommitment(address(nft), ls[i], user, 0, _s(ls[i], user, 0)));
        }
        vm.warp(vm.getBlockTimestamp() + 61);
        for (uint256 i; i < 3; ++i) ids[i] = sp.trial(ls[i], user, _s(ls[i], user, 0), PRICE5);
        vm.prank(bob);
        nft.renew{value: FEE5}(ids[0]);
        vm.warp(nft.expiresAt(ids[1]) + 1);
        nft.release(ids[1]);
        _buy(carol, "charlie");
        assertEq(nft.ownerOf(ids[2]), carol);
    }

    // 5. the pause
    function test_Pa1_pauseBoundariesAndRegistrationStaysOpen() public {
        uint256 id = _trial("alpha", user);
        uint256 e = nft.expiresAt(id);
        vm.warp(e + PAUSE - 1 hours);
        _commitTrial(carol, "alpha", carol, 0);
        _commitPaid(bob, "alpha", bob, 0);
        // the last second of the pause refuses a trial
        vm.warp(e + PAUSE);
        vm.prank(carol);
        vm.expectRevert(PageNFT.TrialNotAllowed.selector);
        nft.revealTrial{value: PRICE5}("alpha", carol, 0, _s("alpha", carol, 0));
        assertTrue(nft.isAvailable("alpha", 0), "isAvailable is true during the pause");
        // a paid registration works at that same second
        uint256 snap = vm.snapshotState();
        vm.prank(bob);
        nft.reveal{value: FEE5}("alpha", bob, 0, _s("alpha", bob, 0));
        assertEq(nft.ownerOf(id), bob);
        vm.revertToState(snap);
        // one second later the trial works
        vm.warp(e + PAUSE + 1);
        vm.prank(carol);
        nft.revealTrial{value: PRICE5}("alpha", carol, 0, _s("alpha", carol, 0));
        assertEq(nft.ownerOf(id), carol);
    }

    function test_Pa2_registrationOpenAllThroughThePause() public {
        uint256 id = _trial("alpha", user);
        uint256 e = nft.expiresAt(id);
        uint256[4] memory at = [e + 1, e + 1 days, e + 7 days, e + PAUSE];
        for (uint256 i; i < 4; ++i) {
            uint256 snap = vm.snapshotState();
            vm.warp(at[i] - 61);
            _commitPaid(bob, "alpha", bob, 0);
            vm.warp(at[i]);
            vm.prank(bob);
            nft.reveal{value: FEE5}("alpha", bob, 0, _s("alpha", bob, 0));
            assertEq(nft.ownerOf(id), bob);
            assertEq(nft.owed(relayer), PRICE5);
            vm.revertToState(snap);
        }
    }

    // the pause counts from the trial end, whether or not its money was already released
    function test_Pa3_releaseDoesNotLiftThePause() public {
        uint256 id = _trial("alpha", user);
        uint256 e = nft.expiresAt(id);
        vm.warp(e + 1);
        nft.release(id);
        _commitTrial(carol, "alpha", carol, 0);
        vm.warp(e + 1 days);
        vm.prank(carol);
        vm.expectRevert(PageNFT.TrialNotAllowed.selector);
        nft.revealTrial{value: PRICE5}("alpha", carol, 0, _s("alpha", carol, 0));
    }

    // a trial thrown to DEAD shows Invalid and blocks the name until its end, then the pause applies as for any trial
    function test_Pa4_trialThrownToDead() public {
        uint256 id = _trial("alpha", user);
        vm.prank(user);
        nft.transferFrom(user, DEAD, id);
        _assertStatus(id, PageCard.Status.Invalid);
        _commitPaid(bob, "alpha", bob, 0);
        vm.warp(vm.getBlockTimestamp() + 61);
        vm.prank(bob);
        vm.expectRevert(PageNFT.AlreadyRegistered.selector);
        nft.reveal{value: FEE5}("alpha", bob, 0, _s("alpha", bob, 0));
        uint256 e = nft.expiresAt(id);
        vm.warp(e + 1 days);
        _assertStatus(id, PageCard.Status.Invalid);
        _commitTrial(carol, "alpha", carol, 0);
        vm.warp(e + 1 days + 61);
        vm.prank(carol);
        vm.expectRevert(PageNFT.TrialNotAllowed.selector);
        nft.revealTrial{value: PRICE5}("alpha", carol, 0, _s("alpha", carol, 0));
        nft.release(id);
        assertEq(nft.owed(relayer), PRICE5);
        assertEq(nft.owed(DEAD), 0);
    }

    // a released paid name has no pause
    function test_Pa5_releasedPaidNameHasNoPause() public {
        uint256 id = _buy(bob, "alpha");
        vm.warp(nft.expiresAt(id) + 111 days + 1);
        nft.release(id);
        _trial("alpha", user);
        assertEq(nft.ownerOf(id), user);
    }

    // a trial never takes over a deposit, live or not, and a live trial answers AlreadyRegistered
    function test_Pa6_errorsForAPaidName() public {
        uint256 id = _buy(bob, "alpha");
        _commitTrial(carol, "alpha", carol, 0);
        vm.warp(vm.getBlockTimestamp() + 61);
        vm.prank(carol);
        vm.expectRevert(PageNFT.TrialNotAllowed.selector);
        nft.revealTrial{value: 1 ether}("alpha", carol, 0, _s("alpha", carol, 0));
        vm.warp(nft.expiresAt(id) + 100 days);
        _commitTrial(carol, "alpha", carol, 0);
        vm.warp(vm.getBlockTimestamp() + 61);
        vm.prank(carol);
        vm.expectRevert(PageNFT.TrialNotAllowed.selector);
        nft.revealTrial{value: 1000 ether}("alpha", carol, 0, _s("alpha", carol, 0));
        // a live trial answers AlreadyRegistered to a new trial, before the pause check
        uint256 t = _trial("bravo", user);
        _commitTrial(carol, "bravo", carol, 0);
        vm.warp(vm.getBlockTimestamp() + 61);
        vm.prank(carol);
        vm.expectRevert(PageNFT.AlreadyRegistered.selector);
        nft.revealTrial{value: PRICE5}("bravo", carol, 0, _s("bravo", carol, 0));
        assertEq(nft.ownerOf(t), user);
    }

    // 6. the referrer
    // the referrer of an unpaid trial is never paid and never carried: not at a registration right after
    // the end, not in what would be the auction window, and not at a later trial
    function test_Ref1_unpaidTrialReferrerNeverPaidNorCarried() public {
        uint256 ref = _buy(carol, "carol-ref");
        uint256 id = _trial(relayer, "alpha", user, ref);
        assertEq(nft.referrerOf(id), ref);
        uint256 e = nft.expiresAt(id);
        uint256[3] memory at = [e + 1, e + 95 days, e + 200 days];
        for (uint256 i; i < 3; ++i) {
            uint256 snap = vm.snapshotState();
            vm.warp(at[i] - 61);
            _commitPaid(bob, "alpha", bob, 0);
            vm.warp(at[i]);
            vm.recordLogs();
            vm.prank(bob);
            nft.reveal{value: FEE5}("alpha", bob, 0, _s("alpha", bob, 0));
            Vm.Log[] memory logs = vm.getRecordedLogs();
            assertEq(_count(logs, T_REF_PREMIUM) + _count(logs, T_OWNER_PREMIUM), 0);
            assertEq(nft.owed(carol), 0, "the trial's referrer earns nothing");
            assertEq(nft.referrerOf(id), 0, "only the new referrer is recorded");
            vm.revertToState(snap);
        }
        // a later trial records only its own referrer
        uint256 ref2 = _buy(dave, "dave-ref");
        vm.warp(e + PAUSE - 1 hours);
        _commitTrial(bob, "alpha", bob, ref2);
        vm.warp(e + PAUSE + 1);
        vm.prank(bob);
        nft.revealTrial{value: PRICE5}("alpha", bob, ref2, _s("alpha", bob, ref2));
        assertEq(nft.referrerOf(id), ref2);
        assertEq(nft.owed(carol), 0);
    }

    // a converted trial keeps its referrer, who earns its share of a later auction
    function test_Ref2_convertedTrialKeepsReferrer() public {
        uint256 ref = _buy(carol, "carol-ref");
        uint256 id = _trial(relayer, "alpha", user, ref);
        uint256 e = nft.expiresAt(id);
        vm.prank(bob);
        nft.renew{value: FEE5}(id);
        assertEq(nft.expiresAt(id), e + 365 days);
        assertEq(nft.referrerOf(id), ref);
        // keep the referrer's name alive
        vm.startPrank(carol);
        nft.renew{value: FEE5}(ref);
        nft.renew{value: FEE5}(ref);
        vm.stopPrank();
        uint256 end = nft.expiresAt(id);
        vm.warp(end + 90 days + 1 days - 61);
        _commitPaid(dave, "alpha", dave, 0);
        vm.warp(end + 90 days + 1 days);
        uint256 premium = nft.getPremium(id);
        assertGt(premium, 0);
        (,,, uint256 total) = nft.quote("alpha");
        vm.prank(dave);
        nft.reveal{value: total}("alpha", dave, 0, _s("alpha", dave, 0));
        assertEq(nft.owed(carol), premium * 2500 / 10000, "the referrer earns a quarter of the premium");
    }

    // 7. status and the card
    function test_S1_statusOfEveryState() public {
        uint256 alice = _buy(bob, "alice");
        vm.prank(bob);
        uint256 sub = nft.registerSubpageFor("sub", alice, carol);
        vm.prank(bob);
        uint256 del = nft.registerSubpageFor("gone", alice, carol);
        vm.prank(carol);
        nft.transferFrom(carol, DEAD, del);
        _assertStatus(alice, PageCard.Status.Active);
        _assertStatus(sub, PageCard.Status.Active);
        _assertStatus(del, PageCard.Status.Invalid);
        uint256 t = _trial("trial", user);
        _assertStatus(t, PageCard.Status.Trial);
        uint256 e = nft.expiresAt(alice);
        vm.warp(e);
        _assertStatus(alice, PageCard.Status.Active);
        vm.warp(e + 1);
        _assertStatus(alice, PageCard.Status.Grace);
        _assertStatus(sub, PageCard.Status.Grace);
        _assertStatus(t, PageCard.Status.Expired);
        vm.warp(e + 90 days);
        _assertStatus(alice, PageCard.Status.Grace);
        vm.warp(e + 90 days + 1);
        _assertStatus(alice, PageCard.Status.Expired);
        _assertStatus(sub, PageCard.Status.Expired);
        vm.warp(e + 111 days + 1);
        _buy(dave, "alice");
        _assertStatus(alice, PageCard.Status.Active);
        _assertStatus(sub, PageCard.Status.Invalid);
        _assertStatus(del, PageCard.Status.Invalid);
        // a trial converted is Active, a trial at its last second is still Trial
        uint256 t2 = _trial("second", user);
        vm.warp(nft.expiresAt(t2));
        _assertStatus(t2, PageCard.Status.Trial);
        vm.prank(bob);
        nft.renew{value: FEE5}(t2);
        _assertStatus(t2, PageCard.Status.Active);
    }

    function test_S2_statusOfAMissingTokenReverts() public {
        vm.expectRevert(ERC721.TokenDoesNotExist.selector);
        nft.status(0);
        vm.expectRevert(ERC721.TokenDoesNotExist.selector);
        nft.status(12345);
        uint256 id = nft.computeId("never");
        vm.expectRevert(ERC721.TokenDoesNotExist.selector);
        nft.status(id);
        vm.expectRevert(ERC721.TokenDoesNotExist.selector);
        nft.tokenURI(id);
    }

    // a subpage made invalid by a new registration of its parent shows its full name, like a deleted one
    function test_S3_staleSubpageShowsItsFullName() public {
        uint256 alice = _buy(bob, "alice");
        vm.prank(bob);
        uint256 sub = nft.registerSubpageFor("bob", alice, carol);
        vm.warp(nft.expiresAt(alice) + 111 days + 1);
        _buy(dave, "alice");
        _assertStatus(sub, PageCard.Status.Invalid);
        string memory json = _json(sub);
        assertTrue(LibString.contains(json, '"name":"bob.alice"'));
        assertTrue(LibString.contains(json, '"description":"Etherpage: bob.alice ('));
        assertTrue(LibString.contains(json, '"value":"Subpage"'));
        // a subpage shows only its Type and Status
        string memory attrs = '[{"trait_type":"Type","value":"Subpage"},{"trait_type":"Status","value":"Invalid"}]}';
        assertTrue(LibString.endsWith(json, string.concat('","attributes":', attrs)), "only Type and Status");
        CardReader.Card memory c = reader.read(_svg(sub));
        assertEq(c.name, "bob.alice");
        assertEq(c.dimmed, ".alice", "the parent part dimmed");
        assertTrue(c.dead, "a dead card");
        assertEq(c.left, "Invalid");
        assertEq(c.dot, "#e5484d", "the red dot");
        assertEq(nft.getPageName(sub), "", "getPageName still answers nothing for it");
    }

    // the code of a page as its card shows it: the first 14 and the last 6 of the 64 hex digits of its id
    function _code(uint256 id) internal pure returns (string memory) {
        string memory h = vm.toString(bytes32(id));
        return string.concat(LibString.slice(h, 2, 16), unicode"…", LibString.slice(h, 60, 66));
    }

    function test_S4_trialCardAndMetadata() public {
        uint256 id = _trial("alpha", user);
        CardReader.Card memory c = reader.read(_svg(id));
        assertFalse(c.dead, "a trial draws a live card");
        assertEq(c.name, "alpha");
        assertEq(c.left, "Trial");
        assertEq(c.dot, "#7193f2", "the blue dot of a trial");
        assertEq(c.right, _code(id), "the code of the page");
        string memory json = _json(id);
        assertTrue(LibString.contains(json, string.concat("(", card.shortAddress(user), ")")), "paid to its holder");
        assertTrue(LibString.contains(json, '"Status","value":"Trial"'));
        // a top level page shows its Length between Status and Expires
        string memory length = '{"trait_type":"Length","display_type":"number","value":5}';
        assertTrue(LibString.contains(json, string.concat('"Trial"},', length, ',{"trait_type":"Expires"')), "Length");
        assertTrue(LibString.contains(json, '"Deposit","display_type":"number","value":0}'));
        assertTrue(
            LibString.contains(
                json, string.concat('"Expires","display_type":"date","value":', LibString.toString(nft.expiresAt(id)))
            )
        );
    }
}

// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {trialCommitment} from "../utils/TrialCommitment.sol";

import {Vm} from "forge-std/Test.sol";
import {PageNFT} from "../../src/PageNFT.sol";
import {PageCard} from "../../src/PageCard.sol";
import {SubpageRegistrar} from "../../src/SubpageRegistrar.sol";
import {PageNFTNoTrial} from "../differential/harness/PageNFTNoTrial.sol";
import {TrialBase} from "../utils/TrialBase.sol";

// abuse of the sponsored paid trial, and of free subpages under a team name
contract TrialAttackTest is TrialBase {
    address bot = makeAddr("bot");
    address payer = makeAddr("payer");
    uint256 constant FEE2 = 0.01 ether;
    uint256 constant PRICE2 = 0.001 ether;

    function setUp() public override {
        super.setUp();
        vm.deal(bot, 1000 ether);
        vm.deal(user, 1 ether);
    }

    // 1. a paid registration cannot be downgraded to a trial
    // The user commits for a paid reveal. Their first reveal fails on chain (sent one second early), and its
    // calldata shows label, owner, referrer and secret. With the trial commitment form the bot cannot use the
    // user's ripe paid commitment for a trial, and the user's retry wins exactly as in a build with no trials.
    function test_downgradeAPaidRevealIsRefused() public {
        string memory L = "alice-smith";
        _commit(user, L, user);
        uint256 t0 = vm.getBlockTimestamp();
        vm.warp(t0 + 19);
        vm.prank(user);
        vm.expectRevert(PageNFT.CommitmentTooNew.selector);
        nft.reveal{value: FEE5}(L, user, 0, _secret(L, user));
        // the bot learns the secret; at +20 the user's ripe paid commitment cannot serve a trial
        vm.warp(t0 + 20);
        vm.prank(bot);
        vm.expectRevert(PageNFT.CommitmentNotFound.selector);
        nft.revealTrial{value: PRICE5}(L, user, 0, _secret(L, user));
        // a trial form the bot commits now is too new
        _commitTrial(bot, L, user);
        vm.prank(bot);
        vm.expectRevert(PageNFT.CommitmentTooNew.selector);
        nft.revealTrial{value: PRICE5}(L, user, 0, _secret(L, user));
        // the user's retry wins with a paid year
        vm.prank(user);
        uint256 id = nft.reveal{value: FEE5}(L, user, 0, _secret(L, user));
        assertEq(nft.ownerOf(id), user);
        assertEq(nft.depositOf(id), FEE5);
        assertEq(nft.expiresAt(id), t0 + 20 + 365 days);
        assertEq(nft.owed(DEAD), 0);
    }

    // the same leak on the PageNFTNoTrial reference build gives the bot nothing: with the user's commitment
    // it can only pay the full fee for the user, which becomes the user's refundable deposit
    function test_sameLeakWithoutTrialsIsAGift() public {
        PageNFTNoTrial rec = new PageNFTNoTrial(new PageCard());
        string memory L = "alice-smith";
        bytes32 recCommitment = rec.makeCommitment(L, user, 0, _secret(L, user));
        vm.prank(user);
        rec.commit(recCommitment);
        uint256 t0 = vm.getBlockTimestamp();
        // the user's early reveal fails and leaks the label and secret; the bot commits for itself at once
        vm.warp(t0 + 19);
        bytes32 recCommitment2 = rec.makeCommitment(L, bot, 0, _secret(L, bot));
        vm.prank(bot);
        rec.commit(recCommitment2);
        // at +20 the bot's own commitment is too new, and the user's retry wins
        vm.warp(t0 + 20);
        vm.prank(bot);
        vm.expectRevert(PageNFTNoTrial.CommitmentTooNew.selector);
        rec.reveal{value: FEE5}(L, bot, 0, _secret(L, bot));
        // with the user's own commitment the bot can only pay the full fee for the user
        uint256 snap = vm.snapshotState();
        vm.prank(bot);
        uint256 id = rec.reveal{value: FEE5}(L, user, 0, _secret(L, user));
        assertEq(rec.ownerOf(id), user);
        assertEq(rec.depositOf(id), FEE5);
        assertEq(rec.expiresAt(id), t0 + 20 + 365 days);
        vm.revertToState(snap);
        vm.prank(user);
        id = rec.reveal{value: FEE5}(L, user, 0, _secret(L, user));
        assertEq(rec.ownerOf(id), user);
        assertEq(rec.depositOf(id), FEE5);
    }

    // with the leaked secret the bot can only complete the paid registration for the user
    function test_leakedSecretCanOnlyBeAGift() public {
        string memory L = "alice-smith";
        _commit(user, L, user);
        uint256 t0 = vm.getBlockTimestamp();
        vm.warp(t0 + 60);
        vm.prank(bot);
        uint256 id = nft.reveal{value: FEE5}(L, user, 0, _secret(L, user));
        assertEq(nft.ownerOf(id), user);
        assertEq(nft.depositOf(id), FEE5);
    }

    // a paid registration an app sponsors, revealed by its relayer, cannot be downgraded either
    function test_downgradeASponsoredRevealIsRefused() public {
        string memory L = "alice-smith";
        _commit(relayer, L, user);
        vm.warp(vm.getBlockTimestamp() + 61);
        vm.prank(bot);
        vm.expectRevert(PageNFT.CommitmentNotFound.selector);
        nft.revealTrial{value: PRICE5}(L, user, 0, _secret(L, user));
        vm.prank(relayer);
        uint256 id = nft.reveal{value: FEE5}(L, user, 0, _secret(L, user));
        assertEq(nft.depositOf(id), FEE5);
    }

    // 2. taking a lapsed trial, money redirected
    // a second after the trial ends a bot cannot trial the name again, but it can register it for the
    // plain yearly fee, which becomes its refundable deposit; the trial price goes back to the relayer
    function test_lapsedTrialIsTakenAtOnceOnlyByAPaidRegistration() public {
        uint256 id = _trial("alice-smith", user);
        vm.prank(user);
        nft.setPrimaryPage(id);
        assertEq(nft.resolve(id), user);
        uint256 e = nft.expiresAt(id);
        vm.warp(e - 1 hours);
        _commitTrial(bot, "alice-smith", bot);
        _commit(bot, "alice-smith", bot);
        vm.warp(e + 1);
        vm.prank(bot);
        vm.expectRevert(PageNFT.TrialNotAllowed.selector);
        nft.revealTrial{value: PRICE5}("alice-smith", bot, 0, _secret("alice-smith", bot));
        vm.prank(bot);
        nft.reveal{value: FEE5}("alice-smith", bot, 0, _secret("alice-smith", bot));
        assertEq(nft.resolve(id), bot);
        assertEq(nft.addr(id, 0x8000000a), abi.encodePacked(bot));
        // nobody saved an entry for coin type 60 or a default, so it answers empty
        assertEq(nft.addr(id, 60).length, 0);
        assertEq(nft.payee(id), bot);
        assertEq(nft.depositOf(id), FEE5);
        assertEq(nft.owed(relayer), PRICE5);
        assertEq(nft.reverseResolve(user), "");
        emit log_named_uint("cost to take over a lapsed trial one second later, refundable wei", FEE5);
    }

    // the same takeover of a lapsed PAID name: refused through 90 days of grace, then a 10 ETH premium
    function test_lapsedPaidNameCannotBeSnipedCheaply() public {
        bytes32 commitment = nft.makeCommitment("alice-smith", user, 0, _secret("alice-smith", user));
        vm.prank(user);
        nft.commit(commitment);
        vm.warp(vm.getBlockTimestamp() + 61);
        vm.prank(user);
        uint256 id = nft.reveal{value: FEE5}("alice-smith", user, 0, _secret("alice-smith", user));
        uint256 e = nft.expiresAt(id);
        vm.warp(e + 1);
        assertFalse(nft.isAvailable("alice-smith", 0));
        vm.warp(e + 90 days + 1);
        (,, uint256 premium, uint256 total) = nft.quote("alice-smith");
        emit log_named_uint("premium one second after grace, wei", premium);
        assertGt(premium, 9.9 ether);
        assertEq(total, premium + 2 * FEE5);
        // and a trial is refused all through the auction, whatever it pays
        _commitTrial(bot, "alice-smith", bot);
        vm.warp(vm.getBlockTimestamp() + 61);
        vm.prank(bot);
        vm.expectRevert(PageNFT.TrialNotAllowed.selector);
        nft.revealTrial{value: 200 ether}("alice-smith", bot, 0, _secret("alice-smith", bot));
    }

    // 3. keeping a name by rolling trials
    // one bot address rolls trials as fast as the rules allow; after every trial the name stays free for
    // fourteen days, so a buyer who checks at random moments finds it free about half of the time, and a
    // buyer's paid registration in any pause wins without a race.
    function test_rollingHoldLeavesTheNameFreeDuringEachPause() public {
        string memory L = "apple";
        uint256 id = _trialFor(bot, L, bot);
        uint256 checks;
        uint256 free;
        for (uint256 w; w < 10; ++w) {
            uint256 e = nft.expiresAt(id);
            // the buyer looks at 1,000 moments spread over the trial and the pause after it
            for (uint256 k = 1; k <= 1000; ++k) {
                vm.warp(e - 14 days + (28 days * k) / 1001);
                ++checks;
                if (nft.isAvailable(L, 0)) ++free;
            }
            // the bot cannot trial again inside the pause
            vm.warp(e + 14 days - 1 hours);
            _commitTrial(bot, L, bot);
            vm.warp(e + 14 days);
            vm.prank(bot);
            vm.expectRevert(PageNFT.TrialNotAllowed.selector);
            nft.revealTrial{value: PRICE5}(L, bot, 0, _secret(L, bot));
            vm.warp(e + 14 days + 1);
            vm.prank(bot);
            id = nft.revealTrial{value: PRICE5}(L, bot, 0, _secret(L, bot));
        }
        emit log_named_uint("buyer checks", checks);
        emit log_named_uint("checks that saw the name free", free);
        assertGt(free, checks * 49 / 100);
        assertLt(free, checks * 51 / 100);
        assertEq(nft.owed(bot), 10 * PRICE5, "every earlier trial price came back to the bot");

        // in the next pause a buyer registers with no race: the bot's next trial is refused all the while
        uint256 e2 = nft.expiresAt(id);
        vm.warp(e2 + 3 days);
        _commit(bob, L, bob);
        _commitTrial(bot, L, bot);
        vm.warp(e2 + 3 days + 61);
        vm.prank(bot);
        vm.expectRevert(PageNFT.TrialNotAllowed.selector);
        nft.revealTrial{value: PRICE5}(L, bot, 0, _secret(L, bot));
        vm.prank(bob);
        nft.reveal{value: FEE5}(L, bob, 0, _secret(L, bob));
        assertEq(nft.ownerOf(id), bob);
        assertEq(nft.owed(bot), 11 * PRICE5);
    }

    // registering the name outright is the only way to hold it without gaps: the deposit comes back, and
    // trials cost nothing either but leave a fourteen day gap after each one
    function test_holdingANameWithoutGapsNeedsARegistration() public {
        uint256 id = _buy(bot, "apple");
        uint256 e = nft.expiresAt(id);
        for (uint256 t = vm.getBlockTimestamp(); t < e + 90 days; t += 5 days) {
            vm.warp(t);
            assertFalse(nft.isAvailable("apple", 0));
        }
        vm.warp(e + 90 days + 21 days + 1);
        _commit(bob, "apple", bob);
        vm.warp(vm.getBlockTimestamp() + 61);
        (,,, uint256 total) = nft.quote("apple");
        vm.prank(bob);
        nft.reveal{value: total}("apple", bob, 0, _secret("apple", bob));
        emit log_named_uint("bot's credit after holding the name for a year and 111 days, wei", nft.owed(bot));
        assertEq(nft.owed(bot), FEE5);
        // a trial also costs nothing in the end, but the name is free right after it
        uint256 t2 = _trialFor(bot, "bravo", bot);
        vm.warp(nft.expiresAt(t2) + 1);
        assertTrue(nft.isAvailable("bravo", 0));
        nft.release(t2);
        assertEq(nft.owed(bot), FEE5 + PRICE5);
    }

    // 4. a thrown away trial still blocks the name
    // its price still goes back to the payer, when the name is converted or after the end
    function test_trialSentToDeadStillBlocksAndRefundsThePayer() public {
        uint256 id = _trial("alice-smith", user);
        vm.prank(user);
        nft.setAddr(id, user);
        vm.prank(user);
        nft.transferFrom(user, DEAD, id);
        assertEq(nft.resolve(id), address(0), "the dead address deletes the name, so it resolves to nothing");
        assertEq(nft.payee(id), DEAD, "anyone paying the name now pays the dead address");
        assertFalse(nft.isAvailable("alice-smith", 0));
        _commit(bob, "alice-smith", bob);
        vm.warp(vm.getBlockTimestamp() + 61);
        vm.prank(bob);
        vm.expectRevert(PageNFT.AlreadyRegistered.selector);
        nft.reveal{value: FEE5}("alice-smith", bob, 0, _secret("alice-smith", bob));
        // left alone, the price goes back to the relayer after the end
        uint256 snap = vm.snapshotState();
        vm.warp(nft.expiresAt(id) + 1);
        nft.release(id);
        assertEq(nft.owed(relayer), PRICE5);
        assertEq(nft.owed(DEAD), 0);
        vm.revertToState(snap);
        // anyone may still convert it, the deposit then belongs to DEAD and the price to the relayer
        vm.prank(bob);
        nft.renew{value: FEE5}(id);
        assertEq(nft.payee(id), DEAD);
        assertEq(nft.owed(relayer), PRICE5);
        assertEq(nft.owed(DEAD), 0);
    }

    // 5. NFT gates
    // a shop gated on holding one Etherpage lets a trial holder in, and keeps letting them in after the lapse with the
    // ended trial alone; a gate on an owned name whose status is Active refuses the trial, running or ended, but not a
    // free subpage of a paid name
    function test_gateOnHoldingAnEtherpageAcceptsTrialsForever() public {
        uint256 club = _buy(carol, "club");
        vm.startPrank(carol);
        nft.setSubpageMinter(club, address(shop));
        shop.configure(club, carol, address(0), 0, true, address(nft), 1, false);
        vm.stopPrank();
        uint256 t = _trialFor(bot, "bot-one", bot);
        assertEq(uint256(nft.status(t)), uint256(PageCard.Status.Trial), "a running trial is not Active");
        vm.prank(bot);
        uint256 s1 = shop.registerSubpageFor(club, "in1", user, 0, address(0));
        assertEq(nft.ownerOf(s1), user);
        vm.warp(nft.expiresAt(t) + 30 days);
        assertTrue(nft.isExpired(t));
        assertEq(uint256(nft.status(t)), uint256(PageCard.Status.Expired), "nor is an ended one");
        assertEq(nft.ownerOf(t), bot, "the ended trial stays in the wallet");
        assertEq(nft.balanceOf(bot), 1, "and is all the wallet holds");
        vm.prank(bot);
        uint256 s2 = shop.registerSubpage(club, "in2", 0, address(0));
        assertEq(nft.ownerOf(s2), bot);
        assertEq(uint256(nft.status(club)), uint256(PageCard.Status.Active), "a paid name in its year is Active");
        assertEq(uint256(nft.status(s2)), uint256(PageCard.Status.Active), "and so is a free subpage of it");
    }

    // 6. calls back in through the refund
    function test_refundReentryCannotMoveOrRenew() public {
        Reenterer r = new Reenterer{value: 1 ether}(nft);
        string memory L = "alice-smith";
        bytes32 commitment = trialCommitment(address(nft), L, address(r), 0, _secret(L, address(r)));
        vm.prank(address(r));
        nft.commit(commitment);
        vm.warp(vm.getBlockTimestamp() + 61);
        r.go(L, _secret(L, address(r)), 0.001 ether);
        assertTrue(r.moveFailed());
        assertTrue(r.renewFailed());
        assertEq(nft.depositOf(nft.computeId(L)), 0);
        assertEq(address(nft).balance, PRICE5);
        assertEq(nft.owed(DEAD), 0);
        (address p, uint256 held) = nft.trialPaymentOf(nft.computeId(L));
        assertEq(p, address(r));
        assertEq(held, PRICE5);
    }

    // 7. free subpages under a team name
    function test_teamSubpages_whatTheTeamKeyAndAMinterCanDo() public {
        address team = carol;
        uint256 parent = _buyAs(team, "id", FEE2);
        vm.prank(team);
        nft.setSubpageMinter(parent, relayer);
        uint256 g = gasleft();
        vm.prank(relayer);
        uint256 sub = nft.registerSubpageFor("bob", parent, bob);
        emit log_named_uint("gas of one free subpage (execution only)", g - gasleft());
        assertEq(nft.resolve(sub), bob);
        vm.prank(bob);
        nft.setPrimaryPage(sub);
        assertEq(nft.reverseResolve(bob), "bob.id");

        // a leaked minter key: mints lookalikes, cannot overwrite bob.id
        vm.prank(relayer);
        nft.registerSubpageFor("coinbase-support", parent, relayer);
        vm.prank(relayer);
        vm.expectRevert(PageNFT.AlreadyRegistered.selector);
        nft.registerSubpageFor("bob", parent, relayer);

        // the parent holder can mint bob.id again to someone else: payments to bob.id then reach that account
        vm.prank(team);
        nft.registerSubpageFor("bob", parent, payer);
        assertEq(nft.resolve(sub), payer);
        assertEq(nft.reverseResolve(bob), "");

        // and can delete lookalikes through the dead address
        vm.prank(team);
        nft.registerSubpageFor("coinbase-support", parent, DEAD);
        assertEq(nft.resolve(nft.computeId("coinbase-support.id")), address(0));
    }

    // if the team lets its name lapse, every free subpage stops at the parent's expiry (no grace for
    // subpages); after grace, auction and release a stranger can take the parent and recreate bob.id
    function test_teamSubpages_parentLapseLetsAStrangerRecreateBobDotId() public {
        address team = carol;
        uint256 parent = _buyAs(team, "id", FEE2);
        vm.prank(team);
        uint256 sub = nft.registerSubpageFor("bob", parent, bob);
        uint256 e = nft.expiresAt(parent);
        vm.warp(e + 1);
        assertEq(nft.resolve(sub), address(0), "subpages answer nothing from the parent's first expired second");
        // renewing in grace brings them back unchanged
        vm.prank(team);
        nft.renew{value: FEE2}(parent);
        assertEq(nft.resolve(sub), bob);
        // lapse for good: grace, auction, release
        e = nft.expiresAt(parent);
        vm.warp(e + 90 days + 21 days + 1);
        nft.release(parent);
        // a stranger can trial the 2 character parent for 0.001 ETH but cannot mint under it unpaid
        uint256 p2 = _trialFor(bot, "id", bot);
        assertEq(p2, parent);
        vm.prank(bot);
        vm.expectRevert(PageNFT.Unpaid.selector);
        nft.registerSubpageFor("bob", parent, bot);
        vm.prank(bot);
        nft.renew{value: FEE2}(parent);
        vm.prank(bot);
        uint256 again = nft.registerSubpageFor("bob", parent, bot);
        assertEq(again, sub);
        assertEq(nft.resolve(sub), bot);
    }

    // helpers
    function _trialFor(address sender, string memory label, address owner) internal returns (uint256 id) {
        _commitTrial(sender, label, owner);
        vm.warp(vm.getBlockTimestamp() + 61);
        uint256 p = _price(label);
        vm.prank(sender);
        id = nft.revealTrial{value: p}(label, owner, 0, _secret(label, owner));
    }

    function _buyAs(address who, string memory label, uint256 fee) internal returns (uint256 id) {
        _commit(who, label, who);
        vm.warp(vm.getBlockTimestamp() + 61);
        vm.prank(who);
        id = nft.reveal{value: fee}(label, who, 0, _secret(label, who));
    }
}

// starts a trial for itself with too much ETH and, when the excess comes back, tries to move and renew
contract Reenterer {
    PageNFT immutable nft;
    bool public moveFailed;
    bool public renewFailed;
    uint256 id;

    constructor(PageNFT n) payable {
        nft = n;
    }

    function go(string calldata label, bytes32 secret, uint256 value) external {
        id = nft.computeId(label);
        nft.revealTrial{value: value}(label, address(this), 0, secret);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    receive() external payable {
        if (msg.sender != address(nft)) return;
        try nft.transferFrom(address(this), address(0xB0B), id) {} catch { moveFailed = true; }
        try nft.renew{value: 0.0001 ether}(id) {} catch { renewFailed = true; }
    }
}

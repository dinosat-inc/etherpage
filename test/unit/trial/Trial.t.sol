// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {trialCommitment} from "../../utils/TrialCommitment.sol";

import {Vm} from "forge-std/Test.sol";
import {LibString} from "solady/utils/LibString.sol";
import {PageNFT} from "../../../src/PageNFT.sol";
import {SubpageRegistrar} from "../../../src/SubpageRegistrar.sol";
import {TrialBase} from "../../utils/TrialBase.sol";

// Behaviour of the sponsored trial: a tenth of the yearly fee, held and credited back to its payer,
// fourteen days, no transfers while unpaid except to the dead address, kept by renew, no grace and no
// auction when it lapses, a new trial only after a fourteen day pause
contract TrialTest is TrialBase {
    // the start
    function test_relayerStartsATrialForAUserWithNoEth() public {
        assertEq(user.balance, 0);
        _commitTrial(relayer, "alice", user);
        vm.warp(vm.getBlockTimestamp() + 61);
        uint256 t = vm.getBlockTimestamp();
        uint256 relayerBefore = relayer.balance;
        vm.recordLogs();
        vm.prank(relayer);
        uint256 id = nft.revealTrial{value: PRICE5}("alice", user, 0, _secret("alice", user));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(user.balance, 0, "the user paid nothing");
        assertEq(relayerBefore - relayer.balance, PRICE5, "the relayer paid a tenth of the fee");
        assertEq(nft.ownerOf(id), user);
        assertEq(nft.expiresAt(id), t + 14 days);
        assertEq(nft.depositOf(id), 0, "no deposit");
        (address payer, uint256 held) = nft.trialPaymentOf(id);
        assertEq(payer, relayer, "the price is held for the relayer");
        assertEq(held, PRICE5);
        assertEq(nft.owed(DEAD), 0, "nothing is burned");
        assertEq(nft.owed(relayer) + nft.owed(user), 0);
        assertEq(address(nft).balance, PRICE5);
        assertEq(_countTopic(logs, DEPOSIT_ADDED), 0);
        assertEq(_countTopic(logs, TRIAL_STARTED), 1);
    }

    function test_priceIsATenthOfTheFeeForEveryLength() public {
        string[6] memory labels = ["a", "ab", "abc", "abcd", "abcde", "a-longer-name"];
        uint256[6] memory prices = [uint256(0.001 ether), 0.001 ether, 0.0001 ether, 0.0001 ether, 0.00001 ether, 0.00001 ether];
        uint256 held;
        for (uint256 i; i < labels.length; ++i) {
            _commitTrial(relayer, labels[i], user);
            vm.warp(vm.getBlockTimestamp() + 61);
            vm.prank(relayer);
            vm.expectRevert(PageNFT.InsufficientFee.selector);
            nft.revealTrial{value: prices[i] - 1}(labels[i], user, 0, _secret(labels[i], user));
            uint256 before = relayer.balance;
            vm.prank(relayer);
            uint256 id = nft.revealTrial{value: prices[i] + 1 ether}(labels[i], user, 0, _secret(labels[i], user));
            assertEq(before - relayer.balance, prices[i], "excess refunded");
            held += prices[i];
            (, uint256 amount) = nft.trialPaymentOf(id);
            assertEq(amount, prices[i]);
            assertEq(address(nft).balance, held);
            assertEq(nft.owed(DEAD), 0);
            assertEq(nft.depositOf(id), 0);
        }
    }

    // what apps see
    function test_whatAppsSeeDuringTheTrial() public {
        uint256 id = _trial("alice", user);
        assertEq(nft.resolve(id), user);
        assertEq(nft.addr(bytes32(id), 0x8000000a), abi.encodePacked(user));
        // nothing for coin type 60 until the holder saves an entry or a default, and addr with no coin type answers
        // coin type 60
        assertEq(nft.addr(bytes32(id), 60), "", "coin type 60 answer before a save");
        assertEq(nft.addr(bytes32(id)), address(0), "addr answers coin type 60");
        assertEq(nft.payee(id), user);
        assertEq(nft.getPageName(id), "alice");
        assertEq(nft.computeId("alice"), id);
        assertFalse(nft.isAvailable("alice", 0));
        assertFalse(nft.isExpired(id));
        assertFalse(nft.inGracePeriod(id));
        (uint256 fee, uint256 carried, uint256 premium, uint256 total) = nft.quote("alice");
        assertEq(fee, FEE5);
        assertEq(carried, 0);
        assertEq(premium, 0);
        assertEq(total, FEE5, "quote is the paid price, as for any name");
        assertEq(nft.getPremium(id), 0);
        assertEq(_status(id), "Trial");
        assertEq(uint256(nft.status(id)), 4);
        string memory json = _json(id);
        assertTrue(LibString.contains(json, '"Deposit","display_type":"number","value":0}'), "card shows deposit 0");
        assertTrue(LibString.contains(json, LibString.toString(nft.expiresAt(id))), "card shows the trial end");
        // the display name needs one transaction from the user
        assertEq(nft.reverseResolve(user), "");
        vm.prank(user);
        nft.setPrimaryPage(id);
        assertEq(nft.reverseResolve(user), "alice");
        // records work for the holder
        vm.startPrank(user);
        nft.setText(id, "avatar", "ipfs://x");
        nft.setContenthash(id, hex"e301");
        nft.setAddr(id, carol);
        nft.setAddrForCoin(id, 0x80000000, abi.encodePacked(user));
        vm.stopPrank();
        assertEq(nft.text(id, "avatar"), "ipfs://x");
        assertEq(nft.contenthash(id), hex"e301");
        assertEq(nft.resolve(id), carol);
        assertEq(nft.payee(id), carol);
        assertEq(nft.addr(bytes32(id), 60), abi.encodePacked(user), "coin type 60 answers the saved default");
        assertEq(nft.addr(bytes32(id)), user, "addr answers coin type 60");
    }

    // keeping it
    function test_userKeepsItWithRenew() public {
        uint256 id = _trial("alice", user);
        uint256 e = nft.expiresAt(id);
        vm.warp(vm.getBlockTimestamp() + 3 days);
        vm.deal(user, FEE5);
        vm.prank(user);
        nft.renew{value: FEE5}(id);
        assertEq(nft.depositOf(id), FEE5);
        assertEq(nft.expiresAt(id), e + 365 days, "trial end plus one year");
        assertEq(nft.owed(DEAD), 0);
        assertEq(nft.owed(relayer), PRICE5, "the price is credited back to the relayer");
        vm.prank(user);
        nft.transferFrom(user, bob, id);
        assertEq(nft.ownerOf(id), bob);
    }

    // anyone may pay for the user; the name and the future refund stay the user's
    function test_payerKeepsItOnTheUsersBehalf() public {
        uint256 id = _trial("alice", user);
        uint256 e = nft.expiresAt(id);
        vm.prank(carol);
        nft.renew{value: FEE5}(id);
        assertEq(nft.ownerOf(id), user);
        assertEq(nft.depositOf(id), FEE5);
        assertEq(nft.expiresAt(id), e + 365 days);
        assertEq(nft.owed(relayer), PRICE5, "the trial price goes back to the relayer, not to carol");
        // left to lapse, the deposit comes back to the user, not to the payer
        vm.warp(nft.expiresAt(id) + 111 days + 1);
        nft.release(id);
        assertEq(nft.owed(user), FEE5);
        assertEq(nft.owed(carol), 0);
    }

    // conversion is renew; a reveal by the holder is refused while the trial runs
    function test_holderCannotConvertThroughReveal() public {
        uint256 id = _trial("alice", user);
        vm.deal(user, 1 ether);
        _commit(user, "alice", user);
        vm.warp(vm.getBlockTimestamp() + 61);
        vm.prank(user);
        vm.expectRevert(PageNFT.AlreadyRegistered.selector);
        nft.reveal{value: FEE5}("alice", user, 0, _secret("alice", user));
        vm.prank(user);
        nft.renew{value: FEE5}(id);
        assertEq(nft.depositOf(id), FEE5);
    }

    // after a lapse the old holder registers with commit and reveal like anyone else, at the plain fee
    function test_holderRegistersAfterTheLapseWithCommitAndReveal() public {
        uint256 id = _trial("alice", user);
        vm.deal(user, 1 ether);
        vm.warp(nft.expiresAt(id) - 1 hours);
        _commit(user, "alice", user);
        vm.warp(nft.expiresAt(id) + 1);
        vm.prank(user);
        nft.reveal{value: FEE5}("alice", user, 0, _secret("alice", user));
        assertEq(nft.ownerOf(id), user);
        assertEq(nft.depositOf(id), FEE5);
        assertEq(nft.epochOf(id), 2);
        assertEq(nft.expiresAt(id), vm.getBlockTimestamp() + 365 days);
    }

    function test_renewTwiceDuringTheTrial() public {
        uint256 id = _trial("alice", user);
        uint256 e = nft.expiresAt(id);
        vm.startPrank(carol);
        nft.renew{value: FEE5}(id);
        nft.renew{value: FEE5}(id);
        vm.stopPrank();
        assertEq(nft.expiresAt(id), e + 730 days);
        assertEq(nft.depositOf(id), 2 * FEE5);
    }

    // after payment every paid rule applies: grace, auction, and the trial's referrer earns from the premium
    function test_paidAfterTrialHasGraceAuctionAndReferrer() public {
        uint256 ref = _buy(carol, "carol-ref");
        bytes32 commitment = trialCommitment(address(nft), "alice", user, ref, bytes32("s"));
        vm.prank(relayer);
        nft.commit(commitment);
        vm.warp(vm.getBlockTimestamp() + 61);
        vm.prank(relayer);
        uint256 id = nft.revealTrial{value: PRICE5}("alice", user, ref, bytes32("s"));
        assertEq(nft.referrerOf(id), ref);
        assertEq(nft.owed(carol), 0, "the referrer earns nothing from the trial price");
        vm.prank(bob);
        nft.renew{value: FEE5}(id);
        vm.prank(carol);
        nft.renew{value: FEE5}(ref);
        vm.prank(carol);
        nft.renew{value: FEE5}(ref);
        uint256 e = nft.expiresAt(id);
        vm.warp(e + 1);
        assertTrue(nft.inGracePeriod(id));
        assertEq(_status(id), "Grace");
        assertFalse(nft.isAvailable("alice", 0));
        vm.warp(e + 90 days + 1 days);
        uint256 premium = nft.getPremium(id);
        assertGt(premium, 9 ether);
        _commit(bob, "alice", bob);
        vm.warp(vm.getBlockTimestamp() + 61);
        (,,, uint256 total) = nft.quote("alice");
        vm.prank(bob);
        nft.reveal{value: total}("alice", bob, 0, _secret("alice", bob));
        assertGt(nft.owed(carol), 0, "referrer paid from the auction premium");
    }

    // others during the trial
    function test_nobodyElseCanTakeItDuringTheTrial() public {
        uint256 id = _trial("alice", user);
        vm.warp(vm.getBlockTimestamp() + 6 days);
        _commit(bob, "alice", bob);
        _commitTrial(relayer, "alice", carol);
        vm.warp(vm.getBlockTimestamp() + 61);
        vm.prank(bob);
        vm.expectRevert(PageNFT.AlreadyRegistered.selector);
        nft.reveal{value: FEE5}("alice", bob, 0, _secret("alice", bob));
        vm.prank(relayer);
        vm.expectRevert(PageNFT.AlreadyRegistered.selector);
        nft.revealTrial{value: PRICE5}("alice", carol, 0, _secret("alice", carol));
        vm.startPrank(bob);
        vm.expectRevert(PageNFT.Unauthorized.selector);
        nft.setAddr(id, bob);
        vm.expectRevert(PageNFT.Unauthorized.selector);
        nft.setText(id, "url", "x");
        vm.expectRevert(PageNFT.Unauthorized.selector);
        nft.setPrimaryPage(id);
        vm.expectRevert(PageNFT.Unpaid.selector);
        nft.registerSubpage("sub", id);
        vm.stopPrank();
        assertEq(nft.ownerOf(id), user);
    }

    function test_trialCannotMoveExceptToDead() public {
        uint256 id = _trial("alice", user);
        vm.startPrank(user);
        vm.expectRevert(PageNFT.Unpaid.selector);
        nft.transferFrom(user, bob, id);
        vm.expectRevert(PageNFT.Unpaid.selector);
        nft.safeTransferFrom(user, bob, id);
        nft.setApprovalForAll(bob, true);
        nft.approve(carol, id);
        vm.stopPrank();
        vm.prank(bob);
        vm.expectRevert(PageNFT.Unpaid.selector);
        nft.transferFrom(user, bob, id);
        vm.prank(carol);
        vm.expectRevert(PageNFT.Unpaid.selector);
        nft.transferFrom(user, carol, id);
        vm.prank(user);
        nft.transferFrom(user, DEAD, id);
        assertEq(nft.ownerOf(id), DEAD);
        vm.warp(nft.expiresAt(id) + 1);
        assertTrue(nft.isAvailable("alice", 0));
    }

    // the end
    function test_lapseAtTheLastSecond() public {
        uint256 id = _trial("alice", user);
        uint256 e = nft.expiresAt(id);
        vm.prank(user);
        nft.setPrimaryPage(id);
        vm.warp(e - 1 hours);
        _commit(bob, "alice", bob);
        vm.warp(e);
        assertEq(nft.resolve(id), user, "the last second is still the user's");
        assertFalse(nft.isAvailable("alice", 0));
        vm.prank(bob);
        vm.expectRevert(PageNFT.AlreadyRegistered.selector);
        nft.reveal{value: FEE5}("alice", bob, 0, _secret("alice", bob));
        vm.warp(e + 1);
        assertEq(nft.resolve(id), address(0));
        assertEq(nft.addr(bytes32(id), 60), "");
        assertEq(nft.text(id, "avatar"), "");
        assertEq(nft.reverseResolve(user), "");
        assertTrue(nft.isAvailable("alice", 0));
        assertTrue(nft.isExpired(id));
        assertFalse(nft.inGracePeriod(id));
        assertEq(_status(id), "Expired");
        assertEq(nft.ownerOf(id), user, "the dead NFT stays in the wallet until the name is taken");
        vm.prank(carol);
        vm.expectRevert(PageNFT.Expired.selector);
        nft.renew{value: FEE5}(id);
        vm.prank(user);
        vm.expectRevert(PageNFT.Expired.selector);
        nft.transferFrom(user, bob, id);
    }

    function test_renewAtTheLastSecond() public {
        uint256 id = _trial("alice", user);
        vm.warp(nft.expiresAt(id));
        vm.prank(carol);
        nft.renew{value: FEE5}(id);
        assertEq(nft.ownerOf(id), user);
        assertEq(nft.depositOf(id), FEE5);
    }

    // a lapsed trial never has an auction premium, and release only credits the price back to its payer
    function test_noPremiumAfterALapseAndReleaseRefundsThePayer() public {
        uint256 id = _trial("alice", user);
        uint256 e = nft.expiresAt(id);
        uint256[6] memory offsets = [uint256(1), 1 days, 90 days, 90 days + 1, 100 days, 111 days + 1];
        for (uint256 i; i < offsets.length; ++i) {
            vm.warp(e + offsets[i]);
            assertEq(nft.getPremium(id), 0);
            (, uint256 carried, uint256 premium, uint256 total) = nft.quote("alice");
            assertEq(carried + premium, 0);
            assertEq(total, FEE5);
            assertEq(_status(id), "Expired");
            assertTrue(nft.isReleasable(id), "the held price can go back");
        }
        nft.release(id);
        assertEq(nft.owed(relayer), PRICE5);
        assertEq(nft.depositOf(id), 0);
        assertFalse(nft.isReleasable(id));
        vm.expectRevert(PageNFT.NothingToRelease.selector);
        nft.release(id);
    }

    // the next buyer pays the plain fee and only the trial payer is credited, with its own price
    function test_buyerAfterALapseCreditsOnlyTheTrialPayer() public {
        uint256 id = _trial("alice", user);
        vm.prank(user);
        nft.setPrimaryPage(id);
        vm.warp(nft.expiresAt(id) - 1 hours);
        _commit(bob, "alice", bob);
        vm.warp(nft.expiresAt(id) + 1);
        vm.recordLogs();
        _revealPaid(bob, "alice");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_countTopic(logs, BOUGHT_OUT) + _countTopic(logs, OWNER_PREMIUM) + _countTopic(logs, REF_PREMIUM), 0);
        assertEq(_countTopic(logs, TRIAL_REFUNDED), 1);
        assertEq(nft.owed(user), 0);
        assertEq(nft.owed(relayer), PRICE5);
        assertEq(nft.owed(DEAD), 0);
        assertEq(nft.ownerOf(id), bob);
        assertEq(nft.primaryPage(user), 0);
        assertEq(address(nft).balance, PRICE5 + FEE5);
        uint256 before = relayer.balance;
        vm.prank(bob);
        nft.withdraw(relayer);
        assertEq(relayer.balance - before, PRICE5);
    }

    // a new trial after the pause
    function test_reTrialRefusedDuringThePauseThenAllowed() public {
        uint256 id = _trial("alice", user);
        vm.prank(user);
        nft.setPrimaryPage(id);
        uint256 e = nft.expiresAt(id);
        vm.warp(e - 1 hours);
        _commitTrial(relayer, "alice", carol);
        vm.warp(e + 1);
        vm.prank(relayer);
        vm.expectRevert(PageNFT.TrialNotAllowed.selector);
        nft.revealTrial{value: PRICE5}("alice", carol, 0, _secret("alice", carol));
        vm.warp(e + 14 days - 1 hours);
        _commitTrial(relayer, "alice", carol);
        vm.warp(e + 14 days + 1);
        vm.prank(relayer);
        nft.revealTrial{value: PRICE5}("alice", carol, 0, _secret("alice", carol));
        assertEq(nft.ownerOf(id), carol);
        assertEq(nft.epochOf(id), 2);
        assertEq(nft.primaryPage(user), 0);
        assertEq(nft.owed(DEAD), 0);
        assertEq(nft.owed(relayer), PRICE5, "the first price is credited back");
        (address payer, uint256 held) = nft.trialPaymentOf(id);
        assertEq(payer, relayer);
        assertEq(held, PRICE5, "the second price is held");
        assertEq(nft.expiresAt(id), e + 14 days + 1 + 14 days);
    }

    // rolling trials cost only the held capital, but every pause leaves the name open to anyone for
    // fourteen days, so a holder rolling trials for a year leaves it open about half of the year
    function test_rollingTrialsLeaveTheNameOpenHalfTheYear() public {
        uint256 id;
        uint256 start = vm.getBlockTimestamp();
        uint256 n;
        uint256 open;
        while (n == 0 || nft.expiresAt(id) + 14 days + 1 < start + 365 days) {
            if (n > 0) {
                uint256 e = nft.expiresAt(id);
                vm.warp(e + 1);
                assertTrue(nft.isAvailable("alice", 0), "open to a paid registration");
                vm.warp(e + 14 days - 1 hours);
                _commitTrial(relayer, "alice", user);
                vm.warp(e + 14 days + 1);
                open += 14 days;
            } else {
                _commitTrial(relayer, "alice", user);
                vm.warp(vm.getBlockTimestamp() + 61);
            }
            vm.prank(relayer);
            id = nft.revealTrial{value: PRICE5}("alice", user, 0, _secret("alice", user));
            ++n;
        }
        emit log_named_uint("trials in one year", n);
        emit log_named_uint("days open to anyone", open / 1 days);
        assertEq(n, 14);
        assertEq(open, 182 days);
        assertEq(nft.owed(DEAD), 0);
        assertEq(nft.owed(relayer), (n - 1) * PRICE5, "every earlier price is credited back");
    }

    // interplay with paid names
    function test_noTrialOverALiveOrGraceName() public {
        uint256 id = _buy(bob, "vault");
        _commitTrial(relayer, "vault", carol);
        vm.warp(vm.getBlockTimestamp() + 61);
        vm.prank(relayer);
        vm.expectRevert(PageNFT.TrialNotAllowed.selector);
        nft.revealTrial{value: PRICE5}("vault", carol, 0, _secret("vault", carol));
        vm.warp(nft.expiresAt(id) + 30 days);
        _commitTrial(relayer, "vault", carol);
        vm.warp(vm.getBlockTimestamp() + 61);
        vm.prank(relayer);
        vm.expectRevert(PageNFT.TrialNotAllowed.selector);
        nft.revealTrial{value: PRICE5}("vault", carol, 0, _secret("vault", carol));
        // after a conversion too
        uint256 t = _trial("alice", user);
        vm.prank(carol);
        nft.renew{value: FEE5}(t);
        _commitTrial(relayer, "alice", carol);
        vm.warp(vm.getBlockTimestamp() + 61);
        vm.prank(relayer);
        vm.expectRevert(PageNFT.TrialNotAllowed.selector);
        nft.revealTrial{value: PRICE5}("alice", carol, 0, _secret("alice", carol));
    }

    // a trial is refused while the auction runs, up to its last second, and one second later it first releases the
    // deposit to the last payee
    function test_noTrialDuringTheAuction() public {
        uint256 id = _buy(bob, "vault");
        uint256 e = nft.expiresAt(id);
        uint256[2] memory at = [e + 95 days, e + 111 days];
        for (uint256 i; i < at.length; ++i) {
            vm.warp(at[i] - 2 minutes);
            _commitTrial(relayer, "vault", carol);
            vm.warp(at[i]);
            assertTrue(nft.isAvailable("vault", 0));
            vm.prank(relayer);
            vm.expectRevert(PageNFT.TrialNotAllowed.selector);
            nft.revealTrial{value: 1 ether}("vault", carol, 0, _secret("vault", carol));
        }
        vm.warp(e + 111 days + 1);
        assertTrue(nft.isReleasable(id));
        vm.recordLogs();
        vm.prank(relayer);
        nft.revealTrial{value: PRICE5}("vault", carol, 0, _secret("vault", carol));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_countTopic(logs, DEPOSIT_RELEASED), 1);
        assertEq(logs[0].topics[0], DEPOSIT_RELEASED, "the release comes first");
        assertEq(_countTopic(logs, BOUGHT_OUT) + _countTopic(logs, OWNER_PREMIUM) + _countTopic(logs, REF_PREMIUM), 0);
        assertEq(nft.ownerOf(id), carol);
        assertEq(nft.epochOf(id), 2);
        assertEq(nft.owed(bob), FEE5);
        assertEq(nft.owed(DEAD), 0);
        assertEq(nft.depositOf(id), 0);
        (, uint256 held) = nft.trialPaymentOf(id);
        assertEq(held, PRICE5);
        assertEq(nft.expiresAt(id), e + 111 days + 1 + 14 days);
    }

    // a name that lapsed from a trial and was bought is a normal name
    function test_reRegisteredNameIsNormal() public {
        uint256 id = _trial("alice", user);
        vm.warp(nft.expiresAt(id) - 1 hours);
        _commit(bob, "alice", bob);
        vm.warp(nft.expiresAt(id) + 1);
        _revealPaid(bob, "alice");
        vm.prank(bob);
        nft.transferFrom(bob, carol, id);
        vm.prank(carol);
        nft.registerSubpage("sub", id);
        uint256 e = nft.expiresAt(id);
        vm.warp(e + 45 days);
        assertTrue(nft.inGracePeriod(id));
        assertFalse(nft.isAvailable("alice", 0));
    }

    // subpages and the minter
    function test_noSubpagesUnderATrial() public {
        uint256 id = _trial("alice", user);
        vm.prank(user);
        vm.expectRevert(PageNFT.Unpaid.selector);
        nft.registerSubpage("sub", id);
        assertFalse(nft.isAvailable("sub", id));
        // the minter can be picked and subpageMinterOf shows it, but it cannot mint while the name is unpaid
        vm.prank(user);
        nft.setSubpageMinter(id, carol);
        assertEq(nft.subpageMinterOf(id), carol);
        vm.prank(carol);
        vm.expectRevert(PageNFT.Unpaid.selector);
        nft.registerSubpageFor("sub", id, carol);
        // the shop refuses before taking money
        vm.startPrank(user);
        nft.setSubpageMinter(id, address(shop));
        shop.configure(id, user, address(0), 0.01 ether, true, address(0), 0, false);
        vm.stopPrank();
        uint256 before = bob.balance;
        vm.prank(bob);
        vm.expectRevert(SubpageRegistrar.NotAvailable.selector);
        shop.registerSubpage{value: 0.01 ether}(id, "sub", 0.01 ether, address(0));
        assertEq(bob.balance, before);
        // once paid the same pick and the same config sell
        vm.prank(carol);
        nft.renew{value: FEE5}(id);
        assertTrue(nft.isAvailable("sub", id));
        vm.prank(bob);
        uint256 sub = shop.registerSubpage{value: 0.01 ether}(id, "sub", 0.01 ether, address(0));
        assertEq(nft.ownerOf(sub), bob);
        assertEq(nft.getPageName(sub), "sub.alice");
    }

    // a lapsed trial's minter dies with the name when it is taken again
    function test_minterPickedDuringTrialDiesWithALapse() public {
        uint256 id = _trial("alice", user);
        vm.prank(user);
        nft.setSubpageMinter(id, carol);
        vm.warp(nft.expiresAt(id) - 1 hours);
        _commit(bob, "alice", bob);
        vm.warp(nft.expiresAt(id) + 1);
        _revealPaid(bob, "alice");
        assertEq(nft.subpageMinterOf(id), address(0));
        vm.prank(carol);
        vm.expectRevert(PageNFT.NotParentOwner.selector);
        nft.registerSubpageFor("sub", id, carol);
    }

    // a subpage's card follows its paid parent through grace and expiry
    function test_subpageCardFollowsAPaidParent() public {
        uint256 id = _trial("alice", user);
        vm.prank(carol);
        nft.renew{value: FEE5}(id);
        vm.prank(user);
        uint256 sub = nft.registerSubpage("sub", id);
        vm.warp(nft.expiresAt(id) + 1);
        assertEq(_status(sub), "Grace");
        vm.warp(nft.expiresAt(id) + 90 days + 1);
        assertEq(_status(sub), "Expired");
    }

    // primary names
    function test_primaryPageDuringAndAfter() public {
        uint256 id = _trial("alice", user);
        vm.prank(user);
        nft.setPrimaryPage(id);
        assertEq(nft.reverseResolve(user), "alice");
        // the address the name points at may also show it
        vm.prank(user);
        nft.setAddr(id, carol);
        vm.prank(carol);
        nft.setPrimaryPage(id);
        assertEq(nft.reverseResolve(carol), "alice");
        assertEq(nft.reverseResolve(user), "", "the name no longer points at the holder");
        // conversion keeps it
        vm.prank(bob);
        nft.renew{value: FEE5}(id);
        assertEq(nft.reverseResolve(carol), "alice");
        // after a lapse, a new registration clears the last holder's entry with one PrimaryPageSet
        vm.prank(user);
        nft.setAddr(id, address(0));
        vm.warp(nft.expiresAt(id) + 90 days + 21 days + 1);
        nft.release(id);
        _commit(bob, "alice", bob);
        vm.warp(vm.getBlockTimestamp() + 61);
        vm.recordLogs();
        _revealPaid(bob, "alice");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_countTopic(logs, PRIMARY_SET), 1);
        assertEq(nft.primaryPage(user), 0);
    }

    // events
    function test_eventsOfATrialInOrder() public {
        _commitTrial(relayer, "alice", user);
        vm.warp(vm.getBlockTimestamp() + 61);
        vm.recordLogs();
        vm.prank(relayer);
        uint256 id = nft.revealTrial{value: PRICE5}("alice", user, 0, _secret("alice", user));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32[8] memory want = [REFERRER_SET, TRIAL_STARTED, TRANSFER, ADDRESS_CHANGED, ADDRESS_CHANGED, ADDR_CHANGED, NAME_REGISTERED, METADATA];
        assertEq(logs.length, want.length);
        for (uint256 i; i < want.length; ++i) assertEq(logs[i].topics[0], want[i]);
        assertEq(logs[1].topics[1], bytes32(id));
        assertEq(logs[1].topics[2], bytes32(uint256(uint160(relayer))));
        assertEq(abi.decode(logs[1].data, (uint256)), PRICE5);
        (, uint256 exp) = abi.decode(logs[6].data, (string, uint256));
        assertEq(exp, vm.getBlockTimestamp() + 14 days);
        // conversion: the refund of the trial price, then the usual renewal events
        vm.recordLogs();
        vm.prank(carol);
        nft.renew{value: FEE5}(id);
        logs = vm.getRecordedLogs();
        assertEq(logs.length, 4);
        assertEq(logs[0].topics[0], TRIAL_REFUNDED);
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(relayer))));
        assertEq(abi.decode(logs[0].data, (uint256)), PRICE5);
        assertEq(logs[1].topics[0], DEPOSIT_ADDED);
        assertEq(logs[2].topics[0], NAME_RENEWED);
        assertEq(logs[3].topics[0], METADATA);
    }

    function test_eventsOfAReTrialOverALapse() public {
        uint256 id = _trial("alice", user);
        vm.prank(user);
        nft.setPrimaryPage(id);
        vm.warp(nft.expiresAt(id) + 14 days - 1 hours);
        _commitTrial(relayer, "alice", carol);
        vm.warp(nft.expiresAt(id) + 14 days + 1);
        vm.recordLogs();
        vm.prank(relayer);
        nft.revealTrial{value: PRICE5}("alice", carol, 0, _secret("alice", carol));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32[14] memory want = [
            TRIAL_REFUNDED, PRIMARY_SET, TRANSFER, ADDRESS_CHANGED, ADDRESS_CHANGED, ADDR_CHANGED, VERSION_CHANGED,
            REFERRER_SET, TRIAL_STARTED, TRANSFER, ADDRESS_CHANGED, ADDRESS_CHANGED, ADDR_CHANGED, NAME_REGISTERED
        ];
        for (uint256 i; i < want.length; ++i) assertEq(logs[i].topics[0], want[i]);
        assertEq(logs[14].topics[0], METADATA);
        assertEq(logs.length, 15);
    }

    // commitments
    // the trial commitment names the owner and not the sender, so a reveal for another owner finds no
    // commitment, while anyone with the secret can complete it for the named owner
    function test_commitmentBindsTheOwner() public {
        _commitTrial(relayer, "alice", user);
        vm.warp(vm.getBlockTimestamp() + 61);
        vm.prank(bob);
        vm.expectRevert(PageNFT.CommitmentNotFound.selector);
        nft.revealTrial{value: PRICE5}("alice", bob, 0, _secret("alice", user));
        vm.prank(bob);
        uint256 id = nft.revealTrial{value: PRICE5}("alice", user, 0, _secret("alice", user));
        assertEq(nft.ownerOf(id), user);
    }

    // a commitment made for a paid reveal can never be used for a trial, even by someone who knows the
    // secret, and a trial commitment can never be used for a paid reveal
    function test_paidCommitmentCannotBecomeATrial() public {
        vm.deal(user, 1 ether);
        _commit(user, "alice", user);
        vm.warp(vm.getBlockTimestamp() + 61);
        vm.prank(relayer);
        vm.expectRevert(PageNFT.CommitmentNotFound.selector);
        nft.revealTrial{value: PRICE5}("alice", user, 0, _secret("alice", user));
        vm.prank(user);
        uint256 id = nft.reveal{value: FEE5}("alice", user, 0, _secret("alice", user));
        assertEq(nft.depositOf(id), FEE5);
        _commitTrial(relayer, "bravo", user);
        vm.warp(vm.getBlockTimestamp() + 61);
        vm.prank(relayer);
        vm.expectRevert(PageNFT.CommitmentNotFound.selector);
        nft.reveal{value: FEE5}("bravo", user, 0, _secret("bravo", user));
        vm.prank(relayer);
        uint256 t = nft.revealTrial{value: PRICE5}("bravo", user, 0, _secret("bravo", user));
        assertEq(nft.depositOf(t), 0);
    }

    // makeCommitment refuses a name as its own referrer
    function test_selfReferralRefused() public {
        uint256 id = nft.computeId("alice");
        vm.expectRevert(PageNFT.SelfReferral.selector);
        nft.makeCommitment("alice", user, id, bytes32("s"));
    }

    // inside the mint callback an unpaid name cannot move, renew is locked by the guard, records work
    function test_receiverActsInsideTheTrialMint() public {
        ActingReceiver r = new ActingReceiver{value: 1 ether}(nft);
        _commitTrial(relayer, "alice", address(r));
        vm.warp(vm.getBlockTimestamp() + 61);
        vm.prank(relayer);
        uint256 id = nft.revealTrial{value: PRICE5}("alice", address(r), 0, _secret("alice", address(r)));
        assertTrue(r.moveFailed());
        assertTrue(r.renewFailed());
        assertTrue(r.textWritten());
        assertEq(nft.ownerOf(id), address(r));
        assertEq(nft.depositOf(id), 0);
        assertEq(address(nft).balance, PRICE5);
    }

    // an unsolicited trial cannot be pushed on a contract that refuses NFTs: the reveal reverts with the receiver
    // error, the relayer keeps its ETH, no money stays behind and the commitment is still there
    function test_trialToAContractThatRefusesNfts() public {
        address refuser = address(new Refuser());
        bytes32 c = trialCommitment(address(nft), "alice", refuser, 0, _secret("alice", refuser));
        _commitTrial(relayer, "alice", refuser);
        uint256 committedAt = vm.getBlockTimestamp();
        vm.warp(committedAt + 61);
        uint256 before = relayer.balance;
        vm.prank(relayer);
        vm.expectRevert(bytes4(0xd1a57ed6)); // TransferToNonERC721ReceiverImplementer()
        nft.revealTrial{value: PRICE5}("alice", refuser, 0, _secret("alice", refuser));
        assertEq(relayer.balance, before, "the relayer keeps its ETH");
        assertEq(nft.commitments(c), committedAt, "the commitment is still there");
        assertEq(nft.owed(DEAD), 0);
        assertEq(address(nft).balance, 0);
    }
}

contract Refuser {}

// a receiver that, inside the trial's mint, tries to move the name, to renew it and to write a record
contract ActingReceiver {
    PageNFT immutable nft;
    bool public moveFailed;
    bool public renewFailed;
    bool public textWritten;

    constructor(PageNFT n) payable {
        nft = n;
    }

    function onERC721Received(address, address, uint256 id, bytes calldata) external returns (bytes4) {
        try nft.transferFrom(address(this), address(0xB0B), id) {} catch { moveFailed = true; }
        try nft.renew{value: 0.0001 ether}(id) {} catch { renewFailed = true; }
        try nft.setText(id, "k", "v") { textWritten = true; } catch {}
        return this.onERC721Received.selector;
    }
}

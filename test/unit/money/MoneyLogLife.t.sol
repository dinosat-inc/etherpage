// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {trialCommitmentRaw} from "../../utils/TrialCommitment.sol";

import {PageNFT} from "../../../src/PageNFT.sol";
import {PageCard} from "../../../src/PageCard.sol";
import {MoneyLogReplay, LedgerForce} from "../../utils/MoneyLogReplay.sol";

// One life of a few names, replayed from the money events after every step. An indexer that reads only those
// events holds every credit, deposit and trial payment the contract holds, at every step, and the ETH the
// events account for, plus any ETH forced in, is the balance.
contract MoneyLogLifeTest is MoneyLogReplay {
    PageNFT nft;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address dave = makeAddr("dave");
    address erin = makeAddr("erin");
    address relayer = makeAddr("relayer");
    address user = makeAddr("user");
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256[] tracked;
    uint256 forced;

    function setUp() public {
        vm.warp(1_800_000_000);
        nft = new PageNFT(new PageCard());
        address[7] memory who = [alice, bob, carol, dave, erin, relayer, user];
        for (uint256 i; i < who.length; ++i) {
            vm.deal(who[i], 1000 ether);
            _track(who[i]);
        }
        _track(DEAD);
        string[6] memory ls = ["referrer", "alpha", "bravo", "trial-one", "trial-two", "trial-three"];
        for (uint256 i; i < ls.length; ++i) tracked.push(nft.computeId(ls[i]));
        vm.recordLogs();
    }

    // replays the logs of the last step and compares every ledger with the contract
    function _step() internal {
        _replay(address(nft), vm.getRecordedLogs());
        _assertReplay(nft, tracked, forced);
    }

    function _secret(string memory l, address owner) internal pure returns (bytes32) {
        return keccak256(abi.encode("life", l, owner));
    }

    // payer commits, 61 seconds pass, and payer registers l for owner at the quote plus extra
    function _buy(address payer, string memory l, address owner, uint256 ref, uint256 extra)
        internal
        returns (uint256 id)
    {
        bytes32 c = nft.makeCommitment(l, owner, ref, _secret(l, owner));
        vm.prank(payer);
        nft.commit(c);
        vm.warp(vm.getBlockTimestamp() + 61);
        (,,, uint256 total) = nft.quote(l);
        vm.prank(payer);
        id = nft.reveal{value: total + extra}(l, owner, ref, _secret(l, owner));
    }

    // the same for a trial, paying a tenth of the yearly fee plus 1 ether that comes straight back
    function _trial(address payer, string memory l, address owner) internal returns (uint256 id) {
        bytes32 c = trialCommitmentRaw(l, owner, 0, _secret(l, owner));
        vm.prank(payer);
        nft.commit(c);
        vm.warp(vm.getBlockTimestamp() + 61);
        uint256 price = nft.getFee(bytes(l).length) / 10;
        vm.prank(payer);
        id = nft.revealTrial{value: price + 1 ether}(l, owner, 0, _secret(l, owner));
    }

    // 24 steps, each followed by the replay of its logs and a comparison of every ledger
    function test_logReplayReproducesOwed() public {
        uint256 fee5 = nft.getFee(5);

        // a referrer name, then alpha bought for alice by the relayer, which overpays, naming that referrer
        uint256 ref = _buy(carol, "referrer", carol, 0, 0);
        _step();
        uint256 id = _buy(relayer, "alpha", alice, ref, 0.5 ether);
        _step();

        // a stranger renews twice, overpaying, and alice points the name at dave, its payee from now on
        for (uint256 i; i < 2; ++i) {
            vm.prank(bob);
            nft.renew{value: fee5 + 1 ether}(id);
            _step();
        }
        vm.prank(alice);
        nft.setAddr(id, dave);
        _step();

        // in grace alice renews once more
        vm.warp(nft.expiresAt(id) + 30 days);
        assertTrue(nft.inGracePeriod(id));
        vm.prank(alice);
        nft.renew{value: fee5}(id);
        _step();
        assertEq(nft.depositOf(id), 4 * fee5);

        // after grace erin buys alpha at auction, naming the same referrer: dave gets the deposit and 75 percent
        // of the premium, and carol, payee of the referrer named at the last registration, the other 25 percent
        vm.warp(nft.expiresAt(id) + 90 days + 3 days);
        bytes32 c = nft.makeCommitment("alpha", erin, ref, _secret("alpha", erin));
        vm.prank(erin);
        nft.commit(c);
        vm.warp(vm.getBlockTimestamp() + 61);
        (uint256 fee, uint256 carried, uint256 premium, uint256 total) = nft.quote("alpha");
        vm.prank(erin);
        nft.reveal{value: total}("alpha", erin, ref, _secret("alpha", erin));
        _step();
        uint256 refShare = premium * 2500 / 10_000;
        assertGt(refShare, 0);
        assertEq(carried, 4 * fee5);
        assertEq(nft.owed(dave), carried + premium - refShare);
        assertEq(nft.owed(carol), refShare);

        // a stranger pushes dave's credit out and carol takes hers
        vm.prank(bob);
        nft.withdraw(dave);
        _step();
        vm.prank(carol);
        nft.withdraw(carol);
        _step();

        // ETH forced in is no one's credit and has no event
        new LedgerForce{value: 1 ether}(payable(address(nft)));
        forced += 1 ether;
        _step();

        // erin moves alpha to user, then its year lapses unrenewed: anyone releases the deposit, which goes to
        // the payee of the moment, user, who withdraws it
        vm.prank(erin);
        nft.transferFrom(erin, user, id);
        _step();
        vm.warp(nft.expiresAt(id) + 111 days + 1);
        vm.prank(bob);
        nft.release(id);
        _step();
        assertEq(nft.owed(user), carried + fee);
        assertEq(nft.owed(erin), 0);
        vm.prank(user);
        nft.withdraw(user);
        _step();

        // bravo names no referrer, so 25 percent of its premium goes to the dead address, which anyone withdraws
        uint256 b = _buy(bob, "bravo", bob, 0, 0);
        _step();
        vm.warp(nft.expiresAt(b) + 90 days + 1 days);
        _buy(user, "bravo", user, 0, 0);
        _step();
        assertGt(nft.owed(DEAD), 0);
        vm.prank(user);
        nft.withdraw(DEAD);
        _step();
        // bob, the last payee of bravo, takes his credit inside a bundle
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeCall(PageNFT.withdraw, (bob));
        vm.prank(bob);
        nft.multicall(calls);
        _step();
        assertEq(nft.owed(bob), 0);

        // trial money goes back to its payer in each of three ways
        // a renewal before the trial ends makes it a normal name
        uint256 t1 = _trial(relayer, "trial-one", user);
        _step();
        uint256 fee9 = nft.getFee(9);
        vm.prank(bob);
        nft.renew{value: fee9}(t1);
        _step();
        // a release once it has ended unpaid
        uint256 t2 = _trial(relayer, "trial-two", user);
        _step();
        vm.warp(nft.expiresAt(t2) + 1);
        vm.prank(carol);
        nft.release(t2);
        _step();
        // a new registration once it has ended unpaid
        uint256 t3 = _trial(relayer, "trial-three", user);
        _step();
        vm.warp(nft.expiresAt(t3) + 1);
        _buy(dave, "trial-three", dave, 0, 0);
        _step();
        assertEq(nft.owed(relayer), nft.getFee(9) / 10 + nft.getFee(9) / 10 + nft.getFee(11) / 10);
        vm.prank(relayer);
        nft.withdraw(relayer);
        _step();

        // every money event of the life was replayed, each kind as often as the steps made it
        assertEq(logCounts[0], 10, "DepositAdded");
        assertEq(logCounts[1], 2, "DepositBoughtOut");
        assertEq(logCounts[2], 1, "DepositReleased");
        assertEq(logCounts[3], 2, "ReferrerPremiumCredited");
        assertEq(logCounts[4], 2, "OwnerPremiumCredited");
        assertEq(logCounts[5], 6, "Withdrawn");
        assertEq(logCounts[6], 3, "TrialStarted");
        assertEq(logCounts[7], 3, "TrialRefunded");
    }
}

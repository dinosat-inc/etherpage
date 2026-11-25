// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {PageNFT} from "../../../src/PageNFT.sol";
import {AcceptedBase} from "./AcceptedBase.sol";

// A commitment can be revealed for one day after its block. A reveal that fails in the last block of that day, or
// that lands in the first block after it, makes the label, owner, referrer and secret public and leaves the owner
// nothing to retry with: the retry is too old, so the owner must commit again and wait twenty seconds like anyone
// else, and a watcher that commits in the same block or earlier can reveal first. It can start a trial for the
// owner with the owner's own values, or take a paid year for itself. Interfaces never reveal a commitment older
// than 23 hours.
contract AcceptedLateRevealTest is AcceptedBase {
    string constant L = "late-name";
    address bot = makeAddr("bot");
    bytes32 constant BOT_SECRET = bytes32("watcher");

    function setUp() public override {
        super.setUp();
        vm.deal(bot, 10 ether);
    }

    // the reveal fails on the fee in the last second of the day; one block later the retry is too old, and the
    // trial form the watcher commits for the owner in that block ripens with the owner's new commitment and is
    // revealed first
    function test_revealFailingAtTheEndOfTheDayCannotBeRetried() public {
        uint256 t0 = vm.getBlockTimestamp();
        _commitPaid(user, L, user, 0);
        uint256 fee = nft.getFee(bytes(L).length);
        bytes32 s = _secret(L, user);

        // two seconds earlier the next block is still inside the day, and the retry there wins the year
        uint256 snap = vm.snapshotState();
        vm.warp(t0 + 86398);
        vm.prank(user);
        vm.expectRevert(PageNFT.InsufficientFee.selector);
        nft.reveal{value: fee - 1}(L, user, 0, s);
        vm.warp(t0 + 86400);
        vm.prank(user);
        uint256 won = nft.reveal{value: fee}(L, user, 0, s);
        assertEq(nft.ownerOf(won), user);
        assertEq(nft.depositOf(won), fee);
        vm.revertToState(snap);

        vm.warp(t0 + 86400);
        vm.prank(user);
        vm.expectRevert(PageNFT.InsufficientFee.selector);
        nft.reveal{value: fee - 1}(L, user, 0, s);
        vm.warp(t0 + 86402);
        _commitTrial(bot, L, user, 0);
        vm.prank(user);
        vm.expectRevert(PageNFT.CommitmentTooOld.selector);
        nft.reveal{value: fee}(L, user, 0, s);
        _commitPaid(user, L, user, 0);
        vm.warp(t0 + 86422);
        uint256 price = _trialPrice(L);
        vm.prank(bot);
        uint256 id = nft.revealTrial{value: price}(L, user, 0, s);
        vm.prank(user);
        vm.expectRevert(PageNFT.AlreadyRegistered.selector);
        nft.reveal{value: fee}(L, user, 0, s);
        // the owner holds a trial of fourteen days that the watcher paid for, not a paid year
        assertEq(nft.ownerOf(id), user);
        assertEq(nft.depositOf(id), 0);
        assertEq(nft.expiresAt(id), t0 + 86422 + 14 days);
        (address payer, uint96 held) = nft.trialPaymentOf(id);
        assertEq(payer, bot);
        assertEq(held, price);
    }

    // a reveal that passed its simulation in the last block of the day lands in the next one and reverts
    // CommitmentTooOld, which makes its values public just the same; a watcher that commits for itself in that block,
    // ahead of the owner's new commitment, takes the name
    function test_revealLandingAfterTheDayLosesTheRace() public {
        uint256 t0 = vm.getBlockTimestamp();
        _commitPaid(user, L, user, 0);
        uint256 fee = nft.getFee(bytes(L).length);
        bytes32 s = _secret(L, user);
        vm.warp(t0 + 86402);
        vm.prank(user);
        vm.expectRevert(PageNFT.CommitmentTooOld.selector);
        nft.reveal{value: fee}(L, user, 0, s);
        bytes32 c = nft.makeCommitment(L, bot, 0, BOT_SECRET);
        vm.prank(bot);
        nft.commit(c);
        _commitPaid(user, L, user, 0);
        vm.warp(t0 + 86422);
        vm.prank(bot);
        uint256 id = nft.reveal{value: fee}(L, bot, 0, BOT_SECRET);
        // the owner's reveal in the same block fails on the fee, since the watcher's deposit now counts, and with that
        // deposit added it fails because the name is taken
        uint256 deposit = nft.depositOf(id);
        vm.prank(user);
        vm.expectRevert(PageNFT.InsufficientFee.selector);
        nft.reveal{value: fee}(L, user, 0, s);
        vm.prank(user);
        vm.expectRevert(PageNFT.AlreadyRegistered.selector);
        nft.reveal{value: fee + deposit}(L, user, 0, s);
        assertEq(nft.ownerOf(id), bot);
    }
}

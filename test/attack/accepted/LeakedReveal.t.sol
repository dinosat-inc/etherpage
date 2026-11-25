// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {PageNFT} from "../../../src/PageNFT.sol";
import {AcceptedBase} from "./AcceptedBase.sol";

// A reveal whose arguments are public before it lands, such as a multisig proposal waiting for signatures or an L1
// deposit on its way to OP, shows the label to everyone, and every reveal shows it to the RPC provider it is sent to
// and to the sequencer, which can hold it back. A watcher that commits for itself at that moment can reveal twenty
// seconds later and takes the name if the reveal has not landed by then, with a paid year or with a trial for
// itself. The reveal still wins if it lands before then, for example when it is sent again through another
// provider. The contracts cannot tell such a watcher from any other buyer.
contract AcceptedLeakedRevealTest is AcceptedBase {
    string constant L = "dao-name";
    address safe = makeAddr("safe");
    address bot = makeAddr("bot");
    bytes32 constant BOT_SECRET = bytes32("watcher");

    function setUp() public override {
        super.setUp();
        vm.deal(safe, 10 ether);
        vm.deal(bot, 10 ether);
    }

    // the safe commits at t0, its reveal is published at t0 + 120, and the watcher's commitment ripens at t0 + 140
    function test_publishedRevealLosesToAWatcherThatCommitsForItself() public {
        uint256 t0 = vm.getBlockTimestamp();
        _commitPaid(safe, L, safe, 0);
        vm.warp(t0 + 120);
        bytes32 c = nft.makeCommitment(L, bot, 0, BOT_SECRET);
        vm.prank(bot);
        nft.commit(c);
        uint256 fee = nft.getFee(bytes(L).length);
        bytes32 s = _secret(L, safe);

        // landing one second before the watcher's commitment ripens, the published reveal still wins
        uint256 snap = vm.snapshotState();
        vm.warp(t0 + 139);
        vm.prank(bot);
        vm.expectRevert(PageNFT.CommitmentTooNew.selector);
        nft.reveal{value: fee}(L, bot, 0, BOT_SECRET);
        vm.prank(safe);
        uint256 won = nft.reveal{value: fee}(L, safe, 0, s);
        assertEq(nft.ownerOf(won), safe);
        vm.revertToState(snap);

        vm.warp(t0 + 140);
        vm.prank(bot);
        uint256 id = nft.reveal{value: fee}(L, bot, 0, BOT_SECRET);
        // the published reveal lands at t0 + 720: with the price it expected it fails on the fee, since the
        // watcher's deposit now counts, and with the deposit added it fails because the name is taken
        vm.warp(t0 + 720);
        vm.prank(safe);
        vm.expectRevert(PageNFT.InsufficientFee.selector);
        nft.reveal{value: fee}(L, safe, 0, s);
        uint256 deposit = nft.depositOf(id);
        vm.prank(safe);
        vm.expectRevert(PageNFT.AlreadyRegistered.selector);
        nft.reveal{value: fee + deposit}(L, safe, 0, s);
        assertEq(nft.ownerOf(id), bot);
    }

    // the watcher can also take it with a trial for itself, for a tenth of the fee, which comes back to it
    function test_publishedRevealLosesToAWatchersTrial() public {
        uint256 t0 = vm.getBlockTimestamp();
        _commitPaid(safe, L, safe, 0);
        vm.warp(t0 + 120);
        _commitTrial(bot, L, bot, 0);
        vm.warp(t0 + 140);
        uint256 price = _trialPrice(L);
        bytes32 bs = _secret(L, bot);
        vm.prank(bot);
        uint256 id = nft.revealTrial{value: price}(L, bot, 0, bs);
        vm.warp(t0 + 720);
        uint256 fee = nft.getFee(bytes(L).length);
        bytes32 s = _secret(L, safe);
        vm.prank(safe);
        vm.expectRevert(PageNFT.AlreadyRegistered.selector);
        nft.reveal{value: fee}(L, safe, 0, s);
        assertEq(nft.ownerOf(id), bot);
        (address payer, uint96 held) = nft.trialPaymentOf(id);
        assertEq(payer, bot);
        assertEq(held, price);
    }
}

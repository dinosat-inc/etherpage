// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {PageNFT} from "../../../src/PageNFT.sol";
import {EdgesBase} from "./EdgesBase.sol";

// Anyone who learns the preimage of alice's commitment can complete her registration: the name goes to alice with
// the committed referrer and the completer pays. Her own paid reveal then has to pay the fee and the deposit the
// name now holds. Below that it reverts InsufficientFee, at or above it CommitmentNotFound, so with the quote she was
// given it reverts InsufficientFee unless that quote held a premium of at least one fee. Her own trial reveal finds
// no commitment. Every refusal leaves her money and the name as they were.
contract CompletedRevealOldQuoteTest is EdgesBase {
    // alice reveals her own commitment for alpha with value and expects err; nothing she holds changes
    function _ownRevealReverts(uint256 ref, uint256 value, bytes4 err) internal {
        uint256 id = nft.computeId("alpha");
        uint256 balance = alice.balance;
        uint256 deposit = nft.depositOf(id);
        bytes32 s = _secret("alpha", alice, ref);
        vm.prank(alice);
        vm.expectRevert(err);
        nft.reveal{value: value}("alpha", alice, ref, s);
        assertEq(alice.balance, balance, "alice keeps her money");
        assertEq(nft.ownerOf(id), alice, "the name stays hers");
        assertEq(nft.depositOf(id), deposit, "the deposit is unchanged");
    }

    function test_ownRevealAtTheOldQuoteRevertsInsufficientFee() public {
        uint256 ref = _buy(dave, "referrer", dave, 0);
        _commitPaid(alice, "alpha", alice, ref);
        vm.warp(vm.getBlockTimestamp() + 61);
        (uint256 fee,,, uint256 oldQuote) = nft.quote("alpha");
        assertEq(oldQuote, fee, "a fresh name costs the fee alone");

        // a watcher completes it with the preimage, overpaying, and gets its excess back
        bytes32 s = _secret("alpha", alice, ref);
        uint256 watcher = bob.balance;
        vm.prank(bob);
        uint256 id = nft.reveal{value: fee + 1 ether}("alpha", alice, ref, s);
        assertEq(nft.ownerOf(id), alice, "minted to the committed owner");
        assertEq(nft.referrerOf(id), ref, "with the committed referrer");
        assertEq(watcher - bob.balance, fee, "the completer paid the fee");
        assertEq(nft.depositOf(id), fee);

        _ownRevealReverts(ref, oldQuote, PageNFT.InsufficientFee.selector);
        uint256 need = fee + nft.depositOf(id);
        _ownRevealReverts(ref, need - 1, PageNFT.InsufficientFee.selector);
        _ownRevealReverts(ref, need, PageNFT.CommitmentNotFound.selector);
        _ownRevealReverts(ref, need + 1 ether, PageNFT.CommitmentNotFound.selector);
    }

    // the same over a lapsed name: the old quote is the fee, the carried deposit and the premium, and the new price is
    // the fee and the deposit the completion left, which is the carried deposit and one fee, so the outcome turns on
    // whether the premium was at least one fee
    function test_oldAuctionQuoteIsShortOnlyWhenItsPremiumIsUnderOneFee() public {
        uint256 id = _buy(carol, "alpha", carol, 0);
        uint256 year = nft.getFee(5);
        vm.prank(carol);
        nft.renew{value: year}(id);
        uint256 carried = nft.depositOf(id);
        assertEq(carried, 2 * year);
        uint256 p = nft.expiresAt(id) + GRACE + DECAY;
        uint256 snap = vm.snapshotState();

        // completed at P - 1, where the premium is under one fee
        vm.warp(p - 1 - 61);
        _commitPaid(alice, "alpha", alice, 0);
        vm.warp(p - 1);
        (uint256 fee,, uint256 premium, uint256 oldQuote) = nft.quote("alpha");
        assertGt(premium, 0);
        assertLt(premium, fee, "the premium at P - 1 is under one fee");
        bytes32 s = _secret("alpha", alice, 0);
        vm.prank(bob);
        nft.reveal{value: oldQuote}("alpha", alice, 0, s);
        assertEq(nft.ownerOf(id), alice);
        assertEq(nft.depositOf(id), carried + fee, "the carried deposit and the new fee");
        assertLt(oldQuote, fee + nft.depositOf(id));
        _ownRevealReverts(0, oldQuote, PageNFT.InsufficientFee.selector);
        _ownRevealReverts(0, fee + nft.depositOf(id), PageNFT.CommitmentNotFound.selector);

        // completed at G + 1, where the premium is near its top, so the old quote covers the new price
        vm.revertToState(snap);
        uint256 g = nft.expiresAt(id) + GRACE;
        vm.warp(g + 1 - 61);
        _commitPaid(alice, "alpha", alice, 0);
        vm.warp(g + 1);
        (fee,, premium, oldQuote) = nft.quote("alpha");
        assertGe(premium, fee);
        vm.prank(bob);
        nft.reveal{value: oldQuote}("alpha", alice, 0, s);
        assertEq(nft.ownerOf(id), alice);
        assertGe(oldQuote, fee + nft.depositOf(id));
        _ownRevealReverts(0, oldQuote, PageNFT.CommitmentNotFound.selector);
    }

    // a trial completed by a watcher records the watcher as payer; alice's own trial reveal finds no commitment
    function test_ownTrialRevealAfterACompletionFindsNoCommitment() public {
        _commitTrial(alice, "alpha", alice, 0);
        vm.warp(vm.getBlockTimestamp() + 61);
        uint256 price = _trialPrice("alpha");
        bytes32 s = _secret("alpha", alice, 0);
        vm.prank(bob);
        uint256 id = nft.revealTrial{value: price}("alpha", alice, 0, s);
        assertEq(nft.ownerOf(id), alice);
        (address payer, uint256 held) = _held(id);
        assertEq(payer, bob, "the completer is the payer");
        assertEq(held, price);
        uint256 balance = alice.balance;
        vm.prank(alice);
        vm.expectRevert(PageNFT.CommitmentNotFound.selector);
        nft.revealTrial{value: price}("alpha", alice, 0, s);
        assertEq(alice.balance, balance);
        (payer, held) = _held(id);
        assertEq(payer, bob, "the payer is unchanged");
    }
}

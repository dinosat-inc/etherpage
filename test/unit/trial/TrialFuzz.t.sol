// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {trialCommitment} from "../../utils/TrialCommitment.sol";

import {PageNFT} from "../../../src/PageNFT.sol";
import {TrialBase} from "../../utils/TrialBase.sol";

// random timings and lengths around one trial: the price is always held and then credited back to
// the relayer that paid it, a new trial waits out the pause, and the views agree
contract TrialFuzzTest is TrialBase {
    string[5] names = ["q", "qz", "qzx", "qzxw", "qzxwv"];

    function _views(string memory l, uint256 id) internal view {
        uint256 e = nft.expiresAt(id);
        uint256 t = vm.getBlockTimestamp();
        bool paid = nft.depositOf(id) != 0;
        uint256 graceEnd = paid ? e + 90 days : e;
        if (!paid) assertEq(nft.getPremium(id), 0, "no premium without a deposit");
        assertEq(nft.isAvailable(l, 0), t > graceEnd, "available exactly after the grace end");
        assertEq(nft.isExpired(id), t > graceEnd, "isExpired agrees");
        assertEq(nft.inGracePeriod(id), t > e && t <= graceEnd, "grace only when paid");
        (,,, uint256 total) = nft.quote(l);
        if (!paid) assertEq(total, nft.getFee(bytes(l).length), "a lapsed trial costs the plain fee");
    }

    function testFuzz_trialLife(uint256 li, uint256 d1, uint256 d2, bool convert, bool buy, bool retrial) public {
        string memory l = names[li % 5];
        uint256 fee = nft.getFee(bytes(l).length);
        uint256 price = fee / 10;
        d1 = bound(d1, 0, 16 days);
        d2 = bound(d2, 0, 600 days);
        bytes32 commitment = trialCommitment(address(nft), l, user, 0, _secret(l, user));
        vm.prank(relayer);
        nft.commit(commitment);
        vm.warp(vm.getBlockTimestamp() + 61);
        vm.prank(relayer);
        uint256 id = nft.revealTrial{value: price}(l, user, 0, _secret(l, user));
        assertEq(nft.owed(DEAD), 0);
        assertEq(_held(id), price);
        uint256 e = nft.expiresAt(id);
        assertEq(e, vm.getBlockTimestamp() + 14 days);
        _views(l, id);
        vm.warp(vm.getBlockTimestamp() + d1);
        _views(l, id);
        bool active = vm.getBlockTimestamp() <= e;
        if (convert) {
            vm.prank(carol);
            if (active) {
                nft.renew{value: fee}(id);
                assertEq(nft.depositOf(id), fee);
                assertEq(nft.expiresAt(id), e + 365 days);
                assertEq(nft.owed(relayer), price, "conversion credits the relayer");
                assertEq(_held(id), 0);
            } else {
                vm.expectRevert(PageNFT.Expired.selector);
                nft.renew{value: fee}(id);
            }
        }
        _views(l, id);
        if (nft.depositOf(id) == 0 && active) {
            vm.prank(user);
            vm.expectRevert(PageNFT.Unpaid.selector);
            nft.transferFrom(user, bob, id);
            vm.prank(user);
            vm.expectRevert(PageNFT.Unpaid.selector);
            nft.registerSubpage("s", id);
        }
        vm.warp(vm.getBlockTimestamp() + d2);
        _views(l, id);
        uint256 balBefore = address(nft).balance;
        bool wasPaid = nft.depositOf(id) != 0;
        if (retrial) {
            bytes32 commitment2 = trialCommitment(address(nft), l, bob, 0, _secret(l, bob));
            vm.prank(relayer);
            nft.commit(commitment2);
            vm.warp(vm.getBlockTimestamp() + 61);
            // a paid name takes a trial only after its auction, which first releases the deposit to the holder
            uint256 end = nft.expiresAt(id) + (wasPaid ? 111 days : 14 days);
            bool ok = nft.isAvailable(l, 0) && vm.getBlockTimestamp() > end;
            vm.prank(relayer);
            if (!ok) vm.expectRevert();
            nft.revealTrial{value: price}(l, bob, 0, _secret(l, bob));
            if (ok) {
                assertEq(nft.owed(DEAD), 0);
                assertEq(nft.owed(relayer), price, "the first price is credited back");
                assertEq(_held(id), price, "the second price is held");
                assertEq(nft.owed(user), wasPaid ? fee : 0, "the old holder gets back only its deposit");
                assertEq(nft.depositOf(id), 0);
            }
        } else if (buy && nft.isAvailable(l, 0)) {
            bytes32 commitment3 = nft.makeCommitment(l, bob, 0, _secret(l, bob));
            vm.prank(bob);
            nft.commit(commitment3);
            vm.warp(vm.getBlockTimestamp() + 61);
            uint256 auctionEnd = nft.expiresAt(id) + 111 days;
            (uint256 f, uint256 carried, uint256 premium, uint256 total) = nft.quote(l);
            vm.prank(bob);
            nft.reveal{value: total}(l, bob, 0, _secret(l, bob));
            if (!wasPaid) {
                assertEq(carried + premium, 0, "a trial is taken over at the plain fee");
                assertEq(nft.owed(user), 0, "the trial holder is credited nothing");
                assertEq(nft.owed(relayer), price, "only the trial payer is credited, its own price");
                assertEq(nft.owed(DEAD), 0);
            } else {
                assertEq(carried, vm.getBlockTimestamp() <= auctionEnd ? fee : 0, "a deposit is bought out only in the auction");
                assertEq(nft.owed(user), fee + premium - premium / 4, "the old holder gets its deposit either way");
            }
            assertEq(address(nft).balance, balBefore + total);
            assertEq(nft.depositOf(id), carried + f);
        }
        assertEq(
            address(nft).balance,
            nft.depositOf(id) + _held(id) + nft.owed(user) + nft.owed(DEAD) + nft.owed(carol) + nft.owed(bob)
                + nft.owed(relayer)
        );
    }

    function _held(uint256 id) internal view returns (uint256 a) {
        (, a) = nft.trialPaymentOf(id);
    }
}

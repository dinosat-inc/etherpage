// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {PageNFT} from "../../../src/PageNFT.sol";
import {AcceptedBase} from "./AcceptedBase.sol";

// reveal checks the price, counting the deposit it would take over, before it checks that the name is free. quote
// counts that deposit only once the grace period has ended, so paying quote().total for a paid name that is live
// or in grace reverts InsufficientFee, and only a payment that also covers the deposit reaches AlreadyRegistered.
// A trial holds no deposit, so the same payment for a live trial reverts AlreadyRegistered.
contract AcceptedPriceBeforeTakenTest is AcceptedBase {
    string constant L = "alice-smith";

    // the revert selector of a stranger's reveal of label at time t paying value, with a commitment made an hour
    // before, or zero when it succeeds; the state is restored afterwards
    function _revealAt(string memory label, uint256 t, uint256 value) internal returns (bytes4 err) {
        uint256 snap = vm.snapshotState();
        vm.warp(t - 1 hours);
        _commitPaid(stranger, label, stranger, 0);
        vm.warp(t);
        bytes memory data = abi.encodeCall(PageNFT.reveal, (label, stranger, 0, _secret(label, stranger)));
        vm.prank(stranger);
        (bool ok, bytes memory ret) = address(nft).call{value: value}(data);
        if (!ok) err = ret.length >= 4 ? bytes4(ret) : bytes4(0xffffffff);
        vm.revertToState(snap);
    }

    // at the last live second, the first and the last second of grace
    function test_quoteTotalForATakenPaidNameRevertsInsufficientFee() public {
        uint256 id = _buy(alice, L, alice, 0);
        uint256 fee = nft.getFee(bytes(L).length);
        uint256 deposit = nft.depositOf(id);
        assertEq(deposit, fee);
        uint256 e = nft.expiresAt(id);
        uint256[3] memory times = [e, e + 1, e + 90 days];
        for (uint256 i; i < 3; ++i) {
            vm.warp(times[i]);
            (uint256 qFee, uint256 carried, uint256 premium, uint256 total) = nft.quote(L);
            assertEq(qFee, fee);
            assertEq(carried + premium, 0, "the quote leaves the deposit out");
            assertEq(total, fee);
            assertFalse(nft.isAvailable(L, 0));
            assertEq(_revealAt(L, times[i], total), PageNFT.InsufficientFee.selector, "the quote fails on the price");
            assertEq(_revealAt(L, times[i], total + deposit), PageNFT.AlreadyRegistered.selector, "the deposit added");
        }
    }

    // once the grace period has ended the quote counts the deposit and the premium, and paying it registers
    function test_quoteTotalRegistersOnceGraceHasEnded() public {
        uint256 id = _buy(alice, L, alice, 0);
        uint256 deposit = nft.depositOf(id);
        uint256 t = nft.expiresAt(id) + 90 days + 1;
        vm.warp(t);
        (, uint256 carried, uint256 premium, uint256 total) = nft.quote(L);
        assertEq(carried, deposit);
        assertGt(premium, 0);
        assertTrue(nft.isAvailable(L, 0));
        assertEq(_revealAt(L, t, total - 1), PageNFT.InsufficientFee.selector);
        assertEq(_revealAt(L, t, total), bytes4(0));
    }

    // a live trial has no deposit, so paying its quote fails because the name is taken
    function test_quoteTotalForALiveTrialRevertsAlreadyRegistered() public {
        uint256 id = _trial(relayer, L, user, 0);
        uint256 t = nft.expiresAt(id);
        vm.warp(t);
        (, uint256 carried, uint256 premium, uint256 total) = nft.quote(L);
        assertEq(carried + premium, 0);
        assertEq(nft.depositOf(id), 0);
        assertEq(_revealAt(L, t, total), PageNFT.AlreadyRegistered.selector);
    }
}

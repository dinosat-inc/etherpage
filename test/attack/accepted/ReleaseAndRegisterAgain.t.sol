// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {PageNFT} from "../../../src/PageNFT.sol";
import {AcceptedBase} from "./AcceptedBase.sol";

// After the premium window the previous holder releases the deposit and registers the name again, paying the fee
// alone, so it keeps both the name and the money. What it risks is the lapse: through the grace period nobody else
// can register the name, and in the 21 days of the auction anyone can buy it at the falling premium. The new
// registration has a new epoch and record version, so nothing saved under the old one counts any more.
contract AcceptedReleaseAndRegisterAgainTest is AcceptedBase {
    string constant L = "alpha";

    // alice registers alpha and renews it twice; returns the id, the yearly fee and the deposit of three fees
    function _threeYears() internal returns (uint256 id, uint256 fee, uint256 deposit) {
        id = _buy(alice, L, alice, 0);
        fee = nft.getFee(bytes(L).length);
        vm.prank(alice);
        nft.renew{value: fee}(id);
        vm.prank(alice);
        nft.renew{value: fee}(id);
        deposit = nft.depositOf(id);
        assertEq(deposit, 3 * fee);
    }

    // alice commits again and registers alpha for herself at the quote, which must be the fee alone
    function _registerAgain(uint256 fee) internal returns (uint256 id) {
        _commitPaid(alice, L, alice, 0);
        vm.warp(vm.getBlockTimestamp() + 61);
        (uint256 f, uint256 carried, uint256 premium, uint256 total) = nft.quote(L);
        assertEq(carried, 0, "nothing to take over after the release");
        assertEq(premium, 0, "no premium after the window");
        assertEq(total, fee);
        assertEq(f, fee);
        bytes32 s = _secret(L, alice);
        vm.prank(alice);
        id = nft.reveal{value: total}(L, alice, 0, s);
    }

    function test_previousHolderReleasesThenRegistersAgainKeepingNameAndMoney() public {
        uint256 start = alice.balance;
        (uint256 id, uint256 fee, uint256 deposit) = _threeYears();
        uint256 g = nft.expiresAt(id) + 90 days;
        uint256 p = g + 21 days;

        // at the end of grace nobody else can register it
        vm.warp(g - 61);
        _commitPaid(bob, L, bob, 0);
        vm.warp(g);
        bytes32 bs = _secret(L, bob);
        vm.prank(bob);
        vm.expectRevert(PageNFT.AlreadyRegistered.selector);
        nft.reveal{value: 1 ether}(L, bob, 0, bs);

        // release is shut at the last second of the window and opens one second later, for alice herself
        vm.warp(p);
        vm.prank(alice);
        vm.expectRevert(PageNFT.NotReleasable.selector);
        nft.release(id);
        vm.warp(p + 1);
        vm.prank(alice);
        nft.release(id);
        assertEq(nft.depositOf(id), 0);
        assertEq(nft.owed(alice), deposit, "the deposit is credited to alice, its payee");

        assertEq(_registerAgain(fee), id);
        assertEq(nft.ownerOf(id), alice, "alice holds the name again");
        assertEq(nft.depositOf(id), fee, "with a fresh deposit of one fee");
        assertEq(nft.epochOf(id), 2, "in a new registration");
        assertEq(nft.recordVersion(id), 1);
        assertEq(nft.owed(alice), deposit, "the released money is untouched");

        vm.prank(stranger);
        nft.withdraw(alice);
        assertEq(nft.owed(alice), 0);
        // four fees paid, three back, and the fourth is the deposit of the name she holds
        assertEq(start - alice.balance, fee);
        assertEq(address(nft).balance, fee);
    }

    // with a saved main address the deposit goes to that address, and stays its own after alice registers again
    function test_releasePaysTheSavedMainAddressWhichKeepsItAfterTheNewRegistration() public {
        (uint256 id, uint256 fee, uint256 deposit) = _threeYears();
        vm.prank(alice);
        nft.setAddr(id, hot);
        vm.warp(nft.expiresAt(id) + 111 days + 1);
        vm.prank(alice);
        nft.release(id);
        assertEq(nft.owed(hot), deposit, "the payee is the saved main address");
        assertEq(nft.owed(alice), 0);
        _registerAgain(fee);
        assertEq(nft.ownerOf(id), alice);
        assertEq(nft.payee(id), alice, "the earlier save no longer counts in the new registration");
        assertEq(nft.owed(hot), deposit, "and the released money stays with it");
        uint256 before = hot.balance;
        nft.withdraw(hot);
        assertEq(hot.balance - before, deposit);
    }
}

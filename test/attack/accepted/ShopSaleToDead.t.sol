// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {AcceptedBase} from "./AcceptedBase.sol";

// A paid shop sale that names DEAD as the recipient is accepted. The payout is credited, the subpage is deleted as
// it arrives, and the label is for sale again at once, so a shop can be paid any number of times for one label.
// The buyer's loss is the loss of any payment to a name DEAD holds.
contract AcceptedShopSaleToDeadTest is AcceptedBase {
    // the price the holder sets for its subpages
    uint256 constant PRICE = 0.05 ether;
    uint256 club;

    function setUp() public override {
        super.setUp();
        club = _buy(alice, "club", alice, 0);
    }

    // the buyer names DEAD and buys through commit and reveal; then carol buys the same label. A top level name DEAD
    // holds is deleted too and resolves to nothing, so it never hands a buyer DEAD as a recipient
    function test_revealedSaleToDeadIsPaidDeletedAndSoldAgain() public {
        _openShop(club, PRICE, true);
        uint256 carolName = _buy(carol, "carol", carol, 0);
        vm.prank(carol);
        nft.transferFrom(carol, DEAD, carolName);
        assertEq(nft.resolve(carolName), address(0), "a top level name DEAD holds resolves to nothing");
        address to = DEAD;

        bytes32 s = keccak256("gift");
        bytes32 c = reg.makeSubpageCommitment(club, "gift", to, s);
        vm.prank(bob);
        reg.commitSubpage(c);
        vm.warp(vm.getBlockTimestamp() + 61);
        uint256 bobBefore = bob.balance;
        vm.prank(bob);
        uint256 sub = reg.revealSubpageFor{value: PRICE}(club, "gift", to, s, PRICE, address(0));
        assertEq(bobBefore - bob.balance, PRICE, "the buyer paid");
        assertEq(reg.proceedsOf(payout), PRICE, "the payout is credited");
        assertEq(nft.ownerOf(sub), DEAD);
        assertEq(nft.resolve(sub), address(0), "deleted on arrival");
        assertTrue(nft.isAvailable("gift", club), "the label is free again at once");

        c = reg.makeSubpageCommitment(club, "gift", carol, s);
        vm.prank(carol);
        reg.commitSubpage(c);
        vm.warp(vm.getBlockTimestamp() + 61);
        vm.prank(carol);
        uint256 again = reg.revealSubpageFor{value: PRICE}(club, "gift", carol, s, PRICE, address(0));
        assertEq(again, sub);
        assertEq(reg.proceedsOf(payout), 2 * PRICE, "paid twice for one label");
        assertEq(nft.ownerOf(sub), carol);
        assertEq(nft.resolve(sub), carol);
    }

    // a sale with no commitment names DEAD in the same way, and the label is free again for the next buyer
    function test_directSaleToDeadIsPaidDeletedAndSoldAgain() public {
        _openShop(club, PRICE, false);
        vm.prank(bob);
        uint256 sub = reg.registerSubpageFor{value: PRICE}(club, "gift", DEAD, PRICE, address(0));
        assertEq(reg.proceedsOf(payout), PRICE);
        assertEq(nft.ownerOf(sub), DEAD);
        assertEq(nft.resolve(sub), address(0), "deleted on arrival");
        assertTrue(nft.isAvailable("gift", club));
        vm.prank(carol);
        reg.registerSubpage{value: PRICE}(club, "gift", PRICE, address(0));
        assertEq(reg.proceedsOf(payout), 2 * PRICE, "paid twice for one label");
        assertEq(nft.ownerOf(sub), carol);
    }
}

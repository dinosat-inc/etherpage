// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {RulesBase} from "../utils/RulesBase.sol";
import {ReentrantToken} from "../utils/TokenMocks.sol";

// A sale priced in a token takes the price from the buyer, never from the account the subpage goes to.
contract SaleTokenPayerTest is RulesBase {
    // dave buys a subpage of bob's club for carol; both hold tokens and have approved the registrar, and
    // only dave pays
    function test_tokenPriceComesFromTheBuyerNotTheReceiver() public {
        ReentrantToken token = new ReentrantToken();
        uint256 club = _buy(bob, "club");
        vm.startPrank(bob);
        nft.setSubpageMinter(club, address(shop));
        shop.configure(club, bob, address(token), 5, true, address(0), 0, false);
        vm.stopPrank();
        token.mint(dave, 10);
        token.mint(carol, 10);
        vm.prank(dave);
        token.approve(address(shop), 10);
        vm.prank(carol);
        token.approve(address(shop), 10);

        vm.prank(dave);
        uint256 sub = shop.registerSubpageFor(club, "gift", carol, 5, address(token));
        assertEq(nft.ownerOf(sub), carol, "the subpage goes to carol");
        assertEq(token.balanceOf(dave), 5, "the buyer paid the price");
        assertEq(token.balanceOf(carol), 10, "the receiver paid nothing");
        assertEq(token.balanceOf(bob), 5, "the payout got the price");
        assertEq(shop.proceedsOf(bob), 0, "a token price is not held as proceeds");
    }
}

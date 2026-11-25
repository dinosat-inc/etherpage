// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {PageNFT} from "../../../src/PageNFT.sol";
import {SubpageRegistrar} from "../../../src/SubpageRegistrar.sol";
import {MinterBase} from "../../utils/MinterBase.sol";
import {trialCommitment} from "../../utils/TrialCommitment.sol";

// The holder of a trial sets up a shop during it: a config and a pick of the registrar, both of the trial's
// registration. The trial ends unpaid and the name is registered again, paid by a stranger, paid by the same holder,
// or as a new trial. The new registration has a new epoch, so the old config sells nothing: a sale reverts
// StaleConfig, also once the new holder picks the registrar, until the new holder configures again.
contract SaleOverEndedTrialTest is MinterBase {
    uint256 constant PRICE = 0.01 ether;
    address relayer = makeAddr("relayer");

    uint256 id;
    uint256 e;

    function setUp() public override {
        super.setUp();
        vm.deal(relayer, 1 ether);
        bytes32 secret = keccak256("first trial");
        bytes32 c = trialCommitment(address(nft), "alpha", alice, 0, secret);
        vm.prank(relayer);
        nft.commit(c);
        vm.warp(vm.getBlockTimestamp() + 61);
        uint256 price = nft.getFee(5) / 10;
        vm.prank(relayer);
        id = nft.revealTrial{value: price}("alpha", alice, 0, secret);
        e = nft.expiresAt(id);
        _sellSetup(id, PRICE);
        assertEq(nft.subpageMinterOf(id), address(reg), "the pick made during the trial counts");
        assertEq(nft.epochOf(id), 1);
    }

    // the sale the shop offers, by the buyer
    function _sale() internal {
        vm.prank(buyer);
        reg.registerSubpage{value: PRICE}(id, "kid", PRICE, address(0));
    }

    // who commits and registers alpha for itself at the quote, a new paid registration of the ended trial
    function _paidRegistration(address who) internal {
        bytes32 secret = keccak256(abi.encode("again", who));
        bytes32 c = nft.makeCommitment("alpha", who, 0, secret);
        vm.prank(who);
        nft.commit(c);
        vm.warp(vm.getBlockTimestamp() + 61);
        (,,, uint256 total) = nft.quote("alpha");
        vm.prank(who);
        nft.reveal{value: total}("alpha", who, 0, secret);
        assertEq(nft.epochOf(id), 2, "a new registration");
        assertGt(nft.depositOf(id), 0, "a paid name");
    }

    function test_strangersRegistrationLeavesTheTrialsShopStale() public {
        vm.warp(e + 1);
        _paidRegistration(bob);
        vm.expectRevert(SubpageRegistrar.StaleConfig.selector);
        _sale();
        _setMinter(id, address(reg));
        vm.expectRevert(SubpageRegistrar.StaleConfig.selector);
        _sale();
        assertTrue(nft.isAvailable("kid", id), "nothing was sold");
        assertEq(reg.proceedsOf(payout), 0);
    }

    function test_sameHoldersRegistrationLeavesTheTrialsShopStaleUntilItConfiguresAgain() public {
        vm.warp(e + 1);
        _paidRegistration(alice);
        assertEq(nft.subpageMinterOf(id), address(0), "the pick of the trial stops counting");
        vm.expectRevert(SubpageRegistrar.StaleConfig.selector);
        _sale();
        _setMinter(id, address(reg));
        vm.expectRevert(SubpageRegistrar.StaleConfig.selector);
        _sale();
        // a new config of this registration sells
        _configure(id, payout, address(0), PRICE, false);
        _sale();
        assertEq(reg.proceedsOf(payout), PRICE);
    }

    function test_newTrialOverTheEndedOneLeavesTheShopStale() public {
        vm.warp(e + 14 days + 1);
        bytes32 secret = keccak256("second trial");
        bytes32 c = trialCommitment(address(nft), "alpha", alice, 0, secret);
        vm.prank(relayer);
        nft.commit(c);
        vm.warp(vm.getBlockTimestamp() + 61);
        uint256 price = nft.getFee(5) / 10;
        vm.prank(relayer);
        nft.revealTrial{value: price}("alpha", alice, 0, secret);
        assertEq(nft.epochOf(id), 2);
        assertEq(nft.ownerOf(id), alice, "the same holder");
        vm.expectRevert(SubpageRegistrar.StaleConfig.selector);
        _sale();
    }

    // while the first trial runs, the same shop refuses with NotAvailable, and PageNFT itself with Unpaid
    function test_runningTrialSellsNothing() public {
        vm.expectRevert(SubpageRegistrar.NotAvailable.selector);
        _sale();
        vm.prank(address(reg));
        vm.expectRevert(PageNFT.Unpaid.selector);
        nft.registerSubpageFor("kid", id, buyer);
    }
}

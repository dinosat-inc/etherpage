// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Vm} from "forge-std/Test.sol";
import {PageNFT} from "../../../src/PageNFT.sol";
import {SubpageRegistrar, IPageNFT} from "../../../src/SubpageRegistrar.sol";
import {MinterBase} from "../../utils/MinterBase.sol";

// Edge cases: a pick at the expiry second, claims to zero, subpage parents, the registrar constructor
// and a zero payout.
contract MinterEdgesTest is MinterBase {
    uint256 club;

    function setUp() public override {
        super.setUp();
        club = _reg(alice, "club");
    }

    // a name counts as live up to and including its expiry second, so a minter can be picked then
    function test_pickAtTheExactExpirySecond() public {
        uint256 exp = nft.expiresAt(club);
        vm.warp(exp);
        vm.prank(alice);
        nft.setSubpageMinter(club, hot);
        assertEq(_minter(club), hot);
        vm.prank(hot);
        nft.registerSubpageFor("edge", club, carol);

        vm.warp(exp + 1);
        vm.prank(alice);
        vm.expectRevert(PageNFT.Expired.selector);
        nft.setSubpageMinter(club, hot2);
        // clearing still works one second later
        vm.prank(alice);
        nft.setSubpageMinter(club, address(0));
        assertEq(_minter(club), address(0));
    }

    // claimProceeds to address(0) pays the account itself, never the zero address
    function test_claimToZeroPaysTheAccount() public {
        _sellSetup(club, 0.02 ether);
        vm.prank(buyer);
        reg.registerSubpage{value: 0.02 ether}(club, "paid", 0.02 ether, address(0));
        uint256 before = payout.balance;
        vm.recordLogs();
        vm.prank(payout);
        uint256 paid = reg.claimProceeds(address(0));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(paid, 0.02 ether);
        assertEq(payout.balance, before + 0.02 ether);
        assertEq(address(0).balance, 0);
        assertEq(reg.proceedsOf(payout), 0);
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[1], bytes32(uint256(uint160(payout))));
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(payout))));
    }

    // a subpage can never be a selling parent: configure refuses it, so no enabled config exists
    // for it and a sale stops at NotEnabled before the registrar's own top level check
    function test_subpageParentNeverSells() public {
        _setMinter(club, alice);
        vm.prank(alice);
        uint256 sub = nft.registerSubpageFor("shop", club, alice);
        vm.prank(alice);
        vm.expectRevert(PageNFT.NotTopLevel.selector);
        nft.setSubpageMinter(sub, address(reg));
        vm.prank(alice);
        vm.expectRevert(SubpageRegistrar.ParentNotTopLevel.selector);
        reg.configure(sub, payout, address(0), 0, true, address(0), 0, false);
        vm.prank(buyer);
        vm.expectRevert(SubpageRegistrar.NotEnabled.selector);
        reg.registerSubpage(sub, "x", 0, address(0));
    }

    // the registrar refuses to bind to an address without code
    function test_constructorRefusesNoCode() public {
        vm.expectRevert(SubpageRegistrar.InvalidAddress.selector);
        new SubpageRegistrar(IPageNFT(address(0x1234)));
    }

    // a zero payout means the holder that configures
    function test_zeroPayoutMeansTheHolder() public {
        _setMinter(club, address(reg));
        vm.prank(alice);
        reg.configure(club, address(0), address(0), 0.01 ether, true, address(0), 0, false);
        (,,,,,,, address p,) = reg.config(club);
        assertEq(p, alice);
        vm.prank(buyer);
        reg.registerSubpage{value: 0.01 ether}(club, "zero", 0.01 ether, address(0));
        assertEq(reg.proceedsOf(alice), 0.01 ether);
    }
}

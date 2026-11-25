// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Vm} from "forge-std/Test.sol";
import {PageNFT} from "../../src/PageNFT.sol";
import {SubpageRegistrar} from "../../src/SubpageRegistrar.sol";
import {MinterBase} from "../utils/MinterBase.sol";
import {LogShapes} from "../utils/LogShapes.sol";

// holds names for its depositors and saves nothing
contract HoldingVault {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}

// A name registered again while it is stranded in the registrar or held by a vault pays the payee of the moment
// and gives the new holder full control at once, and the old minter pick and sale config never count again. A
// seller keeps no lever on a name it sold except switching its own minter pick off.
contract CustodyAndSellerTest is MinterBase {
    uint256 constant PRICE = 0.01 ether;

    struct Auction {
        uint256 carried;
        uint256 premium;
        uint256 id;
    }

    // who buys label one second into its premium window, plus the 61 seconds the helper waits after the commit
    function _auction(string memory label, address who) internal returns (Auction memory a) {
        a.id = _id(label);
        vm.warp(nft.expiresAt(a.id) + 90 days + 1);
        bytes32 secret = keccak256(abi.encode("again", label, who));
        bytes32 c = nft.makeCommitment(label, who, 0, secret);
        vm.prank(who);
        nft.commit(c);
        vm.warp(vm.getBlockTimestamp() + 61);
        uint256 total;
        (, a.carried, a.premium, total) = nft.quote(label);
        assertGt(a.premium, 0);
        vm.deal(who, who.balance + total);
        vm.prank(who);
        nft.reveal{value: total}(label, who, 0, secret);
    }

    // the new holder controls the name at once: it saves, picks a minter, mints, and sets up its own sale
    function _newHolderControls(uint256 id, address holder) internal {
        vm.startPrank(holder);
        nft.setAddr(id, holder);
        nft.setSubpageMinter(id, address(reg));
        nft.registerSubpage("own", id);
        reg.configure(id, holder, address(0), PRICE, true, address(0), 0, false);
        vm.stopPrank();
        vm.prank(buyer);
        reg.registerSubpage{value: PRICE}(id, "fresh", PRICE, address(0));
        assertEq(nft.ownerOf(_subId("fresh", id)), buyer);
    }

    // a name stranded in the registrar by a plain transfer, with a minter pick and an enabled sale config, is
    // registered again at auction: the credits go to the registrar, the payee read before the burn, and neither the
    // old pick nor the old config counts, also after the new holder picks the registrar
    function test_reRegistrationOverEveryCustodyState() public {
        uint256 gold = _reg(alice, "gold");
        _sellSetup(gold, PRICE);
        vm.prank(alice);
        nft.transferFrom(alice, address(reg), gold);
        assertEq(nft.payee(gold), address(reg));
        Auction memory a = _auction("gold", dave);
        assertEq(nft.ownerOf(gold), dave);
        assertEq(nft.owed(address(reg)), a.carried + a.premium - a.premium * 2500 / 10000, "the stranded name's payee");
        assertEq(nft.owed(alice), 0);
        (address m, uint64 e, address setter) = _raw(gold);
        assertEq(m, address(reg));
        assertEq(e, 1);
        assertEq(setter, alice);
        assertEq(nft.subpageMinterOf(gold), address(0), "the old pick does not count");
        vm.prank(buyer);
        vm.expectRevert(SubpageRegistrar.StaleConfig.selector);
        reg.registerSubpage{value: PRICE}(gold, "x", PRICE, address(0));
        vm.prank(dave);
        nft.setSubpageMinter(gold, address(reg));
        vm.prank(buyer);
        vm.expectRevert(SubpageRegistrar.StaleConfig.selector);
        reg.registerSubpage{value: PRICE}(gold, "x", PRICE, address(0));
        _newHolderControls(gold, dave);

        // a name held by a vault, whose depositor had picked a minter and set up a sale, registered again by that
        // same depositor: the vault is paid, and the depositor's old pick and config count for nobody
        uint256 silver = _reg(alice, "silver");
        _setMinter(silver, hot);
        _configure(silver, payout, address(0), PRICE, false);
        HoldingVault v = new HoldingVault();
        vm.prank(alice);
        nft.safeTransferFrom(alice, address(v), silver);
        a = _auction("silver", alice);
        assertEq(nft.ownerOf(silver), alice);
        assertEq(nft.owed(address(v)), a.carried + a.premium - a.premium * 2500 / 10000, "the vault, which held it");
        assertEq(nft.subpageMinterOf(silver), address(0), "the old pick does not count for the same account");
        vm.prank(hot);
        vm.expectRevert(PageNFT.NotParentOwner.selector);
        nft.registerSubpage("x", silver);
        vm.prank(buyer);
        vm.expectRevert(SubpageRegistrar.StaleConfig.selector);
        reg.registerSubpage{value: PRICE}(silver, "x", PRICE, address(0));
        _newHolderControls(silver, alice);
    }

    // after a sale the seller, the address it saved, the account it approved, its operator and the minter it picked
    // can write nothing, pick no minter, mint nothing and set up no sale; the payee stays the buyer. The seller can
    // only switch its own pick off, which changes nothing that counts, and not once the buyer has picked
    function test_sellerHasNoLeverAfterASale() public {
        uint256 club = _reg(alice, "club");
        address aliceMain = makeAddr("aliceMain");
        address appr = makeAddr("approved");
        address op = makeAddr("operator");
        vm.startPrank(alice);
        nft.setAddr(club, aliceMain);
        nft.setSubpageMinter(club, hot);
        nft.approve(appr, club);
        nft.setApprovalForAll(op, true);
        vm.stopPrank();
        _configure(club, payout, address(0), PRICE, false);
        vm.prank(alice);
        nft.transferFrom(alice, bob, club);
        assertEq(nft.payee(club), bob);

        address[5] memory levers = [alice, aliceMain, appr, op, hot];
        for (uint256 i; i < levers.length; ++i) {
            address a = levers[i];
            vm.startPrank(a);
            vm.expectRevert(PageNFT.Unauthorized.selector);
            nft.setAddr(club, a);
            vm.expectRevert(PageNFT.Unauthorized.selector);
            nft.setAddrForCoin(club, 60, abi.encodePacked(a));
            vm.expectRevert(PageNFT.Unauthorized.selector);
            nft.setText(club, "url", "x");
            vm.expectRevert(PageNFT.Unauthorized.selector);
            nft.setContenthash(club, hex"01");
            vm.expectRevert(PageNFT.Unauthorized.selector);
            nft.clearRecords(club);
            vm.expectRevert(PageNFT.Unauthorized.selector);
            nft.keepProfile(club);
            vm.expectRevert(PageNFT.Unauthorized.selector);
            nft.setSubpageMinter(club, a);
            vm.expectRevert(PageNFT.NotParentOwner.selector);
            nft.registerSubpage("x", club);
            vm.expectRevert(PageNFT.NotParentOwner.selector);
            nft.registerSubpageFor("x", club, a);
            vm.expectRevert(SubpageRegistrar.NotAuthorized.selector);
            reg.configure(club, a, address(0), 0, true, address(0), 0, false);
            vm.expectRevert(SubpageRegistrar.NotAuthorized.selector);
            reg.disable(club);
            vm.stopPrank();
        }
        // of the seller's levers, only the account that picked can switch the pick off
        for (uint256 i = 1; i < levers.length; ++i) {
            vm.prank(levers[i]);
            vm.expectRevert(PageNFT.Unauthorized.selector);
            nft.setSubpageMinter(club, address(0));
        }
        vm.recordLogs();
        vm.prank(alice);
        nft.setSubpageMinter(club, address(0));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(LogShapes.hashOf(logs[0]), LogShapes.minterSet(club, alice, address(0), 1));
        (address m, uint64 e, address setter) = _raw(club);
        assertEq(m, address(0));
        assertEq(e, 1);
        assertEq(setter, alice);
        assertEq(nft.subpageMinterOf(club), address(0));
        assertEq(nft.payee(club), bob);
        assertEq(nft.resolve(club), bob);
        // once the buyer picks, the seller cannot touch it
        vm.prank(bob);
        nft.setSubpageMinter(club, carol);
        assertEq(nft.subpageMinterOf(club), carol);
        vm.prank(alice);
        vm.expectRevert(PageNFT.Unauthorized.selector);
        nft.setSubpageMinter(club, address(0));
    }
}

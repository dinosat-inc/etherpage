// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Test, Vm} from "forge-std/Test.sol";
import {PageCard} from "../../../src/PageCard.sol";
import {PageNFT} from "../../../src/PageNFT.sol";
import {SubpageRegistrar, IPageNFT} from "../../../src/SubpageRegistrar.sol";

contract RegistrarTest is Test {
    PageCard card;
    PageNFT nft;
    SubpageRegistrar reg;

    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address carol = address(0xCA201);
    address payoutX = address(0x5AFE);

    function setUp() public {
        vm.warp(1_800_000_000);
        card = new PageCard();
        nft = new PageNFT(card);
        reg = new SubpageRegistrar(IPageNFT(address(nft)));
        vm.deal(alice, 1000 ether);
        vm.deal(bob, 1000 ether);
        vm.deal(carol, 1000 ether);
    }

    function _register(address who, string memory label) internal returns (uint256 id) {
        bytes32 secret = keccak256(abi.encode(who, label, block.timestamp));
        bytes32 commitment = nft.makeCommitment(label, who, 0, secret);
        vm.prank(who);
        nft.commit(commitment);
        vm.warp(vm.getBlockTimestamp() + 61);
        (,,, uint256 total) = nft.quote(label);
        vm.prank(who);
        id = nft.reveal{value: total}(label, who, 0, secret);
    }

    // a safe transfer into the registrar reverts, with or without data, and the parent stays put
    function test_safeTransferIntoRegistrarReverts() public {
        uint256 p = _register(alice, "parent");
        vm.startPrank(alice);
        nft.setAddr(p, payoutX);
        vm.expectRevert(bytes4(0xd1a57ed6));
        nft.safeTransferFrom(alice, address(reg), p, hex"00");
        vm.expectRevert(bytes4(0xd1a57ed6));
        nft.safeTransferFrom(alice, address(reg), p);
        vm.stopPrank();
        assertEq(nft.ownerOf(p), alice);
        assertEq(nft.payee(p), payoutX);
        assertEq(nft.resolve(p), payoutX);
    }

    // a sale through the minter: the parent never moves and the buyer gets back what it paid above the price
    function test_minterSale() public {
        uint256 p = _register(alice, "parent");
        vm.startPrank(alice);
        nft.setAddr(p, payoutX);
        nft.setSubpageMinter(p, address(reg));
        reg.configure(p, address(0), address(0), 0.01 ether, true, address(0), 0, false);
        vm.stopPrank();
        uint256 before = bob.balance;
        vm.recordLogs();
        vm.prank(bob);
        uint256 sub = reg.registerSubpage{value: 0.0125 ether}(p, "Shop", 0.01 ether, address(0));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 6);
        assertEq(before - bob.balance, 0.01 ether);
        assertEq(nft.ownerOf(sub), bob);
        assertEq(nft.getPageName(sub), "shop.parent");
        assertEq(nft.ownerOf(p), alice);
        assertEq(nft.payee(p), payoutX);
        assertEq(reg.proceedsOf(alice), 0.01 ether);
        assertEq(address(reg).balance, 0.01 ether);
    }

    // the commit and reveal path, through the minter
    function test_revealSale() public {
        uint256 p = _register(alice, "parent");
        vm.startPrank(alice);
        nft.setSubpageMinter(p, address(reg));
        reg.configure(p, address(0), address(0), 0, true, address(0), 0, true);
        vm.stopPrank();
        vm.prank(bob);
        vm.expectRevert(SubpageRegistrar.CommitRequired.selector);
        reg.registerSubpage(p, "shop", 0, address(0));
        bytes32 c = reg.makeSubpageCommitment(p, "Shop", bob, bytes32("s"));
        vm.prank(bob);
        reg.commitSubpage(c);
        vm.warp(vm.getBlockTimestamp() + 61);
        vm.prank(bob);
        uint256 sub = reg.revealSubpage(p, "Shop", bytes32("s"), 0, address(0));
        assertEq(nft.ownerOf(sub), bob);
    }

    // once the parent is registered again the former holder's config and minter pick give nothing,
    // and the new holder sells with no cleanup first
    function test_staleAfterReRegistration() public {
        uint256 p = _register(alice, "parent");
        vm.startPrank(alice);
        nft.setSubpageMinter(p, address(reg));
        reg.configure(p, address(0), address(0), 0, true, address(0), 0, false);
        vm.stopPrank();
        uint256 E = nft.expiresAt(p);
        vm.warp(E + 111 days + 10);
        _register(carol, "parent");
        assertEq(nft.ownerOf(p), carol);
        vm.prank(bob);
        vm.expectRevert(SubpageRegistrar.StaleConfig.selector);
        reg.registerSubpage(p, "x", 0, address(0));
        vm.startPrank(carol);
        nft.setSubpageMinter(p, address(reg));
        reg.configure(p, address(0), address(0), 0, true, address(0), 0, false);
        vm.stopPrank();
        vm.prank(alice);
        vm.expectRevert(SubpageRegistrar.NotAuthorized.selector);
        reg.configure(p, address(0), address(0), 0, true, address(0), 0, false);
        vm.prank(bob);
        reg.registerSubpage(p, "x", 0, address(0));
    }
}

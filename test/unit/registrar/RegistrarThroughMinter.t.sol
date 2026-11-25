// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {PageNFT} from "../../../src/PageNFT.sol";
import {PageCard} from "../../../src/PageCard.sol";
import {SubpageRegistrar, IPageNFT} from "../../../src/SubpageRegistrar.sol";

// The registrar sells only as the parent's minter in PageNFT, and the account that picked the
// minter can switch it off.
contract RegistrarThroughMinterTest is Test {
    bytes4 constant NON_RECEIVER = 0xd1a57ed6;
    bytes32 constant T_TRANSFER = keccak256("Transfer(address,address,uint256)");

    PageNFT nft;
    SubpageRegistrar reg;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address buyer = makeAddr("buyer");
    address hot = makeAddr("hot");

    function setUp() public {
        vm.warp(1_800_000_000);
        nft = new PageNFT(new PageCard());
        reg = new SubpageRegistrar(IPageNFT(address(nft)));
        vm.deal(alice, 1000 ether);
        vm.deal(bob, 1000 ether);
        vm.deal(buyer, 1000 ether);
    }

    function _reg(address who, string memory label) internal returns (uint256 id) {
        bytes32 secret = keccak256(abi.encode(who, label, block.timestamp));
        bytes32 commitment = nft.makeCommitment(label, who, 0, secret);
        vm.prank(who);
        nft.commit(commitment);
        vm.warp(block.timestamp + 61);
        (,,, uint256 total) = nft.quote(label);
        vm.prank(who);
        id = nft.reveal{value: total}(label, who, 0, secret);
    }

    function _sellSetup(uint256 id, uint256 price, bool commitReveal) internal {
        vm.startPrank(alice);
        nft.setSubpageMinter(id, address(reg));
        reg.configure(id, alice, address(0), price, true, address(0), 0, commitReveal);
        vm.stopPrank();
    }

    function test_saleNeverMovesTheParentOrTouchesDeposits() public {
        uint256 club = _reg(alice, "club");
        vm.prank(alice);
        nft.setAddr(club, bob);
        uint256 dep = nft.depositOf(club);
        uint256 nftBal = address(nft).balance;
        _sellSetup(club, 0.01 ether, false);

        vm.recordLogs();
        vm.prank(buyer);
        uint256 sub = reg.registerSubpage{value: 0.02 ether}(club, "Shop", 0.01 ether, address(0));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] == T_TRANSFER) assertTrue(uint256(logs[i].topics[3]) != club, "parent moved");
        }
        assertEq(nft.ownerOf(sub), buyer);
        assertEq(nft.ownerOf(club), alice);
        assertEq(nft.resolve(club), bob);
        assertEq(nft.payee(club), bob);
        assertEq(nft.depositOf(club), dep);
        assertEq(nft.depositOf(sub), 0);
        assertEq(address(nft).balance, nftBal);
        assertEq(nft.owed(address(reg)), 0);
        assertEq(reg.proceedsOf(alice), 0.01 ether);
        assertEq(address(reg).balance, 0.01 ether);
        assertEq(nft.isApprovedForAll(alice, address(reg)), false);
        assertEq(nft.getApproved(club), address(0));
    }

    function test_commitRevealSale() public {
        uint256 club = _reg(alice, "club");
        _sellSetup(club, 0, true);
        vm.prank(buyer);
        vm.expectRevert(SubpageRegistrar.CommitRequired.selector);
        reg.registerSubpage(club, "vip", 0, address(0));
        bytes32 s = keccak256("s");
        bytes32 c = reg.makeSubpageCommitment(club, "vip", buyer, s);
        vm.prank(buyer);
        reg.commitSubpage(c);
        vm.warp(block.timestamp + 61);
        vm.prank(buyer);
        uint256 sub = reg.revealSubpage(club, "vip", s, 0, address(0));
        assertEq(nft.ownerOf(sub), buyer);
    }

    function test_whyASaleStops() public {
        uint256 club = _reg(alice, "club");
        vm.prank(alice);
        reg.configure(club, alice, address(0), 0, true, address(0), 0, false);
        // configured but the registrar was never chosen as minter
        vm.prank(buyer);
        vm.expectRevert(SubpageRegistrar.NotMinter.selector);
        reg.registerSubpage(club, "a", 0, address(0));

        vm.prank(alice);
        nft.setSubpageMinter(club, address(reg));
        vm.prank(buyer);
        reg.registerSubpage(club, "a", 0, address(0));
        // a live label, the minter never overwrites
        vm.prank(buyer);
        vm.expectRevert(SubpageRegistrar.NotAvailable.selector);
        reg.registerSubpage(club, "a", 0, address(0));

        // the parent leaves: the config pauses first, with its own error
        vm.prank(alice);
        nft.transferFrom(alice, bob, club);
        vm.prank(buyer);
        vm.expectRevert(SubpageRegistrar.StaleController.selector);
        reg.registerSubpage(club, "b", 0, address(0));
        // bob picks the registrar but the old config is alice's
        vm.prank(bob);
        nft.setSubpageMinter(club, address(reg));
        vm.prank(buyer);
        vm.expectRevert(SubpageRegistrar.StaleController.selector);
        reg.registerSubpage(club, "b", 0, address(0));

        // a new registration: the config is dead for everyone
        vm.warp(nft.expiresAt(club) + 200 days);
        _reg(alice, "club");
        vm.prank(alice);
        nft.setSubpageMinter(club, address(reg));
        vm.prank(buyer);
        vm.expectRevert(SubpageRegistrar.StaleConfig.selector);
        reg.registerSubpage(club, "b", 0, address(0));
    }

    function test_nothingEntersTheRegistrar() public {
        uint256 club = _reg(alice, "club");
        uint256 gold = _reg(alice, "gold");
        vm.prank(alice);
        vm.expectRevert(NON_RECEIVER);
        nft.registerSubpageFor("gift", club, address(reg));
        vm.prank(alice);
        vm.expectRevert(NON_RECEIVER);
        nft.safeTransferFrom(alice, address(reg), club);

        bytes32 s = keccak256("t");
        bytes32 commitment = nft.makeCommitment("fresh", address(reg), 0, s);
        vm.prank(alice);
        nft.commit(commitment);
        vm.warp(block.timestamp + 61);
        (,,, uint256 total) = nft.quote("fresh");
        vm.prank(alice);
        vm.expectRevert(NON_RECEIVER);
        nft.reveal{value: total}("fresh", address(reg), 0, s);

        _sellSetup(club, 0, false);
        vm.prank(buyer);
        vm.expectRevert(SubpageRegistrar.NotAuthorized.selector);
        reg.registerSubpageFor(club, "x", address(reg), 0, address(0));

        // a plain transfer is the one route left
        vm.prank(alice);
        nft.transferFrom(alice, address(reg), gold);
        assertEq(nft.ownerOf(gold), address(reg));
    }

    function test_setterClearsWhileAway() public {
        uint256 club = _reg(alice, "club");
        _sellSetup(club, 0, false);
        vm.prank(alice);
        nft.transferFrom(alice, bob, club);
        vm.prank(alice);
        nft.setSubpageMinter(club, address(0));
        vm.prank(bob);
        nft.transferFrom(bob, alice, club);
        vm.prank(buyer);
        vm.expectRevert(SubpageRegistrar.NotMinter.selector);
        reg.registerSubpage(club, "back", 0, address(0));
        // an away setter can never choose, and a stranger can never clear
        vm.prank(alice);
        nft.transferFrom(alice, bob, club);
        vm.prank(alice);
        vm.expectRevert(PageNFT.Unauthorized.selector);
        nft.setSubpageMinter(club, hot);
        vm.prank(hot);
        vm.expectRevert(PageNFT.Unauthorized.selector);
        nft.setSubpageMinter(club, address(0));
    }

    function test_takeBackAndHotKey() public {
        uint256 club = _reg(alice, "club");
        _sellSetup(club, 0, false);
        vm.prank(buyer);
        uint256 sub = reg.registerSubpage(club, "member", 0, address(0));
        vm.prank(alice);
        nft.registerSubpageFor("member", club, alice); // take back, one call from the cold wallet
        assertEq(nft.ownerOf(sub), alice);

        vm.prank(alice);
        nft.setSubpageMinter(club, hot); // an app key mints, the parent stays put
        vm.prank(hot);
        uint256 m = nft.registerSubpageFor("guest", club, buyer);
        assertEq(nft.ownerOf(m), buyer);
        vm.prank(hot);
        vm.expectRevert(PageNFT.AlreadyRegistered.selector);
        nft.registerSubpageFor("member", club, hot);
        // the registrar is no longer the minter, so its sales stop with a clear error
        vm.prank(buyer);
        vm.expectRevert(SubpageRegistrar.NotMinter.selector);
        reg.registerSubpage(club, "x", 0, address(0));
    }
}

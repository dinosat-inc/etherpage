// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {PageNFT} from "../../../src/PageNFT.sol";
import {PageCard} from "../../../src/PageCard.sol";
import {SubpageRegistrar, IPageNFT} from "../../../src/SubpageRegistrar.sol";

// Anyone may renew a top level name sent to the dead address, nobody can mint under it, and once its grace ends
// it goes to auction like any other name. A name can also be minted straight to the dead address.
contract DeadHeldNamesTest is Test {
    PageNFT nft;
    SubpageRegistrar reg;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address owner = makeAddr("owner");
    address stranger = makeAddr("stranger");
    address buyer = makeAddr("buyer");

    function setUp() public {
        vm.warp(1_800_000_000);
        nft = new PageNFT(new PageCard());
        reg = new SubpageRegistrar(IPageNFT(address(nft)));
        vm.deal(owner, 100 ether);
        vm.deal(stranger, 1000 ether);
        vm.deal(buyer, 1000 ether);
    }

    function _reg(address from, string memory label, address to) internal returns (uint256 id, uint256 paid) {
        bytes32 secret = keccak256(abi.encode(from, label, to));
        bytes32 c = nft.makeCommitment(label, to, 0, secret);
        vm.prank(from);
        nft.commit(c);
        vm.warp(vm.getBlockTimestamp() + 61);
        (,,, uint256 total) = nft.quote(label);
        vm.prank(from);
        id = nft.reveal{value: total}(label, to, 0, secret);
        paid = total;
    }

    function test_deadHeldNameRenewsAndMintsNothing() public {
        string[3] memory labels = ["maple", "cedar", "birch"];
        for (uint256 i; i < 3; ++i) {
            (uint256 pid,) = _reg(owner, labels[i], owner);
            // a sale config and a minter pick written before the burn
            vm.startPrank(owner);
            reg.configure(pid, owner, address(0), 0, true, address(0), 0, false);
            nft.setSubpageMinter(pid, address(reg));
            nft.transferFrom(owner, DEAD, pid);
            vm.stopPrank();
            assertEq(nft.ownerOf(pid), DEAD);

            // renewal paid by a wallet that does not hold the name
            uint256 exp = nft.expiresAt(pid);
            uint256 dep = nft.depositOf(pid);
            uint256 fee = nft.getFee(bytes(labels[i]).length);
            vm.prank(stranger);
            nft.renew{value: fee}(pid);
            assertEq(nft.expiresAt(pid), exp + 365 days);
            assertEq(nft.depositOf(pid), dep + fee);

            // no direct mint, by the former holder or anyone else
            vm.prank(owner);
            vm.expectRevert(PageNFT.NotParentOwner.selector);
            nft.registerSubpage("alice", pid);
            vm.prank(stranger);
            vm.expectRevert(PageNFT.NotParentOwner.selector);
            nft.registerSubpageFor("alice", pid, stranger);

            // no registrar path: the config set before the burn is paused, nobody can configure, the minter is off
            vm.prank(stranger);
            vm.expectRevert(SubpageRegistrar.StaleController.selector);
            reg.registerSubpage(pid, "alice", 0, address(0));
            vm.prank(owner);
            vm.expectRevert(SubpageRegistrar.NotAuthorized.selector);
            reg.configure(pid, owner, address(0), 0, true, address(0), 0, false);
            address cm = nft.subpageMinterOf(pid);
            assertEq(cm, address(0));
            vm.prank(owner);
            vm.expectRevert(PageNFT.Unauthorized.selector);
            nft.setSubpageMinter(pid, owner);

            // the dotted string points at a subpage that does not exist
            uint256 sub = nft.computeId(string.concat("alice.", labels[i]));
            assertEq(nft.resolve(sub), address(0));
            // a name held by the dead address is not active, so the view calls no slot under it free
            assertFalse(nft.isAvailable("alice", pid));
            // and the renewed name itself answers nothing
            assertEq(nft.resolve(pid), address(0));
        }
    }

    function test_deadHeldNameLapsesToAuction() public {
        (uint256 pid,) = _reg(owner, "maple", owner);
        vm.prank(owner);
        nft.transferFrom(owner, DEAD, pid);
        uint256 dep = nft.depositOf(pid);
        vm.warp(nft.expiresAt(pid) + 90 days + 1 days);
        assertTrue(nft.isAvailable("maple", 0));
        uint256 deadBefore = nft.owed(DEAD);
        (uint256 id2, uint256 paid) = _reg(buyer, "maple", buyer);
        assertEq(id2, pid);
        assertEq(nft.ownerOf(pid), buyer);
        // paid is fee plus carried deposit plus premium, and all but the fee goes to the dead address
        uint256 fee = nft.getFee(bytes("maple").length);
        assertGt(paid, dep + fee);
        assertEq(nft.owed(DEAD) - deadBefore, paid - fee);
        vm.prank(buyer);
        uint256 sub = nft.registerSubpage("alice", pid);
        assertEq(nft.computeId("alice.maple"), sub);
        assertEq(nft.resolve(sub), buyer);
    }

    function test_mintStraightToDeadWorks() public {
        (uint256 pid,) = _reg(owner, "cedar", DEAD);
        assertEq(nft.ownerOf(pid), DEAD);
    }
}

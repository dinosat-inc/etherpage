// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Vm} from "forge-std/Test.sol";
import {PageNFT} from "../../../src/PageNFT.sol";
import {PageCard} from "../../../src/PageCard.sol";
import {MinterBase} from "../../utils/MinterBase.sol";

// A top level page held by the dead address answers nothing and shows Invalid, like a deleted subpage. Its renewal,
// its deposit and its subpages are unchanged. Its payee is the dead address, so its deposit is burned.
contract DeadHeldPagesTest is MinterBase {
    uint256 constant COIN_60 = 60;
    uint256 constant DEFAULT_EVM = 0x80000000;
    uint256 constant GRACE = 90 days;
    uint256 constant PREMIUM = 21 days;
    bytes32 constant T_ADDRESS = keccak256("AddressChanged(bytes32,uint256,bytes)");

    function _trialFor(address who, string memory label) internal returns (uint256 id) {
        bytes32 secret = keccak256(abi.encode(label));
        vm.prank(who);
        nft.commit(keccak256(abi.encode(bytes(label), who, uint256(0), secret, true)));
        vm.warp(vm.getBlockTimestamp() + 61);
        vm.prank(who);
        id = nft.revealTrial{value: nft.getFee(bytes(label).length) / 10}(label, who, 0, secret);
    }

    function test_everyReadIsEmptyAndTheStatusIsInvalid() public {
        uint256 id = _reg(alice, "gone");
        bytes32 node = bytes32(id);
        vm.startPrank(alice);
        nft.setAddr(id, hot);
        nft.setAddrForCoin(id, COIN_60, abi.encodePacked(hot2));
        nft.setText(id, "url", "x");
        nft.setContenthash(id, hex"e301");
        nft.setData(id, "k", hex"0102");
        vm.stopPrank();
        vm.prank(hot);
        nft.setPrimaryPage(id);
        assertEq(nft.reverseResolve(hot), "gone");

        vm.recordLogs();
        vm.prank(alice);
        nft.transferFrom(alice, DEAD, id);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 announced;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] != T_ADDRESS) continue;
            (, bytes memory v) = abi.decode(logs[i].data, (uint256, bytes));
            assertEq(v.length, 0, "the transfer announces empty addresses");
            ++announced;
        }
        assertEq(announced, 2, "the home chain and coin type 60");

        assertEq(nft.resolve(id), address(0));
        assertEq(nft.resolveAs(id, alice), address(0));
        assertEq(nft.addr(node), address(0));
        assertEq(nft.addr(id, COIN_OP).length, 0);
        assertEq(nft.addr(id, COIN_60).length, 0);
        assertEq(nft.text(id, "url"), "");
        assertEq(nft.text(node, "url"), "");
        assertEq(nft.contenthash(id).length, 0);
        assertEq(nft.data(node, "k").length, 0);
        assertEq(nft.reverseResolve(hot), "");
        assertEq(uint256(nft.status(id)), uint256(PageCard.Status.Invalid));
        nft.tokenURI(id);
    }

    // The same empty answers right after the move, at expiry, in grace, at the end of grace, in the premium period and
    // after it. Only the clock views, the price and the release follow the time.
    function test_everyPhaseUntilItIsRegisteredAgain() public {
        uint256 id = _reg(bob, "gold");
        vm.startPrank(bob);
        nft.setAddr(id, carol);
        nft.setAddrForCoin(id, DEFAULT_EVM, abi.encodePacked(hot));
        nft.setPrimaryPage(id);
        nft.setSubpageMinter(id, hot2);
        vm.stopPrank();
        vm.prank(carol);
        nft.setPrimaryPage(id);
        assertEq(nft.payee(id), carol);
        uint256 updatedAt = nft.addressesUpdatedAt(id);

        vm.warp(vm.getBlockTimestamp() + 7);
        uint256 movedAt = vm.getBlockTimestamp();
        vm.prank(bob);
        nft.transferFrom(bob, DEAD, id);
        assertEq(nft.holderSince(id), movedAt, "the move sets holderSince");
        assertEq(nft.addressesUpdatedAt(id), updatedAt, "and no address time");
        assertEq(nft.primaryPage(bob), 0, "the sender's display name is cleared");

        uint256 e = nft.expiresAt(id);
        uint256 dep = nft.depositOf(id);
        uint256[7] memory times =
            [movedAt, e, e + 1, e + GRACE, e + GRACE + 1, e + GRACE + PREMIUM, e + GRACE + PREMIUM + 1];
        for (uint256 i; i < times.length; ++i) {
            uint256 t = times[i];
            vm.warp(t);
            assertEq(nft.resolve(id), address(0), "resolve");
            assertEq(nft.addr(bytes32(id)), address(0), "addr with no coin type");
            assertEq(nft.addr(id, DEFAULT_EVM).length, 0, "the saved default");
            assertEq(nft.reverseResolve(bob), "", "the old holder's display name");
            assertEq(nft.reverseResolve(carol), "", "the old main address's display name");
            assertEq(uint256(nft.status(id)), uint256(PageCard.Status.Invalid), "Invalid in every phase");
            assertEq(nft.getPageName(id), "gold", "it keeps its name");
            assertEq(nft.payee(id), DEAD, "payee");
            assertEq(nft.subpageMinterOf(id), address(0), "no minter counts");
            assertFalse(nft.isAvailable("x", id), "no subpage label is free under it");
            assertEq(nft.isAvailable("gold", 0), t > e + GRACE, "taken until its grace period ends");
            assertEq(nft.inGracePeriod(id), t > e && t <= e + GRACE, "inGracePeriod follows the clock");
            bool inPremium = t > e + GRACE && t < e + GRACE + PREMIUM;
            assertEq(nft.getPremium(id) > 0, inPremium, "a premium in the premium period only");
            (uint256 fee, uint256 carried, uint256 premium, uint256 total) = nft.quote("gold");
            assertEq(fee, nft.getFee(4));
            assertEq(premium, nft.getPremium(id));
            assertEq(carried, t > e + GRACE && t <= e + GRACE + PREMIUM ? dep : 0, "the deposit a buyer pays");
            assertEq(total, fee + carried + premium);
            assertEq(nft.isReleasable(id), t > e + GRACE + PREMIUM, "releasable after the premium period");
        }
    }

    function test_renewalDepositAndRegistrationAgainAreUnchanged() public {
        uint256 id = _reg(alice, "gone");
        vm.prank(alice);
        nft.transferFrom(alice, DEAD, id);
        assertEq(nft.payee(id), DEAD, "its deposit still goes to the dead address");

        uint256 e0 = nft.expiresAt(id);
        vm.prank(stranger);
        nft.renew{value: 0.001 ether}(id);
        assertEq(nft.expiresAt(id), e0 + 365 days, "anyone may renew it");
        assertEq(uint256(nft.status(id)), uint256(PageCard.Status.Invalid));

        vm.warp(nft.expiresAt(id) + 1);
        assertEq(uint256(nft.status(id)), uint256(PageCard.Status.Invalid), "Invalid in the grace period");
        assertFalse(nft.isAvailable("gone", 0), "not free in the grace period");
        vm.warp(nft.expiresAt(id) + 90 days + 1);
        assertEq(uint256(nft.status(id)), uint256(PageCard.Status.Invalid), "Invalid after the grace period");
        assertTrue(nft.isAvailable("gone", 0), "free after the grace period");

        _lapseAndRegister(id, bob);
        assertEq(nft.ownerOf(id), bob);
        assertEq(nft.resolve(id), bob);
        assertEq(uint256(nft.status(id)), uint256(PageCard.Status.Active));
    }

    // Renewals add to its deposit, also in grace. A release, or a registration after the premium period, credits all
    // of it to the dead address, and withdraw burns it. The old main address gets nothing.
    function test_itsDepositIsBurned() public {
        uint256 id = _reg(bob, "gold");
        vm.prank(bob);
        nft.setAddr(id, carol);
        assertEq(nft.payee(id), carol);
        vm.prank(bob);
        nft.transferFrom(bob, DEAD, id);

        uint256 fee = nft.getFee(4);
        uint256 e0 = nft.expiresAt(id);
        vm.prank(stranger);
        nft.renew{value: fee}(id);
        vm.warp(e0 + 365 days + 1);
        assertTrue(nft.inGracePeriod(id));
        vm.prank(carol);
        nft.renew{value: fee}(id);
        assertEq(uint256(nft.status(id)), uint256(PageCard.Status.Invalid), "still deleted");
        uint256 e = nft.expiresAt(id);
        uint256 dep = nft.depositOf(id);
        assertEq(dep, 3 * fee, "the registration and two renewals");

        uint256 snap = vm.snapshotState();
        vm.warp(e + GRACE + PREMIUM);
        vm.expectRevert(PageNFT.NotReleasable.selector);
        nft.release(id);
        vm.warp(e + GRACE + PREMIUM + 1);
        vm.expectEmit(true, true, false, true, address(nft));
        emit PageNFT.DepositReleased(id, DEAD, dep);
        nft.release(id);
        assertEq(nft.owed(DEAD), dep, "the whole deposit goes to the dead address");
        assertEq(nft.owed(carol), 0, "nothing to the old main address");
        assertEq(nft.depositOf(id), 0);
        uint256 before = DEAD.balance;
        vm.prank(stranger);
        nft.withdraw(DEAD);
        assertEq(DEAD.balance - before, dep, "withdraw burns it");
        assertEq(address(nft).balance, 0, "nothing is left in the contract");
        assertEq(uint256(nft.status(id)), uint256(PageCard.Status.Invalid), "released, still Invalid");
        assertTrue(nft.isAvailable("gold", 0));

        // a registration after the premium period releases the old deposit to the dead address first
        vm.revertToState(snap);
        vm.warp(e + GRACE + PREMIUM + 1);
        (,,, uint256 total) = nft.quote("gold");
        assertEq(total, fee, "only the fee");
        assertEq(_reg(buyer, "gold"), id);
        assertEq(nft.owed(DEAD), dep);
        assertEq(nft.owed(carol), 0);
        assertEq(nft.depositOf(id), fee, "the new registration starts its own deposit");
        assertEq(nft.resolve(id), buyer);
    }

    // Its subpages keep working until it expires: they answer, take writes and move. Nobody can mint under it or take
    // a subpage back. Anyone may renew it to keep them, and they end with its expiry.
    function test_subpagesUnderItLiveUntilItExpires() public {
        uint256 shop = _reg(alice, "shop");
        vm.prank(alice);
        uint256 pay = nft.registerSubpageFor("pay", shop, bob);
        vm.prank(bob);
        nft.setText(pay, "url", "x");
        _setMinter(shop, carol);
        vm.prank(alice);
        nft.transferFrom(alice, DEAD, shop);
        assertEq(nft.resolve(shop), address(0));

        assertEq(nft.resolve(pay), bob, "the subpage keeps answering");
        assertEq(nft.text(pay, "url"), "x", "and keeps its profile");
        assertEq(uint256(nft.status(pay)), uint256(PageCard.Status.Active));
        vm.prank(bob);
        nft.setData(pay, "k", hex"01");
        assertEq(nft.data(bytes32(pay), "k"), hex"01", "its holder still writes");
        vm.prank(bob);
        nft.transferFrom(bob, dave, pay);
        assertEq(nft.resolve(pay), dave, "and it moves");

        // nobody can mint under it or take the subpage back: not the old holder, the minter it picked or a stranger
        assertFalse(nft.isAvailable("new", shop), "nobody can mint under it");
        assertFalse(nft.isAvailable("pay", shop));
        assertEq(nft.subpageMinterOf(shop), address(0), "the minter no longer counts");
        address[3] memory who = [alice, carol, stranger];
        for (uint256 i; i < who.length; ++i) {
            vm.startPrank(who[i]);
            vm.expectRevert(PageNFT.NotParentOwner.selector);
            nft.registerSubpage("new", shop);
            vm.expectRevert(PageNFT.NotParentOwner.selector);
            nft.registerSubpageFor("pay", shop, who[i]);
            vm.stopPrank();
        }
        assertEq(nft.ownerOf(pay), dave);

        // anyone may renew the parent, and its subpages live on with it to the last second of its registration
        uint256 e0 = nft.expiresAt(shop);
        vm.prank(stranger);
        nft.renew{value: 0.001 ether}(shop);
        uint256 e = nft.expiresAt(shop);
        assertEq(e, e0 + 365 days);
        vm.warp(e);
        assertEq(nft.resolve(pay), dave, "live at the parent's last second");
        assertEq(uint256(nft.status(pay)), uint256(PageCard.Status.Active));

        // it ends with the parent's expiry, and a renewal in grace brings it back
        vm.warp(e + 1);
        assertEq(nft.resolve(pay), address(0), "it ends with the parent's expiry");
        assertEq(uint256(nft.status(pay)), uint256(PageCard.Status.Grace));
        vm.prank(dave);
        vm.expectRevert(PageNFT.Expired.selector);
        nft.transferFrom(dave, bob, pay);
        vm.prank(dave);
        nft.renew{value: 0.001 ether}(shop);
        assertEq(nft.resolve(pay), dave, "the subpage's holder can renew the parent");

        // past the parent's grace period it is Expired, and Invalid once the parent is registered again
        vm.warp(nft.expiresAt(shop) + GRACE + 1);
        assertEq(nft.resolve(pay), address(0));
        assertEq(uint256(nft.status(pay)), uint256(PageCard.Status.Expired));
        _lapseAndRegister(shop, carol);
        assertEq(uint256(nft.status(pay)), uint256(PageCard.Status.Invalid));
        assertTrue(nft.isAvailable("pay", shop), "free for the new holder");
    }

    function test_aPageMintedStraightToTheDeadAddress() public {
        uint256 id = _regTo(alice, "straight", DEAD);
        assertEq(nft.ownerOf(id), DEAD);
        assertEq(nft.resolve(id), address(0));
        assertEq(uint256(nft.status(id)), uint256(PageCard.Status.Invalid));
    }

    // A trial has no grace period and no premium, so a trial given up is taken to the last second of its days and then
    // free.
    function test_aTrialGivenUpToTheDeadAddress() public {
        uint256 id = _trialFor(alice, "gone");
        vm.prank(alice);
        nft.setText(id, "url", "x");
        vm.prank(alice);
        nft.transferFrom(alice, DEAD, id);
        assertEq(nft.resolve(id), address(0));
        assertEq(nft.addr(id, COIN_OP).length, 0);
        assertEq(nft.text(id, "url"), "");
        assertEq(uint256(nft.status(id)), uint256(PageCard.Status.Invalid));

        uint256 e = nft.expiresAt(id);
        vm.warp(e);
        assertFalse(nft.isAvailable("gone", 0), "taken to its last second");
        vm.warp(e + 1);
        assertTrue(nft.isAvailable("gone", 0), "free at once after it");
        assertFalse(nft.inGracePeriod(id), "no grace period");
        assertEq(nft.getPremium(id), 0, "no premium");
        assertEq(uint256(nft.status(id)), uint256(PageCard.Status.Invalid));
    }

    // paid by anyone, a trial given up has a grace period like any paid page, and it stays deleted
    function test_aTrialGivenUpAndThenPaidForByAnyone() public {
        uint256 id = _trialFor(alice, "gone");
        vm.prank(alice);
        nft.transferFrom(alice, DEAD, id);
        vm.prank(stranger);
        nft.renew{value: nft.getFee(4)}(id);
        assertEq(nft.depositOf(id), nft.getFee(4));
        assertEq(nft.payee(id), DEAD, "its deposit will be burned");
        assertEq(uint256(nft.status(id)), uint256(PageCard.Status.Invalid), "paid, still deleted");
        vm.warp(nft.expiresAt(id) + 1);
        assertTrue(nft.inGracePeriod(id), "now it has a grace period");
        assertFalse(nft.isAvailable("gone", 0));
        assertEq(uint256(nft.status(id)), uint256(PageCard.Status.Invalid));
    }

    function test_nobodyCanWriteToItOrMoveIt() public {
        uint256 id = _reg(alice, "gone");
        vm.startPrank(alice);
        nft.approve(carol, id);
        nft.setApprovalForAll(dave, true);
        nft.transferFrom(alice, DEAD, id);
        vm.stopPrank();
        assertEq(nft.getApproved(id), address(0), "the move cleared the approval");

        // not the account approved before the move, not the old holder's operator
        vm.prank(carol);
        vm.expectRevert(PageNFT.Expired.selector);
        nft.transferFrom(DEAD, carol, id);
        vm.prank(dave);
        vm.expectRevert(PageNFT.Expired.selector);
        nft.transferFrom(DEAD, dave, id);

        // not the old holder, and not anyone holding the dead address's key, which nobody has
        address[2] memory who = [alice, DEAD];
        for (uint256 i; i < who.length; ++i) {
            vm.startPrank(who[i]);
            vm.expectRevert(PageNFT.Expired.selector);
            nft.setText(id, "url", "x");
            vm.expectRevert(PageNFT.Expired.selector);
            nft.setData(id, "k", hex"01");
            vm.expectRevert(PageNFT.Expired.selector);
            nft.setAddr(id, hot);
            vm.expectRevert(PageNFT.Expired.selector);
            nft.setAddrForCoin(id, COIN_60, abi.encodePacked(hot));
            vm.expectRevert(PageNFT.Expired.selector);
            nft.setContenthash(id, hex"01");
            vm.expectRevert(PageNFT.Expired.selector);
            nft.clearRecords(id);
            vm.expectRevert(PageNFT.Expired.selector);
            nft.keepProfile(id);
            vm.expectRevert(PageNFT.Expired.selector);
            nft.setPrimaryPage(id);
            vm.stopPrank();
        }
        vm.startPrank(DEAD);
        vm.expectRevert(PageNFT.Expired.selector);
        nft.transferFrom(DEAD, alice, id);
        vm.expectRevert(PageNFT.Expired.selector);
        nft.safeTransferFrom(DEAD, alice, id);
        vm.expectRevert(PageNFT.Expired.selector);
        nft.safeTransferFrom(DEAD, alice, id, "");
        vm.expectRevert(PageNFT.Expired.selector);
        nft.transferFrom(DEAD, DEAD, id);
        vm.stopPrank();

        // a bundle fails the same way
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeCall(PageNFT.setText, (id, "url", "y"));
        vm.prank(alice);
        vm.expectRevert(PageNFT.Expired.selector);
        nft.multicall(calls);
        assertEq(nft.ownerOf(id), DEAD);
    }

    // whatever the time, and whether anyone renewed it, it answers nothing and its money stays in its deposit
    function testFuzz_answersNothingAtAnyTime(uint32 dt, bool renewFirst) public {
        uint256 id = _reg(bob, "gold");
        vm.startPrank(bob);
        nft.setAddr(id, carol);
        nft.setAddrForCoin(id, COIN_60, abi.encodePacked(dave));
        nft.setText(id, "url", "x");
        nft.setData(id, "k", hex"01");
        nft.transferFrom(bob, DEAD, id);
        vm.stopPrank();
        if (renewFirst) {
            vm.prank(stranger);
            nft.renew{value: nft.getFee(4)}(id);
        }
        vm.warp(vm.getBlockTimestamp() + uint256(dt) % (3 * 365 days));
        assertEq(nft.resolve(id), address(0));
        assertEq(nft.addr(bytes32(id)), address(0));
        assertEq(nft.addr(id, COIN_OP).length, 0);
        assertEq(nft.text(id, "url"), "");
        assertEq(nft.data(bytes32(id), "k").length, 0);
        assertEq(uint256(nft.status(id)), uint256(PageCard.Status.Invalid));
        assertEq(nft.payee(id), DEAD);
        assertEq(nft.isAvailable("gold", 0), vm.getBlockTimestamp() > nft.expiresAt(id) + GRACE);
        assertEq(address(nft).balance, nft.depositOf(id), "its money stays in its deposit");
    }
}

// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Vm} from "forge-std/Test.sol";
import {PageNFT} from "../../../src/PageNFT.sol";
import {SubpageRegistrar} from "../../../src/SubpageRegistrar.sol";
import {MinterBase} from "../../utils/MinterBase.sol";
import {HookCaller, RefundHook, RejectETH, Holder721, NoHook, SafeLike, Delegate7702} from "../../utils/MinterMocks.sol";

// The registrar sells only as the parent's minter.
contract MinterRegistrarTest is MinterBase {
    uint256 club;

    function setUp() public override {
        super.setUp();
        club = _reg(alice, "club");
    }

    // one call: no parent Transfer, no parent address event, no approval anywhere
    function test_oneCallSaleTouchesNothingOfTheParent() public {
        vm.startPrank(alice);
        nft.setAddr(club, payout);
        nft.setAddrForCoin(club, 60, abi.encodePacked(dave));
        nft.setText(club, "url", "https://club");
        nft.setPrimaryPage(club);
        vm.stopPrank();
        _sellSetup(club, 0.01 ether);
        uint256 dep = nft.depositOf(club);
        uint256 nftBal = address(nft).balance;
        bytes memory before = abi.encode(
            nft.ownerOf(club), nft.resolve(club), nft.payee(club), nft.addr(club, 60), nft.text(club, "url"),
            nft.primaryPage(alice), nft.recordVersion(club), nft.tokenURI(club)
        );

        vm.recordLogs();
        vm.prank(buyer);
        uint256 sub = reg.registerSubpage{value: 0.01 ether}(club, "Shop", 0.01 ether, address(0));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Transfer(0, buyer, sub), the trio for sub, SubpageRegistered, SubpageSold, nothing else
        assertEq(logs.length, 6);
        assertEq(logs[0].topics[0], T_TRANSFER);
        assertEq(logs[0].topics[1], bytes32(0));
        assertEq(uint256(logs[0].topics[3]), sub);
        for (uint256 i = 1; i < 4; ++i) assertEq(logs[i].topics[1], bytes32(sub));
        assertEq(logs[4].topics[0], PageNFT.SubpageRegistered.selector);
        assertEq(logs[5].topics[0], SubpageRegistrar.SubpageSold.selector);
        assertEq(logs[5].emitter, address(reg));
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != T_APPROVAL && logs[i].topics[0] != T_APPROVAL_ALL);
            // no PageNFT event has the parent as its first indexed argument; SubpageRegistered and SubpageSold
            // carry it as parentId
            if (logs[i].emitter == address(nft) && logs[i].topics.length > 1) assertTrue(logs[i].topics[1] != bytes32(club));
            if (logs[i].topics[0] == T_TRANSFER) assertTrue(uint256(logs[i].topics[3]) != club);
        }
        bytes memory afterSale = abi.encode(
            nft.ownerOf(club), nft.resolve(club), nft.payee(club), nft.addr(club, 60), nft.text(club, "url"),
            nft.primaryPage(alice), nft.recordVersion(club), nft.tokenURI(club)
        );
        assertEq(keccak256(afterSale), keccak256(before));
        assertFalse(nft.isApprovedForAll(alice, address(reg)));
        assertEq(nft.getApproved(club), address(0));
        assertEq(nft.ownerOf(sub), buyer);
        assertEq(nft.getPageName(sub), "shop.club");
        assertEq(nft.depositOf(club), dep);
        assertEq(address(nft).balance, nftBal);
        assertEq(nft.balanceOf(address(reg)), 0);
    }

    // paid in ETH, with a refund to the payer only
    function test_paidSaleAndRefund() public {
        _sellSetup(club, 0.01 ether);
        uint256 b0 = buyer.balance;
        vm.prank(buyer);
        uint256 sub = reg.registerSubpageFor{value: 0.0125 ether}(club, "vip", carol, 0.01 ether, address(0));
        assertEq(nft.ownerOf(sub), carol);
        assertEq(b0 - buyer.balance, 0.01 ether);
        assertEq(carol.balance, 1000 ether);
        assertEq(reg.proceedsOf(payout), 0.01 ether);
        assertEq(reg.proceedsOf(buyer), 0);
        assertEq(address(reg).balance, 0.01 ether);
        vm.prank(buyer);
        vm.expectRevert(SubpageRegistrar.InsufficientFee.selector);
        reg.registerSubpage{value: 0.01 ether - 1}(club, "vip2", 0.01 ether, address(0));
        vm.prank(buyer);
        vm.expectRevert(SubpageRegistrar.PriceTooHigh.selector);
        reg.registerSubpage{value: 0.01 ether}(club, "vip2", 0.01 ether - 1, address(0));
        vm.prank(buyer);
        vm.expectRevert(SubpageRegistrar.UnexpectedFeeToken.selector);
        reg.registerSubpage{value: 0.01 ether}(club, "vip2", 0.01 ether, address(usd));
    }

    // free sale
    function test_freeSale() public {
        _sellSetup(club, 0);
        vm.prank(buyer);
        uint256 sub = reg.registerSubpage(club, "free", 0, address(0));
        assertEq(nft.ownerOf(sub), buyer);
        assertEq(reg.proceedsOf(payout), 0);
        assertEq(address(reg).balance, 0);
        // extra value on a free sale comes back at once
        uint256 b0 = buyer.balance;
        vm.prank(buyer);
        reg.registerSubpage{value: 1 ether}(club, "free2", 0, address(0));
        assertEq(buyer.balance, b0);
    }

    // ERC20 fee, pushed straight to the payout
    function test_erc20Fee() public {
        _setMinter(club, address(reg));
        _configure(club, payout, address(usd), 5e6, false);
        usd.mint(buyer, 10e6);
        vm.prank(buyer);
        usd.approve(address(reg), 5e6);
        vm.prank(buyer);
        vm.expectRevert(SubpageRegistrar.UnexpectedETH.selector);
        reg.registerSubpage{value: 1}(club, "coin", 5e6, address(usd));
        vm.prank(buyer);
        vm.expectRevert(SubpageRegistrar.UnexpectedFeeToken.selector);
        reg.registerSubpage(club, "coin", 5e6, address(0));
        vm.prank(buyer);
        uint256 sub = reg.registerSubpage(club, "coin", 5e6, address(usd));
        assertEq(nft.ownerOf(sub), buyer);
        assertEq(usd.balanceOf(payout), 5e6);
        assertEq(usd.balanceOf(address(reg)), 0);
        assertEq(reg.proceedsOf(payout), 0);
        // no allowance left: the pull fails and the whole sale reverts
        vm.prank(buyer);
        vm.expectRevert();
        reg.registerSubpage(club, "coin2", 5e6, address(usd));
        assertFalse(nft.isAvailable("coin2", club) == false);
    }

    // gated by an ERC20 balance and by holding Etherpage
    function test_gatedSales() public {
        _setMinter(club, address(reg));
        vm.prank(alice);
        reg.configure(club, payout, address(0), 0, true, address(usd), 100, false);
        vm.prank(buyer);
        vm.expectRevert(SubpageRegistrar.GateFailed.selector);
        reg.registerSubpage(club, "gated", 0, address(0));
        usd.mint(buyer, 100);
        vm.prank(buyer);
        reg.registerSubpage(club, "gated", 0, address(0));

        vm.prank(alice);
        reg.configure(club, payout, address(0), 0, true, address(nft), 1, false);
        vm.prank(buyer);
        reg.registerSubpage(club, "one", 0, address(0));
        vm.prank(alice);
        reg.configure(club, payout, address(0), 0, true, address(nft), 2, false);
        // the buyer now holds two Etherpage, gated.club and one.club, and the stranger holds none
        vm.prank(stranger);
        vm.expectRevert(SubpageRegistrar.GateFailed.selector);
        reg.registerSubpage(club, "two", 0, address(0));
        vm.prank(buyer);
        reg.registerSubpageFor(club, "two", stranger, 0, address(0));
        assertEq(nft.ownerOf(_subId("two", club)), stranger);
    }

    // commit and reveal, consumed once, with the timing errors
    function test_commitReveal() public {
        _setMinter(club, address(reg));
        _configure(club, payout, address(0), 0.01 ether, true);
        vm.prank(buyer);
        vm.expectRevert(SubpageRegistrar.CommitRequired.selector);
        reg.registerSubpage{value: 0.01 ether}(club, "vip", 0.01 ether, address(0));
        bytes32 s = keccak256("s");
        bytes32 c = reg.makeSubpageCommitment(club, "VIP", buyer, s);
        vm.prank(buyer);
        reg.commitSubpage(c);
        vm.prank(stranger);
        vm.expectRevert(SubpageRegistrar.AlreadyCommitted.selector);
        reg.commitSubpage(c);
        vm.prank(buyer);
        vm.expectRevert(SubpageRegistrar.CommitmentTooNew.selector);
        reg.revealSubpage{value: 0.01 ether}(club, "vip", s, 0.01 ether, address(0));
        vm.warp(vm.getBlockTimestamp() + 20);
        vm.prank(buyer);
        uint256 sub = reg.revealSubpage{value: 0.01 ether}(club, "Vip", s, 0.01 ether, address(0));
        assertEq(nft.ownerOf(sub), buyer);
        vm.prank(buyer);
        vm.expectRevert(SubpageRegistrar.CommitmentNotFound.selector);
        reg.revealSubpage{value: 0.01 ether}(club, "vip", s, 0.01 ether, address(0));
        bytes32 c2 = reg.makeSubpageCommitment(club, "late", buyer, s);
        vm.prank(buyer);
        reg.commitSubpage(c2);
        vm.warp(vm.getBlockTimestamp() + 86401);
        vm.prank(buyer);
        vm.expectRevert(SubpageRegistrar.CommitmentTooOld.selector);
        reg.revealSubpage{value: 0.01 ether}(club, "late", s, 0.01 ether, address(0));
        vm.expectRevert(SubpageRegistrar.NotAuthorized.selector);
        reg.makeSubpageCommitment(club, "x", address(reg), s);
    }

    // NotMinter: configured but no minter, another minter or a zero minter
    function test_notMinter() public {
        _configure(club, payout, address(0), 0, false);
        vm.prank(buyer);
        vm.expectRevert(SubpageRegistrar.NotMinter.selector);
        reg.registerSubpage(club, "a", 0, address(0));
        _setMinter(club, hot);
        vm.prank(buyer);
        vm.expectRevert(SubpageRegistrar.NotMinter.selector);
        reg.registerSubpage(club, "a", 0, address(0));
        _setMinter(club, address(reg));
        vm.prank(buyer);
        reg.registerSubpage(club, "a", 0, address(0));
        _setMinter(club, address(0));
        vm.prank(buyer);
        vm.expectRevert(SubpageRegistrar.NotMinter.selector);
        reg.registerSubpage(club, "b", 0, address(0));
        // an operator approval alone sells nothing
        vm.prank(alice);
        nft.setApprovalForAll(address(reg), true);
        vm.prank(buyer);
        vm.expectRevert(SubpageRegistrar.NotMinter.selector);
        reg.registerSubpage(club, "b", 0, address(0));
    }

    // after a sale of the parent the old config pauses, and the new holder's minter never sells it
    function test_staleControllerAndNewHolder() public {
        _sellSetup(club, 0);
        vm.prank(alice);
        nft.transferFrom(alice, bob, club);
        vm.prank(buyer);
        vm.expectRevert(SubpageRegistrar.StaleController.selector);
        reg.registerSubpage(club, "a", 0, address(0));
        vm.prank(bob);
        nft.setSubpageMinter(club, address(reg));
        vm.prank(buyer);
        vm.expectRevert(SubpageRegistrar.StaleController.selector);
        reg.registerSubpage(club, "a", 0, address(0));
        vm.prank(alice);
        vm.expectRevert(SubpageRegistrar.NotAuthorized.selector);
        reg.configure(club, alice, address(0), 0, true, address(0), 0, false);
        vm.prank(alice);
        vm.expectRevert(SubpageRegistrar.NotAuthorized.selector);
        reg.disable(club);
        // bob's own config sells to bob's payout
        vm.prank(bob);
        reg.configure(club, bob, address(0), 0.02 ether, true, address(0), 0, false);
        vm.prank(buyer);
        reg.registerSubpage{value: 0.02 ether}(club, "a", 0.02 ether, address(0));
        assertEq(reg.proceedsOf(bob), 0.02 ether);
        assertEq(reg.proceedsOf(payout), 0);
        // back with alice: bob's config is not alice's, alice's minter pick was replaced by bob's
        vm.prank(bob);
        nft.transferFrom(bob, alice, club);
        vm.prank(buyer);
        vm.expectRevert(SubpageRegistrar.StaleController.selector);
        reg.registerSubpage{value: 0.02 ether}(club, "b", 0.02 ether, address(0));
    }

    // config and minter revive together when the parent comes back to the account that set both
    function test_configAndMinterReviveTogether() public {
        _sellSetup(club, 0.01 ether);
        vm.prank(alice);
        nft.transferFrom(alice, bob, club);
        vm.prank(buyer);
        vm.expectRevert(SubpageRegistrar.StaleController.selector);
        reg.registerSubpage{value: 0.01 ether}(club, "a", 0.01 ether, address(0));
        vm.prank(bob);
        nft.transferFrom(bob, alice, club);
        vm.prank(buyer);
        reg.registerSubpage{value: 0.01 ether}(club, "a", 0.01 ether, address(0));
        assertEq(reg.proceedsOf(payout), 0.01 ether);
    }

    // switching off while away stops a sale that would otherwise revive
    function test_switchOffWhileAwayStopsRevivedSale() public {
        _sellSetup(club, 0.01 ether);
        vm.prank(alice);
        nft.transferFrom(alice, bob, club);
        vm.prank(alice);
        nft.setSubpageMinter(club, address(0));
        vm.prank(bob);
        nft.transferFrom(bob, alice, club);
        vm.prank(buyer);
        vm.expectRevert(SubpageRegistrar.NotMinter.selector);
        reg.registerSubpage{value: 0.01 ether}(club, "a", 0.01 ether, address(0));
    }

    // registering the parent again makes the old config stale, even for the same account: a sale reverts
    // StaleConfig, also after the minter is picked again, until the holder configures again
    function test_reRegistrationEndsTheSale() public {
        _sellSetup(club, 0);
        _lapseAndRegister(club, alice);
        vm.prank(buyer);
        vm.expectRevert(SubpageRegistrar.StaleConfig.selector);
        reg.registerSubpage(club, "a", 0, address(0));
        _setMinter(club, address(reg));
        vm.prank(buyer);
        vm.expectRevert(SubpageRegistrar.StaleConfig.selector);
        reg.registerSubpage(club, "a", 0, address(0));
        _configure(club, payout, address(0), 0, false);
        vm.prank(buyer);
        reg.registerSubpage(club, "a", 0, address(0));
    }

    // grace stops sales with NotAvailable and a renewal brings them back
    function test_graceStopsSales() public {
        _sellSetup(club, 0);
        vm.warp(nft.expiresAt(club) + 1);
        vm.prank(buyer);
        vm.expectRevert(SubpageRegistrar.NotAvailable.selector);
        reg.registerSubpage(club, "a", 0, address(0));
        vm.prank(stranger);
        nft.renew{value: 0.001 ether}(club);
        vm.prank(buyer);
        reg.registerSubpage(club, "a", 0, address(0));
    }

    // the registrar never takes back a live subpage, and a stale label sells
    function test_registrarNeverTakesBack() public {
        vm.prank(alice);
        uint256 live = nft.registerSubpageFor("live", club, carol);
        vm.prank(alice);
        uint256 old = nft.registerSubpageFor("old", club, carol);
        _setMinter(club, address(reg));
        _configure(club, payout, address(0), 0, false);
        vm.prank(buyer);
        vm.expectRevert(SubpageRegistrar.NotAvailable.selector);
        reg.registerSubpage(club, "live", 0, address(0));
        vm.prank(buyer);
        vm.expectRevert(SubpageRegistrar.NotAvailable.selector);
        reg.registerSubpage(club, "LIVE", 0, address(0));
        assertEq(nft.ownerOf(live), carol);
        // a stale label sells
        _lapseAndRegister(club, alice);
        _setMinter(club, address(reg));
        _configure(club, payout, address(0), 0, false);
        vm.prank(buyer);
        reg.registerSubpage(club, "old", 0, address(0));
        assertEq(nft.ownerOf(old), buyer);
    }

    // the error order of _sell, the minter check sitting right after StaleController
    function test_saleOrderPinned() public {
        _sellSetup(club, 0.01 ether);
        vm.prank(alice);
        nft.registerSubpageFor("taken", club, carol);
        // StaleController before NotMinter before NotAvailable
        vm.prank(alice);
        nft.transferFrom(alice, bob, club);
        vm.prank(buyer);
        vm.expectRevert(SubpageRegistrar.StaleController.selector);
        reg.registerSubpage(club, "taken", 0.01 ether, address(0));
        vm.prank(bob);
        nft.transferFrom(bob, alice, club);
        _setMinter(club, hot);
        vm.prank(buyer);
        vm.expectRevert(SubpageRegistrar.NotMinter.selector);
        reg.registerSubpage(club, "taken", 0.01 ether, address(0));
        _setMinter(club, address(reg));
        vm.prank(buyer);
        vm.expectRevert(SubpageRegistrar.NotAvailable.selector);
        reg.registerSubpage(club, "taken", 0.01 ether, address(0));
        // NotMinter before GateFailed and InsufficientFee
        _setMinter(club, hot);
        vm.prank(alice);
        reg.configure(club, payout, address(0), 0.01 ether, true, address(usd), 1, false);
        vm.prank(buyer);
        vm.expectRevert(SubpageRegistrar.NotMinter.selector);
        reg.registerSubpage(club, "fresh", 0.01 ether, address(0));
        // StaleConfig before StaleController and NotMinter
        uint256 id = _lapseAndRegister(club, bob);
        assertEq(id, club);
        vm.prank(buyer);
        vm.expectRevert(SubpageRegistrar.StaleConfig.selector);
        reg.registerSubpage(club, "fresh", 0.01 ether, address(0));
        // a bad label: InvalidLabel on the reveal path, NotAvailable on the direct path
        vm.prank(bob);
        nft.setSubpageMinter(club, address(reg));
        vm.prank(bob);
        reg.configure(club, payout, address(0), 0, true, address(0), 0, false);
        vm.prank(buyer);
        vm.expectRevert(SubpageRegistrar.NotAvailable.selector);
        reg.registerSubpage(club, "-bad", 0, address(0));
        vm.prank(buyer);
        vm.expectRevert(PageNFT.InvalidLabel.selector);
        reg.revealSubpage(club, "-bad", bytes32(0), 0, address(0));
    }

    // proceeds: claim, claim for, zero, the three uncreditable accounts, a rejecting account
    function test_claimProceedsAndClaimFor() public {
        _sellSetup(club, 0.01 ether);
        for (uint256 i; i < 3; ++i) {
            vm.prank(buyer);
            reg.registerSubpage{value: 0.01 ether}(club, string.concat("s", vm.toString(i)), 0.01 ether, address(0));
        }
        assertEq(reg.proceedsOf(payout), 0.03 ether);
        vm.recordLogs();
        vm.prank(stranger);
        uint256 paid = reg.claimProceedsFor(payout);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(paid, 0.03 ether);
        assertEq(payout.balance, 0.03 ether);
        assertEq(address(reg).balance, 0);
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], SubpageRegistrar.ProceedsClaimed.selector);
        assertEq(logs[0].topics[1], bytes32(uint256(uint160(payout))));
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(payout))));
        vm.expectRevert(SubpageRegistrar.NothingToClaim.selector);
        reg.claimProceedsFor(payout);
        address[5] memory never = [address(0), address(reg), address(nft), DEAD, stranger];
        for (uint256 i; i < 5; ++i) {
            vm.expectRevert(SubpageRegistrar.NothingToClaim.selector);
            reg.claimProceedsFor(never[i]);
        }
        // claimProceeds to another address
        vm.prank(buyer);
        reg.registerSubpage{value: 0.01 ether}(club, "s9", 0.01 ether, address(0));
        vm.prank(payout);
        vm.expectRevert(SubpageRegistrar.NotAuthorized.selector);
        reg.claimProceeds(address(reg));
        vm.prank(payout);
        reg.claimProceeds(carol);
        assertEq(carol.balance, 1000 ether + 0.01 ether);

        // a payout that rejects ETH is frozen for claimFor and can still claim elsewhere
        RejectETH rj = new RejectETH();
        vm.prank(alice);
        reg.configure(club, address(rj), address(0), 0.01 ether, true, address(0), 0, false);
        vm.prank(buyer);
        reg.registerSubpage{value: 0.01 ether}(club, "s10", 0.01 ether, address(0));
        vm.expectRevert(ETH_TRANSFER_FAILED);
        reg.claimProceedsFor(address(rj));
        assertEq(reg.proceedsOf(address(rj)), 0.01 ether);
        rj.claim(address(reg), dave);
        assertEq(dave.balance, 1000 ether + 0.01 ether);
        assertEq(address(reg).balance, 0);
    }

    // configure refuses the registrar and PageNFT as payout, before the other value checks
    function test_payoutRefusals() public {
        vm.startPrank(alice);
        vm.expectRevert(SubpageRegistrar.NotAuthorized.selector);
        reg.configure(club, address(reg), address(0), 0, true, address(0), 0, false);
        vm.expectRevert(SubpageRegistrar.NotAuthorized.selector);
        reg.configure(club, address(nft), address(0), 0, true, address(0), 0, false);
        vm.expectRevert(SubpageRegistrar.NotAuthorized.selector);
        reg.configure(club, address(nft), address(nft), uint256(type(uint96).max) + 1, true, address(0), 1, false);
        vm.expectRevert(SubpageRegistrar.BadFeeToken.selector);
        reg.configure(club, payout, address(nft), 0, true, address(0), 0, false);
        vm.expectRevert(SubpageRegistrar.ValueTooLarge.selector);
        reg.configure(club, payout, address(0), uint256(type(uint96).max) + 1, true, address(0), 0, false);
        vm.expectRevert(SubpageRegistrar.BadGateConfig.selector);
        reg.configure(club, payout, address(0), 0, true, address(usd), 0, false);
        reg.configure(club, DEAD, address(0), 0, true, address(0), 0, false);
        reg.configure(club, address(0), address(0), 0, true, address(0), 0, false);
        vm.stopPrank();
        (, , , , , , , address p,) = reg.config(club);
        assertEq(p, alice);
        // configure on a nonexistent parent and on a subpage
        vm.prank(alice);
        uint256 s = nft.registerSubpageFor("sub", club, alice);
        vm.prank(alice);
        vm.expectRevert(TOKEN_DOES_NOT_EXIST);
        reg.configure(_id("ghost"), payout, address(0), 0, true, address(0), 0, false);
        vm.prank(alice);
        vm.expectRevert(SubpageRegistrar.ParentNotTopLevel.selector);
        reg.configure(s, payout, address(0), 0, true, address(0), 0, false);
    }

    // disable by the holder only, and it keeps the controller
    function test_disable() public {
        _sellSetup(club, 0);
        vm.prank(hot);
        vm.expectRevert(SubpageRegistrar.NotAuthorized.selector);
        reg.disable(club);
        vm.prank(alice);
        reg.disable(club);
        (address controller, bool enabled,,,,,,,) = reg.config(club);
        assertEq(controller, alice);
        assertFalse(enabled);
        vm.prank(buyer);
        vm.expectRevert(SubpageRegistrar.NotEnabled.selector);
        reg.registerSubpage(club, "a", 0, address(0));
    }

    // nothing enters the registrar by a safe path, and a plain transferFrom strands the name there
    function test_nothingEntersSafelyAndPlainTransferStrands() public {
        _sellSetup(club, 0);
        uint256 gold = _reg(alice, "gold");
        vm.startPrank(alice);
        vm.expectRevert(NON_RECEIVER);
        nft.safeTransferFrom(alice, address(reg), gold);
        vm.expectRevert(NON_RECEIVER);
        nft.safeTransferFrom(alice, address(reg), gold, "");
        vm.expectRevert(NON_RECEIVER);
        nft.registerSubpageFor("gift", club, address(reg));
        vm.stopPrank();
        _setMinter(club, hot);
        vm.prank(hot);
        vm.expectRevert(NON_RECEIVER);
        nft.registerSubpageFor("gift", club, address(reg));
        bytes32 sec = keccak256("t");
        bytes32 commitment = nft.makeCommitment("fresh", address(reg), 0, sec);
        vm.prank(alice);
        nft.commit(commitment);
        vm.warp(vm.getBlockTimestamp() + 61);
        vm.prank(alice);
        vm.expectRevert(NON_RECEIVER);
        nft.reveal{value: 0.0001 ether}("fresh", address(reg), 0, sec);
        _setMinter(club, address(reg));
        vm.prank(buyer);
        vm.expectRevert(SubpageRegistrar.NotAuthorized.selector);
        reg.registerSubpageFor(club, "x", address(reg), 0, address(0));

        // the plain transfer: the registrar holds it, nobody controls it, payee is the registrar
        vm.prank(alice);
        nft.setAddr(gold, payout);
        vm.prank(alice);
        nft.transferFrom(alice, address(reg), gold);
        assertEq(nft.ownerOf(gold), address(reg));
        assertEq(nft.payee(gold), address(reg));
        assertEq(nft.resolve(gold), address(reg));
        vm.prank(alice);
        vm.expectRevert(SubpageRegistrar.NotAuthorized.selector);
        reg.configure(gold, alice, address(0), 0, true, address(0), 0, false);
        assertEq(_minter(gold), address(0));
        vm.prank(alice);
        vm.expectRevert(PageNFT.NotParentOwner.selector);
        nft.registerSubpage("x", gold);
        // at auction the carried deposit and 75 percent of the premium go to an account nobody can withdraw
        uint256 dep = nft.depositOf(gold);
        vm.prank(stranger);
        nft.renew{value: 0.001 ether}(club);
        vm.warp(nft.expiresAt(gold) + 90 days + 1 days);
        bytes32 bs = keccak256("bob");
        bytes32 commitment2 = nft.makeCommitment("gold", bob, 0, bs);
        vm.prank(bob);
        nft.commit(commitment2);
        vm.warp(vm.getBlockTimestamp() + 61);
        uint256 prem = nft.getPremium(gold);
        (,,, uint256 total) = nft.quote("gold");
        vm.prank(bob);
        nft.reveal{value: total}("gold", bob, 0, bs);
        assertEq(nft.owed(address(reg)), dep + (prem - prem * 2500 / 10000));
        vm.expectRevert(ETH_TRANSFER_FAILED);
        nft.withdraw(address(reg));

        // a subpage sent in plainly: the parent owner takes it back, the registrar never does
        vm.prank(alice);
        uint256 s = nft.registerSubpageFor("stuck", club, alice);
        vm.prank(alice);
        nft.transferFrom(alice, address(reg), s);
        vm.prank(buyer);
        vm.expectRevert(SubpageRegistrar.NotAvailable.selector);
        reg.registerSubpage(club, "stuck", 0, address(0));
        vm.prank(alice);
        nft.registerSubpageFor("stuck", club, alice);
        assertEq(nft.ownerOf(s), alice);
    }

    // reentry through the recipient's hook during a sale, on the direct and the reveal path
    function test_reentryThroughTheSaleRecipient() public {
        _sellSetup(club, 0.01 ether);
        HookCaller h = new HookCaller();
        bytes[6] memory calls = [
            abi.encodeCall(SubpageRegistrar.registerSubpageFor, (club, "again", address(h), 0.01 ether, address(0))),
            abi.encodeCall(SubpageRegistrar.claimProceedsFor, (payout)),
            abi.encodeCall(SubpageRegistrar.claimProceeds, (address(h))),
            abi.encodeCall(SubpageRegistrar.disable, (club)),
            abi.encodeCall(PageNFT.registerSubpageFor, ("again", club, address(h))),
            abi.encodeCall(SubpageRegistrar.revealSubpageFor, (club, "again", address(h), bytes32(0), 0, address(0)))
        ];
        address[6] memory targets = [address(reg), address(reg), address(reg), address(reg), address(nft), address(reg)];
        for (uint256 i; i < 6; ++i) {
            h.arm(targets[i], calls[i], false);
            vm.prank(buyer);
            reg.registerSubpageFor{value: 0.01 ether}(club, string.concat("r", vm.toString(i)), address(h), 0.01 ether, address(0));
            assertTrue(h.called());
            assertFalse(h.ok());
            assertEq(bytes4(h.ret()), REENTRANCY);
        }
        // commitSubpage is unguarded and harmless
        h.arm(address(reg), abi.encodeCall(SubpageRegistrar.commitSubpage, (keccak256("c"))), false);
        vm.prank(buyer);
        reg.registerSubpageFor{value: 0.01 ether}(club, "r9", address(h), 0.01 ether, address(0));
        assertTrue(h.ok());
        // the reveal path
        vm.prank(alice);
        reg.configure(club, payout, address(0), 0.01 ether, true, address(0), 0, true);
        bytes32 sec = keccak256("s");
        bytes32 subCommitment = reg.makeSubpageCommitment(club, "rv", address(h), sec);
        vm.prank(buyer);
        reg.commitSubpage(subCommitment);
        vm.warp(vm.getBlockTimestamp() + 61);
        h.arm(address(reg), calls[0], false);
        vm.prank(buyer);
        reg.revealSubpageFor{value: 0.01 ether}(club, "rv", address(h), sec, 0.01 ether, address(0));
        assertEq(bytes4(h.ret()), REENTRANCY);
        assertEq(reg.proceedsOf(payout), 0.08 ether);
    }

    // the buyer's refund hook cannot reenter: its claimProceedsFor gets Reentrancy, and the sale still completes
    function test_refundHookSeesFinishedSale() public {
        _sellSetup(club, 0.01 ether);
        RefundHook rh = new RefundHook();
        vm.deal(address(rh), 1 ether);
        rh.arm(address(reg), abi.encodeCall(SubpageRegistrar.claimProceedsFor, (payout)));
        bytes memory buy = abi.encodeCall(SubpageRegistrar.registerSubpage, (club, "rf", 0.01 ether, address(0)));
        rh.buy(address(reg), buy, 0.02 ether);
        assertTrue(rh.called());
        assertFalse(rh.ok());
        assertEq(bytes4(rh.ret()), REENTRANCY);
        assertEq(nft.ownerOf(_subId("rf", club)), address(rh));
        assertEq(address(rh).balance, 1 ether - 0.01 ether);
        assertEq(address(reg).balance, reg.proceedsOf(payout));
    }

    // a holder shaped like a Safe and a 7702 holder sell through the registrar
    function test_safeAnd7702HoldersSell() public {
        SafeLike safe = new SafeLike(alice);
        uint256 vault = _regTo(alice, "vault", address(safe));
        vm.startPrank(alice);
        safe.exec(address(nft), 0, abi.encodeCall(PageNFT.setSubpageMinter, (vault, address(reg))));
        safe.exec(
            address(reg), 0,
            abi.encodeCall(SubpageRegistrar.configure, (vault, address(0), address(0), 0.01 ether, true, address(0), 0, false))
        );
        vm.stopPrank();
        vm.prank(buyer);
        reg.registerSubpage{value: 0.01 ether}(vault, "a", 0.01 ether, address(0));
        assertEq(reg.proceedsOf(address(safe)), 0.01 ether);
        reg.claimProceedsFor(address(safe));
        assertEq(address(safe).balance, 0.01 ether);

        (address eoa, uint256 pk) = makeAddrAndKey("seller7702");
        Delegate7702 impl = new Delegate7702();
        vm.signAndAttachDelegation(address(impl), pk);
        vm.prank(stranger);
        (bool ok,) = eoa.call("");
        assertTrue(ok);
        uint256 p = _regTo(stranger, "seven", eoa);
        vm.startPrank(eoa);
        nft.setSubpageMinter(p, address(reg));
        reg.configure(p, address(0), address(0), 0.01 ether, true, address(0), 0, false);
        vm.stopPrank();
        vm.prank(buyer);
        reg.registerSubpage{value: 0.01 ether}(p, "b", 0.01 ether, address(0));
        reg.claimProceedsFor(eoa);
        assertEq(eoa.balance, 0.01 ether);
    }

    // a sale to a 7702 account whose delegate has no hook goes through, since its key can move the name;
    // a sale to a plain contract with no hook reverts and leaves the commitment
    function test_delegatedEoaBuyerReceivesAndContractBuyerReverts() public {
        _setMinter(club, address(reg));
        _configure(club, payout, address(0), 0, true);
        (address eoa, uint256 pk) = makeAddrAndKey("buyer7702");
        NoHook none = new NoHook();
        vm.signAndAttachDelegation(address(none), pk);
        vm.prank(stranger);
        // the delegate has no fallback, so this call fails, but the delegation stays in place
        (bool ok,) = eoa.call("");
        assertFalse(ok);
        assertEq(eoa.code.length, 23);
        bytes32 sec = keccak256("d");
        bytes32 c = reg.makeSubpageCommitment(club, "d", eoa, sec);
        vm.prank(buyer);
        reg.commitSubpage(c);
        vm.warp(vm.getBlockTimestamp() + 61);
        vm.prank(buyer);
        uint256 id = reg.revealSubpageFor(club, "d", eoa, sec, 0, address(0));
        assertEq(id, _subId("d", club));
        assertEq(nft.ownerOf(id), eoa);
        assertEq(reg.subCommitments(c), 0);
        vm.prank(eoa, eoa);
        nft.transferFrom(eoa, carol, id);
        assertEq(nft.ownerOf(id), carol);

        address plain = address(new NoHook());
        bytes32 c2 = reg.makeSubpageCommitment(club, "e", plain, sec);
        vm.prank(buyer);
        reg.commitSubpage(c2);
        vm.warp(vm.getBlockTimestamp() + 61);
        vm.prank(buyer);
        vm.expectRevert(NON_RECEIVER);
        reg.revealSubpageFor(club, "e", plain, sec, 0, address(0));
        assertTrue(reg.subCommitments(c2) != 0);
    }

    // the registrar mints only where a holder set it up, whatever a caller tries
    function testFuzz_registrarMintsOnlyWhereSetUp(address caller, uint8 which, string calldata label) public {
        vm.assume(caller != address(0) && caller.code.length == 0 && uint160(caller) > 0x10000);
        uint256 gold = _reg(bob, "gold");
        if (which % 4 == 0) _sellSetup(club, 0);
        else if (which % 4 == 1) _configure(club, payout, address(0), 0, false);
        else if (which % 4 == 2) _setMinter(club, address(reg));
        uint256[2] memory parents = [club, gold];
        uint256 p = parents[which % 2 == 0 ? 0 : 1];
        vm.prank(caller);
        (bool ok,) = address(reg).call(
            abi.encodeCall(SubpageRegistrar.registerSubpageFor, (p, label, caller, 0, address(0)))
        );
        if (ok) {
            assertEq(p, club);
            assertEq(which % 4, 0);
            assertEq(_minter(club), address(reg));
        }
        assertEq(nft.ownerOf(club), alice);
        assertEq(nft.ownerOf(gold), bob);
    }
}

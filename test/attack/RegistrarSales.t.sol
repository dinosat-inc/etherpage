// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Vm} from "forge-std/Test.sol";
import {PageNFT} from "../../src/PageNFT.sol";
import {SubpageRegistrar} from "../../src/SubpageRegistrar.sol";
import {MinterBase} from "../utils/MinterBase.sol";
import {HookCaller} from "../utils/MinterMocks.sol";
import {
    ReentrantToken,
    FalseToken,
    NoReturnToken,
    HolderWallet,
    TakeBackToken,
    RevertGate,
    WriteGate,
    ShortGate,
    LongGate,
    GasBurnGate,
    Hostile,
    RejectingBuyer,
    ForceSend
} from "../utils/TokenMocks.sol";

contract RegistrarSalesTest is MinterBase {
    uint256 club;
    uint256 zoo;
    bytes4 constant TRANSFER_FROM_FAILED = 0x7939f424; // TransferFromFailed()

    function setUp() public override {
        super.setUp();
        club = _reg(alice, "club");
        zoo = _reg(bob, "zoo");
    }

    function _now() internal view returns (uint256) {
        return vm.getBlockTimestamp();
    }

    function _cfg(uint256 id, address feeToken, uint256 price, address gate, uint256 minGate, bool cr) internal {
        vm.prank(nft.ownerOf(id));
        reg.configure(id, payout, feeToken, price, true, gate, minGate, cr);
    }

    function _buy(uint256 id, string memory label, uint256 value, uint256 maxPrice) internal returns (uint256) {
        vm.prank(buyer);
        return reg.registerSubpage{value: value}(id, label, maxPrice, address(0));
    }

    // order

    // steps 1 to 10 and 14 of _sell forced to fail in turn, steps 1 and 2 under zoo, which has no config, and
    // the rest under club. Step 6 holds the top level and epoch checks, step 7 the holder and minter checks
    function test_fullCheckOrder() public {
        bytes32 sec = keccak256("s");
        // 1: to is the registrar, even with no config at all
        vm.prank(buyer);
        vm.expectRevert(SubpageRegistrar.NotAuthorized.selector);
        reg.registerSubpageFor(zoo, "a", address(reg), 0, address(0));
        vm.prank(buyer);
        vm.expectRevert(SubpageRegistrar.NotAuthorized.selector);
        reg.revealSubpageFor(zoo, "a", address(reg), sec, 0, address(0));
        // 2: no config
        vm.prank(buyer);
        vm.expectRevert(SubpageRegistrar.NotEnabled.selector);
        reg.registerSubpage(zoo, "a", 0, address(0));

        // alice: config with commit and reveal and a gate, minter set, all in epoch 1
        _setMinter(club, address(reg));
        _cfg(club, address(0), 0.01 ether, address(usd), 5, true);
        // then the parent lapses and alice registers it again (epoch 2), and sends it to bob
        _lapseAndRegister(club, alice);
        vm.prank(alice);
        nft.transferFrom(alice, bob, club);
        vm.prank(bob);
        nft.registerSubpageFor("live", club, carol);

        // 3 and 4
        vm.prank(buyer);
        vm.expectRevert(SubpageRegistrar.UnexpectedFeeToken.selector);
        reg.registerSubpage{value: 0.01 ether}(club, "a", 0.01 ether, address(usd));
        vm.prank(buyer);
        vm.expectRevert(SubpageRegistrar.PriceTooHigh.selector);
        reg.registerSubpage{value: 0.01 ether}(club, "a", 0.01 ether - 1, address(0));
        // 5, direct
        vm.prank(buyer);
        vm.expectRevert(SubpageRegistrar.CommitRequired.selector);
        reg.registerSubpage{value: 0.01 ether}(club, "a", 0.01 ether, address(0));
        // 5, reveal: normalize first, then the commitment checks
        vm.prank(buyer);
        vm.expectRevert(PageNFT.InvalidLabel.selector);
        reg.revealSubpage{value: 0.01 ether}(club, "a_b", sec, 0.01 ether, address(0));
        vm.prank(buyer);
        vm.expectRevert(SubpageRegistrar.CommitmentNotFound.selector);
        reg.revealSubpage{value: 0.01 ether}(club, "a", sec, 0.01 ether, address(0));
        bytes32 c = reg.makeSubpageCommitment(club, "a", buyer, sec);
        vm.prank(buyer);
        reg.commitSubpage(c);
        vm.prank(buyer);
        vm.expectRevert(SubpageRegistrar.CommitmentTooNew.selector);
        reg.revealSubpage{value: 0.01 ether}(club, "a", sec, 0.01 ether, address(0));
        vm.warp(_now() + 86401);
        vm.prank(buyer);
        vm.expectRevert(SubpageRegistrar.CommitmentTooOld.selector);
        reg.revealSubpage{value: 0.01 ether}(club, "a", sec, 0.01 ether, address(0));
        vm.prank(buyer);
        reg.commitSubpage(c);
        vm.warp(_now() + 61);
        // 6: the config is from epoch 1 and bob holds: StaleConfig wins over StaleController and NotMinter
        vm.prank(buyer);
        vm.expectRevert(SubpageRegistrar.StaleConfig.selector);
        reg.revealSubpage{value: 0.01 ether}(club, "a", sec, 0.01 ether, address(0));
        assertEq(reg.subCommitments(c), _now() - 61, "a refused reveal keeps the commitment");

        // alice writes a config in epoch 2 while she holds it, then it goes to bob
        vm.prank(bob);
        nft.transferFrom(bob, alice, club);
        _cfg(club, address(0), 0.01 ether, address(usd), 5, true);
        vm.prank(alice);
        nft.transferFrom(alice, bob, club);
        // 7: bob holds, no counted minter: StaleController wins over NotMinter
        assertEq(_minter(club), address(0));
        vm.prank(buyer);
        vm.expectRevert(SubpageRegistrar.StaleController.selector);
        reg.revealSubpage{value: 0.01 ether}(club, "a", sec, 0.01 ether, address(0));
        // bob picks the registrar: still StaleController
        vm.prank(bob);
        nft.setSubpageMinter(club, address(reg));
        vm.prank(buyer);
        vm.expectRevert(SubpageRegistrar.StaleController.selector);
        reg.revealSubpage{value: 0.01 ether}(club, "a", sec, 0.01 ether, address(0));
        // back to alice: the minter is bob's pick, so NotMinter (bob's pick never counts for alice)
        vm.prank(bob);
        nft.transferFrom(bob, alice, club);
        vm.prank(buyer);
        vm.expectRevert(SubpageRegistrar.NotMinter.selector);
        reg.revealSubpage{value: 0.01 ether}(club, "a", sec, 0.01 ether, address(0));
        // alice picks the registrar herself in epoch 2, so the minter check passes from here on
        _setMinter(club, address(reg));
        // 8: a live label is NotAvailable before the gate
        bytes32 c2 = reg.makeSubpageCommitment(club, "live", buyer, sec);
        vm.prank(buyer);
        reg.commitSubpage(c2);
        vm.warp(_now() + 61);
        vm.prank(buyer);
        vm.expectRevert(SubpageRegistrar.NotAvailable.selector);
        reg.revealSubpage{value: 0.01 ether}(club, "live", sec, 0.01 ether, address(0));
        // 9
        vm.prank(buyer);
        vm.expectRevert(SubpageRegistrar.GateFailed.selector);
        reg.revealSubpage{value: 0.01 ether}(club, "a", sec, 0.01 ether, address(0));
        usd.mint(buyer, 5);
        // 10
        vm.prank(buyer);
        vm.expectRevert(SubpageRegistrar.InsufficientFee.selector);
        reg.revealSubpage{value: 0.01 ether - 1}(club, "a", sec, 0.01 ether, address(0));
        // 14: a refund to a buyer that rejects ETH undoes the whole sale and keeps the commitment
        RejectingBuyer rb = new RejectingBuyer();
        usd.mint(address(rb), 5);
        bytes32 c3 = reg.makeSubpageCommitment(club, "rb", address(rb), sec);
        reg.commitSubpage(c3);
        vm.warp(_now() + 61);
        vm.deal(address(rb), 1 ether);
        vm.expectRevert(ETH_TRANSFER_FAILED);
        rb.buy(
            address(reg),
            abi.encodeCall(reg.revealSubpage, (club, "rb", sec, 0.01 ether, address(0))),
            0.02 ether
        );
        assertEq(reg.subCommitments(c3), _now() - 61);
        assertTrue(nft.isAvailable("rb", club));
        // the exact price is accepted: no refund, so the same buyer succeeds
        rb.buy(
            address(reg),
            abi.encodeCall(reg.revealSubpage, (club, "rb", sec, 0.01 ether, address(0))),
            0.01 ether
        );
        assertEq(reg.subCommitments(c3), 0);
        assertEq(nft.ownerOf(_subId("rb", club)), address(rb));
        // the good sale
        uint256 id = _sale("a", sec);
        assertEq(nft.ownerOf(id), buyer);
        assertEq(reg.proceedsOf(payout), 0.02 ether);
        assertEq(address(reg).balance, 0.02 ether);
    }

    function _sale(string memory label, bytes32 sec) internal returns (uint256) {
        vm.prank(buyer);
        return reg.revealSubpage{value: 0.01 ether}(club, label, sec, 0.01 ether, address(0));
    }

    // ERC20 path: UnexpectedETH at step 10, TransferFromFailed at step 12 rolls back the mint
    function test_erc20OrderAndRollback() public {
        _setMinter(club, address(reg));
        _cfg(club, address(usd), 7, address(0), 0, false);
        vm.prank(buyer);
        vm.expectRevert(SubpageRegistrar.UnexpectedETH.selector);
        reg.registerSubpage{value: 1}(club, "a", 7, address(usd));
        // no allowance
        vm.prank(buyer);
        vm.expectRevert(TRANSFER_FROM_FAILED);
        reg.registerSubpage(club, "a", 7, address(usd));
        assertTrue(nft.isAvailable("a", club), "mint rolled back");
        // a token that returns false
        FalseToken ft = new FalseToken();
        _cfg(club, address(ft), 7, address(0), 0, false);
        vm.prank(buyer);
        vm.expectRevert(TRANSFER_FROM_FAILED);
        reg.registerSubpage(club, "a", 7, address(ft));
        // a fee token with no code at all
        address eoa = makeAddr("eoaToken");
        _cfg(club, eoa, 7, address(0), 0, false);
        vm.prank(buyer);
        vm.expectRevert(TRANSFER_FROM_FAILED);
        reg.registerSubpage(club, "a", 7, eoa);
        // a token with no return data sells
        NoReturnToken nr = new NoReturnToken();
        nr.mint(buyer, 7);
        _cfg(club, address(nr), 7, address(0), 0, false);
        vm.prank(buyer);
        reg.registerSubpage(club, "a", 7, address(nr));
        assertEq(nr.balanceOf(payout), 7);
        // the PageNFT and the registrar are refused as fee tokens
        vm.prank(alice);
        vm.expectRevert(SubpageRegistrar.BadFeeToken.selector);
        reg.configure(club, payout, address(nft), 7, true, address(0), 0, false);
        vm.prank(alice);
        vm.expectRevert(SubpageRegistrar.BadFeeToken.selector);
        reg.configure(club, payout, address(reg), 7, true, address(0), 0, false);
        // a price of zero with a fee token calls nothing
        _cfg(club, address(ft), 0, address(0), 0, false);
        vm.prank(buyer);
        reg.registerSubpage(club, "zero", 0, address(ft));
        assertEq(address(reg).balance, 0);
    }

    // calls back in through the fee token

    function test_reentrantFeeToken() public {
        ReentrantToken t = new ReentrantToken();
        t.mint(buyer, 100);
        vm.prank(buyer);
        t.approve(address(reg), type(uint256).max);
        _setMinter(club, address(reg));
        _cfg(club, address(t), 1, address(0), 0, false);

        bytes[6] memory calls = [
            abi.encodeCall(reg.registerSubpageFor, (club, "x", address(t), 1, address(t))),
            abi.encodeCall(reg.revealSubpageFor, (club, "x", address(t), bytes32(0), 1, address(t))),
            abi.encodeCall(reg.configure, (club, address(t), address(0), 0, true, address(0), 0, false)),
            abi.encodeCall(reg.disable, (club)),
            abi.encodeCall(reg.claimProceeds, (address(t))),
            abi.encodeCall(reg.claimProceedsFor, (payout))
        ];
        for (uint256 i; i < calls.length; ++i) {
            t.arm(address(reg), calls[i]);
            string memory label = string.concat("r", vm.toString(i));
            vm.prank(buyer);
            reg.registerSubpage(club, label, 1, address(t));
            assertTrue(t.called());
            assertFalse(t.ok(), "registrar guard");
            assertEq(bytes4(t.ret()), REENTRANCY);
        }
        // the token acting as itself on PageNFT has no power under the parent
        t.arm(address(nft), abi.encodeCall(nft.registerSubpageFor, ("live", club, address(t))));
        vm.prank(buyer);
        reg.registerSubpage(club, "r9", 1, address(t));
        assertFalse(t.ok());
        assertEq(bytes4(t.ret()), PageNFT.NotParentOwner.selector);
        // commitSubpage has no guard: it runs, and changes nothing that a sale reads
        t.arm(address(reg), abi.encodeCall(reg.commitSubpage, (bytes32(uint256(1)))));
        vm.prank(buyer);
        reg.registerSubpage(club, "r10", 1, address(t));
        assertTrue(t.ok());
        assertEq(t.balanceOf(payout), 8);
        assertEq(reg.proceedsOf(payout), 0);
        assertEq(address(reg).balance, 0);
    }

    // a holder can take a sold subpage back inside the sale itself, through its own fee token.
    // Minting over its own subpages is the holder's power, and the minter does not change it.
    function test_holderTakesBackInsideTheSale() public {
        HolderWallet w = new HolderWallet(alice, address(nft));
        vm.prank(alice);
        nft.transferFrom(alice, address(w), club);
        TakeBackToken t = new TakeBackToken();
        t.mint(buyer, 100);
        vm.prank(buyer);
        t.approve(address(reg), type(uint256).max);
        vm.startPrank(alice);
        w.exec(address(nft), 0, abi.encodeCall(nft.setSubpageMinter, (club, address(reg))));
        w.exec(
            address(reg), 0, abi.encodeCall(reg.configure, (club, payout, address(t), 10, true, address(0), 0, false))
        );
        vm.stopPrank();
        t.set(w, "gold", club);
        vm.recordLogs();
        vm.prank(buyer);
        uint256 id = reg.registerSubpage(club, "gold", 10, address(t));
        // the buyer paid and holds nothing
        assertEq(t.balanceOf(payout), 10);
        assertEq(t.balanceOf(buyer), 90);
        assertEq(nft.ownerOf(id), address(w));
        assertEq(nft.balanceOf(buyer), 0);
        // and SubpageSold still names the buyer
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool sold;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == SubpageRegistrar.SubpageSold.selector) {
                sold = true;
                assertEq(address(uint160(uint256(logs[i].topics[3]))), buyer);
            }
        }
        assertTrue(sold);
    }

    // gates

    function test_gates() public {
        _setMinter(club, address(reg));
        // PageNFT as the gate counts the buyer's names, not the recipient's
        _cfg(club, address(0), 0, address(nft), 1, false);
        vm.prank(buyer);
        vm.expectRevert(SubpageRegistrar.GateFailed.selector);
        reg.registerSubpageFor(club, "a", bob, 0, address(0));
        vm.prank(bob);
        reg.registerSubpageFor(club, "a", buyer, 0, address(0));
        assertEq(nft.ownerOf(_subId("a", club)), buyer);

        address[3] memory bad = [address(new RevertGate()), address(new WriteGate()), address(new ShortGate())];
        for (uint256 i; i < 3; ++i) {
            _cfg(club, address(0), 0, bad[i], 1, false);
            vm.prank(bob);
            vm.expectRevert(SubpageRegistrar.GateFailed.selector);
            reg.registerSubpage(club, "b", 0, address(0));
        }
        // an EOA gate reads as zero
        _cfg(club, address(0), 0, makeAddr("eoaGate"), 1, false);
        vm.prank(bob);
        vm.expectRevert(SubpageRegistrar.GateFailed.selector);
        reg.registerSubpage(club, "b", 0, address(0));
        // a longer answer: only the first word counts
        _cfg(club, address(0), 0, address(new LongGate()), type(uint96).max, false);
        vm.prank(bob);
        reg.registerSubpage(club, "b", 0, address(0));
        // a gate that burns all gas: the sale cannot complete, nothing changes
        _cfg(club, address(0), 0, address(new GasBurnGate()), 1, false);
        vm.prank(bob);
        (bool ok,) = address(reg).call{gas: 2_000_000}(abi.encodeCall(reg.registerSubpage, (club, "c", 0, address(0))));
        assertFalse(ok);
        assertTrue(nft.isAvailable("c", club));
        // BadGateConfig either way
        vm.prank(alice);
        vm.expectRevert(SubpageRegistrar.BadGateConfig.selector);
        reg.configure(club, payout, address(0), 0, true, address(nft), 0, false);
        vm.prank(alice);
        vm.expectRevert(SubpageRegistrar.BadGateConfig.selector);
        reg.configure(club, payout, address(0), 0, true, address(0), 1, false);
    }

    // proceeds

    function test_proceedsCannotBeStrandedOrTaken() public {
        _sellSetup(club, 0.01 ether);
        _buy(club, "a", 0.05 ether, 0.01 ether);
        assertEq(address(reg).balance, 0.01 ether);
        // to the PageNFT: reverts, the balance stays
        vm.prank(payout);
        vm.expectRevert(ETH_TRANSFER_FAILED);
        reg.claimProceeds(address(nft));
        // to the registrar: refused
        vm.prank(payout);
        vm.expectRevert(SubpageRegistrar.NotAuthorized.selector);
        reg.claimProceeds(address(reg));
        // nobody else's call moves it anywhere but the payout
        vm.prank(stranger);
        vm.expectRevert(SubpageRegistrar.NothingToClaim.selector);
        reg.claimProceeds(stranger);
        vm.prank(alice);
        vm.expectRevert(SubpageRegistrar.NothingToClaim.selector);
        reg.claimProceeds(alice);
        assertEq(reg.proceedsOf(payout), 0.01 ether);
        uint256 before = payout.balance;
        vm.prank(stranger);
        reg.claimProceedsFor(payout);
        assertEq(payout.balance, before + 0.01 ether);
        assertEq(address(reg).balance, 0);
        // a parent sale does not move proceeds already earned
        _buy(club, "b", 0.01 ether, 0.01 ether);
        vm.prank(alice);
        nft.transferFrom(alice, bob, club);
        assertEq(reg.proceedsOf(payout), 0.01 ether);
        // ETH forced in by SELFDESTRUCT is owed to nobody and stays: no claim reaches it
        new ForceSend{value: 1 ether}(payable(address(reg)));
        assertEq(address(reg).balance, 1.01 ether);
        vm.prank(payout);
        reg.claimProceeds(address(0));
        assertEq(address(reg).balance, 1 ether);
        vm.prank(payout);
        vm.expectRevert(SubpageRegistrar.NothingToClaim.selector);
        reg.claimProceeds(address(0));
    }

    // a holder contract that is also the recipient cannot reconfigure from its hook during the sale
    function test_recipientHookCannotRedirectProceeds() public {
        HookCaller hc = new HookCaller();
        vm.prank(alice);
        nft.transferFrom(alice, address(hc), club);
        hc.exec(address(nft), 0, abi.encodeCall(nft.setSubpageMinter, (club, address(reg))));
        hc.exec(
            address(reg), 0, abi.encodeCall(reg.configure, (club, payout, address(0), 0.01 ether, true, address(0), 0, false))
        );
        hc.arm(
            address(reg),
            abi.encodeCall(reg.configure, (club, address(hc), address(0), 0.01 ether, true, address(0), 0, false)),
            false
        );
        vm.prank(buyer);
        reg.registerSubpageFor{value: 0.01 ether}(club, "a", address(hc), 0.01 ether, address(0));
        assertTrue(hc.called());
        assertFalse(hc.ok());
        assertEq(bytes4(hc.ret()), REENTRANCY);
        assertEq(reg.proceedsOf(payout), 0.01 ether);
        assertEq(reg.proceedsOf(address(hc)), 0);
    }

    // never overwrites a live subpage

    function testFuzz_neverOverwritesLive(uint8 mask, bytes6 noise, bool viaReveal) public {
        vm.prank(alice);
        uint256 live = nft.registerSubpageFor("bob", club, carol);
        _setMinter(club, address(reg));
        _cfg(club, address(0), 0, address(0), 0, false);
        // any case mix of "bob"
        bytes memory b = bytes("bob");
        for (uint256 i; i < 3; ++i) if ((mask >> i) & 1 == 1) b[i] = bytes1(uint8(b[i]) - 32);
        string memory label = string(b);
        if (viaReveal) {
            bytes32 sec = bytes32(uint256(uint48(noise)));
            bytes32 subCommitment = reg.makeSubpageCommitment(club, label, buyer, sec);
            vm.prank(buyer);
            reg.commitSubpage(subCommitment);
            vm.warp(_now() + 61);
            vm.prank(buyer);
            vm.expectRevert(SubpageRegistrar.NotAvailable.selector);
            reg.revealSubpage(club, label, sec, 0, address(0));
        } else {
            vm.prank(buyer);
            vm.expectRevert(SubpageRegistrar.NotAvailable.selector);
            reg.registerSubpage(club, label, 0, address(0));
        }
        assertEq(nft.ownerOf(live), carol);
        // a random other label either sells a different id or is refused; it never touches the live one
        string memory other = string(abi.encodePacked(noise));
        vm.prank(buyer);
        try reg.registerSubpage(club, other, 0, address(0)) returns (uint256 id) {
            assertTrue(id != live);
        } catch {}
        assertEq(nft.ownerOf(live), carol);
    }

    // plain transfer into the registrar

    // the PageNFT treats the registrar as the owner of a parent it holds, so it could take back
    // anything; the tests show no sale path reaches that
    function testFuzz_strandedParentNeverSells(string calldata label, uint256 value, bool viaReveal) public {
        value = bound(value, 0, 1 ether);
        vm.prank(alice);
        uint256 live = nft.registerSubpageFor("live", club, carol);
        _setMinter(club, address(reg));
        _cfg(club, address(0), 0, address(0), 0, false);
        vm.prank(alice);
        nft.transferFrom(alice, address(reg), club);
        assertEq(nft.ownerOf(club), address(reg));
        assertEq(_minter(club), address(0));
        vm.deal(buyer, 2 ether);
        vm.prank(buyer);
        bool ok;
        if (viaReveal) {
            (ok,) = address(reg).call{value: value}(
                abi.encodeCall(reg.revealSubpage, (club, label, bytes32(0), type(uint256).max, address(0)))
            );
        } else {
            (ok,) = address(reg).call{value: value}(
                abi.encodeCall(reg.registerSubpage, (club, label, type(uint256).max, address(0)))
            );
        }
        assertFalse(ok);
        assertEq(nft.ownerOf(live), carol);
        // nobody can write a config for it
        address[3] memory who = [alice, bob, buyer];
        for (uint256 i; i < 3; ++i) {
            vm.prank(who[i]);
            vm.expectRevert(SubpageRegistrar.NotAuthorized.selector);
            reg.configure(club, payout, address(0), 0, true, address(0), 0, false);
        }
    }

    function test_strandedParentExactErrors() public {
        _sellSetup(club, 0);
        vm.prank(alice);
        nft.transferFrom(alice, address(reg), club);
        vm.prank(buyer);
        vm.expectRevert(SubpageRegistrar.StaleController.selector);
        reg.registerSubpage(club, "a", 0, address(0));
        // the old controller cannot switch it off through the registrar, but can switch its minter off
        vm.prank(alice);
        vm.expectRevert(SubpageRegistrar.NotAuthorized.selector);
        reg.disable(club);
        vm.prank(alice);
        nft.setSubpageMinter(club, address(0));
        assertEq(nft.payee(club), address(reg));
        // safe transfer in and a mint to the registrar revert
        vm.prank(bob);
        vm.expectRevert(NON_RECEIVER);
        nft.safeTransferFrom(bob, address(reg), zoo);
        vm.prank(bob);
        vm.expectRevert(NON_RECEIVER);
        nft.safeTransferFrom(bob, address(reg), zoo, "");
        vm.prank(bob);
        vm.expectRevert(NON_RECEIVER);
        nft.registerSubpageFor("x", zoo, address(reg));
    }

    // holder changes, directed

    // alice sets both, the parent goes to bob, one change or none is made to the pick or the config,
    // and it comes back to alice
    function test_roundTripMatrix() public {
        for (uint256 k; k < 7; ++k) {
            uint256 snap = vm.snapshotState();
            _sellSetup(club, 0);
            vm.prank(alice);
            nft.transferFrom(alice, bob, club);
            bytes4 want;
            if (k == 0) {
                want = bytes4(0); // nothing: the pick and the config count again for alice
            } else if (k == 1) {
                vm.prank(bob);
                nft.setSubpageMinter(club, address(reg));
                want = SubpageRegistrar.NotMinter.selector;
            } else if (k == 2) {
                vm.prank(bob);
                nft.setSubpageMinter(club, address(0));
                want = SubpageRegistrar.NotMinter.selector;
            } else if (k == 3) {
                vm.prank(bob);
                reg.disable(club);
                want = SubpageRegistrar.NotEnabled.selector;
            } else if (k == 4) {
                vm.prank(bob);
                reg.configure(club, bob, address(0), 0, true, address(0), 0, false);
                want = SubpageRegistrar.StaleController.selector;
            } else if (k == 5) {
                vm.prank(alice);
                nft.setSubpageMinter(club, address(0));
                want = SubpageRegistrar.NotMinter.selector;
            } else {
                // bob sends it on to carol, who picks the registrar and sends it back to bob
                vm.prank(bob);
                nft.transferFrom(bob, carol, club);
                vm.prank(carol);
                nft.setSubpageMinter(club, address(reg));
                vm.prank(carol);
                nft.transferFrom(carol, bob, club);
                want = SubpageRegistrar.NotMinter.selector;
            }
            // while bob holds, never a sale
            vm.prank(buyer);
            vm.expectRevert();
            reg.registerSubpage(club, "a", 0, address(0));
            vm.prank(bob);
            nft.transferFrom(bob, alice, club);
            vm.prank(buyer);
            if (want != bytes4(0)) {
                vm.expectRevert(want);
                reg.registerSubpage(club, "a", 0, address(0));
            } else {
                reg.registerSubpage(club, "a", 0, address(0));
                assertEq(nft.ownerOf(_subId("a", club)), buyer);
            }
            vm.revertToState(snap);
        }
    }

    // an operator or an account approved for the token can neither pick the minter nor configure
    function test_approvedAccountsCannotStartSales() public {
        vm.startPrank(alice);
        nft.setApprovalForAll(hot, true);
        nft.approve(hot2, club);
        vm.stopPrank();
        address[2] memory who = [hot, hot2];
        for (uint256 i; i < 2; ++i) {
            vm.prank(who[i]);
            vm.expectRevert(PageNFT.Unauthorized.selector);
            nft.setSubpageMinter(club, address(reg));
            vm.prank(who[i]);
            vm.expectRevert(SubpageRegistrar.NotAuthorized.selector);
            reg.configure(club, who[i], address(0), 0, true, address(0), 0, false);
        }
        // an operator that moves the parent to itself stops alice's sale, since her config and pick count
        // only while she holds it
        _sellSetup(club, 0);
        vm.prank(hot);
        nft.transferFrom(alice, hot, club);
        vm.prank(buyer);
        vm.expectRevert(SubpageRegistrar.StaleController.selector);
        reg.registerSubpage(club, "a", 0, address(0));
        // the operator now holds it, which its ERC721 operator grant allowed, and can do what a holder does
        vm.prank(hot);
        reg.configure(club, hot, address(0), 0, true, address(0), 0, false);
        vm.prank(hot);
        nft.setSubpageMinter(club, address(reg));
        vm.prank(buyer);
        reg.registerSubpage(club, "a", 0, address(0));
    }

    // blast radius

    struct World {
        uint256 club;
        uint256 zoo2;
        uint256 sub;
        uint256 zsub;
    }

    // alice holds club and zoo2, carol holds live subpages under each
    function _world() internal returns (World memory w) {
        w.club = club;
        w.zoo2 = _reg(alice, "zoo2");
        vm.startPrank(alice);
        w.sub = nft.registerSubpageFor("live", club, carol);
        w.zsub = nft.registerSubpageFor("live", w.zoo2, carol);
        nft.setAddr(club, alice);
        vm.stopPrank();
    }

    function _try(Hostile h, bytes memory d) internal returns (bool ok) {
        (ok,) = h.exec(address(nft), d);
    }

    struct Reach {
        uint256 minted;
        uint256 took;
        uint256 moved;
        uint256 records;
        uint256 picks;
    }

    function _log(string memory what, Reach memory r) internal {
        emit log_string(what);
        emit log_named_uint("  fresh subpages minted", r.minted);
        emit log_named_uint("  live subpages of other people taken", r.took);
        emit log_named_uint("  top-level names moved out", r.moved);
        emit log_named_uint("  parent records rewritten", r.records);
        emit log_named_uint("  minter picks written", r.picks);
    }

    // what a hostile contract can do with each grant
    function test_blastRadius() public {
        Hostile h = new Hostile();

        // 1. minter
        uint256 snap = vm.snapshotState();
        World memory w = _world();
        _setMinter(club, address(h));
        Reach memory r = _probe(h, w);
        _log("create-only minter", r);
        assertEq(r.minted, 1);
        assertEq(r.took + r.moved + r.records + r.picks, 0);
        vm.revertToState(snap);

        // 2. operator approval
        snap = vm.snapshotState();
        w = _world();
        vm.prank(alice);
        nft.setApprovalForAll(address(h), true);
        uint256 dep = nft.depositOf(club) + nft.depositOf(w.zoo2);
        r = _probe(h, w);
        _log("operator approval", r);
        assertEq(r.moved, 2); // club and zoo2
        assertEq(r.took, 2); // then, as their owner, both parents' subpages
        assertEq(nft.payee(club), makeAddr("thief"), "club's deposit now pays the thief");
        assertEq(nft.payee(w.zoo2), makeAddr("thief"));
        emit log_named_uint("  deposits now paying the thief (wei)", dep);
        vm.revertToState(snap);

        // 3. custody: the contract holds club
        snap = vm.snapshotState();
        w = _world();
        vm.prank(alice);
        nft.transferFrom(alice, address(h), club);
        r = _probe(h, w);
        _log("custody", r);
        assertEq(r.took, 1);
        assertEq(r.moved, 1); // club leaves for good
        assertEq(r.records, 1);
        vm.revertToState(snap);
    }

    // the hostile contract tries everything it can reach and reports what it got
    function _probe(Hostile h, World memory w) internal returns (Reach memory r) {
        address thief = makeAddr("thief");
        if (_try(h, abi.encodeCall(nft.setAddr, (w.club, thief)))) r.records++;
        if (_try(h, abi.encodeCall(nft.setText, (w.club, "url", "evil")))) r.records++;
        if (_try(h, abi.encodeCall(nft.setAddr, (w.zoo2, thief)))) r.records++;
        if (_try(h, abi.encodeCall(nft.setSubpageMinter, (w.zoo2, address(h))))) r.picks++;
        if (_try(h, abi.encodeCall(nft.setSubpageMinter, (w.club, address(h))))) r.picks++;
        if (r.records > 0) r.records = 1; // count the parent once
        // fresh label under each parent
        if (_try(h, abi.encodeCall(nft.registerSubpageFor, ("fresh", w.club, thief)))) r.minted++;
        if (_try(h, abi.encodeCall(nft.registerSubpageFor, ("fresh", w.zoo2, thief)))) r.minted++;
        // the live subpages
        if (_try(h, abi.encodeCall(nft.registerSubpageFor, ("live", w.club, thief)))) r.took++;
        if (_try(h, abi.encodeCall(nft.registerSubpageFor, ("live", w.zoo2, thief)))) r.took++;
        // move the parents out
        uint256[2] memory ps = [w.club, w.zoo2];
        for (uint256 i; i < 2; ++i) {
            address o = nft.ownerOf(ps[i]);
            if (_try(h, abi.encodeCall(nft.transferFrom, (o, thief, ps[i])))) r.moved++;
        }
        // as the new owner of anything moved, take the live subpages not yet taken
        for (uint256 i; i < 2; ++i) {
            uint256 sid = _subId("live", ps[i]);
            if (nft.ownerOf(ps[i]) == thief && nft.ownerOf(sid) != thief) {
                vm.prank(thief);
                nft.registerSubpageFor("live", ps[i], thief);
                r.took++;
            }
        }
        if (r.moved == 0 && r.records == 0) {
            assertEq(nft.ownerOf(w.club), alice);
            assertEq(nft.ownerOf(w.zoo2), alice);
            assertEq(nft.ownerOf(w.zsub), carol);
            assertEq(nft.resolve(w.club), alice);
            assertEq(nft.text(w.club, "url"), "");
            address m = nft.subpageMinterOf(w.zoo2);
            assertEq(m, address(0));
        }
    }

    // the minter grant dies with the parent's sale; an operator approval outlives it and covers later names
    function test_grantLifetime() public {
        Hostile h = new Hostile();
        _setMinter(club, address(h));
        vm.prank(alice);
        nft.transferFrom(alice, bob, club);
        assertFalse(_try(h, abi.encodeCall(nft.registerSubpageFor, ("x", club, address(h)))));
        // operator approval for all: a name alice registers later is still reachable
        vm.prank(alice);
        nft.setApprovalForAll(address(h), true);
        uint256 later = _reg(alice, "later");
        assertTrue(_try(h, abi.encodeCall(nft.transferFrom, (alice, address(h), later))));
        assertEq(nft.ownerOf(later), address(h));
    }

    // the two payouts that could never collect are refused before the fee token, the price and the gate
    // are checked
    function test_payoutRefusalsAndStep1Backstop() public {
        address[2] memory bad = [address(nft), address(reg)];
        for (uint256 i; i < 2; ++i) {
            vm.prank(alice);
            vm.expectRevert(SubpageRegistrar.NotAuthorized.selector);
            reg.configure(club, bad[i], address(nft), type(uint256).max, true, address(0), 1, false);
        }
        // step 1 is the only refusal: the registrar calls the mint itself, so a sale naming it would get a plain
        // mint and strand the subpage; the holder's own mint to it is a safe mint and fails, since it has no hook
        _sellSetup(club, 0);
        vm.prank(buyer);
        vm.expectRevert(SubpageRegistrar.NotAuthorized.selector);
        reg.registerSubpageFor(club, "a", address(reg), 0, address(0));
        vm.prank(alice);
        vm.expectRevert(NON_RECEIVER);
        nft.registerSubpageFor("a", club, address(reg));
    }
}

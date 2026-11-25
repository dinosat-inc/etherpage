// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Vm} from "forge-std/Test.sol";
import {MinterBase} from "../utils/MinterBase.sol";
import {PageNFT} from "../../src/PageNFT.sol";
import {PageCard} from "../../src/PageCard.sol";
import {SubpageRegistrar, IPageNFT} from "../../src/SubpageRegistrar.sol";
import {PageNFTNoMinter} from "../differential/harness/PageNFTNoMinter.sol";
import {MockERC20} from "../utils/MinterMocks.sol";

// a fee token whose transferFrom lets the parent holder act in the middle of a sale
contract HolderToken {
    mapping(address => uint256) public balanceOf;
    address public hook;
    bytes public hookData;

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function arm(address h, bytes calldata d) external {
        hook = h;
        hookData = d;
    }

    function transferFrom(address from, address to, uint256 a) external returns (bool) {
        balanceOf[from] -= a;
        balanceOf[to] += a;
        if (hook != address(0)) {
            (bool ok,) = hook.call(hookData);
            require(ok, "hook");
        }
        return true;
    }
}

// a contract wallet that holds a parent and can be told to call anything
contract WalletHolder {
    function exec(address to, bytes calldata d) external returns (bytes memory) {
        (bool ok, bytes memory r) = to.call(d);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(r, 0x20), mload(r))
            }
        }
        return r;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}

contract MinterAuthorityTest is MinterBase {
    address op = makeAddr("op");
    address appr = makeAddr("appr");
    address k0 = makeAddr("k0");
    address k1 = makeAddr("k1");
    address kOld = makeAddr("kOld");
    address kBob = makeAddr("kBob");

    // J1: the zero address as the caller moves no name and approves none, here and in the PageNFTNoMinter reference
    // build, also when the name has no approval for the token, which the ERC721 library would let it move
    function test_J1_zeroCallerMovesAndApprovesNothing() public {
        uint256 id = _reg(alice, "gold");
        vm.prank(address(0));
        vm.expectRevert(NOT_OWNER_NOR_APPROVED);
        nft.transferFrom(alice, stranger, id);
        vm.prank(address(0));
        vm.expectRevert(NOT_OWNER_NOR_APPROVED);
        nft.safeTransferFrom(alice, stranger, id);
        vm.prank(address(0));
        vm.expectRevert(NOT_OWNER_NOR_APPROVED);
        nft.approve(stranger, id);
        assertEq(nft.ownerOf(id), alice, "minter build: the zero caller moved nothing");
        assertEq(nft.getApproved(id), address(0), "minter build: the zero caller approved nothing");

        PageNFTNoMinter base = new PageNFTNoMinter(card);
        bytes32 secret = keccak256("s");
        bytes32 baseCommitment = base.makeCommitment("gold", alice, 0, secret);
        vm.prank(alice);
        base.commit(baseCommitment);
        vm.warp(vm.getBlockTimestamp() + 61);
        (,,, uint256 total) = base.quote("gold");
        vm.prank(alice);
        uint256 bid = base.reveal{value: total}("gold", alice, 0, secret);
        vm.prank(address(0));
        vm.expectRevert(NOT_OWNER_NOR_APPROVED);
        base.transferFrom(alice, stranger, bid);
        assertEq(base.ownerOf(bid), alice, "no-minter build: the zero caller moved nothing");
    }

    // J2: address(0) mints no subpage where no minter counts, like the PageNFTNoMinter reference build
    function test_J2_zeroCallerMinterPath() public {
        uint256 p = _reg(alice, "club");
        assertEq(nft.subpageMinterOf(p), address(0), "no minter counts");
        vm.prank(address(0));
        vm.expectRevert(PageNFT.NotParentOwner.selector);
        nft.registerSubpageFor("zero", p, carol);
        assertTrue(nft.isAvailable("zero", p), "nothing was minted");

        PageNFTNoMinter base = new PageNFTNoMinter(card);
        bytes32 secret = keccak256("s2");
        bytes32 baseCommitment = base.makeCommitment("club", alice, 0, secret);
        vm.prank(alice);
        base.commit(baseCommitment);
        vm.warp(vm.getBlockTimestamp() + 61);
        (,,, uint256 total) = base.quote("club");
        vm.prank(alice);
        uint256 bp = base.reveal{value: total}("club", alice, 0, secret);
        vm.prank(address(0));
        vm.expectRevert(PageNFT.NotParentOwner.selector);
        base.registerSubpageFor("zero", bp, carol);
    }

    // J3: every caller against every label state, with no pick, k0 or k1 picked, one case at a time
    struct Case {
        address caller;
        uint8 pick; // 0 none, 1 k0 picked, 2 k1 picked
        bool[3] ok; // free, stale, live
        bytes4[3] err;
    }

    function test_J3_authorityMatrix() public {
        uint256 p = _reg(alice, "club");
        vm.prank(alice);
        nft.setSubpageMinter(p, kOld); // picked in epoch 1
        vm.prank(alice);
        nft.registerSubpageFor("stale", p, carol);
        // epoch 2, same holder
        vm.warp(nft.expiresAt(p) + 90 days + 21 days + 1);
        _reg(alice, "club");
        assertEq(nft.epochOf(p), 2);
        vm.prank(alice);
        nft.registerSubpageFor("live", p, carol);
        // bob held it in epoch 2 and picked kBob, then gave it back
        vm.prank(alice);
        nft.transferFrom(alice, bob, p);
        vm.prank(bob);
        nft.setSubpageMinter(p, kBob);
        vm.prank(bob);
        nft.transferFrom(bob, alice, p);
        vm.prank(alice);
        nft.setApprovalForAll(op, true);
        vm.prank(alice);
        nft.approve(appr, p);

        string[3] memory labels = ["free", "stale", "live"];
        bytes4 NPO = PageNFT.NotParentOwner.selector;
        bytes4 AR = PageNFT.AlreadyRegistered.selector;
        Case[9] memory cs;
        cs[0] = Case(alice, 0, [true, true, true], [bytes4(0), 0, 0]);
        cs[1] = Case(k0, 1, [true, true, false], [bytes4(0), 0, AR]);
        cs[2] = Case(k1, 2, [true, true, false], [bytes4(0), 0, AR]);
        cs[3] = Case(kOld, 0, [false, false, false], [NPO, NPO, NPO]);
        cs[4] = Case(kBob, 0, [false, false, false], [NPO, NPO, NPO]);
        cs[5] = Case(op, 1, [false, false, false], [NPO, NPO, NPO]);
        cs[6] = Case(appr, 2, [false, false, false], [NPO, NPO, NPO]);
        cs[7] = Case(stranger, 2, [false, false, false], [NPO, NPO, NPO]);
        cs[8] = Case(bob, 2, [false, false, false], [NPO, NPO, NPO]);

        for (uint256 i; i < cs.length; ++i) {
            for (uint256 j; j < 3; ++j) {
                uint256 snap = vm.snapshotState();
                if (cs[i].pick == 1) {
                    vm.prank(alice);
                    nft.setSubpageMinter(p, k0);
                } else if (cs[i].pick == 2) {
                    vm.prank(alice);
                    nft.setSubpageMinter(p, k1);
                }
                uint256 sid = _subId(labels[j], p);
                address before = nft.ownerOf(p);
                vm.prank(cs[i].caller);
                (bool ok, bytes memory ret) =
                    address(nft).call(abi.encodeCall(PageNFT.registerSubpageFor, (labels[j], p, dave)));
                assertEq(ok, cs[i].ok[j], string.concat("case ", vm.toString(i), " label ", labels[j]));
                if (ok) {
                    assertEq(nft.ownerOf(sid), dave);
                    assertEq(nft.epochOf(sid) >= 1, true);
                } else {
                    assertEq(bytes4(ret), cs[i].err[j], string.concat("err case ", vm.toString(i), " ", labels[j]));
                    if (j != 0) assertEq(nft.ownerOf(sid), carol, "refused call moved nothing");
                }
                assertEq(nft.ownerOf(p), before, "parent never moves");
                vm.revertToState(snap);
            }
        }
    }

    // J4: a minter of one parent has no power under the holder's other parent
    function test_J4_minterScopedToOneParent() public {
        uint256 a = _reg(alice, "aaa1");
        uint256 b = _reg(alice, "bbb1");
        _setMinter(a, k1);
        vm.prank(alice);
        nft.registerSubpageFor("x", b, carol);
        vm.prank(k1);
        vm.expectRevert(PageNFT.NotParentOwner.selector);
        nft.registerSubpageFor("x", b, k1);
        vm.prank(k1);
        vm.expectRevert(PageNFT.NotParentOwner.selector);
        nft.registerSubpageFor("y", b, k1);
        vm.prank(k1);
        nft.registerSubpageFor("y", a, k1);
    }

    // J5: revival when the parent comes back, and switching off while away, which prevents it
    function test_J5_revivalAndAwaySwitchOff() public {
        uint256 p = _reg(alice, "club");
        _setMinter(p, k0);
        vm.prank(alice);
        nft.transferFrom(alice, bob, p);
        assertEq(_minter(p), address(0), "off while bob holds it");
        vm.prank(k0);
        vm.expectRevert(PageNFT.NotParentOwner.selector);
        nft.registerSubpageFor("junk1", p, k0);
        // bob gives it back without alice doing anything
        vm.prank(bob);
        nft.transferFrom(bob, alice, p);
        assertEq(_minter(p), k0, "revived with no new signature");
        vm.prank(k0);
        nft.registerSubpageFor("junk1", p, k0);

        // same story, but alice switches k0 off while the name is away
        uint256 q = _reg(alice, "shop");
        _setMinter(q, k0);
        vm.prank(alice);
        nft.transferFrom(alice, bob, q);
        vm.prank(alice);
        nft.setSubpageMinter(q, address(0));
        vm.prank(bob);
        nft.transferFrom(bob, alice, q);
        assertEq(_minter(q), address(0), "stays off");
        vm.prank(k0);
        vm.expectRevert(PageNFT.NotParentOwner.selector);
        nft.registerSubpageFor("junk1", q, k0);
        // the away setter can only write zero, and cannot touch a later holder's pick
        vm.prank(alice);
        nft.transferFrom(alice, bob, q);
        vm.prank(alice);
        vm.expectRevert(PageNFT.Unauthorized.selector);
        nft.setSubpageMinter(q, k0);
        vm.prank(bob);
        nft.setSubpageMinter(q, kBob);
        vm.prank(alice);
        vm.expectRevert(PageNFT.Unauthorized.selector);
        nft.setSubpageMinter(q, address(0));
        assertEq(_minter(q), kBob);
    }

    // J6: the holder takes a sold subpage back inside the sale, through a fee token it controls.
    // Minting over its own subpages is the holder's power, and the registrar as minter does not stop it.
    function test_J6_holderTakesBackDuringSaleViaFeeToken() public {
        WalletHolder w = new WalletHolder();
        uint256 p = _regTo(alice, "club", address(w));
        HolderToken t = new HolderToken();
        t.mint(buyer, 100);
        w.exec(address(nft), abi.encodeCall(PageNFT.setSubpageMinter, (p, address(reg))));
        w.exec(
            address(reg),
            abi.encodeCall(SubpageRegistrar.configure, (p, payout, address(t), 10, true, address(0), 0, false))
        );
        t.arm(
            address(w),
            abi.encodeCall(WalletHolder.exec, (address(nft), abi.encodeCall(PageNFT.registerSubpageFor, ("gold", p, address(w)))))
        );
        vm.recordLogs();
        vm.prank(buyer);
        uint256 sid = reg.registerSubpage(p, "gold", 10, address(t));
        assertEq(nft.ownerOf(sid), address(w), "holder took it back in the same transaction");
        assertEq(t.balanceOf(payout), 10, "buyer paid");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool sold;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == SubpageRegistrar.SubpageSold.selector) {
                sold = true;
                assertEq(address(uint160(uint256(logs[i].topics[3]))), buyer, "SubpageSold names the buyer");
            }
        }
        assertTrue(sold);
    }

    // J7: the registrar as minter never takes back a live subpage
    function test_J7_registrarNeverTakesBack() public {
        uint256 p = _reg(alice, "club");
        vm.prank(alice);
        nft.registerSubpageFor("live", p, carol);
        _setMinter(p, address(reg));
        _configure(p, payout, address(0), 1 ether, false);
        vm.prank(buyer);
        vm.expectRevert(SubpageRegistrar.NotAvailable.selector);
        reg.registerSubpage{value: 1 ether}(p, "live", 1 ether, address(0));
        vm.prank(buyer);
        vm.expectRevert(SubpageRegistrar.NotAvailable.selector);
        reg.registerSubpage{value: 1 ether}(p, "LIVE", 1 ether, address(0));
        assertEq(nft.ownerOf(_subId("live", p)), carol);
    }

    // J8: fail instead of losing the name. Mints and safe transfers into the registrar revert,
    // a plain transferFrom still strands the name.
    function test_J8_failInsteadOfLosing() public {
        // a top level registration naming the registrar as owner reverts, the payer keeps the ETH
        bytes32 secret = keccak256("r");
        bytes32 commitment = nft.makeCommitment("lost", address(reg), 0, secret);
        vm.prank(alice);
        nft.commit(commitment);
        vm.warp(vm.getBlockTimestamp() + 61);
        (,,, uint256 total) = nft.quote("lost");
        uint256 bal = alice.balance;
        vm.prank(alice);
        vm.expectRevert(NON_RECEIVER);
        nft.reveal{value: total}("lost", address(reg), 0, secret);
        assertEq(alice.balance, bal, "no ETH lost");
        assertTrue(nft.isAvailable("lost", 0));

        // a subpage minted straight to the registrar reverts
        uint256 p = _reg(alice, "club");
        vm.prank(alice);
        vm.expectRevert(NON_RECEIVER);
        nft.registerSubpageFor("s", p, address(reg));
        // the registrar's own sale refuses it as recipient
        _sellSetup(p, 0);
        vm.prank(buyer);
        vm.expectRevert(SubpageRegistrar.NotAuthorized.selector);
        reg.registerSubpageFor(p, "s", address(reg), 0, address(0));

        // a safe transfer reverts and alice keeps the name
        vm.prank(alice);
        vm.expectRevert(NON_RECEIVER);
        nft.safeTransferFrom(alice, address(reg), p);
        assertEq(nft.ownerOf(p), alice);

        // a plain transfer still goes through and strands the name
        vm.prank(alice);
        nft.transferFrom(alice, address(reg), p);
        assertEq(nft.ownerOf(p), address(reg));
        assertEq(nft.payee(p), address(reg));
        vm.prank(buyer);
        vm.expectRevert(SubpageRegistrar.StaleController.selector);
        reg.registerSubpage(p, "t", 0, address(0));
    }

    // J9: a leaked minter that only creates. Junk only, stopped in one call, junk stays until the
    // holder mints each label again. It never touches a live subpage, the parent or any money.
    function test_J9_leakedCreateOnlyMinter() public {
        uint256 p = _reg(alice, "club");
        vm.prank(alice);
        uint256 live = nft.registerSubpageFor("live", p, carol);
        _setMinter(p, k0);
        uint256 dep = nft.depositOf(p);
        uint256 bal = address(nft).balance;
        for (uint256 i; i < 5; ++i) {
            vm.prank(k0);
            nft.registerSubpageFor(string.concat("junk", vm.toString(i)), p, dave);
        }
        vm.prank(k0);
        vm.expectRevert(PageNFT.AlreadyRegistered.selector);
        nft.registerSubpageFor("live", p, k0);
        assertEq(nft.ownerOf(live), carol);
        vm.prank(alice);
        nft.setSubpageMinter(p, address(0));
        vm.prank(k0);
        vm.expectRevert(PageNFT.NotParentOwner.selector);
        nft.registerSubpageFor("junk9", p, dave);
        assertEq(nft.balanceOf(dave), 5, "junk stays");
        vm.prank(alice);
        nft.registerSubpageFor("junk0", p, DEAD);
        assertTrue(nft.isAvailable("junk0", p), "cleanup re-mints to DEAD, the label is free again");
        assertFalse(nft.isAvailable("junk1", p), "junk the holder has not cleaned stays taken");
        assertEq(nft.depositOf(p), dep);
        assertEq(address(nft).balance, bal);
        assertEq(nft.ownerOf(p), alice);
    }

    // J10: a minter picked by the holder cannot touch a live subpage or its records; only the
    // holder minting it again wipes them.
    function test_J10_minterCannotWipeRecords() public {
        uint256 p = _reg(alice, "club");
        vm.prank(alice);
        uint256 s = nft.registerSubpageFor("carol", p, carol);
        vm.prank(carol);
        nft.setText(s, "url", "https://carol.example");
        vm.prank(carol);
        nft.setPrimaryPage(s);
        _setMinter(p, k1);
        vm.prank(k1);
        vm.expectRevert(PageNFT.AlreadyRegistered.selector);
        nft.registerSubpageFor("carol", p, carol);
        assertEq(nft.text(s, "url"), "https://carol.example");
        assertEq(nft.reverseResolve(carol), "carol.club");
        vm.prank(alice);
        nft.registerSubpageFor("carol", p, carol);
        assertEq(nft.text(s, "url"), "", "the holder can still wipe it");
        assertEq(nft.reverseResolve(carol), "");
    }
}

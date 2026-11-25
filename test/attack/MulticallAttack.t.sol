// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {ERC721} from "solady/tokens/ERC721.sol";
import {PageNFT} from "../../src/PageNFT.sol";
import {SubpageRegistrar} from "../../src/SubpageRegistrar.sol";
import {MinterBase} from "../utils/MinterBase.sol";
import {SafeLike} from "../utils/MinterMocks.sol";
import {Actor, Bomb, Burner, RefundPayer} from "../utils/ActorMocks.sol";

// multicall tried from every angle: value, payments, ordering, the guard, gas and contract holders
contract MulticallAttackTest is MinterBase {
    uint256 P;
    bytes4 constant NOTHING_TO_WITHDRAW = PageNFT.NothingToWithdraw.selector;

    function setUp() public override {
        super.setUp();
        P = _reg(alice, "alice");
    }

    function _mc(bytes[] memory d) internal pure returns (bytes memory) {
        return abi.encodeCall(PageNFT.multicall, (d));
    }

    function _b1(bytes memory a) internal pure returns (bytes[] memory d) {
        d = new bytes[](1);
        d[0] = a;
    }

    function _b2(bytes memory a, bytes memory b) internal pure returns (bytes[] memory d) {
        d = new bytes[](2);
        d[0] = a;
        d[1] = b;
    }

    function _b3(bytes memory a, bytes memory b, bytes memory c) internal pure returns (bytes[] memory d) {
        d = new bytes[](3);
        d[0] = a;
        d[1] = b;
        d[2] = c;
    }

    function _call(address who, uint256 value, bytes memory data) internal returns (bool ok, bytes memory ret) {
        vm.deal(who, who.balance + value);
        vm.prank(who);
        (ok, ret) = address(nft).call{value: value}(data);
    }

    function _err(bytes4 s) internal pure returns (bytes memory) {
        return abi.encodePacked(s);
    }

    // a name whose deposit can be released to its payee
    function _releasable(address who, string memory label) internal returns (uint256 id) {
        id = _reg(who, label);
        vm.warp(nft.expiresAt(id) + 90 days + 21 days + 1);
        // point P at a fresh live name for the tests that write to it after the warp
        P = _reg(alice, string.concat("fresh", label));
    }

    // value and payments

    // A1: value never enters a bundle, whatever the bundle holds
    function testFuzz_A1_valueNeverEnters(uint96 v, uint8 shape) public {
        vm.assume(v > 0);
        bytes[] memory d;
        uint8 k = shape % 4;
        if (k == 0) d = new bytes[](0);
        else if (k == 1) d = _b1(abi.encodeCall(PageNFT.renew, (P)));
        else if (k == 2) d = _b1(abi.encodeCall(PageNFT.withdraw, (alice)));
        else d = _b1(_mc(_b1(abi.encodeCall(PageNFT.renew, (P)))));
        uint256 bal = address(nft).balance;
        uint256 exp = nft.expiresAt(P);
        (bool ok, bytes memory ret) = _call(alice, v, _mc(d));
        assertFalse(ok);
        assertEq(ret.length, 0);
        assertEq(address(nft).balance, bal);
        assertEq(nft.expiresAt(P), exp);
    }

    // A2: a paid reveal whose receiver hook bundles a renew and a reveal cannot spend the payment again
    function test_A2_hookOfPaidRevealCannotReuseValue() public {
        Actor act = new Actor();
        string memory label = "paidreveal";
        bytes32 secret = keccak256("s");
        bytes32 commitment = nft.makeCommitment(label, address(act), 0, secret);
        vm.prank(bob);
        nft.commit(commitment);
        bytes32 secret2 = keccak256("s2");
        bytes32 commitment2 = nft.makeCommitment("other", address(act), 0, secret2);
        vm.prank(bob);
        nft.commit(commitment2);
        vm.warp(block.timestamp + 61);
        uint256 id = _id(label);
        address[] memory to = new address[](4);
        bytes[] memory hd = new bytes[](4);
        for (uint256 i; i < 4; ++i) to[i] = address(nft);
        hd[0] = _mc(_b1(abi.encodeCall(PageNFT.renew, (P))));
        hd[1] = _mc(_b1(abi.encodeCall(PageNFT.reveal, ("other", address(act), 0, secret2))));
        hd[2] = _mc(_b1(abi.encodeCall(PageNFT.setText, (id, "k", "v"))));
        hd[3] = abi.encodeCall(PageNFT.renew, (id));
        act.armHook(to, hd);
        uint256 bal = address(nft).balance;
        uint256 bobBal = bob.balance;
        uint256 depP = nft.depositOf(P);
        vm.prank(bob);
        nft.reveal{value: 1 ether}(label, address(act), 0, secret);
        assertFalse(act.hookOkAt(0));
        assertEq(act.hookRetAt(0), _err(REENTRANCY));
        assertFalse(act.hookOkAt(1));
        assertEq(act.hookRetAt(1), _err(REENTRANCY));
        assertTrue(act.hookOkAt(2), "unguarded writes still work from the hook");
        assertFalse(act.hookOkAt(3));
        assertEq(nft.text(id, "k"), "v");
        assertEq(nft.depositOf(P), depP, "P was not renewed");
        assertEq(nft.ownerOf(id), address(act));
        assertEq(address(nft).balance - bal, 0.0001 ether, "the contract keeps exactly one fee");
        assertEq(bobBal - bob.balance, 0.0001 ether, "the payer pays exactly one fee");
        assertEq(nft.depositOf(id), 0.0001 ether);
    }

    // A3: two withdrawals of one account in a bundle; the second fails and the first is undone
    function test_A3_withdrawTwicePaysAtMostOnce() public {
        uint256 z = _releasable(bob, "zed");
        nft.release(z);
        uint256 owed = nft.owed(bob);
        assertGt(owed, 0);
        uint256 bal = bob.balance;
        (bool ok, bytes memory ret) = _call(stranger, 0,
            _mc(_b2(abi.encodeCall(PageNFT.withdraw, (bob)), abi.encodeCall(PageNFT.withdraw, (bob)))));
        assertFalse(ok);
        assertEq(ret, _err(NOTHING_TO_WITHDRAW));
        assertEq(bob.balance, bal);
        assertEq(nft.owed(bob), owed);
        // nested copies do not help either
        bytes memory w = abi.encodeCall(PageNFT.withdraw, (bob));
        (ok, ret) = _call(stranger, 0, _mc(_b2(_mc(_b1(w)), _mc(_b1(_mc(_b1(w)))))));
        assertFalse(ok);
        assertEq(ret, _err(NOTHING_TO_WITHDRAW));
        assertEq(bob.balance, bal);
        (ok,) = _call(stranger, 0, _mc(_b1(w)));
        assertTrue(ok);
        assertEq(bob.balance, bal + owed);
        assertEq(nft.owed(bob), 0);
    }

    // A4: release then withdraw, release twice, and several accounts in one bundle
    function test_A4_releaseAndWithdrawCombos() public {
        uint256 z1 = _releasable(bob, "zed1");
        uint256 z2 = _reg(carol, "zed2");
        vm.warp(nft.expiresAt(z2) + 90 days + 21 days + 1);
        P = _reg(alice, "alive2");
        uint256 d1 = nft.depositOf(z1);
        uint256 d2 = nft.depositOf(z2);
        uint256 bal = address(nft).balance;
        (bool ok, bytes memory ret) = _call(stranger, 0,
            _mc(_b2(abi.encodeCall(PageNFT.release, (z1)), abi.encodeCall(PageNFT.release, (z1)))));
        assertFalse(ok);
        assertEq(ret, _err(PageNFT.NothingToRelease.selector));
        assertEq(nft.depositOf(z1), d1);
        bytes[] memory d = new bytes[](4);
        d[0] = abi.encodeCall(PageNFT.release, (z1));
        d[1] = abi.encodeCall(PageNFT.release, (z2));
        d[2] = abi.encodeCall(PageNFT.withdraw, (bob));
        d[3] = abi.encodeCall(PageNFT.withdraw, (carol));
        uint256 bb = bob.balance;
        uint256 cb = carol.balance;
        (ok,) = _call(stranger, 0, _mc(d));
        assertTrue(ok);
        assertEq(bob.balance - bb, d1);
        assertEq(carol.balance - cb, d2);
        assertEq(bal - address(nft).balance, d1 + d2, "paid out exactly the two deposits");
        assertEq(nft.depositOf(z1) + nft.depositOf(z2) + nft.owed(bob) + nft.owed(carol), 0);
    }

    // A5: the registrar's functions and internal selectors are not reachable through a bundle
    function test_A5_foreignAndInternalSelectors() public {
        bytes[] memory probes = new bytes[](8);
        probes[0] = abi.encodeCall(SubpageRegistrar.claimProceeds, (alice));
        probes[1] = abi.encodeCall(SubpageRegistrar.claimProceedsFor, (alice));
        probes[2] = abi.encodeWithSignature("_credit(address,uint256)", alice, 1 ether);
        probes[3] = abi.encodeWithSignature("_registerSubpage(string,uint256,address)", "x", P, alice);
        probes[4] = abi.encodeWithSignature("_refundExcess(uint256)", 0);
        probes[5] = abi.encodeWithSignature("_saveAddr(uint256,address)", P, stranger);
        probes[6] = hex"";
        probes[7] = hex"ac9650";
        for (uint256 i; i < probes.length; ++i) {
            (bool ok1, bytes memory r1) = _call(stranger, 0, probes[i]);
            (bool ok2, bytes memory r2) = _call(stranger, 0, _mc(_b1(probes[i])));
            assertFalse(ok1);
            assertFalse(ok2);
            assertEq(r1.length, 0);
            assertEq(r2, r1);
        }
        assertEq(nft.owed(alice), 0);
    }

    // A6: calldata tricks: dirty address bits, bad offsets, cut data and aliased entries
    function test_A6_calldataTricks() public {
        bytes memory dirty = abi.encodePacked(
            PageNFT.transferFrom.selector, uint256(uint160(alice)) | (uint256(1) << 200), uint256(uint160(bob)), P
        );
        (bool ok1, bytes memory r1) = _call(alice, 0, dirty);
        (bool ok2, bytes memory r2) = _call(alice, 0, _mc(_b1(dirty)));
        assertFalse(ok1);
        assertFalse(ok2);
        assertEq(r1, r2);
        assertEq(nft.ownerOf(P), alice);
        // an element offset past the end of calldata
        bytes memory bad = abi.encodePacked(PageNFT.multicall.selector, uint256(0x20), uint256(1), uint256(0xffff));
        (ok1, r1) = _call(alice, 0, bad);
        assertFalse(ok1);
        assertEq(r1.length, 0);
        // a huge array length
        bad = abi.encodePacked(PageNFT.multicall.selector, uint256(0x20), type(uint256).max);
        (ok1, r1) = _call(alice, 0, bad);
        assertFalse(ok1);
        // cut setText entries: padding only (the decoder accepts it), then into the data
        bytes memory st = abi.encodeCall(PageNFT.setText, (P, "k", "v"));
        for (uint256 c = 5; c <= 40; c += 35) {
            bytes memory cut = new bytes(st.length - c);
            for (uint256 i; i < cut.length; ++i) cut[i] = st[i];
            uint256 snap = vm.snapshotState();
            (ok1, r1) = _call(alice, 0, cut);
            string memory t1 = nft.text(P, "k");
            vm.revertToState(snap);
            (ok2, r2) = _call(alice, 0, _mc(_b1(cut)));
            assertEq(ok1, ok2);
            assertEq(nft.text(P, "k"), t1);
            if (!ok1) assertEq(r1, r2);
            emit log_named_uint(c == 5 ? "cut 5 bytes, accepted" : "cut 40 bytes, accepted", ok1 ? 1 : 0);
            vm.revertToState(snap);
        }
        // two array slots aliasing one element run it twice, exactly what the caller encoded
        bytes memory inner = abi.encodeCall(PageNFT.setText, (P, "k", "aliased"));
        bytes memory aliased = abi.encodePacked(
            PageNFT.multicall.selector, uint256(0x20), uint256(2), uint256(0x40), uint256(0x40),
            uint256(inner.length), inner, new bytes((32 - inner.length % 32) % 32)
        );
        vm.recordLogs();
        (ok1, r1) = _call(alice, 0, aliased);
        assertTrue(ok1);
        // alice's first profile write also logs the writer event
        assertEq(vm.getRecordedLogs().length, 3);
        assertEq(nft.text(P, "k"), "aliased");
    }

    // ordering

    // A7: ordering entries never skips a check
    function test_A7_orderingCannotBypassChecks() public {
        // write after sending: Unauthorized, the send is undone
        (bool ok, bytes memory ret) = _call(alice, 0, _mc(_b2(
            abi.encodeCall(PageNFT.transferFrom, (alice, bob, P)), abi.encodeCall(PageNFT.setText, (P, "k", "v")))));
        assertFalse(ok);
        assertEq(ret, _err(PageNFT.Unauthorized.selector));
        assertEq(nft.ownerOf(P), alice);
        // pick a minter and send the name in one bundle: the minter no longer counts
        (ok,) = _call(alice, 0, _mc(_b2(
            abi.encodeCall(PageNFT.setSubpageMinter, (P, stranger)), abi.encodeCall(PageNFT.transferFrom, (alice, bob, P)))));
        assertTrue(ok);
        assertEq(nft.subpageMinterOf(P), address(0));
        (ok, ret) = _call(stranger, 0, _mc(_b1(abi.encodeCall(PageNFT.registerSubpageFor, ("x", P, stranger)))));
        assertFalse(ok);
        assertEq(ret, _err(PageNFT.NotParentOwner.selector));
        // the old holder cannot pick a minter through a bundle
        (ok, ret) = _call(alice, 0, _mc(_b1(abi.encodeCall(PageNFT.setSubpageMinter, (P, alice)))));
        assertFalse(ok);
        assertEq(ret, _err(PageNFT.Unauthorized.selector));
        // approve then send: the approval is gone
        (ok,) = _call(bob, 0, _mc(_b2(
            abi.encodeCall(PageNFT.approve, (carol, P)), abi.encodeCall(PageNFT.transferFrom, (bob, dave, P)))));
        assertTrue(ok);
        assertEq(nft.getApproved(P), address(0));
        (ok,) = _call(carol, 0, abi.encodeCall(PageNFT.transferFrom, (dave, carol, P)));
        assertFalse(ok);
        // a minter cannot make itself the minter first
        (ok, ret) = _call(stranger, 0, _mc(_b2(
            abi.encodeCall(PageNFT.setSubpageMinter, (P, stranger)), abi.encodeCall(PageNFT.registerSubpage, ("y", P)))));
        assertFalse(ok);
        assertEq(ret, _err(PageNFT.Unauthorized.selector));
    }

    // A8: an operator's round trip in one bundle does what the same calls one by one do
    function test_A8_operatorRoundTripEqualsSingles() public {
        Actor op = new Actor();
        vm.startPrank(alice);
        nft.setApprovalForAll(address(op), true);
        nft.setPrimaryPage(P);
        vm.stopPrank();
        bytes[] memory d = new bytes[](5);
        d[0] = abi.encodeCall(PageNFT.transferFrom, (alice, address(op), P));
        d[1] = abi.encodeCall(PageNFT.setText, (P, "url", "https://evil.example"));
        d[2] = abi.encodeCall(PageNFT.setSubpageMinter, (P, address(op)));
        d[3] = abi.encodeCall(PageNFT.registerSubpageFor, ("op", P, address(op)));
        d[4] = abi.encodeCall(PageNFT.transferFrom, (address(op), alice, P));
        uint256 snap = vm.snapshotState();
        address[] memory to = new address[](5);
        uint256[] memory val = new uint256[](5);
        for (uint256 i; i < 5; ++i) to[i] = address(nft);
        vm.recordLogs();
        op.run(to, val, d);
        uint256 nSingle = vm.getRecordedLogs().length;
        for (uint256 i; i < 5; ++i) assertTrue(op.okAt(i));
        string memory t1 = nft.text(P, "url");
        uint256 pn1 = nft.primaryPage(alice);
        vm.revertToState(snap);
        address[] memory to1 = new address[](1);
        uint256[] memory val1 = new uint256[](1);
        bytes[] memory d1 = new bytes[](1);
        to1[0] = address(nft);
        d1[0] = _mc(d);
        vm.recordLogs();
        op.run(to1, val1, d1);
        assertEq(vm.getRecordedLogs().length, nSingle);
        assertTrue(op.okAt(0));
        assertEq(nft.text(P, "url"), t1);
        assertEq(nft.primaryPage(alice), pn1);
        // what an operator can do alone anyway: plant a text record, which does not show once the
        // name is back with alice, and mint itself a subpage
        assertEq(nft.ownerOf(P), alice);
        assertEq(nft.text(P, "url"), "");
        assertEq(nft.profileWriter(P), address(op));
        assertEq(nft.ownerOf(_subId("op", P)), address(op));
        assertEq(nft.resolve(_subId("op", P)), address(op));
        assertEq(nft.subpageMinterOf(P), address(0));
        // the transfer out of alice in the round trip cleared her display name
        assertEq(nft.primaryPage(alice), 0);
        assertEq(nft.reverseResolve(alice), "");
    }

    // calls back in and the guard

    // A9: a receiver hook inside a guarded mint bundles writes but no guarded entry, and a bundle
    // inside the hook does not clear the outer guard
    function test_A9_hookBundleDoesNotFreeOuterGuard() public {
        Actor act = new Actor();
        uint256 s = _subId("hk", P);
        address[] memory to = new address[](3);
        bytes[] memory hd = new bytes[](3);
        for (uint256 i; i < 3; ++i) to[i] = address(nft);
        hd[0] = _mc(_b2(abi.encodeCall(PageNFT.setText, (s, "k", "v")), abi.encodeCall(PageNFT.setAddr, (s, hot))));
        hd[1] = abi.encodeCall(PageNFT.registerSubpageFor, ("hk2", P, address(act)));
        hd[2] = _mc(_b1(abi.encodeCall(PageNFT.withdraw, (bob))));
        act.armHook(to, hd);
        vm.prank(alice);
        nft.registerSubpageFor("hk", P, address(act));
        assertTrue(act.hookOkAt(0));
        assertFalse(act.hookOkAt(1));
        assertEq(act.hookRetAt(1), _err(REENTRANCY), "outer guard still set after the inner bundle");
        assertFalse(act.hookOkAt(2));
        assertEq(act.hookRetAt(2), _err(REENTRANCY));
        assertEq(nft.text(s, "k"), "v");
        assertEq(nft.resolve(s), hot);
        // and the guard is free once the outer call returns
        vm.prank(alice);
        nft.registerSubpage("after", P);
    }

    // A10: a payout recipient that calls multicall again gets Reentrancy for guarded entries and is paid once
    function test_A10_payoutReentersMulticall() public {
        Actor act = new Actor();
        uint256 z = _regTo(bob, "payme", address(act));
        uint256 z2 = _regTo(bob, "other2", carol);
        vm.warp(nft.expiresAt(z) + 90 days + 21 days + 1);
        P = _reg(alice, "alive3");
        nft.release(z);
        uint256 owed = nft.owed(address(act));
        assertGt(owed, 0);
        address[] memory to = new address[](4);
        bytes[] memory hd = new bytes[](4);
        for (uint256 i; i < 4; ++i) to[i] = address(nft);
        hd[0] = _mc(_b1(abi.encodeCall(PageNFT.withdraw, (address(act)))));
        hd[1] = _mc(_b1(abi.encodeCall(PageNFT.release, (z2))));
        hd[2] = _mc(_b1(_mc(_b1(abi.encodeCall(PageNFT.withdraw, (address(act)))))));
        hd[3] = _mc(_b1(abi.encodeCall(PageNFT.commit, (bytes32(uint256(7))))));
        act.armHook(to, hd);
        uint256 bal = address(act).balance;
        uint256 nb = address(nft).balance;
        vm.prank(stranger);
        nft.withdraw(address(act));
        assertEq(act.hookRetAt(0), _err(REENTRANCY));
        assertEq(act.hookRetAt(1), _err(REENTRANCY));
        assertEq(act.hookRetAt(2), _err(REENTRANCY));
        assertTrue(act.hookOkAt(3), "unguarded entries run during a payout");
        assertEq(address(act).balance - bal, owed);
        assertEq(nb - address(nft).balance, owed);
        assertEq(nft.owed(address(act)), 0);
        assertGt(nft.depositOf(z2), 0);
    }

    // A11: in one transaction, bundles with guarded entries leave the guard free for what follows
    function test_A11_guardFreeAfterBundlesInOneTx() public {
        Actor act = new Actor();
        vm.prank(alice);
        nft.transferFrom(alice, address(act), P);
        bytes[] memory d = new bytes[](5);
        d[0] = _mc(_b2(abi.encodeCall(PageNFT.registerSubpage, ("a", P)), abi.encodeCall(PageNFT.registerSubpage, ("b", P))));
        d[1] = abi.encodeCall(PageNFT.registerSubpage, ("c", P));
        d[2] = _mc(_b1(_mc(_b1(_mc(_b1(abi.encodeCall(PageNFT.registerSubpage, ("d", P))))))));
        d[3] = abi.encodeCall(PageNFT.registerSubpage, ("e", P));
        // a failing bundle with a guarded entry, then a guarded call again
        d[4] = _mc(_b2(abi.encodeCall(PageNFT.registerSubpage, ("f", P)), abi.encodeCall(PageNFT.withdraw, (bob))));
        address[] memory to = new address[](5);
        uint256[] memory val = new uint256[](5);
        for (uint256 i; i < 5; ++i) to[i] = address(nft);
        op_run(act, to, val, d);
        for (uint256 i; i < 4; ++i) assertTrue(act.okAt(i));
        assertFalse(act.okAt(4));
        assertEq(act.retAt(4), _err(NOTHING_TO_WITHDRAW));
        bytes[] memory d2 = new bytes[](1);
        d2[0] = abi.encodeCall(PageNFT.registerSubpage, ("g", P));
        address[] memory to2 = new address[](1);
        to2[0] = address(nft);
        op_run(act, to2, new uint256[](1), d2);
        assertTrue(act.okAt(0));
        assertEq(nft.balanceOf(address(act)), 1 + 6);
    }

    function op_run(Actor a, address[] memory to, uint256[] memory val, bytes[] memory d) internal {
        a.run(to, val, d);
    }

    // A12: deep nesting works and keeps the caller, and one failure deep inside undoes everything, the
    // transfer at the bottom included
    function test_A12_deepNesting() public {
        bytes memory e = abi.encodeCall(PageNFT.setText, (P, "deep", "yes"));
        bytes memory x = e;
        for (uint256 i; i < 40; ++i) x = _mc(_b2(abi.encodeCall(PageNFT.setText, (P, vm.toString(i), "n")), x));
        (bool ok,) = _call(alice, 0, x);
        assertTrue(ok);
        assertEq(nft.text(P, "deep"), "yes");
        assertEq(nft.text(P, "0"), "n");
        // a stranger's deep bundle fails with the single call's error
        (bool ok2, bytes memory r2) = _call(stranger, 0, x);
        assertFalse(ok2);
        assertEq(r2, _err(PageNFT.Unauthorized.selector));
        bytes memory y = _mc(_b1(abi.encodeCall(PageNFT.transferFrom, (alice, stranger, P))));
        for (uint256 i; i < 40; ++i) y = _mc(_b2(y, abi.encodeCall(PageNFT.setText, (P, "late", vm.toString(i)))));
        y = _mc(_b2(y, abi.encodeCall(PageNFT.setText, (P, "late2", "x"))));
        (ok2, r2) = _call(alice, 0, y);
        assertFalse(ok2);
        assertEq(r2, _err(PageNFT.Unauthorized.selector));
        assertEq(nft.ownerOf(P), alice);
    }

    // gas

    // A13: a receiver's huge revert blob reaches only the caller who picked that receiver
    function test_A13_revertBombEqualsDirect() public {
        Bomb bomb = new Bomb();
        bomb.set(100_000);
        uint256 g0 = gasleft();
        (bool ok1, bytes memory r1) = _call(alice, 0, abi.encodeWithSignature("safeTransferFrom(address,address,uint256)", alice, address(bomb), P));
        uint256 gDirect = g0 - gasleft();
        g0 = gasleft();
        (bool ok2, bytes memory r2) = _call(alice, 0,
            _mc(_b1(abi.encodeWithSignature("safeTransferFrom(address,address,uint256)", alice, address(bomb), P))));
        uint256 gBundle = g0 - gasleft();
        assertFalse(ok1);
        assertFalse(ok2);
        assertEq(r1.length, 100_000);
        assertEq(keccak256(r1), keccak256(r2));
        emit log_named_uint("revert bomb 100 KB, direct gas", gDirect);
        emit log_named_uint("revert bomb 100 KB, bundle gas", gBundle);
        assertEq(nft.ownerOf(P), alice);
    }

    // A14: a bundle that runs out of gas part way keeps nothing
    function test_A14_outOfGasKeepsNothing() public {
        string memory big = string(new bytes(20_000));
        bytes memory d = _mc(_b2(abi.encodeCall(PageNFT.setText, (P, "a", "first")), abi.encodeCall(PageNFT.setText, (P, "b", big))));
        vm.prank(alice);
        (bool ok, bytes memory ret) = address(nft).call{gas: 400_000}(d);
        assertFalse(ok);
        assertEq(ret.length, 0);
        assertEq(nft.text(P, "a"), "");
        // a hook that burns all gas: the bundle fails as the direct call does
        Burner burner = new Burner();
        vm.prank(alice);
        (bool ok1,) = address(nft).call{gas: 2_000_000}(abi.encodeWithSignature("safeTransferFrom(address,address,uint256)", alice, address(burner), P));
        vm.prank(alice);
        (bool ok2,) = address(nft).call{gas: 2_000_000}(_mc(_b1(abi.encodeWithSignature("safeTransferFrom(address,address,uint256)", alice, address(burner), P))));
        assertFalse(ok1);
        assertFalse(ok2);
        assertEq(nft.ownerOf(P), alice);
    }

    // A15: anyone can make a bundle fail by running one of its public entries first
    function test_A15_thirdPartyCanFailABundle() public {
        uint256 z = _releasable(alice, "grief");
        bytes[] memory d = _b2(abi.encodeCall(PageNFT.setText, (P, "url", "mine")), abi.encodeCall(PageNFT.release, (z)));
        uint256 snap = vm.snapshotState();
        // front run: a stranger releases first
        vm.prank(stranger);
        nft.release(z);
        (bool ok, bytes memory ret) = _call(alice, 0, _mc(d));
        assertFalse(ok);
        assertEq(ret, _err(PageNFT.NothingToRelease.selector));
        assertEq(nft.text(P, "url"), "", "the profile write is lost with the bundle");
        // one by one, the profile write would have stayed
        (ok,) = _call(alice, 0, d[0]);
        assertTrue(ok);
        vm.revertToState(snap);
        // the same with withdraw, which anyone may call for any account
        nft.release(z);
        vm.prank(stranger);
        nft.withdraw(alice);
        (ok, ret) = _call(alice, 0, _mc(_b2(abi.encodeCall(PageNFT.setText, (P, "url", "mine")), abi.encodeCall(PageNFT.withdraw, (alice)))));
        assertFalse(ok);
        assertEq(ret, _err(NOTHING_TO_WITHDRAW));
        // and with commit, whose hash a watcher can copy
        bytes32 c = keccak256("c");
        vm.prank(stranger);
        nft.commit(c);
        (ok, ret) = _call(alice, 0, _mc(_b2(abi.encodeCall(PageNFT.setText, (P, "url", "mine")), abi.encodeCall(PageNFT.commit, (c)))));
        assertFalse(ok);
        assertEq(ret, _err(PageNFT.AlreadyCommitted.selector));
    }

    // contract holders

    // A16: a contract holder bundles minter picks, mints and records; a failure undoes all of it
    function test_A16_contractHolderBundles() public {
        SafeLike safe = new SafeLike(bob);
        vm.prank(alice);
        nft.transferFrom(alice, address(safe), P);
        bytes[] memory d = new bytes[](6);
        d[0] = abi.encodeCall(PageNFT.setSubpageMinter, (P, carol));
        for (uint256 i = 1; i < 5; ++i) d[i] = abi.encodeCall(PageNFT.registerSubpageFor, (string.concat("s", vm.toString(i)), P, dave));
        d[5] = abi.encodeCall(PageNFT.setText, (_subId("s1", P), "k", "v"));
        vm.prank(bob);
        vm.expectRevert(PageNFT.Unauthorized.selector);
        safe.exec(address(nft), 0, _mc(d));
        assertEq(nft.balanceOf(dave), 0);
        assertEq(nft.subpageMinterOf(P), address(0));
        d[5] = abi.encodeCall(PageNFT.setText, (P, "k", "v"));
        vm.prank(bob);
        safe.exec(address(nft), 0, _mc(d));
        assertEq(nft.balanceOf(dave), 4);
        assertEq(nft.subpageMinterOf(P), carol);
        // bob, who runs the Safe, has no power of his own on P
        (bool ok,) = _call(bob, 0, _mc(_b1(abi.encodeCall(PageNFT.setText, (P, "k", "w")))));
        assertFalse(ok);
        // value through the Safe is refused
        vm.deal(address(safe), 1 ether);
        vm.prank(bob);
        vm.expectRevert(bytes(""));
        safe.exec(address(nft), 1, _mc(new bytes[](0)));
    }

    // A17: a stranger's bundle of random entries goes through only when each entry is a commit or an
    // approval for all, and leaves the holders, the records, the minter and the stranger's display name
    // and balance as they were, every seed
    function testFuzz_A17_strangerNeverGains(uint256 seed) public {
        uint256 s = _subId("sb", P);
        vm.prank(alice);
        nft.registerSubpageFor("sb", P, bob);
        bytes[] memory pool = new bytes[](10);
        pool[0] = abi.encodeCall(PageNFT.setText, (P, "k", "x"));
        pool[1] = abi.encodeCall(PageNFT.setAddr, (s, stranger));
        pool[2] = abi.encodeCall(PageNFT.transferFrom, (alice, stranger, P));
        pool[3] = abi.encodeCall(PageNFT.approve, (stranger, P));
        pool[4] = abi.encodeCall(PageNFT.registerSubpage, ("mine", P));
        pool[5] = abi.encodeCall(PageNFT.setSubpageMinter, (P, stranger));
        pool[6] = abi.encodeCall(PageNFT.clearRecords, (s));
        pool[7] = abi.encodeCall(PageNFT.setPrimaryPage, (s));
        pool[8] = abi.encodeCall(ERC721.setApprovalForAll, (stranger, true));
        pool[9] = abi.encodeCall(PageNFT.commit, (bytes32(seed)));
        uint256 n = 1 + seed % 6;
        bytes[] memory d = new bytes[](n);
        for (uint256 i; i < n; ++i) d[i] = pool[uint256(keccak256(abi.encode(seed, i))) % 10];
        address o = nft.ownerOf(P);
        address os = nft.ownerOf(s);
        (bool ok,) = _call(stranger, 0, _mc(d));
        if (ok) {
            // only harmless entries got through
            for (uint256 i; i < n; ++i) {
                bytes4 sel = bytes4(d[i]);
                assertTrue(sel == ERC721.setApprovalForAll.selector || sel == PageNFT.commit.selector);
            }
        }
        assertEq(nft.ownerOf(P), o);
        assertEq(nft.ownerOf(s), os);
        assertEq(nft.text(P, "k"), "");
        assertEq(nft.resolve(s), bob);
        assertEq(nft.subpageMinterOf(P), address(0));
        assertEq(nft.primaryPage(stranger), 0);
        assertEq(nft.balanceOf(stranger), 0);
    }

    // A18: a payee paid by a bundled withdraw claims registrar proceeds from its receive and tries
    // the PageNFT bundle again; each ledger pays once
    function test_A18_crossContractPayouts() public {
        Actor act = new Actor();
        uint256 z = _regTo(bob, "payee18", address(act));
        vm.warp(nft.expiresAt(z) + 90 days + 21 days + 1);
        P = _reg(alice, "alive18");
        nft.release(z);
        _setMinter(P, address(reg));
        vm.prank(alice);
        reg.configure(P, address(act), address(0), 0.01 ether, true, address(0), 0, false);
        vm.prank(buyer);
        reg.registerSubpage{value: 0.01 ether}(P, "sold", 0.01 ether, address(0));
        uint256 owedNft = nft.owed(address(act));
        uint256 owedReg = reg.proceedsOf(address(act));
        assertGt(owedNft, 0);
        assertEq(owedReg, 0.01 ether);
        address[] memory to = new address[](3);
        bytes[] memory hd = new bytes[](3);
        to[0] = address(reg);
        hd[0] = abi.encodeCall(SubpageRegistrar.claimProceedsFor, (address(act)));
        to[1] = address(nft);
        hd[1] = _mc(_b1(abi.encodeCall(PageNFT.withdraw, (address(act)))));
        to[2] = address(reg);
        hd[2] = abi.encodeCall(SubpageRegistrar.claimProceedsFor, (address(act)));
        act.armHook(to, hd);
        uint256 b0 = address(act).balance;
        uint256 n0 = address(nft).balance;
        uint256 r0 = address(reg).balance;
        (bool ok,) = _call(stranger, 0, _mc(_b1(abi.encodeCall(PageNFT.withdraw, (address(act))))));
        assertTrue(ok);
        assertTrue(act.hookOkAt(0), "registrar claim from inside the PageNFT payout");
        assertEq(act.hookRetAt(1), _err(REENTRANCY));
        assertFalse(act.hookOkAt(2));
        assertEq(address(act).balance - b0, owedNft + owedReg);
        assertEq(n0 - address(nft).balance, owedNft);
        assertEq(r0 - address(reg).balance, owedReg);
        assertEq(nft.owed(address(act)) + reg.proceedsOf(address(act)), 0);
    }

    // A19: an overpaying payer contract calls a bundle again from its refund; guarded entries fail,
    // unguarded ones run, and the payer pays exactly one fee
    function test_A19_refundReentersBundle() public {
        RefundPayer payer = new RefundPayer();
        vm.deal(address(payer), 5 ether);
        bytes32 secret = keccak256("r");
        payer.exec(address(nft), 0, abi.encodeCall(PageNFT.commit, (nft.makeCommitment("refund19", address(payer), 0, secret))));
        vm.warp(block.timestamp + 61);
        uint256 id = _id("refund19");
        address[] memory to = new address[](4);
        bytes[] memory hd = new bytes[](4);
        for (uint256 i; i < 4; ++i) to[i] = address(nft);
        hd[0] = _mc(_b1(abi.encodeCall(PageNFT.renew, (id))));
        hd[1] = _mc(_b1(abi.encodeCall(PageNFT.withdraw, (address(payer)))));
        hd[2] = _mc(_b2(abi.encodeCall(PageNFT.setText, (id, "k", "v")), abi.encodeCall(PageNFT.setPrimaryPage, (id))));
        hd[3] = _mc(_b1(abi.encodeCall(ERC721.transferFrom, (address(payer), bob, id))));
        payer.arm(to, hd);
        uint256 b0 = address(payer).balance;
        uint256 n0 = address(nft).balance;
        payer.exec(address(nft), 1 ether, abi.encodeCall(PageNFT.reveal, ("refund19", address(payer), 0, secret)));
        assertEq(payer.retAt(0), _err(REENTRANCY));
        assertEq(payer.retAt(1), _err(REENTRANCY));
        assertTrue(payer.okAt(2));
        assertTrue(payer.okAt(3), "a transfer inside the refund is unguarded, as a direct one is");
        assertEq(b0 - address(payer).balance, 0.0001 ether);
        assertEq(address(nft).balance - n0, 0.0001 ether);
        assertEq(nft.expiresAt(id), block.timestamp + 365 days, "not renewed");
        // the display name set in the refund was cleared by the transfer that followed it
        assertEq(nft.primaryPage(address(payer)), 0);
        assertEq(nft.ownerOf(id), bob);
    }
}

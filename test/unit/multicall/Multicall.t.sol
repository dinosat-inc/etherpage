// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Vm} from "forge-std/Test.sol";
import {ERC721} from "solady/tokens/ERC721.sol";
import {PageNFT} from "../../../src/PageNFT.sol";
import {MinterBase} from "../../utils/MinterBase.sol";
import {SafeLike} from "../../utils/MinterMocks.sol";
import {Reenterer, LoudRefuser} from "../../utils/MulticallMocks.sol";

// The multicall of PageNFT. Most tests run a bundle and the same calls one by one from the same
// start state and require the same outcome: same success, same results, same logs, same state, or
// the same revert data from the first failing call and no state change.
contract MulticallTest is MinterBase {
    uint256 P;
    uint256[] watch;
    address[] accts;
    string[5] keys = ["avatar", "url", "com.twitter", "description", "k"];

    function setUp() public override {
        super.setUp();
        P = _reg(alice, "alice");
        address[9] memory a = [alice, bob, carol, dave, hot, hot2, stranger, payout, DEAD];
        for (uint256 i; i < 9; ++i) accts.push(a[i]);
        watch.push(P);
    }

    // helpers

    function _one(bytes memory d) internal pure returns (bytes[] memory b) {
        b = new bytes[](1);
        b[0] = d;
    }

    function _mc(bytes[] memory d) internal pure returns (bytes memory) {
        return abi.encodeCall(PageNFT.multicall, (d));
    }

    function _send(address who, uint256 value, bytes memory data) internal returns (bool ok, bytes memory ret) {
        vm.deal(who, who.balance + value);
        vm.prank(who);
        (ok, ret) = address(nft).call{value: value}(data);
    }

    function _owner(uint256 id) internal view returns (address) {
        (bool ok, bytes memory r) = address(nft).staticcall(abi.encodeCall(ERC721.ownerOf, (id)));
        return ok ? abi.decode(r, (address)) : address(0);
    }

    // a hash of the PageNFT balance and of many views of the watched ids and accounts, from holders, records and
    // money to the main, OP, Ethereum and Bitcoin answers, five text keys, minters, approvals and display names
    function _stateHash() internal view returns (bytes32 h) {
        h = keccak256(abi.encode(address(nft).balance));
        for (uint256 i; i < watch.length; ++i) {
            uint256 id = watch[i];
            h = keccak256(abi.encode(h, _owner(id), nft.getPageName(id), nft.recordVersion(id), nft.depositOf(id)));
            h = keccak256(abi.encode(h, nft.referrerOf(id), nft.epochOf(id), nft.parentOf(id), nft.expiresAt(id)));
            if (_owner(id) != address(0)) h = keccak256(abi.encode(h, nft.getApproved(id)));
            h = keccak256(abi.encode(h, nft.resolve(id), nft.addr(id, COIN_OP), nft.addr(id, 60), nft.addr(id, 0)));
            h = keccak256(abi.encode(h, nft.contenthash(id), nft.subpageMinterOf(id), nft.payee(id)));
            for (uint256 k; k < keys.length; ++k) h = keccak256(abi.encode(h, nft.text(id, keys[k])));
            bytes32 base = keccak256(abi.encode(id, MINTER_SLOT));
            h = keccak256(abi.encode(h, vm.load(address(nft), base), vm.load(address(nft), bytes32(uint256(base) + 1))));
        }
        for (uint256 i; i < accts.length; ++i) {
            address a = accts[i];
            h = keccak256(abi.encode(h, a.balance, nft.owed(a), nft.primaryPage(a), nft.reverseResolve(a)));
            h = keccak256(abi.encode(h, a == address(0) ? 0 : nft.balanceOf(a)));
            for (uint256 j; j < accts.length; ++j) h = keccak256(abi.encode(h, nft.isApprovedForAll(a, accts[j])));
        }
    }

    function _logsHash(Vm.Log[] memory logs) internal pure returns (bytes32 h) {
        for (uint256 i; i < logs.length; ++i) {
            h = keccak256(abi.encode(h, logs[i].emitter, logs[i].topics, logs[i].data));
        }
    }

    struct Run {
        bool ok;
        bytes failRet;
        uint256 failAt;
        bytes[] rets;
        bytes32 logs;
        bytes32 state;
    }

    function _runSingles(address who, bytes[] memory d) internal returns (Run memory r) {
        r.rets = new bytes[](d.length);
        r.ok = true;
        vm.recordLogs();
        for (uint256 i; i < d.length; ++i) {
            (bool ok, bytes memory ret) = _send(who, 0, d[i]);
            if (!ok) {
                r.ok = false;
                r.failRet = ret;
                r.failAt = i;
                break;
            }
            r.rets[i] = ret;
        }
        r.logs = _logsHash(vm.getRecordedLogs());
        r.state = _stateHash();
    }

    // runs d one by one and as one bundle from the same state and requires the same outcome; the
    // state left is the bundle's
    function _same(address who, bytes[] memory d) internal returns (bool ok, bytes[] memory results) {
        bytes32 before = _stateHash();
        uint256 snap = vm.snapshotState();
        Run memory s = _runSingles(who, d);
        vm.revertToStateAndDelete(snap);
        vm.recordLogs();
        (bool bok, bytes memory bret) = _send(who, 0, _mc(d));
        bytes32 blogs = _logsHash(vm.getRecordedLogs());
        assertEq(bok, s.ok, "bundle success differs from the calls one by one");
        if (!s.ok) {
            assertEq(bret, s.failRet, "bundle revert data differs from the first failing call");
            assertEq(_stateHash(), before, "a failed bundle changed state");
            return (false, results);
        }
        results = abi.decode(bret, (bytes[]));
        assertEq(results.length, d.length, "result count");
        for (uint256 i; i < d.length; ++i) assertEq(results[i], s.rets[i], "result differs");
        assertEq(blogs, s.logs, "logs differ");
        assertEq(_stateHash(), s.state, "state differs");
        return (true, results);
    }

    function _sub(address to, string memory label) internal returns (uint256 id) {
        vm.prank(alice);
        id = nft.registerSubpageFor(label, P, to);
        watch.push(id);
    }

    // the three uses

    function test_profileBundle() public {
        bytes[] memory d = new bytes[](9);
        d[0] = abi.encodeCall(PageNFT.setAddr, (P, hot));
        d[1] = abi.encodeCall(PageNFT.setAddrForCoin, (P, 60, abi.encodePacked(hot2)));
        d[2] = abi.encodeCall(PageNFT.setAddrForCoin, (P, 0, hex"0014beef"));
        d[3] = abi.encodeCall(PageNFT.setText, (P, "avatar", "ipfs://avatar"));
        d[4] = abi.encodeCall(PageNFT.setText, (P, "url", "https://alice.example"));
        d[5] = abi.encodeCall(PageNFT.setText, (P, "com.twitter", "alice"));
        d[6] = abi.encodeCall(PageNFT.setText, (P, "description", "hello"));
        d[7] = abi.encodeCall(PageNFT.setContenthash, (P, hex"e30101701220aa"));
        d[8] = abi.encodeCall(PageNFT.setPrimaryPage, (P));
        (bool ok, bytes[] memory res) = _same(alice, d);
        assertTrue(ok);
        for (uint256 i; i < res.length; ++i) assertEq(res[i].length, 0, "writers return nothing");
        assertEq(nft.resolve(P), hot);
        assertEq(nft.addr(P, 60), abi.encodePacked(hot2));
        assertEq(nft.text(P, "com.twitter"), "alice");
        assertEq(nft.contenthash(P), hex"e30101701220aa");
        assertEq(nft.primaryPage(alice), P);
    }

    function test_deleteBundle() public {
        uint256 s = _sub(bob, "bob");
        vm.startPrank(bob);
        nft.setPrimaryPage(s);
        nft.setText(s, "k", "v");
        nft.setAddr(s, carol);
        vm.stopPrank();
        assertEq(nft.reverseResolve(carol), "");
        assertEq(nft.primaryPage(bob), s);
        bytes[] memory d = new bytes[](3);
        d[0] = abi.encodeCall(PageNFT.setPrimaryPage, (0));
        d[1] = abi.encodeCall(PageNFT.clearRecords, (s));
        d[2] = abi.encodeCall(PageNFT.transferFrom, (bob, DEAD, s));
        (bool ok,) = _same(bob, d);
        assertTrue(ok);
        assertEq(nft.ownerOf(s), DEAD);
        assertEq(nft.primaryPage(bob), 0);
        assertEq(nft.resolve(s), address(0));
        assertEq(nft.text(s, "k"), "");
        assertTrue(nft.isAvailable("bob", P));
        assertEq(nft.recordVersion(s), 1, "clearRecords bumped the version once");
    }

    // clearRecords after the send finds a deleted subpage and the whole bundle is undone
    function test_deleteBundleWrongOrderUndoesTheSend() public {
        uint256 s = _sub(bob, "bob");
        bytes[] memory d = new bytes[](2);
        d[0] = abi.encodeCall(PageNFT.transferFrom, (bob, DEAD, s));
        d[1] = abi.encodeCall(PageNFT.clearRecords, (s));
        (bool ok,) = _same(bob, d);
        assertFalse(ok);
        assertEq(nft.ownerOf(s), bob);
        vm.prank(bob);
        vm.expectRevert(PageNFT.Expired.selector);
        nft.multicall(d);
    }

    function _batch(address to0, uint256 n, string memory prefix) internal returns (bytes[] memory d) {
        d = new bytes[](n);
        for (uint256 i; i < n; ++i) {
            string memory label = string.concat(prefix, vm.toString(i));
            address to = i % 3 == 0 ? to0 : i % 3 == 1 ? carol : dave;
            d[i] = abi.encodeCall(PageNFT.registerSubpageFor, (label, P, to));
            watch.push(_subId(label, P));
        }
    }

    function test_batch50ByHolder() public {
        bytes[] memory d = _batch(bob, 50, "m");
        (bool ok, bytes[] memory res) = _same(alice, d);
        assertTrue(ok);
        for (uint256 i; i < 50; ++i) {
            uint256 id = abi.decode(res[i], (uint256));
            assertEq(id, _subId(string.concat("m", vm.toString(i)), P));
            assertEq(nft.parentOf(id), P);
        }
        assertEq(nft.balanceOf(carol), 17);
    }

    function test_batch50ByMinter() public {
        _setMinter(P, hot);
        bytes[] memory d = _batch(hot, 50, "n");
        (bool ok, bytes[] memory res) = _same(hot, d);
        assertTrue(ok);
        assertEq(abi.decode(res[49], (uint256)), _subId("n49", P));
        assertEq(nft.balanceOf(hot), 17);
        // the minter only creates: one live label in the batch undoes all of it
        bytes[] memory again = _batch(hot, 3, "fresh");
        again[2] = abi.encodeCall(PageNFT.registerSubpageFor, ("n7", P, hot));
        (ok,) = _same(hot, again);
        assertFalse(ok);
        vm.prank(hot);
        vm.expectRevert(PageNFT.AlreadyRegistered.selector);
        nft.multicall(again);
        assertEq(_owner(_subId("fresh0", P)), address(0));
    }

    function test_batchByAMinterNoLongerCounted() public {
        _setMinter(P, hot);
        bytes[] memory d = _batch(hot, 5, "q");
        vm.prank(alice);
        nft.transferFrom(alice, bob, P);
        (bool ok,) = _same(hot, d);
        assertFalse(ok);
        vm.prank(hot);
        vm.expectRevert(PageNFT.NotParentOwner.selector);
        nft.multicall(d);
    }

    function test_takeBacksInABatch() public {
        uint256[] memory s = new uint256[](10);
        for (uint256 i; i < 10; ++i) s[i] = _sub(i % 2 == 0 ? bob : carol, string.concat("t", vm.toString(i)));
        vm.prank(bob);
        nft.setPrimaryPage(s[0]);
        vm.prank(carol);
        nft.setText(s[1], "k", "v");
        bytes[] memory d = new bytes[](10);
        for (uint256 i; i < 10; ++i) {
            d[i] = abi.encodeCall(PageNFT.registerSubpageFor, (string.concat("t", vm.toString(i)), P, i < 5 ? DEAD : alice));
        }
        (bool ok,) = _same(alice, d);
        assertTrue(ok);
        assertEq(nft.primaryPage(bob), 0, "take-back cleared the holder's primary name");
        assertEq(nft.ownerOf(s[0]), DEAD);
        assertEq(nft.ownerOf(s[9]), alice);
        assertEq(nft.recordVersion(s[1]), 1);
        assertEq(nft.epochOf(s[3]), 2);
        assertEq(nft.text(s[1], "k"), "");
        // a counted minter cannot take back inside a bundle either
        _setMinter(P, hot);
        d = _one(abi.encodeCall(PageNFT.registerSubpageFor, ("t7", P, hot)));
        (ok,) = _same(hot, d);
        assertFalse(ok);
    }

    function test_batchSubpageMinterSettings() public {
        uint256 P2 = _reg(alice, "second");
        watch.push(P2);
        bytes[] memory d = new bytes[](4);
        d[0] = abi.encodeCall(PageNFT.setSubpageMinter, (P, address(reg)));
        d[1] = abi.encodeCall(PageNFT.setSubpageMinter, (P2, hot));
        d[2] = abi.encodeCall(PageNFT.registerSubpageFor, ("x", P2, bob));
        d[3] = abi.encodeCall(PageNFT.setSubpageMinter, (P2, address(0)));
        (bool ok,) = _same(alice, d);
        assertTrue(ok);
        assertEq(nft.subpageMinterOf(P), address(reg));
        assertEq(nft.subpageMinterOf(P2), address(0));
    }

    // failure

    function test_oneFailingEntryRevertsEverything() public {
        bytes[] memory d = new bytes[](4);
        d[0] = abi.encodeCall(PageNFT.setText, (P, "k", "v"));
        d[1] = abi.encodeCall(PageNFT.setAddr, (P, hot));
        d[2] = abi.encodeCall(PageNFT.setAddr, (P, address(nft)));
        d[3] = abi.encodeCall(PageNFT.setText, (P, "url", "u"));
        (bool ok,) = _same(alice, d);
        assertFalse(ok);
        vm.prank(alice);
        vm.expectRevert(PageNFT.InvalidRecipient.selector);
        nft.multicall(d);
        assertEq(nft.text(P, "k"), "");
        assertEq(nft.resolve(P), alice);
    }

    function test_revertDataPassesThroughUnchanged() public {
        LoudRefuser loud = new LoudRefuser();
        bytes memory call1 = abi.encodeCall(PageNFT.registerSubpageFor, ("x", P, address(loud)));
        (bool ok1, bytes memory direct) = _send(alice, 0, call1);
        assertFalse(ok1);
        assertGt(direct.length, 68, "a long reason");
        bytes[] memory d = new bytes[](2);
        d[0] = abi.encodeCall(PageNFT.setText, (P, "k", "v"));
        d[1] = call1;
        (bool ok, bytes memory ret) = _send(alice, 0, _mc(d));
        assertFalse(ok);
        assertEq(ret, direct, "revert data changed");
        // an unknown function fails with empty data, as it does alone
        (ok, ret) = _send(alice, 0, _mc(_one(hex"deadbeef")));
        assertFalse(ok);
        assertEq(ret.length, 0);
        // cut arguments fail as they do alone
        bytes memory cut = abi.encodePacked(PageNFT.setText.selector, P);
        (bool ok2, bytes memory r2) = _send(alice, 0, cut);
        (ok, ret) = _send(alice, 0, _mc(_one(cut)));
        assertFalse(ok2);
        assertEq(ok, ok2);
        assertEq(ret, r2);
        // an error from a view passes through too
        bytes memory bad = abi.encodeWithSignature("normalize(string)", "");
        (ok2, r2) = _send(alice, 0, bad);
        (ok, ret) = _send(alice, 0, _mc(_one(bad)));
        assertEq(ok, ok2);
        assertEq(ret, r2);
    }

    // value

    function testFuzz_valueRefused(uint96 v, uint8 kind) public {
        v = uint96(bound(v, 1, 1000 ether));
        bytes[] memory d;
        uint256 k = kind % 4;
        if (k == 1) d = _one(abi.encodeCall(PageNFT.setText, (P, "k", "v")));
        if (k == 2) d = _one(abi.encodeCall(PageNFT.renew, (P)));
        if (k == 3) d = _one(_mc(new bytes[](0)));
        if (k == 0) d = new bytes[](0);
        uint256 bal = address(nft).balance;
        vm.deal(alice, alice.balance + v);
        bytes32 before = _stateHash();
        uint256 aliceBal = alice.balance;
        vm.prank(alice);
        (bool ok, bytes memory ret) = address(nft).call{value: v}(_mc(d));
        assertFalse(ok, "a bundle with value was accepted");
        assertEq(ret.length, 0, "the refusal is the compiler's empty revert");
        assertEq(address(nft).balance, bal);
        assertEq(alice.balance, aliceBal);
        assertEq(_stateHash(), before);
    }

    function test_valueRefusedThroughAContractWallet() public {
        SafeLike safe = new SafeLike(alice);
        vm.deal(address(safe), 1 ether);
        vm.prank(alice);
        vm.expectRevert(bytes(""));
        safe.exec(address(nft), 1, _mc(new bytes[](0)));
    }

    function test_paidCallsFailInside() public {
        // renew: a live name, the holder asks, nothing paid
        (bool ok,) = _same(alice, _one(abi.encodeCall(PageNFT.renew, (P))));
        assertFalse(ok);
        vm.prank(alice);
        vm.expectRevert(PageNFT.InsufficientFee.selector);
        nft.multicall(_one(abi.encodeCall(PageNFT.renew, (P))));

        // reveal for oneself and for another wallet, with a ripe commitment
        bytes32 secret = keccak256("s");
        vm.startPrank(bob);
        nft.commit(nft.makeCommitment("bobby", bob, 0, secret));
        nft.commit(nft.makeCommitment("carols", carol, 0, secret));
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + 61);
        uint256 bal = address(nft).balance;
        bytes[] memory d = new bytes[](2);
        d[0] = abi.encodeCall(PageNFT.reveal, ("bobby", bob, 0, secret));
        d[1] = abi.encodeCall(PageNFT.reveal, ("carols", carol, 0, secret));
        (ok,) = _same(bob, d);
        assertFalse(ok);
        vm.prank(bob);
        vm.expectRevert(PageNFT.InsufficientFee.selector);
        nft.multicall(d);
        (ok,) = _same(bob, _one(d[1]));
        assertFalse(ok);
        assertEq(address(nft).balance, bal);
        // paid directly the bobby reveal still works, so its commitment was intact
        (,,, uint256 total) = nft.quote("bobby");
        vm.prank(bob);
        nft.reveal{value: total}("bobby", bob, 0, secret);
        assertEq(nft.ownerOf(_id("bobby")), bob);
    }

    // one payment can never be counted twice: the value never reaches a bundled call
    function testFuzz_noPaymentReuse(uint8 n) public {
        n = uint8(bound(n, 1, 6));
        bytes[] memory d = new bytes[](n);
        for (uint256 i; i < n; ++i) d[i] = abi.encodeCall(PageNFT.renew, (P));
        uint64 exp = uint64(nft.expiresAt(P));
        uint256 dep = nft.depositOf(P);
        for (uint256 v; v < 3; ++v) {
            uint256 value = v == 0 ? 0 : v == 1 ? 0.0005 ether : 1 ether;
            (bool ok,) = _send(alice, value, _mc(d));
            assertFalse(ok);
        }
        assertEq(nft.expiresAt(P), exp);
        assertEq(nft.depositOf(P), dep);
    }

    // authorization per entry

    function _forbidden(uint256 k, uint256 s) internal view returns (bytes memory) {
        if (k == 0) return abi.encodeCall(PageNFT.setAddr, (P, stranger));
        if (k == 1) return abi.encodeCall(PageNFT.setAddrForCoin, (P, 60, abi.encodePacked(stranger)));
        if (k == 2) return abi.encodeCall(PageNFT.setText, (P, "k", "x"));
        if (k == 3) return abi.encodeCall(PageNFT.setContenthash, (P, hex"01"));
        if (k == 4) return abi.encodeCall(PageNFT.clearRecords, (P));
        if (k == 5) return abi.encodeCall(PageNFT.setPrimaryPage, (P));
        if (k == 6) return abi.encodeCall(PageNFT.setSubpageMinter, (P, stranger));
        if (k == 7) return abi.encodeCall(PageNFT.registerSubpage, ("z", P));
        if (k == 8) return abi.encodeCall(PageNFT.registerSubpageFor, ("z", P, stranger));
        if (k == 9) return abi.encodeCall(PageNFT.transferFrom, (alice, stranger, P));
        if (k == 10) return abi.encodeWithSignature("safeTransferFrom(address,address,uint256)", alice, stranger, P);
        if (k == 11) return abi.encodeWithSignature("safeTransferFrom(address,address,uint256,bytes)", alice, stranger, P, "");
        if (k == 12) return abi.encodeCall(PageNFT.approve, (stranger, P));
        if (k == 13) return abi.encodeCall(PageNFT.setAddr, (s, stranger));
        if (k == 14) return abi.encodeCall(PageNFT.transferFrom, (bob, stranger, s));
        if (k == 15) return abi.encodeCall(PageNFT.release, (P));
        return abi.encodeCall(PageNFT.withdraw, (stranger));
    }

    function _harmless(uint256 k, uint256 i) internal view returns (bytes memory) {
        if (k == 0) return abi.encodeCall(PageNFT.commit, (keccak256(abi.encode(i, block.timestamp))));
        if (k == 1) return abi.encodeCall(PageNFT.setPrimaryPage, (0));
        if (k == 2) return abi.encodeCall(ERC721.setApprovalForAll, (hot, true));
        return abi.encodeCall(PageNFT.getPageName, (P));
    }

    function testFuzz_strangerFailsWhereItsSingleCallFails(uint8 k, uint8 pos, uint8 len, uint8 h) public {
        uint256 s = _sub(bob, "b");
        len = uint8(bound(len, 1, 5));
        pos = uint8(pos % len);
        bytes memory bad = _forbidden(k % 17, s);
        (bool okSingle, bytes memory single) = _send(stranger, 0, bad);
        assertFalse(okSingle, "the stranger's single call worked");
        bytes[] memory d = new bytes[](len);
        for (uint256 i; i < len; ++i) d[i] = i == pos ? bad : _harmless((uint256(h) + i) % 4, i);
        (bool ok, bytes memory ret) = _send(stranger, 0, _mc(d));
        assertFalse(ok);
        assertEq(ret, single, "the bundle failed differently from the single call");
        _same(stranger, d);
    }

    // an operator's bundle can move names but cannot write their records, exactly as alone
    function test_operatorBundle() public {
        uint256 P2 = _reg(alice, "second");
        watch.push(P2);
        vm.prank(alice);
        nft.setApprovalForAll(hot, true);
        bytes[] memory d = new bytes[](2);
        d[0] = abi.encodeCall(PageNFT.transferFrom, (alice, carol, P));
        d[1] = abi.encodeCall(PageNFT.transferFrom, (alice, carol, P2));
        (bool ok,) = _same(hot, d);
        assertTrue(ok);
        assertEq(nft.ownerOf(P2), carol);
        (ok,) = _same(hot, _one(abi.encodeCall(PageNFT.setText, (P, "k", "v"))));
        assertFalse(ok);
    }

    // the caller seen by every entry and by the receiver hook is the account that sent the bundle
    function test_callerIsKeptThroughAContractWallet() public {
        SafeLike safe = new SafeLike(bob);
        Reenterer r = new Reenterer();
        vm.prank(alice);
        nft.transferFrom(alice, address(safe), P);
        bytes[] memory d = new bytes[](2);
        d[0] = abi.encodeCall(PageNFT.setText, (P, "k", "safe"));
        d[1] = abi.encodeWithSignature("safeTransferFrom(address,address,uint256)", address(safe), address(r), P);
        vm.prank(bob);
        safe.exec(address(nft), 0, _mc(d));
        assertEq(nft.ownerOf(P), address(r));
        assertEq(r.lastOperator(), address(safe));
        assertEq(r.lastFrom(), address(safe));
        // the write was made by the wallet, and it stops showing once the name has left the wallet
        assertEq(nft.profileWriter(P), address(safe));
        assertEq(nft.text(P, "k"), "");
    }

    // reentry

    // an account with owed ETH, reached by letting its name lapse and releasing the deposit
    // alice registers her name again afterwards, so it is live for the rest of the test
    function _owedTo(address who) internal returns (uint256 id) {
        id = _regTo(alice, "owedname", who);
        vm.warp(nft.expiresAt(id) + 90 days + 21 days + 1);
        nft.release(id);
        assertGt(nft.owed(who), 0);
        _reg(alice, "alice");
    }

    function test_withdrawRecipientCannotReenterAGuardedCallThroughABundle() public {
        Reenterer r = new Reenterer();
        _owedTo(address(r));
        uint256 amount = nft.owed(address(r));
        r.arm(address(nft), _mc(_one(abi.encodeCall(PageNFT.withdraw, (address(r))))), "", false);
        // inside a bundle
        vm.prank(stranger);
        nft.multicall(_one(abi.encodeCall(PageNFT.withdraw, (address(r)))));
        assertFalse(r.ethOk());
        assertEq(r.ethRet(), abi.encodeWithSelector(REENTRANCY));
        assertEq(address(r).balance, amount, "paid exactly once");
        assertEq(nft.owed(address(r)), 0);
    }

    function test_withdrawRecipientCanStillCallUnguardedFunctions() public {
        Reenterer r = new Reenterer();
        _owedTo(address(r));
        bytes32 c = keccak256("c");
        r.arm(address(nft), _mc(_one(abi.encodeCall(PageNFT.commit, (c)))), "", true);
        vm.prank(stranger);
        nft.withdraw(address(r));
        assertTrue(r.ethOk());
        assertEq(nft.commitments(c), block.timestamp);
    }

    function test_sequentialGuardedEntriesWork() public {
        uint256 a1 = _regTo(alice, "first", bob);
        uint256 a2 = _regTo(alice, "second", carol);
        watch.push(a1);
        watch.push(a2);
        vm.warp(nft.expiresAt(a2) + 90 days + 21 days + 1);
        bytes[] memory d = new bytes[](6);
        d[0] = abi.encodeCall(PageNFT.release, (a1));
        d[1] = abi.encodeCall(PageNFT.release, (a2));
        d[2] = abi.encodeCall(PageNFT.withdraw, (bob));
        d[3] = abi.encodeCall(PageNFT.withdraw, (carol));
        d[4] = abi.encodeCall(PageNFT.release, (P));
        d[5] = abi.encodeCall(PageNFT.withdraw, (alice));
        uint256 bobBal = bob.balance;
        (bool ok, bytes[] memory res) = _same(stranger, d);
        assertTrue(ok);
        assertEq(bob.balance - bobBal, 0.0001 ether);
        assertEq(abi.decode(res[3], (uint256)), 0.0001 ether);
        assertEq(address(nft).balance, 0);
        // a later withdraw finds nothing
        (ok,) = _same(stranger, _one(abi.encodeCall(PageNFT.withdraw, (bob))));
        assertFalse(ok);
        // the guard is free again after the bundle
        uint256 a3 = _reg(bob, "third");
        vm.prank(bob);
        nft.renew{value: 0.0001 ether}(a3);
    }

    // the hook of a guarded mint calls multicall: guarded entries fail, the custody route works
    function test_hookOfAGuardedMintCallsMulticall() public {
        Reenterer r = new Reenterer();
        uint256 s = _subId("vault", P);
        bytes[] memory inner = new bytes[](2);
        inner[0] = abi.encodeCall(PageNFT.setAddr, (s, payout));
        inner[1] = abi.encodeCall(PageNFT.setText, (s, "k", "custody"));
        r.arm(address(nft), "", _mc(inner), true);
        vm.prank(alice);
        nft.registerSubpageFor("vault", P, address(r));
        assertTrue(r.nftOk());
        assertEq(nft.resolve(s), payout);
        assertEq(nft.payee(s), payout);

        // a guarded call from the same hook is refused and, bubbled, undoes the mint
        Reenterer r2 = new Reenterer();
        r2.arm(address(nft), "", _mc(_one(abi.encodeCall(PageNFT.registerSubpage, ("y", P)))), true);
        vm.prank(alice);
        vm.expectRevert(REENTRANCY);
        nft.registerSubpageFor("vault2", P, address(r2));
        // unbubbled, the mint completes and the hook saw the refusal
        r2.arm(address(nft), "", _mc(_one(abi.encodeCall(PageNFT.withdraw, (alice)))), false);
        vm.prank(alice);
        nft.registerSubpageFor("vault3", P, address(r2));
        assertFalse(r2.nftOk());
        assertEq(r2.nftRet(), abi.encodeWithSelector(REENTRANCY));
    }

    // a bundled guarded mint still holds the guard across the receiver hook
    function test_hookInsideABundledMintCannotReenter() public {
        Reenterer r = new Reenterer();
        _owedTo(address(r));
        r.arm(address(nft), "", _mc(_one(abi.encodeCall(PageNFT.withdraw, (address(r))))), false);
        bytes[] memory d = new bytes[](2);
        d[0] = abi.encodeCall(PageNFT.registerSubpageFor, ("h", P, address(r)));
        d[1] = abi.encodeCall(PageNFT.registerSubpageFor, ("h2", P, bob));
        vm.prank(alice);
        nft.multicall(d);
        assertFalse(r.nftOk());
        assertEq(r.nftRet(), abi.encodeWithSelector(REENTRANCY));
        assertGt(nft.owed(address(r)), 0, "nothing was paid from inside the hook");
    }

    // an unguarded bundled transfer lets the hook do what it could do alone
    function test_hookInsideABundledSafeTransfer() public {
        Reenterer r = new Reenterer();
        r.arm(address(nft), "", _mc(_one(abi.encodeCall(PageNFT.setAddr, (P, payout)))), true);
        bytes[] memory d = new bytes[](2);
        d[0] = abi.encodeCall(PageNFT.setText, (P, "k", "v"));
        d[1] = abi.encodeWithSignature("safeTransferFrom(address,address,uint256,bytes)", alice, address(r), P, hex"01");
        vm.prank(alice);
        nft.multicall(d);
        assertEq(nft.ownerOf(P), address(r));
        assertEq(nft.resolve(P), payout);
        assertEq(r.lastOperator(), alice);
    }

    // bundles inside bundles run in order, and a failure at any depth undoes all of it
    function test_nestedMulticall() public {
        bytes[] memory inner = new bytes[](2);
        inner[0] = abi.encodeCall(PageNFT.registerSubpageFor, ("n1", P, bob));
        inner[1] = abi.encodeCall(PageNFT.setText, (P, "k", "inner"));
        bytes[] memory d = new bytes[](3);
        d[0] = _mc(inner);
        d[1] = abi.encodeCall(PageNFT.registerSubpageFor, ("n2", P, carol));
        d[2] = _mc(_one(_mc(_one(abi.encodeCall(PageNFT.setText, (P, "url", "deep"))))));
        watch.push(_subId("n1", P));
        watch.push(_subId("n2", P));
        (bool ok, bytes[] memory res) = _same(alice, d);
        assertTrue(ok);
        bytes[] memory r0 = abi.decode(res[0], (bytes[]));
        assertEq(abi.decode(r0[0], (uint256)), _subId("n1", P));
        assertEq(nft.text(P, "url"), "deep");
        // a failure deep inside undoes everything and keeps its data
        d[2] = _mc(_one(_mc(_one(abi.encodeCall(PageNFT.setText, (_subId("n1", P), "k", "x"))))));
        (ok,) = _same(alice, d);
        assertFalse(ok);
        vm.prank(alice);
        vm.expectRevert(PageNFT.Unauthorized.selector);
        nft.multicall(d);
    }

    function test_emptyBundle() public {
        bytes32 before = _stateHash();
        vm.recordLogs();
        vm.prank(stranger);
        bytes[] memory res = nft.multicall(new bytes[](0));
        assertEq(res.length, 0);
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(_stateHash(), before);
    }

    function test_viewsInsideABundle() public {
        uint256 s = _sub(bob, "v");
        bytes[] memory d = new bytes[](5);
        d[0] = abi.encodeCall(ERC721.ownerOf, (s));
        d[1] = abi.encodeCall(PageNFT.getPageName, (s));
        d[2] = abi.encodeCall(PageNFT.tokenURI, (s));
        d[3] = abi.encodeCall(PageNFT.quote, ("alice"));
        d[4] = abi.encodeCall(PageNFT.isAvailable, ("v", P));
        (bool ok, bytes[] memory res) = _same(stranger, d);
        assertTrue(ok);
        for (uint256 i; i < d.length; ++i) {
            (, bytes memory direct) = address(nft).staticcall(d[i]);
            assertEq(res[i], direct);
        }
        assertEq(abi.decode(res[1], (string)), "v.alice");
    }

    // multicall carries no guard of its own, so the receiver hook of a guarded mint can enter it, here with a bundle
    // that holds an empty bundle
    function test_multicallCarriesNoGuard() public {
        Reenterer r = new Reenterer();
        r.arm(address(nft), "", _mc(_one(_mc(new bytes[](0)))), true);
        vm.prank(alice);
        nft.registerSubpageFor("g", P, address(r));
        assertTrue(r.nftOk());
    }

    // gas

    function test_gas_bundles() public {
        uint256 s = _sub(bob, "bob");
        bytes[] memory prof = new bytes[](7);
        prof[0] = abi.encodeCall(PageNFT.setAddr, (P, hot));
        prof[1] = abi.encodeCall(PageNFT.setAddrForCoin, (P, 60, abi.encodePacked(hot2)));
        prof[2] = abi.encodeCall(PageNFT.setText, (P, "avatar", "ipfs://avatar"));
        prof[3] = abi.encodeCall(PageNFT.setText, (P, "url", "https://alice.example"));
        prof[4] = abi.encodeCall(PageNFT.setText, (P, "com.twitter", "alice"));
        prof[5] = abi.encodeCall(PageNFT.setText, (P, "description", "hello"));
        prof[6] = abi.encodeCall(PageNFT.setContenthash, (P, hex"e30101701220aa"));
        _gasPair("profile, 7 writes", alice, prof);

        vm.prank(bob);
        nft.setPrimaryPage(s);
        bytes[] memory del = new bytes[](3);
        del[0] = abi.encodeCall(PageNFT.setPrimaryPage, (0));
        del[1] = abi.encodeCall(PageNFT.clearRecords, (s));
        del[2] = abi.encodeCall(PageNFT.transferFrom, (bob, DEAD, s));
        _gasPair("delete, 3 calls", bob, del);

        _gasPair("50 subpages by the holder", alice, _batch(bob, 50, "g"));
        _setMinter(P, hot);
        _gasPair("50 subpages by a minter", hot, _batch(hot, 50, "h"));
    }

    // execution gas of the bundle and of the same calls one by one. PageNFT's storage is cooled
    // before each single call and before the bundle, as in separate transactions. Each separate
    // transaction would also pay 21000 base gas and its own calldata.
    function _gasPair(string memory what, address who, bytes[] memory d) internal {
        uint256 snap = vm.snapshotState();
        uint256 singles;
        for (uint256 i; i < d.length; ++i) {
            vm.cool(address(nft));
            vm.prank(who);
            uint256 g0 = gasleft();
            (bool ok,) = address(nft).call(d[i]);
            singles += g0 - gasleft();
            assertTrue(ok);
        }
        vm.revertToStateAndDelete(snap);
        bytes memory data = _mc(d);
        vm.cool(address(nft));
        vm.prank(who);
        uint256 g1 = gasleft();
        (bool okB,) = address(nft).call(data);
        uint256 bundle = g1 - gasleft();
        assertTrue(okB);
        emit log_named_string("bundle", what);
        emit log_named_uint("  one by one, execution gas", singles);
        emit log_named_uint("  one by one, plus 21000 per tx", singles + 21000 * d.length);
        emit log_named_uint("  bundle, execution gas", bundle);
        emit log_named_uint("  bundle, plus 21000", bundle + 21000);
        emit log_named_uint("  bundle calldata bytes", data.length);
    }
}

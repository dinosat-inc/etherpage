// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Vm} from "forge-std/Test.sol";
import {ERC721} from "solady/tokens/ERC721.sol";
import {PageNFT} from "../../src/PageNFT.sol";
import {MinterBase} from "../utils/MinterBase.sol";
import {SafeLike, NoHook} from "../utils/MinterMocks.sol";
import {Market} from "../utils/ClearPrimaryMocks.sol";
import {Actor} from "../utils/ActorMocks.sol";

// clearing the sender's display name on a transfer, tried from every angle
contract DisplayClearTest is MinterBase {
    uint256 P;
    uint256 Q;
    Market market;
    address wallet2 = makeAddr("wallet2");
    bytes32 constant T_PRIMARY = keccak256("PrimaryPageSet(address,uint256)");
    bytes32 constant T_META = keccak256("MetadataUpdate(uint256)");
    bytes32 constant T_TEXT = keccak256("TextChanged(bytes32,string,string,string)");

    function setUp() public override {
        super.setUp();
        P = _reg(alice, "alice");
        Q = _reg(bob, "bobby");
        market = new Market();
    }

    function _mc(bytes[] memory d) internal pure returns (bytes memory) {
        return abi.encodeCall(PageNFT.multicall, (d));
    }

    function _call(address who, bytes memory data) internal returns (bool ok, bytes memory ret) {
        vm.prank(who);
        (ok, ret) = address(nft).call(data);
        // the test tool keeps logs of reverted frames; a chain does not, so drop them
        if (!ok && recording) vm.getRecordedLogs();
    }

    bool recording;

    function _primary(address who, uint256 id) internal {
        vm.prank(who);
        nft.setPrimaryPage(id);
    }

    // nobody else's pointer moves

    // B1: a transfer by any caller, of any name, from and to any account, changes no pointer but the
    // sender's, and that one only when it named the moved name and the move went through
    function testFuzz_B1_onlyTheSendersPointerMoves(uint8 callerI, uint8 fromI, uint8 toI, uint8 idI, uint8 route, bool approveAll)
        public
    {
        uint256 s1 = _sub(P, carol, "c");
        uint256 s2 = _sub(P, dave, "d");
        vm.prank(alice);
        nft.setAddr(P, hot);
        vm.prank(bob);
        nft.setAddr(Q, hot2);
        _primary(alice, P);
        _primary(bob, Q);
        _primary(carol, s1);
        _primary(dave, s2);
        _primary(hot, P);
        _primary(hot2, Q);
        address[8] memory acc = [alice, bob, carol, dave, hot, hot2, stranger, DEAD];
        uint256[4] memory ids = [P, Q, s1, s2];
        if (approveAll) {
            vm.prank(acc[fromI % 6]);
            nft.setApprovalForAll(acc[callerI % 7], true);
        }
        uint256[8] memory before;
        for (uint256 i; i < 8; ++i) before[i] = nft.primaryPage(acc[i]);
        address from = acc[fromI % 6];
        address to = acc[toI % 8];
        address caller = acc[callerI % 7];
        uint256 id = ids[idI % 4];
        bytes memory d;
        uint256 r = route % 4;
        if (r == 0) d = abi.encodeCall(ERC721.transferFrom, (from, to, id));
        else if (r == 1) d = abi.encodeWithSignature("safeTransferFrom(address,address,uint256)", from, to, id);
        else if (r == 2) d = abi.encodeWithSignature("safeTransferFrom(address,address,uint256,bytes)", from, to, id, hex"01");
        else {
            bytes[] memory b = new bytes[](1);
            b[0] = abi.encodeCall(ERC721.transferFrom, (from, to, id));
            d = _mc(b);
        }
        (bool ok,) = _call(caller, d);
        for (uint256 i; i < 8; ++i) {
            uint256 want = before[i];
            if (ok && acc[i] == from && from != to && before[i] == id) want = 0;
            assertEq(nft.primaryPage(acc[i]), want);
        }
        if (ok) assertEq(nft.ownerOf(id), to);
    }

    function _sub(uint256 parent, address to, string memory label) internal returns (uint256 id) {
        vm.prank(nft.ownerOf(parent));
        id = nft.registerSubpageFor(label, parent, to);
    }

    // every sale route

    function _sell(uint256 route, address seller, address buyerAcct, uint256 id) internal {
        if (route == 0) {
            vm.prank(seller);
            nft.transferFrom(seller, buyerAcct, id);
        } else if (route == 1) {
            vm.prank(seller);
            nft.safeTransferFrom(seller, buyerAcct, id);
        } else if (route == 2) {
            vm.prank(seller);
            nft.safeTransferFrom(seller, buyerAcct, id, hex"beef");
        } else if (route == 3) {
            vm.prank(seller);
            nft.approve(carol, id);
            vm.prank(carol);
            nft.transferFrom(seller, buyerAcct, id);
        } else if (route == 4 || route == 5) {
            vm.prank(seller);
            nft.setApprovalForAll(address(market), true);
            market.settle(address(nft), seller, buyerAcct, id, route == 5);
        } else if (route == 6) {
            bytes[] memory b = new bytes[](2);
            b[0] = abi.encodeCall(PageNFT.setText, (id, "note", "sold"));
            b[1] = abi.encodeCall(ERC721.transferFrom, (seller, buyerAcct, id));
            vm.prank(seller);
            nft.multicall(b);
        } else if (route == 7) {
            // an operator bundles the sale
            Actor op = new Actor();
            vm.prank(seller);
            nft.setApprovalForAll(address(op), true);
            bytes[] memory b = new bytes[](1);
            b[0] = abi.encodeWithSignature("safeTransferFrom(address,address,uint256)", seller, buyerAcct, id);
            address[] memory to = new address[](1);
            to[0] = address(nft);
            bytes[] memory d = new bytes[](1);
            d[0] = _mc(b);
            op.run(to, new uint256[](1), d);
            assertTrue(op.okAt(0));
        } else if (route == 8) {
            // two hops through the seller's other wallet, which also picked the name
            vm.prank(seller);
            nft.transferFrom(seller, wallet2, id);
            _primary(wallet2, id);
            vm.prank(wallet2);
            nft.transferFrom(wallet2, buyerAcct, id);
        } else if (route == 9) {
            // the buyer contract's hook sends the name on at once
            Actor relay = new Actor();
            address[] memory to = new address[](1);
            to[0] = address(nft);
            bytes[] memory hd = new bytes[](1);
            hd[0] = abi.encodeCall(ERC721.transferFrom, (address(relay), buyerAcct, id));
            relay.armHook(to, hd);
            vm.prank(seller);
            nft.safeTransferFrom(seller, address(relay), id);
            assertTrue(relay.hookOkAt(0));
        }
    }

    // B2: after a sale by any route the seller shows nothing, cannot restore it alone, and the buyer
    // cannot restore it alone
    function test_B2_noRouteKeepsTheSellersPointer() public {
        uint256 s = _sub(P, carol, "shop");
        for (uint256 route; route < 10; ++route) {
            for (uint256 top; top < 2; ++top) {
                uint256 snap = vm.snapshotState();
                address seller = top == 1 ? alice : carol;
                uint256 id = top == 1 ? P : s;
                _primary(seller, id);
                assertGt(bytes(nft.reverseResolve(seller)).length, 0);
                _sell(route, seller, buyer, id);
                assertEq(nft.ownerOf(id), buyer);
                assertEq(nft.primaryPage(seller), 0, "seller pointer kept");
                assertEq(nft.reverseResolve(seller), "");
                // the seller alone
                vm.prank(seller);
                vm.expectRevert(PageNFT.Unauthorized.selector);
                nft.setPrimaryPage(id);
                // the buyer alone, even pointing the name back and dressing it up
                vm.startPrank(buyer);
                nft.setAddr(id, seller);
                nft.setText(id, "url", "https://buyer.example");
                vm.stopPrank();
                assertEq(nft.reverseResolve(seller), "", "buyer revived the seller");
                if (route == 8) assertEq(nft.primaryPage(wallet2), 0);
                vm.revertToState(snap);
            }
        }
    }

    // B3: an address the seller's name pointed at keeps its pointer through the sale, and the buyer
    // cannot make it show the name again by pointing the name back at it.
    function test_B3_pointeeOfTheSellerIsNotRevivedByTheBuyer() public {
        // hot wallet case
        vm.prank(alice);
        nft.setAddr(P, hot);
        _primary(hot, P);
        assertEq(nft.reverseResolve(hot), "alice");
        vm.prank(alice);
        nft.transferFrom(alice, buyer, P);
        assertEq(nft.primaryPage(hot), P, "the pointee keeps its pointer");
        assertEq(nft.reverseResolve(hot), "");
        vm.startPrank(buyer);
        nft.setAddr(P, hot);
        nft.setText(P, "url", "https://buyer.example");
        vm.stopPrank();
        assertEq(nft.reverseResolve(hot), "", "hot does not show the sold name again");
        assertEq(nft.text(P, "url"), "https://buyer.example");

        // a saved address replaced before the sale: hot2 was the main address, then another, then the sale
        vm.prank(bob);
        nft.setAddr(Q, hot2);
        _primary(hot2, Q);
        vm.prank(bob);
        nft.setAddr(Q, dave);
        assertEq(nft.reverseResolve(hot2), "");
        vm.prank(bob);
        nft.transferFrom(bob, buyer, Q);
        vm.prank(buyer);
        nft.setAddr(Q, hot2);
        assertEq(nft.reverseResolve(hot2), "");

        // a Safe holds the name and the person's EOA shows it
        SafeLike safe = new SafeLike(carol);
        uint256 C = _reg(carol, "carolsafe");
        vm.prank(carol);
        nft.transferFrom(carol, address(safe), C);
        vm.prank(carol);
        safe.exec(address(nft), 0, abi.encodeCall(PageNFT.setAddr, (C, carol)));
        _primary(carol, C);
        assertEq(nft.reverseResolve(carol), "carolsafe");
        vm.prank(carol);
        safe.exec(address(nft), 0, abi.encodeCall(ERC721.transferFrom, (address(safe), buyer, C)));
        assertEq(nft.primaryPage(carol), C);
        vm.prank(buyer);
        nft.setAddr(C, carol);
        assertEq(nft.reverseResolve(carol), "", "the Safe's user does not show the sold name again");
    }

    // B4: a bundle cannot keep the pointer in either order, and a hook sees it already cleared
    function test_B4_bundlesAndHooks() public {
        _primary(alice, P);
        bytes[] memory b = new bytes[](2);
        b[0] = abi.encodeCall(ERC721.transferFrom, (alice, buyer, P));
        b[1] = abi.encodeCall(PageNFT.setPrimaryPage, (P));
        (bool ok, bytes memory ret) = _call(alice, _mc(b));
        assertFalse(ok);
        assertEq(ret, abi.encodePacked(PageNFT.Unauthorized.selector));
        b[0] = abi.encodeCall(PageNFT.setPrimaryPage, (P));
        b[1] = abi.encodeCall(ERC721.transferFrom, (alice, buyer, P));
        (ok,) = _call(alice, _mc(b));
        assertTrue(ok);
        assertEq(nft.primaryPage(alice), 0);
        // bob sells to a contract whose hook points the name back at him and writes a text record, and he
        // still shows nothing
        Actor probe = new Actor();
        _primary(bob, Q);
        address[] memory to = new address[](2);
        bytes[] memory hd = new bytes[](2);
        to[0] = address(nft);
        to[1] = address(nft);
        hd[0] = abi.encodeCall(PageNFT.setAddr, (Q, bob));
        hd[1] = abi.encodeCall(PageNFT.setText, (Q, "k", "v"));
        probe.armHook(to, hd);
        vm.recordLogs();
        vm.prank(bob);
        nft.safeTransferFrom(bob, address(probe), Q);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertTrue(probe.hookOkAt(0));
        assertEq(nft.resolve(Q), bob);
        assertEq(nft.primaryPage(bob), 0);
        assertEq(nft.reverseResolve(bob), "", "pointing it back is not enough without bob");
        // order: PrimaryPageSet(bob, 0) sits right before MetadataUpdate, and both precede the hook's logs
        uint256 iP = type(uint256).max;
        uint256 iM = type(uint256).max;
        uint256 iT = type(uint256).max;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == T_PRIMARY && iP == type(uint256).max) iP = i;
            if (logs[i].topics[0] == T_META && iM == type(uint256).max) iM = i;
            if (logs[i].topics[0] == T_TEXT) iT = i;
        }
        assertEq(iM, iP + 1);
        assertLt(iM, iT);
        assertEq(logs[iP].topics[1], bytes32(uint256(uint160(bob))));
        assertEq(logs[iP].topics[2], bytes32(0));
    }

    // deleted subpages, new mints and the minter

    // B5: deleted subpages, recycling by the minter, and the parent holder taking a subpage back
    function test_B5_deletedAndRecycled() public {
        _setMinter(P, dave);
        uint256 s = _sub(P, carol, "gone");
        _primary(carol, s);
        vm.recordLogs();
        vm.prank(carol);
        nft.transferFrom(carol, DEAD, s);
        assertEq(_count(vm.getRecordedLogs(), T_PRIMARY), 1);
        assertEq(nft.primaryPage(carol), 0);
        assertEq(nft.primaryPage(DEAD), 0);
        // the minter recycles it for itself, then shows it
        vm.prank(dave);
        nft.registerSubpageFor("gone", P, dave);
        _primary(dave, s);
        assertEq(nft.reverseResolve(dave), "gone.alice");
        assertEq(nft.reverseResolve(carol), "");
        // the minter sells it on: cleared
        vm.prank(dave);
        nft.transferFrom(dave, stranger, s);
        assertEq(nft.primaryPage(dave), 0);
        // the holder takes it back to carol: stranger had no pointer, so no event; carol shows nothing
        vm.recordLogs();
        vm.prank(alice);
        nft.registerSubpageFor("gone", P, carol);
        assertEq(_count(vm.getRecordedLogs(), T_PRIMARY), 0);
        assertEq(nft.reverseResolve(carol), "");
        // the minter cannot overwrite a live subpage to reach anyone's pointer
        _primary(carol, s);
        vm.prank(dave);
        vm.expectRevert(PageNFT.AlreadyRegistered.selector);
        nft.registerSubpageFor("gone", P, dave);
        assertEq(nft.primaryPage(carol), s);
        // carol deletes it with a bundle that starts with setPrimaryPage(0): one PrimaryPageSet event, and her
        // display name ends cleared as with the send alone
        bytes[] memory b = new bytes[](3);
        b[0] = abi.encodeCall(PageNFT.setPrimaryPage, (0));
        b[1] = abi.encodeCall(PageNFT.clearRecords, (s));
        b[2] = abi.encodeCall(ERC721.transferFrom, (carol, DEAD, s));
        vm.recordLogs();
        vm.prank(carol);
        nft.multicall(b);
        assertEq(_count(vm.getRecordedLogs(), T_PRIMARY), 1, "one event: the send finds the pointer already 0");
        assertEq(nft.primaryPage(carol), 0);
    }

    // B6: registering a lapsed top level name again after a sale clears only the current holder
    function test_B6_reRegistrationAfterSale() public {
        _primary(alice, P);
        vm.prank(alice);
        nft.transferFrom(alice, buyer, P);
        _primary(buyer, P);
        vm.warp(nft.expiresAt(P) + 90 days + 21 days + 1);
        vm.recordLogs();
        _reg(alice, "alice");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_count(logs, T_PRIMARY), 1);
        assertEq(nft.primaryPage(buyer), 0);
        assertEq(nft.primaryPage(alice), 0, "the old seller shows nothing on getting it back");
        assertEq(nft.reverseResolve(alice), "");
    }

    function _count(Vm.Log[] memory logs, bytes32 t) internal view returns (uint256 n) {
        for (uint256 i; i < logs.length; ++i) if (logs[i].emitter == address(nft) && logs[i].topics[0] == t) ++n;
    }

    // indexer

    address[] idxAcc;
    mapping(address => uint256) idx;

    // B7: a reverse indexer built from PrimaryPageSet alone matches primaryPage after a long mixed
    // walk of sales, bundles, deletes, recycles, takebacks and new registrations
    function testFuzz_B7_indexerFromEventsMatches(uint256 seed) public {
        address[7] memory a = [alice, bob, carol, dave, hot, buyer, stranger];
        for (uint256 i; i < 7; ++i) idxAcc.push(a[i]);
        idxAcc.push(DEAD);
        idxAcc.push(wallet2);
        _setMinter(P, dave);
        uint256[] memory ids = new uint256[](6);
        ids[0] = P;
        ids[1] = Q;
        ids[2] = _sub(P, carol, "x0");
        ids[3] = _sub(P, bob, "x1");
        ids[4] = _sub(Q, hot, "y0");
        ids[5] = _sub(Q, carol, "y1");
        vm.recordLogs();
        recording = true;
        _drain();
        for (uint256 step; step < 60; ++step) {
            uint256 r = uint256(keccak256(abi.encode(seed, step)));
            uint256 id = ids[r % 6];
            address who = a[(r >> 8) % 7];
            address to = (r >> 16) % 5 == 0 ? DEAD : a[(r >> 24) % 7];
            uint256 kind = (r >> 32) % 8;
            if (kind == 0 || kind == 1) {
                _call(who, abi.encodeCall(PageNFT.setPrimaryPage, (id)));
            } else if (kind == 2) {
                _call(who, abi.encodeCall(ERC721.transferFrom, (who, to, id)));
            } else if (kind == 3) {
                bytes[] memory b = new bytes[](2);
                b[0] = abi.encodeCall(PageNFT.setPrimaryPage, (id));
                b[1] = abi.encodeCall(ERC721.transferFrom, (who, to, id));
                _call(who, _mc(b));
            } else if (kind == 4) {
                // a random account tries to mint or take back a subpage, which only the parent holder, or the
                // minter for a free subpage, can do
                uint256 parent = (r >> 40) % 2 == 0 ? P : Q;
                string memory label = (r >> 48) % 2 == 0 ? "x0" : "x1";
                if (parent == Q) label = (r >> 48) % 2 == 0 ? "y0" : "y1";
                _call(who, abi.encodeCall(PageNFT.registerSubpageFor, (label, parent, to == DEAD ? who : to)));
            } else if (kind == 5) {
                _call(who, abi.encodeCall(PageNFT.setAddr, (id, a[(r >> 56) % 7])));
            } else if (kind == 6) {
                _call(who, abi.encodeCall(PageNFT.setPrimaryPage, (0)));
            } else {
                // move time a little; sometimes a lapse and a new registration of a top level name
                if ((r >> 64) % 10 == 0) {
                    uint256 t = (r >> 72) % 2 == 0 ? P : Q;
                    vm.warp(nft.expiresAt(t) + 90 days + 21 days + 1);
                    // keep the other one alive
                    uint256 o = t == P ? Q : P;
                    if (nft.expiresAt(o) < block.timestamp) {
                        _renewOrReg(o, a[(r >> 80) % 7]);
                    }
                    _reg(a[(r >> 88) % 7], nft.getPageName(t));
                } else {
                    vm.warp(block.timestamp + 1 days);
                }
            }
            _drain();
            for (uint256 i; i < idxAcc.length; ++i) {
                assertEq(idx[idxAcc[i]], nft.primaryPage(idxAcc[i]),
                    string.concat("indexer differs at step ", vm.toString(step), " kind ", vm.toString(kind), " acct ", vm.toString(idxAcc[i])));
            }
        }
    }

    function _renewOrReg(uint256 id, address who) internal {
        if (block.timestamp <= nft.expiresAt(id) + 90 days) {
            uint256 fee = nft.getFee(bytes(nft.getPageName(id)).length);
            vm.deal(stranger, 1 ether);
            vm.prank(stranger);
            nft.renew{value: fee}(id);
        } else {
            _reg(who, nft.getPageName(id));
        }
    }

    function _drain() internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(nft) || logs[i].topics[0] != T_PRIMARY) continue;
            idx[address(uint160(uint256(logs[i].topics[1])))] = uint256(logs[i].topics[2]);
        }
    }

    // what stays and what it costs

    // B8: a self transfer and a failed transfer clear nothing, a transfer leaves the receiver's own
    // pointer to the name it receives, and an expired name cannot move, so its holder keeps the pointer
    function test_B8_whatDoesNotClear() public {
        _primary(alice, P);
        vm.recordLogs();
        vm.prank(alice);
        nft.transferFrom(alice, alice, P);
        assertEq(vm.getRecordedLogs().length, 1, "only Transfer");
        assertEq(nft.primaryPage(alice), P);
        vm.prank(stranger);
        vm.expectRevert(bytes4(NOT_OWNER_NOR_APPROVED));
        nft.transferFrom(alice, stranger, P);
        assertEq(nft.primaryPage(alice), P);
        // the receiver's pointer to the name it receives is untouched
        vm.prank(alice);
        nft.setAddr(P, hot);
        _primary(hot, P);
        vm.prank(alice);
        nft.transferFrom(alice, hot, P);
        assertEq(nft.primaryPage(hot), P);
        assertEq(nft.primaryPage(alice), 0);
        // hot chose the name while alice held it, so it shows again only once hot chooses it itself
        assertEq(nft.reverseResolve(hot), "");
        _primary(hot, P);
        assertEq(nft.reverseResolve(hot), "alice");
        // an expired name cannot move, so its holder keeps the pointer
        vm.warp(nft.expiresAt(P) + 1);
        vm.prank(hot);
        vm.expectRevert(PageNFT.Expired.selector);
        nft.transferFrom(hot, bob, P);
        assertEq(nft.primaryPage(hot), P);
    }

    // B9: gas of a plain transfer with and without a clear, for the record
    function test_B9_gas() public {
        _primary(alice, P);
        vm.prank(alice);
        uint256 g = gasleft();
        nft.transferFrom(alice, bob, P);
        emit log_named_uint("transferFrom with a clear, warm test gas", g - gasleft());
        vm.prank(bob);
        g = gasleft();
        nft.transferFrom(bob, carol, P);
        emit log_named_uint("transferFrom without a clear, warm test gas", g - gasleft());
    }

    // B10: a bundle that deletes a subpage and starts with setPrimaryPage(0) wipes a display name that
    // names another name; the transfer's own clear touches only the moved name
    function test_B10_zeroChoiceInDeleteBundleWipesAnUnrelatedName() public {
        uint256 s1 = _sub(P, carol, "one");
        uint256 s2 = _sub(P, carol, "two");
        _primary(carol, s2);
        uint256 snap = vm.snapshotState();
        bytes[] memory b = new bytes[](3);
        b[0] = abi.encodeCall(PageNFT.setPrimaryPage, (0));
        b[1] = abi.encodeCall(PageNFT.clearRecords, (s1));
        b[2] = abi.encodeCall(ERC721.transferFrom, (carol, DEAD, s1));
        vm.prank(carol);
        nft.multicall(b);
        assertEq(nft.primaryPage(carol), 0, "a bundle that starts with setPrimaryPage(0) wipes two.alice");
        vm.revertToState(snap);
        bytes[] memory b2 = new bytes[](2);
        b2[0] = b[1];
        b2[1] = b[2];
        vm.prank(carol);
        nft.multicall(b2);
        assertEq(nft.primaryPage(carol), s2, "the contract clear leaves two.alice");
        assertEq(nft.reverseResolve(carol), "two.alice");
    }
}

// checks whether the test tool records logs of a call that reverted
contract DisplayClearLogsTest is MinterBase {
    function test_probe_revertedLogsRecorded() public {
        uint256 P = _reg(alice, "alice");
        bytes[] memory b = new bytes[](2);
        b[0] = abi.encodeCall(PageNFT.setPrimaryPage, (P));
        b[1] = abi.encodeCall(ERC721.transferFrom, (alice, bob, P + 1));
        vm.recordLogs();
        vm.prank(alice);
        (bool ok,) = address(nft).call(abi.encodeCall(PageNFT.multicall, (b)));
        uint256 n = vm.getRecordedLogs().length;
        emit log_named_uint("bundle ok", ok ? 1 : 0);
        emit log_named_uint("logs recorded from the reverted bundle", n);
        vm.recordLogs();
        vm.prank(alice);
        (ok,) = address(nft).call(abi.encodeCall(PageNFT.setText, (P + 1, "k", "v")));
        emit log_named_uint("logs recorded from a reverted plain call", vm.getRecordedLogs().length);
        assertEq(nft.primaryPage(alice), 0);
        // a plain call that emits Transfer and then reverts in the receiver check
        NoHook nh = new NoHook();
        vm.recordLogs();
        vm.prank(alice);
        (ok,) = address(nft).call(abi.encodeWithSignature("safeTransferFrom(address,address,uint256)", alice, address(nh), P));
        emit log_named_uint("plain safeTransferFrom ok", ok ? 1 : 0);
        emit log_named_uint("logs recorded from that reverted plain call", vm.getRecordedLogs().length);
        assertEq(nft.ownerOf(P), alice);
    }
}

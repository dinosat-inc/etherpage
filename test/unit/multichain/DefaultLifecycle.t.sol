// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Vm} from "forge-std/Test.sol";
import {PageNFT} from "../../../src/PageNFT.sol";
import {DefaultLifecycleBase, LifecycleHolder, LifecycleCode} from "./DefaultLifecycleBase.sol";

// The default address a holder may save for every EVM chain, coin type 0x80000000, over a name's whole life: what
// every EVM coin class answers and what is announced, through moves of every kind, round trips, code changes,
// expiry, grace, the premium period, release, registrations again, trials, clearRecords, keepProfile, subpages,
// minters and multicall batches.
contract DefaultLifecycleTest is DefaultLifecycleBase {
    // every mover, every transfer function, with and without a saved default, to every kind of receiver; then back
    function test_transferMatrix() public {
        LifecycleHolder h = new LifecycleHolder(address(nft));
        address[3] memory receivers = [bob, seven, address(h)];
        vm.prank(alice);
        nft.setApprovalForAll(carol, true);
        uint256 n;
        for (uint256 mover; mover < 3; ++mover) {
            for (uint256 how; how < 3; ++how) {
                for (uint256 withDef; withDef < 2; ++withDef) {
                    for (uint256 r; r < 3; ++r) {
                        _resetTracked();
                        string memory label = string.concat("mx", vm.toString(n++));
                        uint256 id = _reveal(relayer, label, alice);
                        if (withDef == 1) _save(alice, id, DEF, abi.encodePacked(cold));
                        _must(alice, abi.encodeCall(PageNFT.approve, (dave, id)));
                        address by = mover == 0 ? alice : mover == 1 ? dave : carol;
                        address to = receivers[r];
                        _move(by, alice, to, id, how);
                        assertEq(nft.getApproved(id), address(0), "the approval is gone after the move");
                        // the receiver, whatever its kind, saved nothing: no EVM chain but the home chain answers,
                        // and never the sender's default
                        _evmAll(id, address(0), "after the move");
                        assertEq(nft.addr(id, OP), _enc(to), "OP is the receiver");
                        // the approved account and the operator never save for the holder
                        vm.prank(dave);
                        vm.expectRevert(PageNFT.Unauthorized.selector);
                        nft.setAddrForCoin(id, DEF, abi.encodePacked(dave));
                        // back to the sender: its own default counts again, announced on coin 60
                        (uint256[] memory k, bytes[] memory v) =
                            _record(to, abi.encodeCall(PageNFT.transferFrom, (to, alice, id)), id);
                        (uint256[] memory wk, bytes[] memory wv) = _trio(alice, withDef == 1 ? cold : address(0));
                        _assertEvents(k, v, wk, wv);
                        _checkModel();
                        _evmAll(id, withDef == 1 ? cold : address(0), "back with the sender");
                    }
                }
            }
        }
        assertEq(n, 54);
    }

    // a round trip brings back every address record of the returning holder, slot by slot, the same rule for the
    // main address, the chain entries and the default; a slot the other holder wrote stays the other holder's
    function test_roundTripRevivesEveryRecordTheSameWay() public {
        uint256 id = _reveal(relayer, "trip", alice);
        _setMain(alice, id, other);
        _save(alice, id, ETH, abi.encodePacked(carol));
        _save(alice, id, DEF, abi.encodePacked(cold));
        _save(alice, id, BASE, abi.encodePacked(dave));
        _save(alice, id, BTC, hex"00141234");
        _must(alice, abi.encodeCall(PageNFT.setText, (id, "url", "a")));

        _move(alice, alice, bob, id, 0);
        assertEq(nft.addr(id, OP), _enc(bob));
        _evmAll(id, address(0), "with the buyer, who saved nothing");
        assertEq(nft.addr(id, BASE), "");
        assertEq(nft.addr(id, BTC), "");
        assertEq(nft.text(id, "url"), "");

        _move(bob, bob, alice, id, 0);
        assertEq(nft.resolve(id), other, "the main address comes back");
        assertEq(nft.addr(id, ETH), _enc(carol), "the Ethereum entry comes back");
        assertEq(nft.addr(id, DEF), _enc(cold), "the default comes back");
        assertEq(nft.addr(id, ARB), _enc(cold));
        assertEq(nft.addr(id, BASE), _enc(dave), "the Base entry comes back");
        assertEq(nft.addr(id, BTC), hex"00141234", "the BTC entry comes back");
        assertEq(nft.text(id, "url"), "a", "the profile comes back when nobody wrote");

        // the other holder writes the Ethereum slot and the profile, never the default
        _move(alice, alice, bob, id, 0);
        _save(bob, id, ETH, abi.encodePacked(bob));
        _must(bob, abi.encodeCall(PageNFT.setText, (id, "url", "b")));
        _move(bob, bob, alice, id, 0);
        assertEq(nft.addr(id, ETH), _enc(cold), "the Ethereum slot is the buyer's, so the default answers");
        assertEq(nft.addr(id, DEF), _enc(cold));
        assertEq(nft.addr(id, BASE), _enc(dave));
        assertEq(nft.text(id, "url"), "", "the profile is the buyer's");
        assertEq(nft.resolve(id), other);
    }

    // a saved default does not follow code appearing or leaving, and without one nothing answers, whatever the code
    function test_codeAndDelegationLater() public {
        address eoa = makeAddr("later");
        uint256 id = _reveal(relayer, "later", eoa);
        _save(eoa, id, DEF, abi.encodePacked(cold));
        vm.etch(eoa, type(LifecycleCode).runtimeCode);
        _checkModel();
        _evmAll(id, cold, "code appeared");
        assertEq(nft.addr(id, OP), _enc(eoa));
        vm.etch(eoa, abi.encodePacked(hex"ef0100", address(this)));
        _checkModel();
        _evmAll(id, cold, "a 7702 delegation");
        _save(eoa, id, DEF, "");
        _evmAll(id, address(0), "cleared, a 7702 account answers nothing");
        vm.etch(eoa, type(LifecycleCode).runtimeCode);
        _checkModel();
        _evmAll(id, address(0), "cleared, regular code answers nothing");
        // moves from and to the account with code
        (uint256[] memory k, bytes[] memory v) = _record(eoa, abi.encodeCall(PageNFT.transferFrom, (eoa, bob, id)), id);
        (uint256[] memory wk, bytes[] memory wv) = _trio(bob, address(0));
        _assertEvents(k, v, wk, wv);
        (k, v) = _record(bob, abi.encodeCall(PageNFT.transferFrom, (bob, eoa, id)), id);
        (wk, wv) = _trio(eoa, address(0));
        _assertEvents(k, v, wk, wv);
        _checkModel();
        // it saves the default again while it has code
        (k, v) = _record(eoa, abi.encodeCall(PageNFT.setAddrForCoin, (id, DEF, abi.encodePacked(eoa))), id);
        _mSave(id, eoa, DEF, abi.encodePacked(eoa));
        (wk, wv) = _defaultSave(eoa, eoa);
        _assertEvents(k, v, wk, wv);
        _checkModel();
        _evmAll(id, eoa, "saved with code");
    }

    // a save of the default announces it, then the coin type 60 answer and AddrChanged with that answer
    function _defaultSave(address d, address eth) internal pure returns (uint256[] memory k, bytes[] memory v) {
        k = new uint256[](3);
        v = new bytes[](3);
        (k[0], v[0]) = (DEF, _enc(d));
        (k[1], v[1]) = (ETH, _enc(eth));
        (k[2], v[2]) = (1, _enc(eth));
    }

    // the coin type 60 answer and AddrChanged with it, as a move gives them when only that answer changes
    function _eth(address eth) internal pure returns (uint256[] memory k, bytes[] memory v) {
        k = new uint256[](2);
        v = new bytes[](2);
        (k[0], v[0]) = (ETH, _enc(eth));
        (k[1], v[1]) = (1, _enc(eth));
    }

    // expiry, grace, a renewal in grace, the premium period, and registrations again by another and the same account
    function test_expiryGraceAuction() public {
        uint256 id = _reveal(relayer, "life", alice);
        _save(alice, id, DEF, abi.encodePacked(cold));
        vm.warp(nft.expiresAt(id));
        _checkModel();
        _evmAll(id, cold, "the last second");
        vm.warp(nft.expiresAt(id) + 1);
        _checkModel();
        _evmAll(id, address(0), "expired");
        assertEq(nft.addr(id, OP), "");
        vm.prank(alice);
        vm.expectRevert(PageNFT.Expired.selector);
        nft.setAddrForCoin(id, DEF, abi.encodePacked(alice));
        vm.prank(alice);
        vm.expectRevert(PageNFT.Expired.selector);
        nft.transferFrom(alice, bob, id);
        vm.prank(alice);
        vm.expectRevert(PageNFT.Expired.selector);
        nft.clearRecords(id);

        // a renewal in grace brings it back with no address event, as for every other answer
        uint256 fee = nft.getFee(4);
        vm.recordLogs();
        vm.prank(relayer);
        nft.renew{value: fee}(id);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (uint256[] memory k,) = _addrEvents(logs, id);
        assertEq(k.length, 0, "a renewal announces no address");
        _checkModel();
        _evmAll(id, cold, "renewed in grace");

        // the premium period: nothing answers, and a registration by another account retires the default
        vm.warp(nft.expiresAt(id) + GRACE + 1);
        assertGt(nft.getPremium(id), 0);
        _checkModel();
        _evmAll(id, address(0), "in the premium period");
        bytes32 secret = keccak256("bob-life");
        _must(bob, abi.encodeCall(PageNFT.commit, (nft.makeCommitment("life", bob, 0, secret))));
        vm.warp(vm.getBlockTimestamp() + 61);
        (,,, uint256 total) = nft.quote("life");
        vm.deal(bob, total);
        bytes[][] memory before = _snap();
        vm.recordLogs();
        vm.prank(bob);
        nft.reveal{value: total}("life", bob, 0, secret);
        logs = vm.getRecordedLogs();
        _checkLogs(before, logs);
        _mBump(id);
        _checkModel();
        bytes[] memory v;
        (k, v) = _addrEvents(logs, id);
        (uint256[] memory bk, bytes[] memory bv) = _trio(address(0), address(0));
        (uint256[] memory mk, bytes[] memory mv) = _trio(bob, address(0));
        (uint256[] memory vk, bytes[] memory vv) = _one(2, abi.encode(uint64(1)));
        (bk, bv) = _cat(bk, bv, vk, vv);
        (bk, bv) = _cat(bk, bv, mk, mv);
        _assertEvents(k, v, bk, bv);
        _evmAll(id, address(0), "registered again by another account, which saved nothing");

        // the same account registers it again in the premium period
        uint256 id2 = _reveal(relayer, "life2", alice);
        _save(alice, id2, DEF, abi.encodePacked(cold));
        vm.warp(nft.expiresAt(id2) + GRACE + 1);
        assertGt(nft.getPremium(id2), 0);
        _reveal(alice, "life2", alice);
        _evmAll(id2, address(0), "registered again by its holder, the old default retired");
    }

    // release, then a paid registration and a trial by the same account
    function test_releaseThenAgain() public {
        uint256 id = _reveal(relayer, "rel", alice);
        _save(alice, id, DEF, abi.encodePacked(cold));
        uint256 id2 = _reveal(relayer, "rel2", alice);
        _save(alice, id2, DEF, abi.encodePacked(cold));
        vm.warp(nft.expiresAt(id2) + GRACE + DECAY + 1);
        _must(relayer, abi.encodeCall(PageNFT.release, (id)));
        _must(relayer, abi.encodeCall(PageNFT.release, (id2)));
        _checkModel();
        _evmAll(id, address(0), "released");
        _reveal(alice, "rel", alice);
        _evmAll(id, address(0), "a paid registration after release");
        _trial("rel2", alice);
        _evmAll(id2, address(0), "a trial after release");
    }

    // a trial saves a default, a renewal keeps it, a move to the dead address deletes it, and a lapse retires it
    function test_trialLifecycle() public {
        uint256 id = _trial("tri", alice);
        _save(alice, id, DEF, abi.encodePacked(cold));
        _evmAll(id, cold, "in the trial");
        uint256 fee = nft.getFee(3);
        vm.recordLogs();
        vm.prank(relayer);
        nft.renew{value: fee}(id);
        (uint256[] memory k,) = _addrEvents(vm.getRecordedLogs(), id);
        assertEq(k.length, 0, "a renewal into a paid name changes no address");
        _checkModel();
        _evmAll(id, cold, "paid after the trial");
        assertGt(nft.depositOf(id), 0);

        uint256 id2 = _trial("tri2", alice);
        _save(alice, id2, DEF, abi.encodePacked(cold));
        vm.prank(alice);
        vm.expectRevert(PageNFT.Unpaid.selector);
        nft.transferFrom(alice, bob, id2);
        (uint256[] memory dk, bytes[] memory dv) =
            _record(alice, abi.encodeCall(PageNFT.transferFrom, (alice, DEAD, id2)), id2);
        // the dead address deletes the page, so the move announces empty addresses
        (uint256[] memory wk, bytes[] memory wv) = _trio(address(0), address(0));
        _assertEvents(dk, dv, wk, wv);
        _checkModel();
        _evmAll(id2, address(0), "a trial sent to the dead address");
        assertEq(nft.addr(id2, OP), "", "nor the home chain");
        assertEq(nft.resolve(id2), address(0), "nor resolve");

        uint256 id3 = _trial("tri3", alice);
        _save(alice, id3, DEF, abi.encodePacked(cold));
        vm.warp(nft.expiresAt(id3) + 1);
        _checkModel();
        _evmAll(id3, address(0), "a lapsed trial");
        _reveal(alice, "tri3", alice);
        _evmAll(id3, address(0), "paid at once by the same account");

        uint256 id4 = _trial("tri4", alice);
        _save(alice, id4, DEF, abi.encodePacked(cold));
        vm.warp(nft.expiresAt(id4) + 14 days + 1);
        _trial("tri4", alice);
        _evmAll(id4, address(0), "a new trial by the same account");
    }

    // keepProfile takes the text and website only; clearRecords retires the default for good
    function test_clearRecordsAndKeepProfile() public {
        uint256 id = _reveal(relayer, "prof", alice);
        _must(alice, abi.encodeCall(PageNFT.setText, (id, "url", "a")));
        _save(alice, id, DEF, abi.encodePacked(cold));
        _save(alice, id, BASE, abi.encodePacked(other));
        _move(alice, alice, bob, id, 0);
        _must(bob, abi.encodeCall(PageNFT.keepProfile, (id)));
        _checkModel();
        assertEq(nft.text(id, "url"), "a", "the profile is kept");
        _evmAll(id, address(0), "the seller's default is not");
        assertEq(nft.addr(id, BASE), "", "nor a chain entry");
        // back with the seller: its addresses count again, its profile only after it keeps it again
        _move(bob, bob, alice, id, 0);
        _evmAll(id, cold, "back with the seller");
        assertEq(nft.text(id, "url"), "", "the profile was kept by the buyer");
        _must(alice, abi.encodeCall(PageNFT.keepProfile, (id)));
        assertEq(nft.text(id, "url"), "a");
        _clear(alice, id);
        _evmAll(id, address(0), "after clearRecords");
        assertEq(nft.addr(id, BASE), "");
        assertEq(nft.text(id, "url"), "");
        _move(alice, alice, bob, id, 0);
        _move(bob, bob, alice, id, 0);
        _evmAll(id, address(0), "not even after a round trip");
        // clearRecords leaves the writer as it was, so there is nothing to keep, and the text stays empty
        assertEq(nft.profileWriter(id), alice);
        vm.prank(alice);
        vm.expectRevert(PageNFT.AlreadyKept.selector);
        nft.keepProfile(id);
        assertEq(nft.text(id, "url"), "");
    }

    // a subpage's own default through the parent moving, a new mint to someone else, deletion and re-creation,
    // and a new registration of the parent
    function test_subpageLifecycle() public {
        uint256 par = _reveal(relayer, "par", alice);
        uint256 s = _sub(alice, "s", par, bob);
        _save(bob, s, DEF, abi.encodePacked(cold));
        _save(alice, par, DEF, abi.encodePacked(other));
        _evmAll(s, cold, "the subpage's own default");
        _evmAll(par, other, "the parent's own default");
        _move(alice, alice, carol, par, 0);
        _evmAll(s, cold, "the parent moved");
        _evmAll(par, address(0), "the parent's default stays with its saver");

        // the new parent holder mints it again to someone else
        (uint256[] memory k, bytes[] memory v) =
            _record(carol, abi.encodeCall(PageNFT.registerSubpageFor, ("s", par, dave)), s);
        _mBump(s);
        _checkModel();
        (uint256[] memory wk, bytes[] memory wv) = _trio(address(0), address(0));
        (uint256[] memory vk, bytes[] memory vv) = _one(2, abi.encode(uint64(1)));
        (wk, wv) = _cat(wk, wv, vk, vv);
        (uint256[] memory mk, bytes[] memory mv) = _trio(dave, address(0));
        (wk, wv) = _cat(wk, wv, mk, mv);
        _assertEvents(k, v, wk, wv);
        _evmAll(s, address(0), "minted again to someone else");

        // deleted, then created again for the account whose default it was
        _save(dave, s, DEF, abi.encodePacked(cold));
        (k, v) = _record(dave, abi.encodeCall(PageNFT.transferFrom, (dave, DEAD, s)), s);
        (wk, wv) = _trio(address(0), address(0));
        _assertEvents(k, v, wk, wv);
        _checkModel();
        _evmAll(s, address(0), "deleted");
        assertEq(nft.addr(s, OP), "");
        vm.prank(DEAD);
        vm.expectRevert(PageNFT.Expired.selector);
        nft.setAddrForCoin(s, DEF, abi.encodePacked(cold));
        _sub(carol, "s", par, dave);
        _evmAll(s, address(0), "created again for the same account");

        // the parent is registered again: the subpage is invalid, then minted again
        _save(dave, s, DEF, abi.encodePacked(cold));
        vm.warp(nft.expiresAt(par) + GRACE + DECAY + 1);
        _checkModel();
        _evmAll(s, address(0), "the parent expired");
        _reveal(relayer, "par", alice);
        _checkModel();
        _evmAll(s, address(0), "invalid after the parent was registered again");
        vm.prank(dave);
        vm.expectRevert(PageNFT.Expired.selector);
        nft.setAddrForCoin(s, DEF, abi.encodePacked(dave));
        vm.prank(dave);
        vm.expectRevert(PageNFT.Expired.selector);
        nft.transferFrom(dave, bob, s);
        _sub(alice, "s", par, dave);
        _evmAll(s, address(0), "minted again under the new registration, to the same account");
    }

    // a minter creates a subpage, its holder saves a default and deletes it, and the minter creates it again
    function test_minterCreation() public {
        uint256 shop = _reveal(relayer, "shop", alice);
        address minter = makeAddr("minter");
        _must(alice, abi.encodeCall(PageNFT.setSubpageMinter, (shop, minter)));
        uint256 m = _sub(minter, "m", shop, bob);
        _save(bob, m, DEF, abi.encodePacked(cold));
        vm.prank(minter);
        vm.expectRevert(PageNFT.AlreadyRegistered.selector);
        nft.registerSubpageFor("m", shop, carol);
        _move(bob, bob, DEAD, m, 0);
        _sub(minter, "m", shop, bob);
        _evmAll(m, address(0), "the minter created it again for the same account");

        // the same through the registrar
        _must(alice, abi.encodeCall(PageNFT.setSubpageMinter, (shop, address(reg))));
        vm.prank(alice);
        reg.configure(shop, address(0), address(0), 0.001 ether, true, address(0), 0, false);
        uint256 r = _subId(shop, "r");
        _track(r);
        _buy(bob, shop, "r");
        _checkModel();
        _save(bob, r, DEF, abi.encodePacked(cold));
        _evmAll(r, cold, "bought, then saved");
        _move(bob, bob, DEAD, r, 1);
        _buy(bob, shop, "r");
        _mBump(r);
        _checkModel();
        _evmAll(r, address(0), "bought again by the same account");
    }

    function _buy(address buyer, uint256 shop, string memory label) internal {
        vm.deal(buyer, buyer.balance + 0.001 ether);
        bytes[][] memory before = _snap();
        vm.recordLogs();
        vm.prank(buyer);
        reg.registerSubpage{value: 0.001 ether}(shop, label, 0.001 ether, address(0));
        _checkLogs(before, vm.getRecordedLogs());
    }

    // batches: a save and a move, a clear and a save, a save and a clear, a move then a save, and an operator
    function test_multicallBatches() public {
        uint256 id = _reveal(relayer, "batch", alice);
        bytes[] memory calls = new bytes[](2);

        calls[0] = abi.encodeCall(PageNFT.setAddrForCoin, (id, DEF, abi.encodePacked(cold)));
        calls[1] = abi.encodeCall(PageNFT.transferFrom, (alice, bob, id));
        (uint256[] memory k, bytes[] memory v) = _record(alice, abi.encodeCall(PageNFT.multicall, (calls)), id);
        _mSave(id, alice, DEF, abi.encodePacked(cold));
        _checkModel();
        (uint256[] memory wk, bytes[] memory wv) = _defaultSave(cold, cold);
        (uint256[] memory tk, bytes[] memory tv) = _trio(bob, address(0));
        (wk, wv) = _cat(wk, wv, tk, tv);
        _assertEvents(k, v, wk, wv);
        _evmAll(id, address(0), "saved then moved in one batch");
        _move(bob, bob, alice, id, 0);
        _evmAll(id, cold, "the batch saved it for the seller");

        calls[0] = abi.encodeCall(PageNFT.clearRecords, (id));
        calls[1] = abi.encodeCall(PageNFT.setAddrForCoin, (id, DEF, abi.encodePacked(other)));
        (k, v) = _record(alice, abi.encodeCall(PageNFT.multicall, (calls)), id);
        _mBump(id);
        _mSave(id, alice, DEF, abi.encodePacked(other));
        _checkModel();
        _evmAll(id, other, "cleared then saved");
        assertEq(k.length, 7);
        assertEq(k[0], 2, "the version first");

        calls[0] = abi.encodeCall(PageNFT.setAddrForCoin, (id, DEF, abi.encodePacked(cold)));
        calls[1] = abi.encodeCall(PageNFT.clearRecords, (id));
        (k, v) = _record(alice, abi.encodeCall(PageNFT.multicall, (calls)), id);
        _mSave(id, alice, DEF, abi.encodePacked(cold));
        _mBump(id);
        _checkModel();
        _evmAll(id, address(0), "saved then cleared");
        assertEq(k[k.length - 2], ETH);
        assertEq(v[v.length - 2], "", "the last announcement of coin type 60 is empty, as nothing is saved");
        assertEq(k[k.length - 1], 1, "AddrChanged last");
        assertEq(v[v.length - 1], "", "with the same empty answer");

        // a move then a save by the seller fails as a whole
        calls[0] = abi.encodeCall(PageNFT.transferFrom, (alice, bob, id));
        calls[1] = abi.encodeCall(PageNFT.setAddrForCoin, (id, DEF, abi.encodePacked(cold)));
        vm.prank(alice);
        vm.expectRevert(PageNFT.Unauthorized.selector);
        nft.multicall(calls);
        assertEq(nft.ownerOf(id), alice);
        _checkModel();

        // an operator takes the name and saves its own default in one batch
        _must(alice, abi.encodeWithSignature("setApprovalForAll(address,bool)", carol, true));
        calls[0] = abi.encodeCall(PageNFT.transferFrom, (alice, carol, id));
        calls[1] = abi.encodeCall(PageNFT.setAddrForCoin, (id, DEF, abi.encodePacked(cold)));
        (k, v) = _record(carol, abi.encodeCall(PageNFT.multicall, (calls)), id);
        _mSave(id, carol, DEF, abi.encodePacked(cold));
        _checkModel();
        _evmAll(id, cold, "the operator's own default");

        // a save then a safe move to a contract
        LifecycleHolder h = new LifecycleHolder(address(nft));
        calls[0] = abi.encodeCall(PageNFT.setAddrForCoin, (id, DEF, abi.encodePacked(other)));
        calls[1] = abi.encodeWithSignature("safeTransferFrom(address,address,uint256)", carol, address(h), id);
        (k, v) = _record(carol, abi.encodeCall(PageNFT.multicall, (calls)), id);
        _mSave(id, carol, DEF, abi.encodePacked(other));
        _checkModel();
        _evmAll(id, address(0), "a contract receiver answers nothing until it saves");
    }

    // The save announces coin type 0x80000000, but a move never announces it again: after the move, the last
    // AddressChanged for 0x80000000 is still the seller's default while addr answers nothing for the buyer, who saved
    // nothing. Coin type 60 is announced again by the move, so it never goes stale this way.
    function test_defaultAnnouncementAfterMove() public {
        uint256 id = _reveal(relayer, "stale", alice);
        (uint256[] memory k, bytes[] memory v) =
            _record(alice, abi.encodeCall(PageNFT.setAddrForCoin, (id, DEF, abi.encodePacked(cold))), id);
        _mSave(id, alice, DEF, abi.encodePacked(cold));
        assertEq(k.length, 3);
        assertEq(k[0], DEF);
        assertEq(v[0], _enc(cold), "the save announces the default");
        (k, v) = _record(alice, abi.encodeCall(PageNFT.transferFrom, (alice, bob, id)), id);
        _checkModel();
        bool sawDef;
        bool sawEth;
        for (uint256 i; i < k.length; ++i) {
            if (k[i] == DEF) sawDef = true;
            if (k[i] == ETH) {
                sawEth = true;
                assertEq(v[i], "");
            }
        }
        assertTrue(sawEth, "the move announces the Ethereum answer");
        assertFalse(sawDef, "the move does not announce the default");
        assertEq(nft.addr(id, DEF), "", "the default now answers nothing for the buyer");
        assertEq(nft.addr(id, ARB), "", "and neither does any chain without an entry");
        // the same holds for a chain entry, here Base
        uint256 id2 = _reveal(relayer, "stale2", alice);
        (k, v) = _record(alice, abi.encodeCall(PageNFT.setAddrForCoin, (id2, BASE, abi.encodePacked(cold))), id2);
        _mSave(id2, alice, BASE, abi.encodePacked(cold));
        (k, v) = _record(alice, abi.encodeCall(PageNFT.transferFrom, (alice, bob, id2)), id2);
        for (uint256 i; i < k.length; ++i) {
            assertTrue(k[i] != BASE, "a move does not announce Base either");
        }
        assertEq(nft.addr(id2, BASE), "");
    }

    // the receiver is the sender's main address, so the main address does not change, but the sender's default
    // stops counting: the Ethereum answer changes alone and must be announced
    function test_moveToTheMainAddressWithADefault() public {
        uint256 id = _reveal(relayer, "tomain", alice);
        _setMain(alice, id, bob);
        _save(alice, id, DEF, abi.encodePacked(cold));
        _evmAll(id, cold, "the seller's default");
        (uint256[] memory k, bytes[] memory v) =
            _record(alice, abi.encodeCall(PageNFT.transferFrom, (alice, bob, id)), id);
        (uint256[] memory wk, bytes[] memory wv) = _eth(address(0));
        _assertEvents(k, v, wk, wv);
        _checkModel();
        _evmAll(id, address(0), "the buyer is its own main address but saved nothing");
        // and back: the main address is bob again, the default counts again
        (k, v) = _record(bob, abi.encodeCall(PageNFT.transferFrom, (bob, alice, id)), id);
        (wk, wv) = _eth(cold);
        _assertEvents(k, v, wk, wv);
        _checkModel();
        assertEq(nft.resolve(id), bob);
        _evmAll(id, cold, "back with the seller");
    }

    // setAddr and clearRecords announce the Ethereum answer the default gives, and setAddr never moves the default
    function test_setAddrAndClearAnnounceTheDefault() public {
        uint256 id = _reveal(relayer, "seta", alice);
        _save(alice, id, DEF, abi.encodePacked(cold));
        (uint256[] memory k, bytes[] memory v) = _record(alice, abi.encodeCall(PageNFT.setAddr, (id, bob)), id);
        _mSetMain(id, alice, bob);
        _checkModel();
        (uint256[] memory wk, bytes[] memory wv) = _trio(bob, cold);
        _assertEvents(k, v, wk, wv);
        _evmAll(id, cold, "the main address moved, the default did not");
        assertEq(nft.addr(id, OP), _enc(bob));
        // the main address is a contract now, still the default answers
        LifecycleHolder c = new LifecycleHolder(address(nft));
        (k, v) = _record(alice, abi.encodeCall(PageNFT.setAddrForCoin, (id, OP, abi.encodePacked(address(c)))), id);
        _mSetMain(id, alice, address(c));
        _checkModel();
        (wk, wv) = _trio(address(c), cold);
        _assertEvents(k, v, wk, wv);
        // clearRecords: coin type 60 is announced empty, never the retired default
        (k, v) = _record(alice, abi.encodeCall(PageNFT.clearRecords, (id)), id);
        _mBump(id);
        _checkModel();
        (wk, wv) = _trio(alice, address(0));
        (uint256[] memory vk, bytes[] memory vv) = _one(2, abi.encode(uint64(1)));
        (wk, wv) = _cat(vk, vv, wk, wv);
        _assertEvents(k, v, wk, wv);
        _evmAll(id, address(0), "after clearRecords");
    }

    // a contract receiver saves its own default from onERC721Received, after the hook's announcements
    function test_receiverSavesInCallback() public {
        LifecycleHolder h = new LifecycleHolder(address(nft));
        h.setSaveOnReceive(true, abi.encodePacked(cold));
        uint256 id = _reveal(relayer, "cb", alice);
        _save(alice, id, DEF, abi.encodePacked(other));
        (uint256[] memory k, bytes[] memory v) = _record(
            alice, abi.encodeWithSignature("safeTransferFrom(address,address,uint256)", alice, address(h), id), id
        );
        _mSave(id, address(h), DEF, abi.encodePacked(cold));
        _checkModel();
        (uint256[] memory wk, bytes[] memory wv) = _trio(address(h), address(0));
        (uint256[] memory sk, bytes[] memory sv) = _defaultSave(cold, cold);
        (wk, wv) = _cat(wk, wv, sk, sv);
        _assertEvents(k, v, wk, wv);
        _evmAll(id, cold, "saved by the receiver in its hook");

        // a mint to the contract: the hook announces first, the receiver's save after
        uint256 id2 = nft.computeId("cb2");
        _track(id2);
        bytes32 secret = keccak256("cb2");
        _must(relayer, abi.encodeCall(PageNFT.commit, (nft.makeCommitment("cb2", address(h), 0, secret))));
        vm.warp(vm.getBlockTimestamp() + 61);
        (,,, uint256 total) = nft.quote("cb2");
        bytes[][] memory before = _snap();
        vm.recordLogs();
        vm.prank(relayer);
        nft.reveal{value: total}("cb2", address(h), 0, secret);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        _checkLogs(before, logs);
        _mSave(id2, address(h), DEF, abi.encodePacked(cold));
        _checkModel();
        (k, v) = _addrEvents(logs, id2);
        _assertEvents(k, v, wk, wv);
        _evmAll(id2, cold, "minted to a contract that saved in its hook");

        // one batch: the seller saves a default, then a safe move to the contract, which saves its own in the hook
        uint256 id3 = _reveal(relayer, "cb3", alice);
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(PageNFT.setAddrForCoin, (id3, DEF, abi.encodePacked(other)));
        calls[1] = abi.encodeWithSignature("safeTransferFrom(address,address,uint256)", alice, address(h), id3);
        (k, v) = _record(alice, abi.encodeCall(PageNFT.multicall, (calls)), id3);
        _mSave(id3, alice, DEF, abi.encodePacked(other));
        _mSave(id3, address(h), DEF, abi.encodePacked(cold));
        _checkModel();
        (wk, wv) = _defaultSave(other, other);
        (uint256[] memory tk, bytes[] memory tv) = _trio(address(h), address(0));
        (wk, wv) = _cat(wk, wv, tk, tv);
        (sk, sv) = _defaultSave(cold, cold);
        (wk, wv) = _cat(wk, wv, sk, sv);
        _assertEvents(k, v, wk, wv);
        _evmAll(id3, cold, "the receiver's own default after a batch");
    }

    // the zero address can never take a name, approve, or mint a subpage, so no default of it can count
    function test_zeroCallerTakesNothing() public {
        uint256 par = _reveal(relayer, "zed", alice);
        _save(alice, par, DEF, abi.encodePacked(cold));
        vm.startPrank(address(0));
        vm.expectRevert(bytes4(0x4b6e7f18));
        nft.transferFrom(alice, address(0x1234), par);
        vm.expectRevert(bytes4(0x4b6e7f18));
        nft.safeTransferFrom(alice, address(0x1234), par);
        vm.expectRevert(bytes4(0x4b6e7f18));
        nft.safeTransferFrom(alice, address(0x1234), par, "");
        vm.expectRevert(bytes4(0x4b6e7f18));
        nft.approve(address(0x1234), par);
        vm.expectRevert(PageNFT.NotParentOwner.selector);
        nft.registerSubpage("z", par);
        vm.expectRevert(PageNFT.NotParentOwner.selector);
        nft.registerSubpageFor("z", par, address(0x1234));
        vm.expectRevert(PageNFT.Unauthorized.selector);
        nft.setAddrForCoin(par, DEF, abi.encodePacked(address(0x1234)));
        vm.stopPrank();
        // also when the holder made the zero address an operator
        _must(alice, abi.encodeWithSignature("setApprovalForAll(address,bool)", address(0), true));
        vm.prank(address(0));
        vm.expectRevert(bytes4(0x4b6e7f18));
        nft.transferFrom(alice, address(0x1234), par);
        _checkModel();
        _evmAll(par, cold, "unchanged");
    }
}

// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {trialCommitment} from "../../utils/TrialCommitment.sol";

import {Vm} from "forge-std/Test.sol";
import {MinterBase} from "../../utils/MinterBase.sol";
import {Holder721} from "../../utils/MinterMocks.sol";

// What clearRecords logs and what it leaves alone, and how a buyer's clear and a buyer's save act on the
// seller's entries.
contract ClearRulesTest is MinterBase {
    uint256 constant COIN_BASE = 0x80002105;
    uint256 constant COIN_BTC = 0;
    uint256 constant DEFAULT_EVM = 0x80000000;
    bytes32 constant T_VERSION = keccak256("VersionChanged(bytes32,uint64)");
    bytes32 constant T_ADDRESS = keccak256("AddressChanged(bytes32,uint256,bytes)");
    bytes32 constant T_ADDR = keccak256("AddrChanged(bytes32,address)");
    bytes32 constant T_META = keccak256("MetadataUpdate(uint256)");

    // a full set of records saved by the holder
    function _load(uint256 id, address who) internal {
        vm.startPrank(who);
        nft.setAddr(id, hot);
        nft.setAddrForCoin(id, 60, abi.encodePacked(hot2));
        nft.setAddrForCoin(id, COIN_BASE, abi.encodePacked(carol));
        nft.setAddrForCoin(id, COIN_BTC, hex"0014deadbeef");
        nft.setText(id, "url", "https://example.org");
        nft.setContenthash(id, hex"e3010170");
        vm.stopPrank();
    }

    // the five logs of a clear, where the coin type 60 answer is empty for every holder, as nothing is saved in
    // the new version and the code at the holder's address does not matter, so AddrChanged carries zero
    function _assertClearLogs(Vm.Log[] memory logs, uint256 id, address holder, uint256 version)
        internal
        view
    {
        assertEq(logs.length, 5, "exactly five logs");
        for (uint256 i; i < 5; ++i) {
            assertEq(logs[i].emitter, address(nft));
            assertEq(logs[i].topics.length, i == 4 ? 1 : 2);
            if (i < 4) assertEq(logs[i].topics[1], bytes32(id), "the node");
        }
        assertEq(logs[0].topics[0], T_VERSION);
        assertEq(abi.decode(logs[0].data, (uint64)), version, "the new version");
        assertEq(logs[1].topics[0], T_ADDRESS);
        (uint256 coin, bytes memory a) = abi.decode(logs[1].data, (uint256, bytes));
        assertEq(coin, COIN_OP);
        assertEq(a, abi.encodePacked(holder), "OP answers the holder");
        assertEq(logs[2].topics[0], T_ADDRESS);
        (coin, a) = abi.decode(logs[2].data, (uint256, bytes));
        assertEq(coin, 60);
        assertEq(a, bytes(""), "the holder's coin type 60 answer");
        assertEq(a, nft.addr(id, 60));
        assertEq(logs[3].topics[0], T_ADDR);
        assertEq(abi.decode(logs[3].data, (address)), address(0), "AddrChanged carries the coin type 60 answer");
        assertEq(abi.decode(logs[3].data, (address)), nft.addr(bytes32(id)));
        assertEq(logs[4].topics[0], T_META);
        assertEq(abi.decode(logs[4].data, (uint256)), id);
    }

    function _clearAndCheck(uint256 id, address holder) internal {
        uint256 v = nft.recordVersion(id);
        vm.recordLogs();
        vm.prank(holder);
        nft.clearRecords(id);
        _assertClearLogs(vm.getRecordedLogs(), id, holder, v + 1);
        assertEq(nft.recordVersion(id), v + 1);
    }

    // a holder with no code, a 7702 account and a contract each clear a loaded name and then clear again
    // with nothing saved: every call logs exactly VersionChanged, the trio for the holder and MetadataUpdate,
    // and the coin type 60 answer is empty for all three alike
    function test_clearEvents() public {
        address delegated = makeAddr("delegated");
        vm.etch(delegated, abi.encodePacked(hex"ef0100", address(new Holder721())));
        address contractHolder = address(new Holder721());
        address[3] memory holders = [bob, delegated, contractHolder];
        string[3] memory labels = ["eoaname", "delegatedname", "contractname"];
        for (uint256 i; i < 3; ++i) {
            uint256 id = _regTo(alice, labels[i], holders[i]);
            _load(id, holders[i]);
            _clearAndCheck(id, holders[i]);
            _clearAndCheck(id, holders[i]);
            assertEq(nft.text(id, "url"), "");
            assertEq(nft.addr(id, COIN_BTC), "");
        }
    }

    // the views a clear of one name must leave alone, hashed; display names are compared as stored, since
    // reverseResolve follows the main address, which the clear points back at the holder
    function _world(uint256[] memory ids, address[] memory accounts) internal view returns (bytes32 h) {
        h = keccak256(abi.encode(address(nft).balance, address(reg).balance));
        for (uint256 i; i < ids.length; ++i) {
            uint256 id = ids[i];
            (string memory label, uint256 parent, uint64 exp, uint64 epoch, uint64 pe) = nft.records(id);
            h = keccak256(abi.encode(h, label, parent, exp, epoch, pe, nft.depositOf(id), nft.referrerOf(id)));
            (bytes32 m0, bytes32 m1) = _raw12(id);
            h = keccak256(abi.encode(h, nft.ownerOf(id), nft.subpageMinterOf(id), m0, m1, _config(id)));
        }
        for (uint256 i; i < accounts.length; ++i) {
            address a = accounts[i];
            h = keccak256(abi.encode(h, nft.owed(a), nft.primaryPage(a), reg.proceedsOf(a)));
        }
    }

    function _config(uint256 id) internal view returns (bytes32) {
        (address c, bool en, bool cr, address ft, uint96 price, address gate, uint96 minGate, address pay, uint64 pe) =
            reg.config(id);
        return keccak256(abi.encode(c, en, cr, ft, price, gate, minGate, pay, pe));
    }

    function _raw12(uint256 id) internal view returns (bytes32, bytes32) {
        bytes32 base = keccak256(abi.encode(id, uint256(12)));
        return (vm.load(address(nft), base), vm.load(address(nft), bytes32(uint256(base) + 1)));
    }

    // everything another name answers
    function _answers(uint256 id) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                nft.recordVersion(id), nft.resolve(id), nft.payee(id), nft.addr(id, COIN_OP), nft.addr(id, 60),
                nft.addr(id, COIN_BASE), nft.addr(id, COIN_BTC), nft.text(id, "url"), nft.contenthash(id),
                nft.profileWriter(id), nft.getPageName(id), nft.tokenURI(id)
            )
        );
    }

    // a parent's clear changes its own records and nothing else: not its record, deposit, referrer, minter
    // pick or sale config, not its subpage's records or version, not another name's records, not any credit,
    // display name, proceeds or balance, and it logs no money event
    function test_clearTouchesOnlyThisNamesRecords() public {
        uint256 ref = _reg(dave, "referrer");
        uint256 club = _regTo(bob, "club", bob);
        uint256 clubFee = nft.getFee(4);
        vm.prank(bob);
        nft.renew{value: clubFee}(club);
        uint256 other = _reg(carol, "other");
        _load(other, carol);
        _load(club, bob);
        vm.prank(bob);
        uint256 sub = nft.registerSubpageFor("shop", club, carol);
        _load(sub, carol);
        vm.prank(carol);
        nft.setPrimaryPage(sub);
        vm.prank(bob);
        nft.setPrimaryPage(club);
        _sellSetup(club, 0.01 ether);
        vm.prank(buyer);
        reg.registerSubpage{value: 0.01 ether}(club, "sold", 0.01 ether, address(0));
        // a held trial and a credit from its release
        uint256 tr = _regTrial(stranger, "trialname");
        vm.warp(nft.expiresAt(tr) + 1);
        nft.release(tr);
        assertGt(nft.owed(stranger), 0);

        uint256[] memory ids = new uint256[](5);
        ids[0] = club;
        ids[1] = sub;
        ids[2] = other;
        ids[3] = ref;
        ids[4] = _subId("sold", club);
        address[] memory accounts = new address[](8);
        address[8] memory who = [alice, bob, carol, dave, hot, buyer, stranger, payout];
        for (uint256 i; i < 8; ++i) accounts[i] = who[i];
        bytes32 before = _world(ids, accounts);
        bytes32 subBefore = _answers(sub);
        bytes32 otherBefore = _answers(other);
        assertEq(nft.reverseResolve(bob), "", "hidden while the name points at hot");
        string memory carolShows = nft.reverseResolve(carol);
        vm.recordLogs();
        vm.prank(bob);
        nft.clearRecords(club);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        _assertClearLogs(logs, club, bob, 1);
        assertEq(_world(ids, accounts), before, "records, ledgers, picks, configs and display names unchanged");
        assertEq(_answers(sub), subBefore, "the subpage's records still count");
        assertEq(_answers(other), otherBefore, "another name's records still count");
        assertEq(nft.resolve(club), bob);
        assertEq(nft.text(club, "url"), "");
        // the stored display names are untouched; bob's shows again only because the name points at bob now
        assertEq(nft.reverseResolve(bob), "club");
        assertEq(nft.reverseResolve(carol), carolShows, "the subpage's display answer is unchanged");
        // the sale config still sells
        vm.prank(buyer);
        reg.registerSubpage{value: 0.01 ether}(club, "after", 0.01 ether, address(0));
    }

    function _regTrial(address who, string memory label) internal returns (uint256 id) {
        bytes32 secret = keccak256(abi.encode(who, label));
        bytes32 c = trialCommitment(address(nft), label, who, 0, secret);
        vm.prank(who);
        nft.commit(c);
        vm.warp(vm.getBlockTimestamp() + 61);
        uint256 price = nft.getFee(bytes(label).length) / 10;
        vm.prank(who);
        id = nft.revealTrial{value: price}(label, who, 0, secret);
    }

    // a buyer clears the seller's records and gives the name back: nothing the seller saved counts again,
    // and every answer is the one of an owner with nothing saved
    function test_buyerClearIsPermanent() public {
        uint256 id = _reg(alice, "alice");
        _load(id, alice);
        uint256 fresh = _reg(alice, "fresh");
        vm.prank(alice);
        nft.transferFrom(alice, bob, id);
        vm.prank(bob);
        nft.clearRecords(id);
        vm.prank(bob);
        nft.transferFrom(bob, alice, id);
        assertEq(nft.resolve(id), alice, "the main address is the holder again");
        assertEq(nft.payee(id), alice);
        assertEq(nft.resolveAs(id, alice), alice);
        uint256[4] memory coins = [COIN_OP, 60, COIN_BASE, COIN_BTC];
        for (uint256 i; i < 4; ++i) {
            assertEq(nft.addr(id, coins[i]), nft.addr(fresh, coins[i]), "as for a name with nothing saved");
        }
        // with nothing saved, coin type 60 answers empty
        assertEq(nft.addr(id, 60), "");
        assertEq(nft.addr(id, COIN_BTC), "");
        assertEq(nft.text(id, "url"), "");
        assertEq(nft.contenthash(id), "");
        // a new save by the seller counts at once
        vm.prank(alice);
        nft.setAddrForCoin(id, COIN_BTC, hex"01");
        assertEq(nft.addr(id, COIN_BTC), hex"01");
    }

    // the raw entry of a coin type at the current record version: its saver and its value
    function _entry(uint256 id, uint256 coin) internal view returns (address saver, bytes memory value) {
        bytes32 inner = keccak256(abi.encode(nft.recordVersion(id), keccak256(abi.encode(id, uint256(9)))));
        bytes32 slot = keccak256(abi.encode(coin, inner));
        saver = address(uint160(uint256(vm.load(address(nft), slot))));
        uint256 w = uint256(vm.load(address(nft), bytes32(uint256(slot) + 1)));
        // short bytes only, as every value here is under 32 bytes
        assertEq(w & 1, 0, "short form");
        value = new bytes((w & 0xff) / 2);
        for (uint256 i; i < value.length; ++i) value[i] = bytes32(w)[i];
    }

    // the buyer's save counts at once and takes the place of the seller's entry for that chain; the seller's
    // entries for the other chains stay stored and do not count while the buyer holds the name, and come
    // back when it returns, except the one the buyer replaced
    function test_buyerSavesOverTheSellersEntries() public {
        uint256 id = _reg(alice, "alice");
        vm.startPrank(alice);
        nft.setAddrForCoin(id, 60, abi.encodePacked(hot));
        nft.setAddrForCoin(id, COIN_BASE, abi.encodePacked(hot2));
        nft.setAddrForCoin(id, COIN_BTC, hex"0014aa");
        nft.transferFrom(alice, bob, id);
        vm.stopPrank();
        vm.prank(bob);
        nft.setAddrForCoin(id, COIN_BASE, abi.encodePacked(carol));
        assertEq(nft.addr(id, COIN_BASE), abi.encodePacked(carol), "the buyer's save counts at once");
        assertEq(nft.addr(id, 60), "", "the seller's entry does not count for the buyer, who saved none");
        assertEq(nft.addr(id, COIN_BTC), "");
        (address saver, bytes memory value) = _entry(id, COIN_BASE);
        assertEq(saver, bob, "the buyer's save replaced the seller's entry");
        assertEq(value, abi.encodePacked(carol));
        (saver, value) = _entry(id, 60);
        assertEq(saver, alice, "the other entries stay stored");
        assertEq(value, abi.encodePacked(hot));
        (saver, value) = _entry(id, COIN_BTC);
        assertEq(saver, alice);
        assertEq(value, hex"0014aa");
        vm.prank(bob);
        nft.transferFrom(bob, alice, id);
        assertEq(nft.addr(id, 60), abi.encodePacked(hot), "the seller's Ethereum entry counts again");
        assertEq(nft.addr(id, COIN_BTC), hex"0014aa");
        assertEq(nft.addr(id, COIN_BASE), "", "the replaced chain falls back to the default, and alice saved none");
        vm.prank(alice);
        nft.setAddrForCoin(id, DEFAULT_EVM, abi.encodePacked(dave));
        assertEq(nft.addr(id, COIN_BASE), abi.encodePacked(dave), "the replaced chain answers the saved default");
        assertEq(nft.addr(id, 60), abi.encodePacked(hot), "an own entry still wins over the default");
    }
}

// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Vm} from "forge-std/Test.sol";
import {PageNFT} from "../../../src/PageNFT.sol";
import {MinterBase} from "../../utils/MinterBase.sol";
import {StorageReader} from "../../utils/NamingBase.sol";

// A holder contract that saves a data record from inside the mint callback.
contract DataWritingReceiver {
    function onERC721Received(address, address, uint256 id, bytes calldata) external returns (bytes4) {
        PageNFT(msg.sender).setData(id, "from-callback", hex"c0ffee");
        return this.onERC721Received.selector;
    }
}

// Data records follow the rule of addresses: a record counts only while the account that saved it holds the page,
// keepProfile never brings it back, and clearRecords or a new registration empties it. They never touch the profile.
contract DataRecordsTest is MinterBase {
    bytes32 constant T_DATA = keccak256("DataChanged(bytes32,string,string,bytes)");
    string constant PREF = "payment-preference";
    string constant LIST = "accounts[10]";

    function _trialFor(address who, string memory label) internal returns (uint256 id) {
        bytes32 secret = keccak256(abi.encode(label));
        vm.prank(who);
        nft.commit(keccak256(abi.encode(bytes(label), who, uint256(0), secret, true)));
        vm.warp(vm.getBlockTimestamp() + 61);
        vm.prank(who);
        id = nft.revealTrial{value: nft.getFee(bytes(label).length) / 10}(label, who, 0, secret);
    }

    function test_saveReadAndEvent() public {
        uint256 id = _reg(alice, "alice");
        bytes32 node = bytes32(id);
        assertEq(nft.data(node, PREF).length, 0, "empty before a save");
        assertTrue(nft.supportsInterface(0xecbfada3), "the interface of data");
        assertEq(PageNFT.data.selector, bytes4(0xecbfada3), "the selector of data is its interface id");
        assertEq(PageNFT.DataChanged.selector, T_DATA);

        vm.recordLogs();
        vm.prank(alice);
        nft.setData(id, PREF, hex"abcd");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "one event");
        assertEq(logs[0].topics.length, 4);
        assertEq(logs[0].topics[0], T_DATA);
        assertEq(logs[0].topics[1], node);
        assertEq(logs[0].topics[2], keccak256(bytes(PREF)));
        assertEq(logs[0].topics[3], keccak256(hex"abcd"));
        assertEq(abi.decode(logs[0].data, (string)), PREF);
        assertEq(nft.data(node, PREF), hex"abcd");

        vm.prank(alice);
        nft.setData(id, PREF, "");
        assertEq(nft.data(node, PREF).length, 0, "an empty value clears it");
    }

    function test_onlyTheHolderOfAnActivePageWrites() public {
        uint256 id = _reg(alice, "alice");
        vm.prank(alice);
        nft.setApprovalForAll(bob, true);
        vm.prank(alice);
        nft.approve(carol, id);
        vm.prank(bob);
        vm.expectRevert(PageNFT.Unauthorized.selector);
        nft.setData(id, PREF, hex"01");
        vm.prank(carol);
        vm.expectRevert(PageNFT.Unauthorized.selector);
        nft.setData(id, PREF, hex"01");
        vm.prank(stranger);
        vm.expectRevert(PageNFT.Unauthorized.selector);
        nft.setData(id, PREF, hex"01");

        vm.warp(nft.expiresAt(id) + 1);
        vm.prank(alice);
        vm.expectRevert(PageNFT.Expired.selector);
        nft.setData(id, PREF, hex"01");
        assertEq(nft.data(bytes32(id), PREF).length, 0);

        vm.expectRevert(PageNFT.Expired.selector);
        nft.setData(_id("nobody"), PREF, hex"01");
        vm.expectRevert(PageNFT.Expired.selector);
        nft.setData(0, PREF, hex"01");
        assertEq(nft.data(bytes32(0), PREF).length, 0, "token 0");
        assertEq(nft.data(ROOT, PREF).length, 0, "the root");
    }

    // the zero caller, a stranger and an approved operator are refused and change nothing, on a live page, a page
    // never minted, an expired page and a page held by the dead address
    function testFuzz_refusedCallersChangeNothing(uint8 who, uint8 state, uint256 otherId) public {
        uint256 id = _reg(alice, "alice");
        vm.startPrank(alice);
        nft.setApprovalForAll(bob, true);
        nft.setData(id, PREF, hex"01");
        vm.stopPrank();
        address caller = [address(0), stranger, bob][who % 3];
        uint256 target = _refusalTarget(id, state, otherId);
        uint256 since = nft.holderSince(id);
        uint256 updated = nft.addressesUpdatedAt(id);
        uint256 version = nft.recordVersion(id);
        _expectWritesRefused(caller, target);
        assertEq(nft.holderSince(id), since);
        assertEq(nft.addressesUpdatedAt(id), updated);
        assertEq(nft.recordVersion(id), version);
        if (state % 4 < 2) assertEq(nft.data(bytes32(id), PREF), hex"01", "the holder's record stands");
    }

    /// @dev state % 4: 0 the live page, 1 another token, 2 the page after its end, 3 the page the dead address holds.
    function _refusalTarget(uint256 id, uint8 state, uint256 otherId) internal returns (uint256 target) {
        target = id;
        if (state % 4 == 1) target = otherId == id ? id + 1 : otherId;
        if (state % 4 == 2) vm.warp(nft.expiresAt(id) + 1);
        if (state % 4 == 3) {
            vm.prank(alice);
            nft.transferFrom(alice, DEAD, id);
        }
    }

    /// @dev Kept apart from the test so forge coverage --ir-minimum can compile it.
    function _expectWritesRefused(address caller, uint256 target) internal {
        bytes[] memory calls = new bytes[](4);
        calls[0] = abi.encodeCall(PageNFT.setData, (target, PREF, hex"02"));
        calls[1] = abi.encodeCall(PageNFT.clearRecords, (target));
        calls[2] = abi.encodeCall(PageNFT.setAddrForCoin, (target, 60, abi.encodePacked(hot)));
        calls[3] = abi.encodeCall(PageNFT.setAddrForCoin, (target, 0x80000000, abi.encodePacked(hot)));
        for (uint256 i; i < calls.length; ++i) {
            vm.recordLogs();
            vm.prank(caller);
            (bool ok, bytes memory ret) = address(nft).call(calls[i]);
            assertFalse(ok, "refused");
            bytes4 e = bytes4(ret);
            assertTrue(e == PageNFT.Unauthorized.selector || e == PageNFT.Expired.selector, "Unauthorized or Expired");
            // forge keeps the logs of a call that reverted, so none were written before the refusal
            assertEq(vm.getRecordedLogs().length, 0, "no event");
        }
    }

    function test_neverCarriedOverToANewHolder() public {
        uint256 id = _reg(alice, "shop");
        bytes32 node = bytes32(id);
        vm.startPrank(alice);
        nft.setText(id, "avatar", "alice's avatar");
        nft.setData(id, PREF, hex"a11ce0");
        nft.setData(id, LIST, hex"a11ce0");
        nft.transferFrom(alice, alice, id);
        assertEq(nft.data(node, PREF), hex"a11ce0", "a transfer to the same account keeps them");
        nft.transferFrom(alice, bob, id);
        vm.stopPrank();
        assertEq(nft.data(node, PREF).length, 0, "hidden after the sale");
        assertEq(nft.data(node, LIST).length, 0);

        vm.prank(bob);
        nft.keepProfile(id);
        assertEq(nft.text(id, "avatar"), "alice's avatar", "keepProfile brings the text back");
        assertEq(nft.data(node, PREF).length, 0, "but never a data record");
        assertEq(nft.data(node, LIST).length, 0);

        vm.prank(bob);
        nft.setData(id, PREF, hex"b0b0");
        assertEq(nft.data(node, PREF), hex"b0b0", "the new holder's own record");
        assertEq(nft.data(node, LIST).length, 0);

        // back to the first holder: her records that were not overwritten count again, as her addresses do
        vm.prank(bob);
        nft.transferFrom(bob, alice, id);
        assertEq(nft.data(node, PREF).length, 0, "overwritten by the other holder");
        assertEq(nft.data(node, LIST), hex"a11ce0");
    }

    // records stop and start counting with no DataChanged: on a sale, on the way back and on clearRecords
    function test_noEventWhenRecordsStopOrStartCounting() public {
        uint256 id = _reg(alice, "club");
        vm.prank(alice);
        nft.setData(id, "avatar", hex"c0ffee");

        vm.recordLogs();
        vm.prank(alice);
        nft.transferFrom(alice, bob, id);
        assertFalse(_has(vm.getRecordedLogs(), T_DATA), "no DataChanged on a sale");
        assertEq(nft.data(bytes32(id), "avatar").length, 0, "empty for the new holder");

        vm.recordLogs();
        vm.prank(bob);
        nft.transferFrom(bob, alice, id);
        assertFalse(_has(vm.getRecordedLogs(), T_DATA), "no DataChanged on the way back");
        assertEq(nft.data(bytes32(id), "avatar"), hex"c0ffee", "counts again for its saver");

        vm.recordLogs();
        vm.prank(alice);
        nft.clearRecords(id);
        assertFalse(_has(vm.getRecordedLogs(), T_DATA), "no DataChanged on clearRecords");
        assertEq(nft.data(bytes32(id), "avatar").length, 0);
    }

    function test_clearRecordsAndRegistrationAgainEmptyThem() public {
        uint256 id = _reg(alice, "alice");
        bytes32 node = bytes32(id);
        vm.prank(alice);
        nft.setData(id, PREF, hex"01");
        vm.prank(alice);
        nft.clearRecords(id);
        assertEq(nft.data(node, PREF).length, 0, "clearRecords");

        vm.prank(alice);
        nft.setData(id, PREF, hex"02");
        _lapseAndRegister(id, alice);
        assertEq(nft.data(node, PREF).length, 0, "a new registration, also by the same account");
    }

    // a record saved after the records start again is read back
    function test_savedAfterClearRecordsIsRead() public {
        uint256 id = _reg(alice, "alice");
        vm.startPrank(alice);
        nft.setData(id, PREF, hex"01");
        nft.clearRecords(id);
        nft.setData(id, PREF, hex"02");
        vm.stopPrank();
        assertEq(nft.data(bytes32(id), PREF), hex"02");
    }

    function test_savedAfterARegistrationAgainIsRead() public {
        uint256 id = _reg(alice, "alice");
        _lapseAndRegister(id, bob);
        vm.prank(bob);
        nft.setData(id, PREF, hex"03");
        assertEq(nft.data(bytes32(id), PREF), hex"03");
    }

    function test_savedAfterASubpageMintedAgainIsRead() public {
        uint256 shop = _reg(alice, "shop");
        vm.prank(alice);
        uint256 pay = nft.registerSubpageFor("pay", shop, bob);
        vm.prank(alice);
        nft.registerSubpageFor("pay", shop, carol);
        vm.prank(carol);
        nft.setData(pay, PREF, hex"04");
        assertEq(nft.data(bytes32(pay), PREF), hex"04");
    }

    // a holder that clears its records and gives the page back leaves nothing of the seller's that counts again
    function test_backToTheSaverAfterTheBuyerCleared() public {
        uint256 id = _reg(alice, "shop");
        vm.prank(alice);
        nft.setData(id, PREF, hex"a1");
        vm.prank(alice);
        nft.transferFrom(alice, bob, id);
        vm.prank(bob);
        nft.clearRecords(id);
        vm.prank(bob);
        nft.transferFrom(bob, alice, id);
        assertEq(nft.data(bytes32(id), PREF).length, 0, "cleared for good");
    }

    function test_subpagesAndTheirParent() public {
        uint256 shop = _reg(alice, "shop");
        vm.prank(alice);
        uint256 pay = nft.registerSubpageFor("pay", shop, bob);
        vm.prank(bob);
        nft.setData(pay, PREF, hex"01");
        assertEq(nft.data(bytes32(pay), PREF), hex"01");

        vm.prank(alice);
        nft.registerSubpageFor("pay", shop, carol);
        assertEq(nft.data(bytes32(pay), PREF).length, 0, "a new mint empties it");

        vm.prank(carol);
        nft.setData(pay, PREF, hex"02");
        _lapseAndRegister(shop, stranger);
        assertEq(nft.data(bytes32(pay), PREF).length, 0, "Invalid once the parent is registered again");
    }

    // only the subpage's holder writes; sent to the dead address it is deleted, and minted again for the same
    // account it starts empty
    function test_subpageWritersAndADeadHeldSubpage() public {
        uint256 shop = _reg(alice, "shop");
        vm.prank(alice);
        uint256 pay = nft.registerSubpageFor("pay", shop, bob);
        _setMinter(shop, carol);
        vm.prank(bob);
        nft.setData(pay, PREF, hex"01");
        vm.prank(alice);
        vm.expectRevert(PageNFT.Unauthorized.selector);
        nft.setData(pay, PREF, hex"ff");
        vm.prank(carol);
        vm.expectRevert(PageNFT.Unauthorized.selector);
        nft.setData(pay, PREF, hex"ff");

        vm.prank(bob);
        nft.transferFrom(bob, DEAD, pay);
        assertEq(nft.data(bytes32(pay), PREF).length, 0, "deleted");
        vm.prank(DEAD);
        vm.expectRevert(PageNFT.Expired.selector);
        nft.setData(pay, PREF, hex"02");

        vm.prank(carol);
        nft.registerSubpageFor("pay", shop, bob);
        assertEq(nft.ownerOf(pay), bob);
        assertEq(nft.data(bytes32(pay), PREF).length, 0, "minted again for the same account, it starts empty");
    }

    // a top level page held by the dead address answers nothing, stays so when anyone renews it, and is empty when
    // registered again, also by the account that held it
    function test_aPageHeldByTheDeadAddress() public {
        uint256 id = _reg(alice, "alice");
        vm.prank(alice);
        nft.setData(id, PREF, hex"01");
        vm.prank(alice);
        nft.transferFrom(alice, DEAD, id);
        assertEq(nft.data(bytes32(id), PREF).length, 0, "deleted");
        vm.prank(DEAD);
        vm.expectRevert(PageNFT.Expired.selector);
        nft.setData(id, PREF, hex"02");

        vm.prank(stranger);
        nft.renew{value: nft.getFee(5)}(id);
        assertEq(nft.data(bytes32(id), PREF).length, 0, "still deleted after a renewal");

        _lapseAndRegister(id, alice);
        assertEq(nft.data(bytes32(id), PREF).length, 0, "registered again by the same account, it starts empty");
    }

    function test_aTrialPage() public {
        uint256 id = _trialFor(alice, "trialpage");
        vm.prank(alice);
        nft.setData(id, PREF, hex"01");
        assertEq(nft.data(bytes32(id), PREF), hex"01", "a trial's holder saves and reads");
        vm.warp(nft.expiresAt(id) + 1);
        assertEq(nft.data(bytes32(id), PREF).length, 0, "empty once the trial ends");
        vm.prank(alice);
        vm.expectRevert(PageNFT.Expired.selector);
        nft.setData(id, PREF, hex"02");
    }

    // in the grace period nothing reads; a renewal by anyone brings the records back, as it brings back the
    // addresses, for the page and for its subpages
    function test_graceAndARenewalByAnyone() public {
        uint256 id = _reg(alice, "alice");
        vm.prank(alice);
        uint256 pay = nft.registerSubpageFor("pay", id, bob);
        vm.prank(alice);
        nft.setData(id, PREF, hex"01");
        vm.prank(alice);
        nft.setAddrForCoin(id, 0, hex"0011");
        vm.prank(bob);
        nft.setData(pay, PREF, hex"02");

        vm.warp(nft.expiresAt(id) + 1);
        assertTrue(nft.inGracePeriod(id));
        assertEq(nft.data(bytes32(id), PREF).length, 0, "empty in the grace period");
        assertEq(nft.data(bytes32(pay), PREF).length, 0, "the subpage too");
        vm.prank(bob);
        vm.expectRevert(PageNFT.Expired.selector);
        nft.setData(pay, PREF, hex"03");

        vm.prank(stranger);
        nft.renew{value: nft.getFee(5)}(id);
        assertEq(nft.data(bytes32(id), PREF), hex"01", "back after the renewal");
        assertEq(nft.addr(id, 0), hex"0011", "as the address");
        assertEq(nft.data(bytes32(pay), PREF), hex"02", "the subpage's too");
    }

    // the receiver of a mint holds the page inside its callback, and its record is its own
    function test_aReceiverSavesInsideTheMintCallback() public {
        uint256 shop = _reg(alice, "shop");
        DataWritingReceiver r = new DataWritingReceiver();
        vm.prank(alice);
        uint256 pay = nft.registerSubpageFor("pay", shop, address(r));
        assertEq(nft.data(bytes32(pay), "from-callback"), hex"c0ffee");
    }

    function test_throughMulticall() public {
        uint256 id = _reg(alice, "alice");
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(PageNFT.setData, (id, PREF, hex"01"));
        calls[1] = abi.encodeCall(PageNFT.setData, (id, LIST, hex"02"));
        vm.prank(alice);
        nft.multicall(calls);
        assertEq(nft.data(bytes32(id), PREF), hex"01");
        assertEq(nft.data(bytes32(id), LIST), hex"02");
    }

    // a model of the rule: a record counts while its saver holds the page in the current record version. The same
    // steps save a chain entry outside the EVM, which must answer the same, and raw storage must agree.
    function testFuzz_followsTheRuleOfAddresses(uint256 seed) public {
        StorageReader sr = new StorageReader(address(nft));
        uint256 id = _reg(alice, "model");
        address[3] memory who = [alice, bob, carol];
        string[3] memory keys = ["a", "b", ""];
        address[3] memory saver;
        bytes[3] memory val;
        for (uint256 step; step < 40; ++step) {
            seed = uint256(keccak256(abi.encode(seed, step)));
            address h = nft.ownerOf(id);
            uint256 op = seed % 6;
            uint256 k = (seed >> 8) % 3;
            if (op <= 1) {
                bytes memory v = (seed >> 16) % 4 == 0 ? bytes("") : abi.encodePacked(uint64(seed >> 32));
                vm.startPrank(h);
                nft.setData(id, keys[k], v);
                nft.setAddrForCoin(id, 1000 + k, v);
                vm.stopPrank();
                saver[k] = h;
                val[k] = v;
            } else if (op <= 3) {
                address to = who[(seed >> 24) % 3];
                vm.prank(h);
                nft.transferFrom(h, to, id);
            } else if (op == 4) {
                vm.prank(h);
                nft.clearRecords(id);
                for (uint256 j; j < 3; ++j) {
                    saver[j] = address(0);
                    val[j] = "";
                }
            } else if (nft.profileWriter(id) != h) {
                vm.prank(h);
                nft.keepProfile(id);
            }
            address o = nft.ownerOf(id);
            for (uint256 j; j < 3; ++j) {
                bytes memory want = saver[j] == o ? val[j] : bytes("");
                assertEq(nft.data(bytes32(id), keys[j]), want, "the model");
                assertEq(nft.addr(id, 1000 + j), want, "the same as a chain entry");
                assertEq(sr.data(id, keys[j]), want, "raw storage");
            }
        }
        address last = nft.ownerOf(id);
        vm.prank(last);
        nft.transferFrom(last, DEAD, id);
        for (uint256 j; j < 3; ++j) assertEq(nft.data(bytes32(id), keys[j]).length, 0, "held by the dead address");
    }

    // saves one record and checks its one event: the key and the value hashed in the topics, the key in the data
    function _saveOne(uint256 id, string memory key, bytes memory value) internal {
        vm.recordLogs();
        vm.prank(nft.ownerOf(id));
        nft.setData(id, key, value);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "exactly one event");
        assertEq(logs[0].emitter, address(nft));
        assertEq(logs[0].topics.length, 4);
        assertEq(logs[0].topics[0], T_DATA);
        assertEq(logs[0].topics[1], bytes32(id));
        assertEq(logs[0].topics[2], keccak256(bytes(key)), "the key hashed");
        assertEq(logs[0].topics[3], keccak256(value), "the value hashed");
        assertEq(logs[0].data, abi.encode(key), "only the key in the data");
    }

    function test_eventEdgeCases() public {
        StorageReader sr = new StorageReader(address(nft));
        uint256 id = _reg(alice, "alice");
        _saveOne(id, "", hex"01");
        assertEq(nft.data(bytes32(id), ""), hex"01", "an empty key is a key");
        _saveOne(id, PREF, "");
        assertEq(nft.data(bytes32(id), PREF).length, 0, "an empty value");

        bytes memory longKey = new bytes(1000);
        bytes memory longValue = new bytes(5000);
        for (uint256 i; i < longKey.length; ++i) longKey[i] = bytes1(uint8(i * 7 + 1));
        for (uint256 i; i < longValue.length; ++i) longValue[i] = bytes1(uint8(i * 13 + 5));
        _saveOne(id, string(longKey), longValue);
        assertEq(nft.data(bytes32(id), string(longKey)), longValue);
        assertEq(sr.data(id, string(longKey)), longValue, "raw storage, a long key and value");
    }

    // keys are raw bytes: no lowercasing and no trimming, and a trailing zero byte makes another key
    function test_keysAreRawBytes() public {
        uint256 id = _reg(alice, "alice");
        vm.startPrank(alice);
        nft.setData(id, "key", hex"01");
        nft.setData(id, "Key", hex"02");
        nft.setData(id, "key\x00", hex"03");
        vm.stopPrank();
        assertEq(nft.data(bytes32(id), "key"), hex"01");
        assertEq(nft.data(bytes32(id), "Key"), hex"02");
        assertEq(nft.data(bytes32(id), "key\x00"), hex"03");
    }

    // a text record and a data record with the same key never meet, and clearRecords empties both
    function test_textAndDataAreSeparate() public {
        uint256 id = _reg(alice, "alice");
        vm.startPrank(alice);
        nft.setText(id, "k", "text");
        nft.setData(id, "k", "data");
        assertEq(nft.text(id, "k"), "text");
        assertEq(nft.data(bytes32(id), "k"), bytes("data"));
        nft.setText(id, "k", "");
        assertEq(nft.data(bytes32(id), "k"), bytes("data"), "a text write leaves data");
        nft.setText(id, "k", "t2");
        nft.setData(id, "k", "");
        assertEq(nft.text(id, "k"), "t2", "a data write leaves text");
        nft.setData(id, "k", "d2");
        nft.clearRecords(id);
        vm.stopPrank();
        assertEq(nft.text(id, "k"), "");
        assertEq(nft.data(bytes32(id), "k").length, 0);
    }

    // setData moves neither the profile writer nor addressesUpdatedAt, and leaves the profile as it was
    function test_leavesTheProfileAndTheAddressTimeAlone() public {
        uint256 id = _reg(alice, "shop");
        vm.prank(alice);
        nft.setText(id, "avatar", "alice's avatar");
        vm.prank(alice);
        nft.setAddr(id, hot);
        uint256 t = vm.getBlockTimestamp();
        vm.prank(alice);
        nft.transferFrom(alice, bob, id);
        assertEq(nft.profileWriter(id), alice);

        vm.warp(t + 100);
        vm.prank(bob);
        nft.setData(id, PREF, hex"01");
        assertEq(nft.profileWriter(id), alice, "the writer stays");
        assertEq(nft.addressesUpdatedAt(id), t, "the address time stays");

        vm.prank(bob);
        nft.keepProfile(id);
        assertEq(nft.text(id, "avatar"), "alice's avatar", "the profile can still be kept");
    }

    // profileWriter keeps its meaning: the account that last wrote or kept the profile, also across a new registration
    function test_profileWriterMeaning() public {
        uint256 id = _reg(alice, "shop");
        assertEq(nft.profileWriter(id), address(0), "zero before any write");
        vm.prank(alice);
        nft.transferFrom(alice, carol, id);
        assertEq(nft.profileWriter(id), address(0), "still zero after a move when nobody wrote");
        vm.prank(carol);
        nft.transferFrom(carol, alice, id);
        vm.prank(alice);
        nft.setText(id, "url", "x");
        assertEq(nft.profileWriter(id), alice, "the writer");
        vm.prank(alice);
        nft.transferFrom(alice, bob, id);
        assertEq(nft.profileWriter(id), alice, "a transfer does not change it");
        vm.prank(bob);
        nft.keepProfile(id);
        assertEq(nft.profileWriter(id), bob, "keepProfile");
        _lapseAndRegister(id, carol);
        assertEq(nft.profileWriter(id), bob, "a new registration does not reset it");
    }
}

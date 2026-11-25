// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Vm} from "forge-std/Test.sol";
import {PageNFT} from "../../../src/PageNFT.sol";
import {MinterBase} from "../../utils/MinterBase.sol";
import {LogShapes} from "../../utils/LogShapes.sol";

// What the two address setters store and answer: entries outside the EVM of any length, the order of their
// errors, the OP save against setAddr, the PageNFT address on other coin types, every other main address, the
// saves after a clear, a round trip with a save by the buyer, and the code shapes that pass as a key wallet at a
// mint, which no answer depends on.
contract ChainSavesTest is MinterBase {
    uint256 constant BASE = 0x80002105;
    uint256 constant BTC = 0;
    uint256 constant DEFAULT_EVM = 0x80000000;

    uint256 club;

    function setUp() public override {
        super.setUp();
        club = _reg(alice, "club");
    }

    function _bytesOf(uint256 n, uint256 salt) internal pure returns (bytes memory b) {
        b = new bytes(n);
        bytes32 w;
        for (uint256 i; i < n; ++i) {
            if (i % 32 == 0) w = keccak256(abi.encode(salt, n, i));
            b[i] = w[i % 32];
        }
    }

    function _move(address from, address to, uint256 id) internal {
        vm.prank(from);
        nft.transferFrom(from, to, id);
    }

    // a chain outside the EVM keeps any bytes as given, from 0 to 1024 of them, while their saver holds the name
    function test_nonEvmEntriesTakeAnyBytes() public {
        uint256 id = club;
        for (uint256 n; n <= 1024; ++n) {
            vm.prank(alice);
            nft.setAddrForCoin(id, 1000 + n, _bytesOf(n, 1));
            assertEq(nft.addr(id, 1000 + n), _bytesOf(n, 1), string.concat("length ", vm.toString(n)));
        }
        // with no counting entry a chain outside the EVM answers empty, the coin types next to the range included
        uint256[5] memory none = [uint256(2), 501, 1000 + 1025, 0x7fffffff, 0x100000000];
        for (uint256 i; i < none.length; ++i) assertEq(nft.addr(id, none[i]), "", "nothing saved, no default");
        assertEq(nft.addr(id, 0x80000001), "", "nor the first EVM coin type, with no default saved");
        // a saved default reaches the first EVM coin type, but never the coin types next to the range
        vm.prank(alice);
        nft.setAddrForCoin(id, DEFAULT_EVM, abi.encodePacked(alice));
        assertEq(nft.addr(id, 0x80000001), abi.encodePacked(alice), "the first EVM coin type takes the default");
        for (uint256 i; i < none.length; ++i) assertEq(nft.addr(id, none[i]), "", "outside the EVM, no default");
        vm.startPrank(alice);
        nft.setAddrForCoin(id, 0x7fffffff, _bytesOf(21, 2));
        nft.setAddrForCoin(id, 0x100000000, _bytesOf(3, 3));
        vm.stopPrank();
        assertEq(nft.addr(id, 0x7fffffff), _bytesOf(21, 2));
        assertEq(nft.addr(id, 0x100000000), _bytesOf(3, 3));
        // the entries stop counting when the name leaves their saver and count again when it returns
        _move(alice, bob, id);
        for (uint256 n; n <= 1024; n += 1) assertEq(nft.addr(id, 1000 + n), "", "not the saver");
        _move(bob, alice, id);
        for (uint256 n; n <= 1024; n += 1) assertEq(nft.addr(id, 1000 + n), _bytesOf(n, 1), "the saver again");
    }

    // the buyer saves one chain and sends the name back: that chain answers nothing for the seller, since the entry's
    // saver is the buyer and the seller saved no default, while the seller's main address and every other entry
    // count again
    function test_roundTripAfterTheBuyerSavedOneChain() public {
        uint256 id = club;
        address m = makeAddr("sellerMain");
        address x = makeAddr("sellerEthereum");
        address xb = makeAddr("sellerBase");
        vm.startPrank(alice);
        nft.setAddr(id, m);
        nft.setAddrForCoin(id, 60, abi.encodePacked(x));
        nft.setAddrForCoin(id, BASE, abi.encodePacked(xb));
        nft.setAddrForCoin(id, BTC, hex"0014aa");
        vm.stopPrank();

        // an EVM chain
        _move(alice, bob, id);
        vm.prank(bob);
        nft.setAddrForCoin(id, BASE, abi.encodePacked(carol));
        assertEq(nft.addr(id, BASE), abi.encodePacked(carol), "the buyer's save counts at once");
        _move(bob, alice, id);
        assertEq(nft.resolve(id), m, "the seller's main address");
        assertEq(nft.addr(id, 60), abi.encodePacked(x), "the seller's Ethereum entry");
        assertEq(nft.addr(id, BTC), hex"0014aa", "the seller's Bitcoin entry");
        assertEq(nft.addr(id, BASE), "", "Base answers nothing for the seller, who saved no default");

        // a chain outside the EVM, which has no default
        _move(alice, bob, id);
        vm.prank(bob);
        nft.setAddrForCoin(id, BTC, hex"0014bb");
        assertEq(nft.addr(id, BTC), hex"0014bb");
        _move(bob, alice, id);
        assertEq(nft.addr(id, BTC), "", "the entry is the buyer's, so it answers nothing for the seller");
        assertEq(nft.resolve(id), m);
        assertEq(nft.addr(id, 60), abi.encodePacked(x));
        assertEq(nft.addr(id, BASE), "");
    }

    // after clearRecords every writer saves again and each new save counts, also after a round trip
    function test_savesWorkAgainAfterAClear() public {
        uint256 id = club;
        vm.startPrank(alice);
        nft.setAddr(id, dave);
        nft.setAddrForCoin(id, 60, abi.encodePacked(dave));
        nft.setAddrForCoin(id, BASE, abi.encodePacked(dave));
        nft.setAddrForCoin(id, BTC, hex"0014aa");
        nft.setText(id, "url", "https://old.example");
        nft.setContenthash(id, hex"e30101");
        nft.clearRecords(id);
        vm.stopPrank();
        assertEq(nft.resolve(id), alice);
        assertEq(nft.addr(id, BASE), "", "nothing saved, so Base answers nothing");
        assertEq(nft.addr(id, BTC), "");
        assertEq(nft.text(id, "url"), "");

        address m = makeAddr("newMain");
        address x = makeAddr("newEthereum");
        address xb = makeAddr("newBase");
        vm.startPrank(alice);
        nft.setAddr(id, m);
        assertEq(nft.resolve(id), m, "setAddr");
        nft.setAddrForCoin(id, 60, abi.encodePacked(x));
        assertEq(nft.addr(id, 60), abi.encodePacked(x), "Ethereum");
        nft.setAddrForCoin(id, BASE, abi.encodePacked(xb));
        assertEq(nft.addr(id, BASE), abi.encodePacked(xb), "Base");
        nft.setAddrForCoin(id, BTC, hex"0014cc");
        assertEq(nft.addr(id, BTC), hex"0014cc", "Bitcoin");
        nft.setText(id, "url", "https://new.example");
        assertEq(nft.text(id, "url"), "https://new.example", "text");
        nft.setContenthash(id, hex"e30102");
        assertEq(nft.contenthash(id), hex"e30102", "contenthash");
        nft.setAddrForCoin(id, COIN_OP, abi.encodePacked(dave));
        assertEq(nft.resolve(id), dave, "the OP save");
        vm.stopPrank();
        _move(alice, bob, id);
        _move(bob, alice, id);
        assertEq(nft.resolve(id), dave);
        assertEq(nft.addr(id, 60), abi.encodePacked(x));
        assertEq(nft.addr(id, BASE), abi.encodePacked(xb));
        assertEq(nft.addr(id, BTC), hex"0014cc");
    }

    // every check of setAddrForCoin fails in turn with every later check failing too
    function test_setAddrForCoinErrorOrder() public {
        uint256 id = club;
        address appr = makeAddr("approved");
        address op = makeAddr("operator");
        vm.startPrank(alice);
        nft.approve(appr, id);
        nft.setApprovalForAll(op, true);
        vm.stopPrank();
        bytes memory reg20 = abi.encodePacked(address(nft));
        bytes memory reg19 = new bytes(19);
        for (uint256 i; i < 19; ++i) reg19[i] = reg20[i];
        bytes memory reg21 = abi.encodePacked(address(nft), hex"00");
        bytes memory reg32 = abi.encodePacked(address(nft), bytes12(0));

        // not the holder: Unauthorized before the coin type, the length and the PageNFT address
        address[3] memory others = [stranger, appr, op];
        for (uint256 i; i < 3; ++i) {
            vm.startPrank(others[i]);
            vm.expectRevert(PageNFT.Unauthorized.selector);
            nft.setAddrForCoin(id, DEFAULT_EVM, reg21);
            vm.expectRevert(PageNFT.Unauthorized.selector);
            nft.setAddrForCoin(id, 60, reg19);
            vm.expectRevert(PageNFT.Unauthorized.selector);
            nft.setAddrForCoin(id, COIN_OP, reg20);
            vm.expectRevert(PageNFT.Unauthorized.selector);
            nft.setAddr(id, address(nft));
            vm.expectRevert(PageNFT.Unauthorized.selector);
            nft.clearRecords(id);
            vm.stopPrank();
        }

        // the holder: the length before the PageNFT address, the default EVM coin type like any EVM chain
        vm.startPrank(alice);
        bytes[3] memory bad = [reg19, reg21, reg32];
        for (uint256 i; i < 3; ++i) {
            vm.expectRevert(PageNFT.InvalidLength.selector);
            nft.setAddrForCoin(id, DEFAULT_EVM, bad[i]);
            vm.expectRevert(PageNFT.InvalidLength.selector);
            nft.setAddrForCoin(id, 60, bad[i]);
            vm.expectRevert(PageNFT.InvalidLength.selector);
            nft.setAddrForCoin(id, BASE, bad[i]);
            vm.expectRevert(PageNFT.InvalidLength.selector);
            nft.setAddrForCoin(id, COIN_OP, bad[i]);
        }
        vm.expectRevert(PageNFT.InvalidRecipient.selector);
        nft.setAddrForCoin(id, COIN_OP, reg20);
        vm.expectRevert(PageNFT.InvalidRecipient.selector);
        nft.setAddr(id, address(nft));
        // the Ethereum entry and the default take the same 20 bytes
        nft.setAddrForCoin(id, 60, reg20);
        nft.setAddrForCoin(id, DEFAULT_EVM, reg20);
        vm.stopPrank();
        assertEq(nft.addr(id, 60), reg20);
        assertEq(nft.addr(id, DEFAULT_EVM), reg20);
        assertEq(nft.addr(id, BASE), reg20, "a chain with no entry of its own answers the default");
        assertEq(nft.resolve(id), alice, "the main address does not move");

        // an inactive name: Expired before everything, for the holder and for anyone else
        vm.warp(nft.expiresAt(id) + 1);
        address[2] memory who = [alice, stranger];
        for (uint256 i; i < 2; ++i) {
            vm.startPrank(who[i]);
            vm.expectRevert(PageNFT.Expired.selector);
            nft.setAddrForCoin(id, DEFAULT_EVM, reg21);
            vm.expectRevert(PageNFT.Expired.selector);
            nft.setAddrForCoin(id, 60, reg21);
            vm.expectRevert(PageNFT.Expired.selector);
            nft.setAddrForCoin(id, COIN_OP, reg20);
            vm.expectRevert(PageNFT.Expired.selector);
            nft.setAddr(id, address(nft));
            vm.expectRevert(PageNFT.Expired.selector);
            nft.clearRecords(id);
            vm.stopPrank();
        }
        // an id with no record at all
        uint256 ghost = _id("neverregistered");
        vm.startPrank(alice);
        vm.expectRevert(PageNFT.Expired.selector);
        nft.setAddrForCoin(ghost, DEFAULT_EVM, reg21);
        vm.expectRevert(PageNFT.Expired.selector);
        nft.setAddr(ghost, address(nft));
        vm.expectRevert(PageNFT.Expired.selector);
        nft.clearRecords(ghost);
        vm.stopPrank();
    }

    function _savesAndClears(address x) internal {
        uint256 id = club;
        address want = x == address(0) ? alice : x;
        vm.prank(alice);
        nft.setAddr(id, x);
        assertEq(nft.resolve(id), want, "setAddr");
        assertEq(nft.addr(bytes32(id)), address(0), "addr(node) is coin type 60, which the main address never reaches");
        assertEq(nft.addr(id, COIN_OP), abi.encodePacked(want), "the OP answer");
        assertEq(nft.payee(id), want, "payee");
        vm.prank(alice);
        nft.setAddr(id, address(0));
        assertEq(nft.resolve(id), alice, "zero points the name back at the holder");
        vm.prank(alice);
        nft.setAddrForCoin(id, COIN_OP, abi.encodePacked(x));
        assertEq(nft.resolve(id), want, "the OP save");
        assertEq(nft.payee(id), want);
        vm.prank(alice);
        nft.setAddrForCoin(id, COIN_OP, "");
        assertEq(nft.resolve(id), alice, "empty OP bytes clear");
        vm.prank(alice);
        nft.setAddrForCoin(id, COIN_OP, abi.encodePacked(x));
        vm.prank(alice);
        nft.setAddrForCoin(id, COIN_OP, new bytes(20));
        assertEq(nft.resolve(id), alice, "twenty zero OP bytes clear");
    }

    // every main address but PageNFT is saved through both setters and counts, DEAD and the registrar included
    function testFuzz_everyOtherMainAddressIsSaved(address x) public {
        vm.assume(x != address(nft));
        _savesAndClears(x);
        address[6] memory named = [DEAD, address(reg), address(card), address(1), address(0x0a), address(this)];
        for (uint256 i; i < named.length; ++i) _savesAndClears(named[i]);
    }

    // a hash of the logs, the written slots with their values, and nine address answers after one call by alice
    function _effect(bytes memory data) internal returns (bytes32) {
        vm.record();
        vm.recordLogs();
        vm.prank(alice);
        (bool ok,) = address(nft).call(data);
        assertTrue(ok, "the save went through");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (, bytes32[] memory writes) = vm.accesses(address(nft));
        bytes32[] memory values = new bytes32[](writes.length);
        for (uint256 i; i < writes.length; ++i) values[i] = vm.load(address(nft), writes[i]);
        bytes32[] memory logHashes = new bytes32[](logs.length);
        for (uint256 i; i < logs.length; ++i) {
            assertEq(logs[i].emitter, address(nft));
            logHashes[i] = LogShapes.hashOf(logs[i]);
        }
        uint256 id = club;
        bytes memory answers = abi.encode(
            nft.resolve(id), nft.payee(id), nft.addr(bytes32(id)), nft.addr(id, COIN_OP), nft.addr(id, 60),
            nft.addr(id, BASE), nft.addr(id, DEFAULT_EVM), nft.resolveAs(id, alice), nft.resolveAs(id, bob)
        );
        assertGt(writes.length, 0, "the save wrote storage");
        return keccak256(abi.encode(logHashes, writes, values, answers));
    }

    // the OP coin type of setAddrForCoin is setAddr: the same storage, the same answers and the same logs
    function testFuzz_opSaveIsSetAddr(address x, bool withEthereum) public {
        vm.assume(x != address(nft));
        uint256 id = club;
        if (withEthereum) {
            vm.prank(alice);
            nft.setAddrForCoin(id, 60, abi.encodePacked(dave));
        }
        uint256 snap = vm.snapshotState();
        bytes32 a = _effect(abi.encodeCall(PageNFT.setAddr, (id, x)));
        vm.revertToState(snap);
        bytes32 b = _effect(abi.encodeCall(PageNFT.setAddrForCoin, (id, COIN_OP, abi.encodePacked(x))));
        assertEq(a, b, "setAddrForCoin for OP and setAddr have the same effect");
        // no entry is kept for the OP coin type
        uint256 v = nft.recordVersion(id);
        bytes32 entry = keccak256(abi.encode(COIN_OP, keccak256(abi.encode(v, keccak256(abi.encode(id, uint256(9)))))));
        assertEq(vm.load(address(nft), entry), bytes32(0), "no saver for OP");
        assertEq(vm.load(address(nft), bytes32(uint256(entry) + 1)), bytes32(0), "no value for OP");

        // empty bytes and twenty zero bytes are setAddr with zero
        vm.revertToState(snap);
        bytes32 z = _effect(abi.encodeCall(PageNFT.setAddr, (id, address(0))));
        vm.revertToState(snap);
        assertEq(_effect(abi.encodeCall(PageNFT.setAddrForCoin, (id, COIN_OP, bytes("")))), z, "empty OP bytes");
        assertEq(nft.resolve(id), alice);
        vm.revertToState(snap);
        assertEq(_effect(abi.encodeCall(PageNFT.setAddrForCoin, (id, COIN_OP, new bytes(20)))), z, "twenty zero OP bytes");

        // both refuse PageNFT itself
        vm.startPrank(alice);
        vm.expectRevert(PageNFT.InvalidRecipient.selector);
        nft.setAddr(id, address(nft));
        vm.expectRevert(PageNFT.InvalidRecipient.selector);
        nft.setAddrForCoin(id, COIN_OP, abi.encodePacked(address(nft)));
        vm.stopPrank();
    }

    // every settable coin type other than OP takes the PageNFT address as given, and the main address does not move;
    // coin type 60 also logs AddrChanged with it
    function testFuzz_otherCoinsTakeTheRegistryBytes(uint256 seed) public {
        uint256 id = club;
        bytes memory v = abi.encodePacked(address(nft));
        uint256 evm = 0x80000001 + seed % 0x7fffffff;
        if (evm == COIN_OP) evm = 60;
        uint256 other = seed % 2 == 0 ? (seed >> 8) % 0x80000000 : 0x100000000 + (seed >> 8) % (1 << 64);
        if (other == 60) other = 61;
        uint256[3] memory coins = [uint256(60), evm, other];
        address mainBefore = nft.resolve(id);
        address payeeBefore = nft.payee(id);
        for (uint256 i; i < 3; ++i) {
            vm.recordLogs();
            vm.prank(alice);
            nft.setAddrForCoin(id, coins[i], v);
            Vm.Log[] memory logs = vm.getRecordedLogs();
            assertEq(logs.length, coins[i] == 60 ? 2 : 1, "one event, and AddrChanged after it for coin type 60");
            assertEq(LogShapes.hashOf(logs[0]), LogShapes.coin(id, coins[i], v), "AddressChanged with the PageNFT address");
            if (coins[i] == 60) {
                assertEq(LogShapes.hashOf(logs[1]), LogShapes.addrChanged(id, address(nft)), "AddrChanged with it too");
                assertEq(nft.addr(bytes32(id)), address(nft), "addr(node) answers it");
            }
            assertEq(nft.addr(id, coins[i]), v, "stored and answered as given");
            assertEq(nft.resolve(id), mainBefore, "the main address does not move");
            assertEq(nft.payee(id), payeeBefore, "nor the payee");
            assertEq(nft.addr(id, COIN_OP), abi.encodePacked(mainBefore), "nor the OP answer");
        }
        // a chain outside the EVM keeps the PageNFT address followed by 12 zero bytes, and its first 19 bytes alone
        bytes memory longer = abi.encodePacked(address(nft), bytes12(0));
        bytes memory shorter = new bytes(19);
        for (uint256 i; i < 19; ++i) shorter[i] = v[i];
        vm.startPrank(alice);
        nft.setAddrForCoin(id, other, longer);
        assertEq(nft.addr(id, other), longer);
        nft.setAddrForCoin(id, other, shorter);
        assertEq(nft.addr(id, other), shorter);
        vm.stopPrank();
    }

    // whatever the code of the main address, no EVM chain but the home chain answers it without a save, and a saved
    // default answers exactly that; the code decides only whether a mint skips the receiver hook, which it does
    // exactly when the code is empty or the 23 byte EIP7702 delegation that starts with 0xef0100; no other code that
    // starts with 0xef can exist on chain (EIP3541)
    function testFuzz_onlyTheDesignatorPrefixPasses(uint8 lenSeed, bytes32 a, bytes32 b, uint8 mode, address to)
        public
    {
        uint256 len = mode % 4 == 1 ? 23 : uint256(lenSeed) % 65;
        bytes memory code = new bytes(len);
        for (uint256 i; i < len; ++i) code[i] = i < 32 ? a[i] : b[i - 32];
        if (mode % 4 == 1) {
            if (to.code.length != 0) to = address(0xBEEF);
            code = abi.encodePacked(hex"ef0100", to);
        } else if (mode % 4 == 2 && len >= 4) {
            // the prefix one byte in
            code[1] = 0xef;
            code[2] = 0x01;
            code[3] = 0x00;
        }
        bool designator = len == 23 && code[0] == 0xef && code[1] == 0x01 && code[2] == 0x00;
        if (len != 0 && code[0] == 0xef && !designator) code[0] = 0xfe;
        bool keyWallet = len == 0 || designator;

        address m = makeAddr("mainWithCode");
        vm.etch(m, code);
        vm.prank(alice);
        nft.setAddr(club, m);
        assertEq(nft.addr(club, 60), "", "coin type 60, nothing saved");
        assertEq(nft.addr(club, BASE), "", "another EVM chain, nothing saved");
        assertEq(nft.addr(club, DEFAULT_EVM), "", "the default EVM coin type, nothing saved");
        assertEq(nft.addr(club, COIN_OP), abi.encodePacked(m), "the OP answer is the main address whatever its code");
        // a saved default answers exactly that, whatever the code
        vm.prank(alice);
        nft.setAddrForCoin(club, DEFAULT_EVM, abi.encodePacked(m));
        assertEq(nft.addr(club, 60), abi.encodePacked(m), "coin type 60, the default saved");
        assertEq(nft.addr(club, BASE), abi.encodePacked(m), "another EVM chain, the default saved");
        assertEq(nft.addr(club, DEFAULT_EVM), abi.encodePacked(m), "the default EVM coin type, saved");
        assertEq(nft.addr(club, COIN_OP), abi.encodePacked(m), "the home chain answer stays the main address");
        // a key wallet receives a mint without its code being called; any other code is asked, once, with the mint
        // arguments, and does not accept
        uint256 subId = nft.computeId("sub.club");
        bytes memory hook = abi.encodeWithSelector(bytes4(0x150b7a02), alice, address(0), subId, bytes(""));
        vm.prank(alice);
        if (keyWallet) {
            vm.expectCall(m, abi.encodeWithSelector(bytes4(0x150b7a02)), 0);
            uint256 sub = nft.registerSubpageFor("sub", club, m);
            assertEq(sub, subId);
            assertEq(nft.ownerOf(sub), m);
        } else {
            vm.expectCall(m, hook, 1);
            vm.expectRevert();
            nft.registerSubpageFor{gas: 5_000_000}("sub", club, m);
        }
    }
}

// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Vm} from "forge-std/Test.sol";
import {MinterBase} from "../../utils/MinterBase.sol";

// What an indexer that reads only the logs can rebuild around a delete. Three indexers replay the same
// logs. The plain one, like a resolver indexer, keeps the last address, text and contenthash events and empties
// the name's text, contenthash and BTC entry on VersionChanged, and it counts the BTC entry only while the account
// that held the name when it was saved still holds it. The ruled one also empties a name on a Transfer to DEAD.
// The profiled one is the plain one where text and contenthash count only while the writer named by the last
// ProfileWriterChanged holds the name, as known from Transfer, and a fresh writer starts empty.
contract IndexerGapsTest is MinterBase {
    bytes32 constant T_VERSION = keccak256("VersionChanged(bytes32,uint64)");
    bytes32 constant T_ADDRESS = keccak256("AddressChanged(bytes32,uint256,bytes)");
    bytes32 constant T_ADDR = keccak256("AddrChanged(bytes32,address)");
    bytes32 constant T_TEXT = keccak256("TextChanged(bytes32,string,string,string)");
    bytes32 constant T_CONTENT = keccak256("ContenthashChanged(bytes32,bytes)");
    bytes32 constant T_PWC = keccak256("ProfileWriterChanged(bytes32,address,bool)");
    uint256 constant COIN_BTC = 0;

    uint8 constant PLAIN = 0;
    uint8 constant RULED = 1;
    uint8 constant PROFILED = 2;

    struct Ix {
        bytes op;
        // the address of the last AddrChanged, which carries the coin type 60 answer
        address addr60;
        bytes e60;
        bytes btc;
        address btcSaver;
        string avatar;
        bytes ch;
        address owner;
        address writer;
    }

    mapping(uint8 => mapping(uint256 => Ix)) ix;
    uint256 club;

    function setUp() public override {
        super.setUp();
        club = _reg(alice, "club");
        vm.recordLogs();
    }

    function _wipeProfile(Ix storage x) internal {
        x.btc = "";
        x.avatar = "";
        x.ch = "";
    }

    function _replay() internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory l = logs[i];
            if (l.emitter != address(nft)) continue;
            bytes32 t = l.topics[0];
            for (uint8 k; k < 3; ++k) {
                if (t == T_TRANSFER) {
                    uint256 tid = uint256(l.topics[3]);
                    address to = address(uint160(uint256(l.topics[2])));
                    Ix storage y = ix[k][tid];
                    y.owner = to;
                    if (k == RULED && to == DEAD) {
                        y.op = "";
                        y.addr60 = address(0);
                        y.e60 = "";
                        _wipeProfile(y);
                    }
                    continue;
                }
                if (l.topics.length < 2) continue;
                Ix storage x = ix[k][uint256(l.topics[1])];
                if (t == T_ADDR) {
                    x.addr60 = abi.decode(l.data, (address));
                } else if (t == T_ADDRESS) {
                    (uint256 coin, bytes memory v) = abi.decode(l.data, (uint256, bytes));
                    if (coin == COIN_OP) x.op = v;
                    if (coin == 60) x.e60 = v;
                    if (coin == COIN_BTC) {
                        x.btc = v;
                        x.btcSaver = x.owner;
                    }
                } else if (t == T_TEXT) {
                    if (l.topics[2] == keccak256("avatar")) (, x.avatar) = abi.decode(l.data, (string, string));
                } else if (t == T_CONTENT) {
                    x.ch = abi.decode(l.data, (bytes));
                } else if (t == T_VERSION) {
                    _wipeProfile(x);
                } else if (t == T_PWC && k == PROFILED) {
                    (address w, bool fresh) = abi.decode(l.data, (address, bool));
                    x.writer = w;
                    if (fresh) {
                        x.avatar = "";
                        x.ch = "";
                    }
                }
            }
        }
    }

    // the answers an indexer gets wrong: 1 the main address, 2 Ethereum, in both of its forms, 4 a chain outside the
    // EVM, 8 text, 16 contenthash
    function _wrong(uint8 k, uint256 id) internal view returns (uint256 m) {
        Ix storage x = ix[k][id];
        if (keccak256(x.op) != keccak256(nft.addr(id, COIN_OP))) m |= 1;
        if (keccak256(x.e60) != keccak256(nft.addr(id, 60)) || x.addr60 != nft.addr(bytes32(id))) m |= 2;
        bytes memory btc = x.btcSaver == x.owner ? x.btc : bytes("");
        if (keccak256(btc) != keccak256(nft.addr(id, COIN_BTC))) m |= 4;
        bool counts = k != PROFILED || x.writer == x.owner;
        string memory avatar = counts ? x.avatar : "";
        bytes memory ch = counts ? x.ch : bytes("");
        if (keccak256(bytes(avatar)) != keccak256(bytes(nft.text(id, "avatar")))) m |= 8;
        if (keccak256(ch) != keccak256(nft.contenthash(id))) m |= 16;
    }

    function _assertMasks(uint256 id, uint256 plain, uint256 ruled, uint256 profiled, string memory when) internal {
        _replay();
        assertEq(_wrong(PLAIN, id), plain, string.concat("plain indexer ", when));
        assertEq(_wrong(RULED, id), ruled, string.concat("ruled indexer ", when));
        assertEq(_wrong(PROFILED, id), profiled, string.concat("profiled indexer ", when));
    }

    // bob.club with a profile and addresses, saved by bob
    function _bobWithProfile() internal returns (uint256 id) {
        vm.prank(alice);
        id = nft.registerSubpageFor("bob", club, bob);
        vm.startPrank(bob);
        nft.setText(id, "avatar", "ipfs://bob");
        nft.setContenthash(id, hex"e3010170");
        nft.setAddr(id, carol);
        nft.setAddrForCoin(id, 60, abi.encodePacked(carol));
        nft.setAddrForCoin(id, COIN_BTC, hex"0014deadbeef");
        vm.stopPrank();
    }

    // Addresses are rebuilt right from the logs at every step. Text and contenthash stop counting with no
    // event when a name moves, on a sale as on a delete, so the plain indexer is wrong after both, the ruled
    // one only fixes the delete, and only the profiled one is right at every step.
    function test_atk06_eventOnlyIndexer() public {
        uint256 id = _bobWithProfile();
        _assertMasks(id, 0, 0, 0, "live");

        vm.prank(bob);
        nft.transferFrom(bob, dave, id);
        _assertMasks(id, 8 | 16, 8 | 16, 0, "after a sale");
        assertEq(nft.text(id, "avatar"), "", "the seller's profile does not count for the buyer");

        vm.startPrank(dave);
        nft.setAddrForCoin(id, COIN_BTC, hex"0014beef");
        nft.setText(id, "avatar", "ipfs://dave");
        vm.stopPrank();
        _assertMasks(id, 16, 16, 0, "after the buyer starts a profile");

        vm.prank(dave);
        nft.transferFrom(dave, DEAD, id);
        _assertMasks(id, 8 | 16, 0, 0, "after the delete");
        assertEq(nft.text(id, "avatar"), "");
        assertEq(nft.resolve(id), address(0));

        vm.prank(alice);
        nft.registerSubpageFor("bob", club, carol);
        _assertMasks(id, 0, 0, 0, "after the name is created again");

        // a top level name sent to DEAD is deleted too: its addresses go out empty, and its profile stops counting
        // with no event
        uint256 top = _reg(bob, "gold");
        vm.prank(bob);
        nft.setText(top, "avatar", "gold");
        vm.prank(bob);
        nft.transferFrom(bob, DEAD, top);
        _assertMasks(top, 8, 0, 0, "top level name at DEAD");
        assertEq(nft.resolve(top), address(0));
        assertEq(nft.text(top, "avatar"), "");

        // a subpage minted straight to DEAD has nothing to clear
        vm.prank(alice);
        uint256 fresh = nft.registerSubpageFor("fresh", club, DEAD);
        _assertMasks(fresh, 0, 0, 0, "minted straight to DEAD");
    }

    // a direct delete logs no text or contenthash event, so an indexer of those events keeps the old profile
    // while the contract answers nothing; an indexer that follows the writer events is right
    function test_J_indexerGap_directDelete() public {
        uint256 id = _bobWithProfile();
        vm.prank(bob);
        nft.transferFrom(bob, DEAD, id);
        _replay();
        assertEq(nft.text(id, "avatar"), "");
        assertEq(nft.contenthash(id), "");
        assertEq(ix[PLAIN][id].avatar, "ipfs://bob", "the gap: the old text stays in the index");
        assertEq(ix[PLAIN][id].ch, hex"e3010170", "and the old contenthash");
        assertEq(_wrong(PROFILED, id), 0);
    }

    // clearing the records before the delete logs VersionChanged, so the plain indexer ends empty, and the transfer
    // itself clears the sender's display name
    function test_J_indexerGap_clearFirstCloses() public {
        uint256 id = _bobWithProfile();
        vm.prank(bob);
        nft.setPrimaryPage(id);
        vm.startPrank(bob);
        nft.clearRecords(id);
        nft.transferFrom(bob, DEAD, id);
        vm.stopPrank();
        _replay();
        assertEq(ix[PLAIN][id].avatar, "");
        assertEq(ix[PLAIN][id].ch, "");
        assertEq(_wrong(PLAIN, id), 0, "every answer of the plain indexer is right");
        assertEq(nft.text(id, "avatar"), "");
        assertEq(nft.primaryPage(bob), 0, "the delete cleared bob's display name");
    }
}

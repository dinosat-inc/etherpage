// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {MinterBase} from "../../utils/MinterBase.sol";
import {StorageReader} from "../../utils/NamingBase.sol";

// holderSince, addressesUpdatedAt and data records read the same from raw storage words, as a storage proof reader
// would read them, as from the views, through sales, a return, a page given to the dead address and clearRecords.
contract StorageProofReadsTest is MinterBase {
    StorageReader sr;
    bytes constant LONG =
        hex"000100000101148004a169fb4a3325136eb29fa0ceb6d2e539a432000100000101148004a169fb4a3325136eb29fa0ceb6d2e539a432";

    function setUp() public override {
        super.setUp();
        sr = new StorageReader(address(nft));
    }

    function _same(uint256 id, string memory where) internal view {
        assertEq(sr.holderSince(id), nft.holderSince(id), string.concat(where, ": holderSince"));
        assertEq(sr.addressesUpdatedAt(id), nft.addressesUpdatedAt(id), string.concat(where, ": addressesUpdatedAt"));
        assertEq(sr.data(id, "short"), nft.data(bytes32(id), "short"), string.concat(where, ": a short record"));
        assertEq(sr.data(id, "long"), nft.data(bytes32(id), "long"), string.concat(where, ": a long record"));
        assertEq(sr.resolve(id), nft.resolve(id), string.concat(where, ": resolve"));
    }

    function test_rawStorageMatchesTheViews() public {
        uint256 id = _reg(alice, "alice");
        _same(id, "registered");
        vm.warp(vm.getBlockTimestamp() + 10);
        vm.startPrank(alice);
        nft.setAddr(id, hot);
        nft.setData(id, "short", hex"0102");
        nft.setData(id, "long", LONG);
        vm.stopPrank();
        assertEq(sr.data(id, "long"), LONG, "a value longer than one word");
        _same(id, "saved");

        vm.warp(vm.getBlockTimestamp() + 10);
        vm.prank(alice);
        nft.transferFrom(alice, bob, id);
        _same(id, "sold");
        vm.prank(bob);
        nft.keepProfile(id);
        _same(id, "kept");

        vm.warp(vm.getBlockTimestamp() + 10);
        vm.prank(bob);
        nft.transferFrom(bob, alice, id);
        _same(id, "back to the first holder");

        vm.prank(alice);
        nft.clearRecords(id);
        _same(id, "cleared");

        vm.prank(alice);
        nft.setData(id, "short", hex"03");
        vm.prank(alice);
        nft.transferFrom(alice, DEAD, id);
        _same(id, "held by the dead address");
    }

    // a data record of any key and value sits at keccak(key . keccak(version . keccak(id . 18))): the saver alone in
    // the first word, the value after it
    function testFuzz_aDataRecordSitsWhereAStorageProofLooks(bytes calldata key, bytes calldata value, bool sell)
        public
    {
        vm.assume(key.length < 300 && value.length < 2000);
        uint256 id = _reg(alice, "alice");
        vm.prank(alice);
        nft.clearRecords(id);
        vm.prank(alice);
        nft.setData(id, string(key), value);
        assertEq(nft.data(bytes32(id), string(key)), value);
        bytes32 inner = keccak256(abi.encode(nft.recordVersion(id), keccak256(abi.encode(id, uint256(18)))));
        uint256 first = uint256(vm.load(address(nft), keccak256(abi.encodePacked(key, inner))));
        assertEq(address(uint160(first)), alice, "the saver in the first word");
        assertEq(first >> 160, 0, "nothing else in the first word");
        assertEq(sr.data(id, string(key)), value);
        if (sell) {
            vm.prank(alice);
            nft.transferFrom(alice, bob, id);
        }
        assertEq(sr.data(id, string(key)), nft.data(bytes32(id), string(key)));
    }
}

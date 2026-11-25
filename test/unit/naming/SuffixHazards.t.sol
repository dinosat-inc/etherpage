// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {PageNFT} from "../../../src/PageNFT.sol";
import {PageCard} from "../../../src/PageCard.sol";

// Checks of the suffix parsing hazard and of what a storage proof bridge can rebuild
contract SuffixHazardsTest is Test {
    PageNFT nft;
    address alice = makeAddr("alice");
    address carol = makeAddr("carol");
    address dave = makeAddr("dave");
    uint256 constant OP = 0x8000000a;
    uint256 constant DEFAULT_EVM = 0x80000000;
    bytes32 constant EMPTY_CODE = keccak256("");

    function setUp() public {
        vm.warp(1_800_000_000);
        nft = new PageNFT(new PageCard());
        vm.deal(alice, 10 ether);
        vm.deal(carol, 10 ether);
        vm.deal(dave, 10 ether);
    }

    function _reg(address who, string memory label) internal returns (uint256 id) {
        bytes32 secret = keccak256(abi.encode(who, label));
        bytes32 commitment = nft.makeCommitment(label, who, 0, secret);
        vm.prank(who);
        nft.commit(commitment);
        vm.warp(block.timestamp + 61);
        (,,, uint256 total) = _quote(label);
        vm.prank(who);
        id = nft.reveal{value: total}(label, who, 0, secret);
    }

    function _quote(string memory label) internal view returns (uint256, uint256, uint256, uint256) {
        return nft.quote(label);
    }

    // parsing hazard

    function test_hazardOneParent() public {
        uint256 real = _reg(alice, "alice");
        assertEq(nft.resolve(nft.computeId("alice.maple")), address(0), "nobody before");
        uint256 p = _reg(carol, "maple");
        vm.prank(carol);
        uint256 s = nft.registerSubpage("alice", p);
        uint256 looked = nft.computeId("Alice.Maple");
        assertEq(looked, s);
        assertTrue(looked != real);
        assertEq(nft.resolve(looked), carol);
        assertEq(nft.getPageName(s), "alice.maple");
        emit log_named_address("alice.maple pays", nft.resolve(looked));
    }

    function test_hazardTwoParents() public {
        _reg(alice, "alice");
        uint256 p1 = _reg(carol, "birch");
        uint256 p2 = _reg(carol, "cedar");
        vm.startPrank(carol);
        uint256 s1 = nft.registerSubpage("alice", p1);
        uint256 s2 = nft.registerSubpage("alice", p2);
        vm.stopPrank();
        assertEq(nft.computeId("alice.birch"), s1);
        assertEq(nft.computeId("alice.cedar"), s2);
        assertEq(nft.resolve(s1), carol);
        assertEq(nft.resolve(s2), carol);
    }

    function test_heldParentClosesIt() public {
        _reg(alice, "alice");
        _reg(dave, "maple");
        assertFalse(nft.isAvailable("maple", 0));
        uint256 pid = nft.computeId("maple");
        vm.prank(carol);
        vm.expectRevert(PageNFT.NotParentOwner.selector);
        nft.registerSubpage("alice", pid);
    }

    function test_twoDotsAndSuffixFormRevert() public {
        vm.expectRevert(PageNFT.InvalidLabel.selector);
        nft.computeId("alice.maple.oak");
        vm.expectRevert();
        nft.normalize("alice.maple");
    }

    // storage proof rebuild: what an Ethereum resolver can compute from proven OP slots

    function _map(uint256 key, uint256 slot) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(key, slot)));
    }

    function _load(uint256 slot) internal view returns (uint256) {
        return uint256(vm.load(address(nft), bytes32(slot)));
    }

    function _ownerRaw(uint256 id) internal view returns (address) {
        uint256 slot;
        unchecked {
            slot = uint256(keccak256(abi.encodePacked(bytes28(bytes32(id)), bytes4(0x7d882553)))) + id + id;
        }
        return address(uint160(_load(slot)));
    }

    function _activeRaw(uint256 id) internal view returns (bool) {
        uint256 base = _map(id, 0);
        if (_load(base) == 0) return false;
        uint256 parent = _load(base + 1);
        uint256 packed = _load(base + 2);
        if (parent == 0) return block.timestamp <= uint64(packed);
        uint256 pbase = _map(parent, 0);
        uint256 ppacked = _load(pbase + 2);
        if (uint64(packed >> 128) != uint64(ppacked >> 64)) return false;
        return block.timestamp <= uint64(ppacked);
    }

    // codeless means the account proof shows no account or the empty code hash
    function _codelessRaw(address a) internal view returns (bool) {
        return a.codehash == bytes32(0) || a.codehash == EMPTY_CODE;
    }

    function _mainRaw(uint256 id, address owner) internal view returns (address) {
        uint256 v = _load(_map(id, 1));
        address a = address(uint160(_load(_map(v, _map(id, 7)))));
        address saver = address(uint160(_load(_map(v, _map(id, 11)))));
        return (a != address(0) && saver == owner) ? a : owner;
    }

    function _coinRaw(uint256 id, uint256 coin, address owner) internal view returns (address a) {
        uint256 v = _load(_map(id, 1));
        uint256 cslot = _map(coin, _map(v, _map(id, 9)));
        address saver = address(uint160(_load(cslot)));
        if (saver == owner) {
            uint256 w = _load(cslot + 1);
            if (w & 1 == 0 && (w & 0xff) == 40) a = address(bytes20(bytes32(w)));
        }
    }

    // an EVM coin type: the home chain answers the main address; any other chain answers the holder's own entry,
    // else the holder's saved default, else nothing, so no account proof is needed
    function _addrRaw(uint256 id, uint256 coin) internal view returns (address) {
        if (!_activeRaw(id)) return address(0);
        address owner = _ownerRaw(id);
        address main = _mainRaw(id, owner);
        if (coin == OP) return main;
        address a = _coinRaw(id, coin, owner);
        if (a == address(0)) a = _coinRaw(id, DEFAULT_EVM, owner);
        return a;
    }

    function _decode(bytes memory b) internal pure returns (address) {
        return b.length == 0 ? address(0) : address(bytes20(b));
    }

    function _same(uint256 id, string memory why) internal view {
        assertEq(_addrRaw(id, OP), _decode(nft.addr(id, OP)), string.concat(why, " OP"));
        assertEq(_addrRaw(id, 60), _decode(nft.addr(id, 60)), string.concat(why, " 60"));
    }

    function test_rawRebuildMatches() public {
        uint256 id = _reg(alice, "alice");
        assertEq(_ownerRaw(id), alice, "owner slot formula");
        _same(id, "fresh");

        address hot = makeAddr("hot");
        vm.prank(alice);
        nft.setAddr(id, hot);
        _same(id, "saved");
        assertEq(_addrRaw(id, OP), hot);
        assertEq(_addrRaw(id, 60), address(0), "the main address does not answer coin 60");

        vm.prank(alice);
        nft.setAddrForCoin(id, DEFAULT_EVM, abi.encodePacked(hot));
        _same(id, "default saved");
        assertEq(_addrRaw(id, 60), hot, "the default answers coin 60");

        address ethOnly = makeAddr("ethOnly");
        vm.prank(alice);
        nft.setAddrForCoin(id, 60, abi.encodePacked(ethOnly));
        _same(id, "coin60 saved");
        assertEq(_addrRaw(id, 60), ethOnly, "an own entry wins over the default");

        vm.prank(alice);
        nft.transferFrom(alice, carol, id);
        _same(id, "after transfer, saver rule");
        assertEq(_addrRaw(id, OP), carol);
        assertEq(_addrRaw(id, 60), address(0), "the seller's entries stop counting");

        vm.prank(carol);
        nft.clearRecords(id);
        _same(id, "cleared");

        vm.prank(carol);
        uint256 sub = nft.registerSubpage("bob", id);
        _same(sub, "subpage");

        vm.warp(block.timestamp + 366 days);
        _same(id, "expired");
        _same(sub, "sub of expired");
    }

    function test_rawRebuildSafeOwner() public {
        address safe = makeAddr("safe");
        vm.etch(safe, hex"6080604052");
        uint256 id = _reg(alice, "alice");
        vm.prank(alice);
        nft.transferFrom(alice, safe, id);
        _same(id, "safe owner");
        assertEq(_addrRaw(id, 60), address(0), "no coin 60 answer before the Safe saves one");
    }

    // a key wallet with an EIP7702 delegation has 23 bytes of code, so its code hash is not empty; the answers do not
    // read code, so a rebuild from storage alone matches the contract, before and after a save
    function test_rawRebuild7702Matches() public {
        address k = makeAddr("k7702");
        vm.etch(k, abi.encodePacked(hex"ef0100", address(0xBEEF)));
        assertFalse(_codelessRaw(k), "its code hash is not empty");
        uint256 id = _reg(alice, "alice");
        vm.prank(alice);
        nft.setAddr(id, k);
        assertEq(_decode(nft.addr(id, 60)), address(0), "the main address does not answer coin 60");
        assertEq(_addrRaw(id, 60), address(0), "the rebuild agrees");
        assertEq(_addrRaw(id, OP), k, "OP answer unaffected");
        _same(id, "7702 main");
        vm.prank(alice);
        nft.setAddrForCoin(id, DEFAULT_EVM, abi.encodePacked(k));
        assertEq(_decode(nft.addr(id, 60)), k, "the saved default answers coin 60");
        assertEq(_addrRaw(id, 60), k, "the rebuild agrees");
        _same(id, "7702 default");
    }
}

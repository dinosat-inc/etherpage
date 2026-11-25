// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Vm} from "forge-std/Vm.sol";

// One hash per log, over its topics and data, so a recorded log can be compared with the exact log a rule expects.
library LogShapes {
    bytes32 internal constant TRANSFER = keccak256("Transfer(address,address,uint256)");
    bytes32 internal constant ADDRESS_CHANGED = keccak256("AddressChanged(bytes32,uint256,bytes)");
    bytes32 internal constant ADDR_CHANGED = keccak256("AddrChanged(bytes32,address)");
    bytes32 internal constant METADATA = keccak256("MetadataUpdate(uint256)");
    bytes32 internal constant VERSION = keccak256("VersionChanged(bytes32,uint64)");
    bytes32 internal constant SUB_REGISTERED = keccak256("SubpageRegistered(uint256,uint256,string)");
    bytes32 internal constant NAME_REGISTERED = keccak256("PageRegistered(uint256,string,address,uint256)");
    bytes32 internal constant PRIMARY = keccak256("PrimaryPageSet(address,uint256)");
    bytes32 internal constant REFERRER_SET = keccak256("ReferrerSet(uint256,uint256)");
    bytes32 internal constant DEPOSIT_ADDED = keccak256("DepositAdded(uint256,address,uint256,uint256)");
    bytes32 internal constant BOUGHT_OUT = keccak256("DepositBoughtOut(uint256,address,uint256)");
    bytes32 internal constant RELEASED = keccak256("DepositReleased(uint256,address,uint256)");
    bytes32 internal constant WITHDRAWN = keccak256("Withdrawn(address,address,uint256)");
    bytes32 internal constant MINTER_SET = keccak256("SubpageMinterSet(uint256,address,address,uint64)");
    uint256 internal constant OP = 0x8000000a;

    function hashOf(Vm.Log memory l) internal pure returns (bytes32) {
        return keccak256(abi.encode(l.topics, l.data));
    }

    function word(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }

    function t1(bytes32 a) internal pure returns (bytes32[] memory t) {
        t = new bytes32[](1);
        t[0] = a;
    }

    function t2(bytes32 a, bytes32 b) internal pure returns (bytes32[] memory t) {
        t = new bytes32[](2);
        t[0] = a;
        t[1] = b;
    }

    function t3(bytes32 a, bytes32 b, bytes32 c) internal pure returns (bytes32[] memory t) {
        t = new bytes32[](3);
        t[0] = a;
        t[1] = b;
        t[2] = c;
    }

    function t4(bytes32 a, bytes32 b, bytes32 c, bytes32 d) internal pure returns (bytes32[] memory t) {
        t = new bytes32[](4);
        t[0] = a;
        t[1] = b;
        t[2] = c;
        t[3] = d;
    }

    // zero goes out as empty bytes
    function enc(address a) internal pure returns (bytes memory) {
        return a == address(0) ? bytes("") : abi.encodePacked(a);
    }

    function transfer(address from, address to, uint256 id) internal pure returns (bytes32) {
        return keccak256(abi.encode(t4(TRANSFER, word(from), word(to), bytes32(id)), bytes("")));
    }

    function coin(uint256 id, uint256 coinType, bytes memory v) internal pure returns (bytes32) {
        return keccak256(abi.encode(t2(ADDRESS_CHANGED, bytes32(id)), abi.encode(coinType, v)));
    }

    function addrChanged(uint256 id, address a) internal pure returns (bytes32) {
        return keccak256(abi.encode(t2(ADDR_CHANGED, bytes32(id)), abi.encode(a)));
    }

    function meta(uint256 id) internal pure returns (bytes32) {
        return keccak256(abi.encode(t1(METADATA), abi.encode(id)));
    }

    function version(uint256 id, uint256 v) internal pure returns (bytes32) {
        return keccak256(abi.encode(t2(VERSION, bytes32(id)), abi.encode(uint64(v))));
    }

    function subRegistered(uint256 id, uint256 parent, string memory label) internal pure returns (bytes32) {
        return keccak256(abi.encode(t3(SUB_REGISTERED, bytes32(id), bytes32(parent)), abi.encode(label)));
    }

    function nameRegistered(uint256 id, string memory label, address owner, uint256 expiry)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(t3(NAME_REGISTERED, bytes32(id), word(owner)), abi.encode(label, expiry)));
    }

    function primary(address a, uint256 id) internal pure returns (bytes32) {
        return keccak256(abi.encode(t3(PRIMARY, word(a), bytes32(id)), bytes("")));
    }

    function referrerSet(uint256 id, uint256 ref) internal pure returns (bytes32) {
        return keccak256(abi.encode(t3(REFERRER_SET, bytes32(id), bytes32(ref)), bytes("")));
    }

    function depositAdded(uint256 id, address payer, uint256 amount, uint256 total) internal pure returns (bytes32) {
        return keccak256(abi.encode(t3(DEPOSIT_ADDED, bytes32(id), word(payer)), abi.encode(amount, total)));
    }

    function boughtOut(uint256 id, address to, uint256 amount) internal pure returns (bytes32) {
        return keccak256(abi.encode(t3(BOUGHT_OUT, bytes32(id), word(to)), abi.encode(amount)));
    }

    function released(uint256 id, address to, uint256 amount) internal pure returns (bytes32) {
        return keccak256(abi.encode(t3(RELEASED, bytes32(id), word(to)), abi.encode(amount)));
    }

    function withdrawn(address account, address caller, uint256 amount) internal pure returns (bytes32) {
        return keccak256(abi.encode(t3(WITHDRAWN, word(account), word(caller)), abi.encode(amount)));
    }

    function minterSet(uint256 parent, address account, address minter, uint64 epoch) internal pure returns (bytes32) {
        return keccak256(abi.encode(t4(MINTER_SET, bytes32(parent), word(account), word(minter)), abi.encode(epoch)));
    }

    // the three address events in their order: the home chain answer, then the coin type 60 answer and its AddrChanged
    function trio(uint256 id, address main, address eth, bytes32[] memory out, uint256 from) internal pure {
        out[from] = coin(id, OP, enc(main));
        out[from + 1] = coin(id, 60, enc(eth));
        out[from + 2] = addrChanged(id, eth);
    }
}

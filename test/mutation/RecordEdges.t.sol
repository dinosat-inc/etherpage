// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Vm} from "forge-std/Test.sol";
import {RulesBase} from "../utils/RulesBase.sol";

// A new registration clears only the old holder's display name of that name, a live trial is never releasable,
// and a main address of zero points the name back at its holder.
contract RecordEdgesTest is RulesBase {
    bytes32 constant T_PRIMARY = keccak256("PrimaryPageSet(address,uint256)");

    function _idOf(string memory l) internal view returns (uint256) {
        return uint256(keccak256(abi.encodePacked(nft.ROOT(), keccak256(bytes(l)))));
    }

    // two labels with the prefix whose ids are below and above the id of x
    function _around(string memory x, string memory prefix) internal view returns (string memory lo, string memory hi) {
        uint256 id = _idOf(x);
        for (uint256 i; i < 40; ++i) {
            string memory l = string.concat(prefix, vm.toString(i));
            if (_idOf(l) < id && bytes(lo).length == 0) lo = l;
            if (_idOf(l) > id && bytes(hi).length == 0) hi = l;
        }
        assertTrue(bytes(lo).length != 0 && bytes(hi).length != 0, "labels found");
    }

    function _lapse(uint256 id) internal {
        vm.warp(nft.expiresAt(id) + 90 days + 21 days + 1);
    }

    function test_reRegistrationKeepsTheOldHoldersOtherDisplayName() public {
        (string memory lo, string memory hi) = _around("xname", "pname");
        uint256 x = _buy(bob, "xname");
        uint256 a = _buy(bob, lo);
        uint256 b = _buy(carol, hi);
        vm.prank(bob);
        nft.setPrimaryPage(a);
        vm.prank(carol);
        nft.setPrimaryPage(b);
        // the names of bob and carol are renewed so they stay live while xname lapses
        for (uint256 i; i < 2; ++i) {
            vm.prank(carol);
            nft.renew{value: FEE5}(b);
            vm.prank(bob);
            nft.renew{value: FEE5}(a);
        }
        _lapse(x);
        vm.recordLogs();
        _buy(dave, "xname");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(nft.primaryPage(bob), a, "a smaller id stays");
        assertEq(_count(logs, T_PRIMARY), 0, "nobody's display name changed");
        // the same with a larger id
        uint256 y = _buy(carol, "yname");
        (lo, hi) = _around("yname", "qname");
        uint256 c = _buy(carol, hi);
        vm.prank(carol);
        nft.setPrimaryPage(c);
        _lapse(y);
        vm.recordLogs();
        _buy(dave, "yname");
        assertEq(nft.primaryPage(carol), c, "a larger id stays");
        assertEq(_count(vm.getRecordedLogs(), T_PRIMARY), 0);
    }

    // an old holder with no display name gets no PrimaryPageSet when the name is registered again
    function test_noDisplayNameNoEvent() public {
        uint256 x = _buy(bob, "xname");
        _lapse(x);
        vm.recordLogs();
        _buy(dave, "xname");
        assertEq(_count(vm.getRecordedLogs(), T_PRIMARY), 0);
        assertEq(nft.primaryPage(bob), 0);
    }

    // a live trial is not releasable at any second of its term, and is releasable once it has ended
    function test_liveTrialIsNeverReleasable() public {
        uint256 id = _trial("alice", bob);
        uint256 t = nft.expiresAt(id);
        assertFalse(nft.isReleasable(id), "just started");
        vm.warp(t - 1);
        assertFalse(nft.isReleasable(id), "a second before the end");
        vm.warp(t);
        assertFalse(nft.isReleasable(id), "at the end");
        vm.warp(t + 1);
        assertTrue(nft.isReleasable(id), "after the end");
    }

    // setAddr with zero, saved by the holder, points the name back at the holder
    function test_zeroMainAddressIsTheHolder() public {
        uint256 id = _buy(bob, "alice");
        vm.prank(bob);
        nft.setAddr(id, carol);
        assertEq(nft.resolve(id), carol);
        vm.prank(bob);
        nft.setAddr(id, address(0));
        assertEq(nft.resolve(id), bob, "back to the holder");
        assertEq(nft.addr(id, 0x8000000a), abi.encodePacked(bob));
        assertEq(nft.payee(id), bob);
    }

    // an id that was never registered is neither expired nor releasable, and resolves to nothing, even at time zero
    function test_unknownIdViews() public {
        uint256 id = uint256(keccak256("never registered"));
        assertFalse(nft.isExpired(id));
        assertFalse(nft.isReleasable(id));
        assertFalse(nft.inGracePeriod(id));
        assertEq(nft.resolve(id), address(0));
        vm.warp(0);
        assertEq(nft.resolve(id), address(0), "at time zero");
        assertEq(nft.addr(id, 60), "");
        assertEq(nft.text(id, "k"), "");
        assertFalse(nft.isExpired(id));
    }

    // the stored record of a top level name and of a subpage, field by field
    function test_storedRecords() public {
        uint256 parent = _buy(bob, "alice");
        (string memory label, uint256 p, uint64 exp, uint64 epoch, uint64 parentEpoch) = nft.records(parent);
        assertEq(label, "alice");
        assertEq(p, 0);
        assertEq(exp, block.timestamp + 365 days);
        assertEq(epoch, 1);
        assertEq(parentEpoch, 0, "a top level name has no parent epoch");
        vm.prank(bob);
        uint256 sub = nft.registerSubpage("sub", parent);
        (label, p, exp, epoch, parentEpoch) = nft.records(sub);
        assertEq(label, "sub");
        assertEq(p, parent);
        assertEq(exp, 0, "a subpage keeps no expiry of its own");
        assertEq(nft.expiresAt(sub), 0);
        assertEq(epoch, 1);
        assertEq(parentEpoch, 1);
    }

    // the main address of every AddressChanged for the home chain in the logs, zero when it is empty
    function _mains(Vm.Log[] memory logs) internal pure returns (address[] memory out) {
        bytes32 tAddress = keccak256("AddressChanged(bytes32,uint256,bytes)");
        out = new address[](logs.length);
        uint256 n;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] != tAddress) continue;
            (uint256 c, bytes memory a) = abi.decode(logs[i].data, (uint256, bytes));
            if (c == 0x8000000a) out[n++] = a.length == 0 ? address(0) : address(bytes20(a));
        }
        assembly ("memory-safe") {
            mstore(out, n)
        }
    }

    // every AddrChanged in the logs
    function _addrs(Vm.Log[] memory logs) internal pure returns (address[] memory out) {
        bytes32 tAddr = keccak256("AddrChanged(bytes32,address)");
        out = new address[](logs.length);
        uint256 n;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == tAddr) out[n++] = abi.decode(logs[i].data, (address));
        }
        assembly ("memory-safe") {
            mstore(out, n)
        }
    }

    // a holder at address(1) gets its address logs like any other holder, when the subpage is made, when it saves
    // itself for coin type 60, and when the subpage is replaced
    function test_lowAddressHolderLogs() public {
        uint256 parent = _buy(bob, "alice");
        vm.recordLogs();
        vm.prank(bob);
        uint256 sub = nft.registerSubpageFor("one", parent, address(1));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        address[] memory mains = _mains(logs);
        assertEq(mains.length, 1, "the main address is logged once");
        assertEq(mains[0], address(1), "as address(1)");
        address[] memory addrs = _addrs(logs);
        assertEq(addrs.length, 1);
        assertEq(addrs[0], address(0), "AddrChanged carries coin type 60, for which address(1) saved nothing");
        assertEq(nft.resolve(sub), address(1));
        // address(1) saves itself for coin type 60, and AddrChanged carries it
        vm.recordLogs();
        vm.prank(address(1));
        nft.setAddrForCoin(sub, 60, abi.encodePacked(address(1)));
        addrs = _addrs(vm.getRecordedLogs());
        assertEq(addrs.length, 1);
        assertEq(addrs[0], address(1), "AddrChanged to address(1)");
        assertEq(nft.addr(bytes32(sub)), address(1));
        // the holder of the parent replaces it: the burn logs address zero for the old holder, then the mint logs
        // the new one
        vm.recordLogs();
        vm.prank(bob);
        nft.registerSubpageFor("one", parent, carol);
        logs = vm.getRecordedLogs();
        mains = _mains(logs);
        assertEq(mains.length, 2);
        assertEq(mains[0], address(0), "the burn logs a main address of zero");
        assertEq(mains[1], carol, "the mint logs the new holder");
        addrs = _addrs(logs);
        assertEq(addrs.length, 2);
        assertEq(addrs[0], address(0), "the burn logs AddrChanged to zero");
        assertEq(addrs[1], address(0), "carol saved nothing for coin type 60");
    }

    // the resolver views that take a node answer as the ones that take an id
    function test_nodeViews() public {
        uint256 id = _buy(bob, "alice");
        vm.startPrank(bob);
        nft.setContenthash(id, hex"e30101");
        nft.setText(id, "url", "x");
        nft.setAddrForCoin(id, 0, hex"0102");
        nft.setAddr(id, carol);
        vm.stopPrank();
        bytes32 node = bytes32(id);
        assertEq(nft.contenthash(node), hex"e30101");
        assertEq(nft.contenthash(id), hex"e30101");
        assertEq(nft.text(node, "url"), "x");
        assertEq(nft.addr(node, 0), hex"0102");
        assertEq(nft.resolve(id), carol);
        assertEq(nft.addr(node, 0x8000000a), abi.encodePacked(carol), "the main address is the home chain answer");
        assertEq(nft.addr(node), address(0), "addr by node is the coin type 60 answer, not the main address");
        assertEq(nft.addr(node, 60), "", "the main address is not the coin type 60 answer");
        assertEq(nft.addr(id, 60), "");
        // once bob saves a default, coin type 60 answers it by node and by id, with or without a coin type
        vm.prank(bob);
        nft.setAddrForCoin(id, 0x80000000, abi.encodePacked(dave));
        assertEq(nft.addr(node, 60), abi.encodePacked(dave));
        assertEq(nft.addr(id, 60), abi.encodePacked(dave));
        assertEq(nft.addr(node), dave);
        // and an entry for coin type 60 wins over the default there too
        vm.prank(bob);
        nft.setAddrForCoin(id, 60, abi.encodePacked(carol));
        assertEq(nft.addr(node), carol);
        assertEq(nft.addr(node, 60), abi.encodePacked(carol));
    }
}

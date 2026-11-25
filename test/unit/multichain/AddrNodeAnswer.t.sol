// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Vm} from "forge-std/Test.sol";
import {MinterBase} from "../../utils/MinterBase.sol";

contract AcceptsPages {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}

// addr(bytes32) gives the same answer as addr with coin type 60, and every AddrChanged comes right after an
// AddressChanged for coin type 60 that carries the same address, on every path that announces addresses.
contract AddrNodeAnswerTest is MinterBase {
    uint256 constant COIN_60 = 60;
    uint256 constant DEFAULT_EVM = 0x80000000;
    bytes32 constant T_ADDR = keccak256("AddrChanged(bytes32,address)");
    bytes32 constant T_ADDRESS = keccak256("AddressChanged(bytes32,uint256,bytes)");

    // checks the pairing on the logs recorded since the last call and returns how many pairs it saw
    function _pairs(string memory where) internal view returns (uint256 n) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(nft)) continue;
            if (logs[i].topics[0] == T_ADDRESS) {
                (uint256 coin, bytes memory v) = abi.decode(logs[i].data, (uint256, bytes));
                if (coin != COIN_60) continue;
                assertTrue(i + 1 < logs.length, string.concat(where, ": AddrChanged follows"));
                assertEq(logs[i + 1].topics[0], T_ADDR, string.concat(where, ": AddrChanged follows"));
                assertEq(logs[i + 1].topics[1], logs[i].topics[1], string.concat(where, ": the same node"));
                address a = abi.decode(logs[i + 1].data, (address));
                assertEq(v, a == address(0) ? bytes("") : abi.encodePacked(a), string.concat(where, ": the same address"));
                ++n;
            }
            if (logs[i].topics[0] == T_ADDR) {
                assertTrue(i > 0, string.concat(where, ": AddressChanged comes first"));
                assertEq(logs[i - 1].topics[0], T_ADDRESS, string.concat(where, ": AddressChanged comes first"));
                (uint256 coin,) = abi.decode(logs[i - 1].data, (uint256, bytes));
                assertEq(coin, COIN_60, string.concat(where, ": for coin type 60"));
            }
        }
    }

    function _trialFor(address who, string memory label) internal returns (uint256 id) {
        bytes32 secret = keccak256(abi.encode(label));
        vm.prank(who);
        nft.commit(keccak256(abi.encode(bytes(label), who, uint256(0), secret, true)));
        vm.warp(vm.getBlockTimestamp() + 61);
        vm.prank(who);
        id = nft.revealTrial{value: nft.getFee(bytes(label).length) / 10}(label, who, 0, secret);
    }

    function test_theAnswer() public {
        uint256 id = _reg(alice, "alice");
        bytes32 node = bytes32(id);
        assertEq(nft.resolve(id), alice, "the main address is the holder");
        assertEq(nft.addr(node), address(0), "nothing saved for coin type 60 and no default");
        assertEq(nft.addr(id, COIN_60).length, 0);

        vm.prank(alice);
        nft.setAddrForCoin(id, DEFAULT_EVM, abi.encodePacked(hot));
        assertEq(nft.addr(node), hot, "the default counts for coin type 60");

        vm.prank(alice);
        nft.setAddrForCoin(id, COIN_60, abi.encodePacked(hot2));
        assertEq(nft.addr(node), hot2, "its own entry wins over the default");
        assertEq(nft.addr(node), address(bytes20(nft.addr(id, COIN_60))));

        vm.prank(alice);
        nft.setAddr(id, carol);
        assertEq(nft.resolve(id), carol, "the main address moves");
        assertEq(nft.addr(node), hot2, "coin type 60 does not");

        vm.prank(alice);
        nft.transferFrom(alice, bob, id);
        assertEq(nft.addr(node), address(0), "the new holder saved nothing");
        assertEq(nft.resolve(id), bob);

        // bob saves an entry, so after expiry only the activity check can make the answer zero
        vm.prank(bob);
        nft.setAddrForCoin(id, COIN_60, abi.encodePacked(hot));
        assertEq(nft.addr(node), hot, "the new holder's own entry");

        vm.warp(nft.expiresAt(id) + 1);
        assertTrue(nft.inGracePeriod(id), "in its grace period");
        assertEq(nft.ownerOf(id), bob, "bob still holds it");
        assertEq(nft.addr(node), address(0), "not active");
        assertEq(nft.addr(bytes32(uint256(123))), address(0), "no such page");
    }

    function test_pairingOnEveryPath() public {
        vm.recordLogs();
        uint256 id = _reg(alice, "alice");
        _pairs("reveal");
        vm.recordLogs();
        _trialFor(bob, "bobtrial");
        _pairs("revealTrial");

        uint256[7] memory coins = [COIN_60, DEFAULT_EVM, COIN_OP, 0, 0xffffffff, uint256(1) << 255, 0x80002105];
        for (uint256 i; i < coins.length; ++i) {
            vm.recordLogs();
            vm.prank(alice);
            nft.setAddrForCoin(id, coins[i], abi.encodePacked(hot));
            uint256 n = _pairs("save");
            assertEq(n, coins[i] == COIN_60 || coins[i] == DEFAULT_EVM || coins[i] == COIN_OP ? 1 : 0, "one pair or none");
            vm.recordLogs();
            vm.prank(alice);
            nft.setAddrForCoin(id, coins[i], "");
            _pairs("clear");
        }

        vm.recordLogs();
        vm.prank(alice);
        nft.setAddr(id, carol);
        assertEq(_pairs("setAddr"), 1);

        bytes[] memory calls = new bytes[](3);
        calls[0] = abi.encodeWithSignature("setAddrForCoin(uint256,uint256,bytes)", id, DEFAULT_EVM, abi.encodePacked(dave));
        calls[1] = abi.encodeWithSignature("setAddrForCoin(uint256,uint256,bytes)", id, COIN_60, bytes(""));
        calls[2] = abi.encodeWithSignature("clearRecords(uint256)", id);
        vm.recordLogs();
        vm.prank(alice);
        nft.multicall(calls);
        assertEq(_pairs("multicall"), 3);

        vm.prank(alice);
        nft.setAddrForCoin(id, COIN_60, abi.encodePacked(hot));
        vm.recordLogs();
        vm.prank(alice);
        nft.setText(id, "url", "x");
        vm.prank(alice);
        nft.setData(id, "k", hex"01");
        assertEq(_pairs("text and data"), 0, "no address events");

        AcceptsPages t = new AcceptsPages();
        vm.recordLogs();
        vm.prank(alice);
        nft.safeTransferFrom(alice, address(t), id, "hi");
        _pairs("safeTransferFrom");
        vm.recordLogs();
        vm.prank(address(t));
        nft.transferFrom(address(t), bob, id);
        _pairs("transferFrom");

        vm.prank(bob);
        nft.setAddrForCoin(id, COIN_60, abi.encodePacked(hot));
        vm.recordLogs();
        vm.prank(bob);
        uint256 sub = nft.registerSubpage("pay", id);
        _pairs("registerSubpage");
        vm.prank(bob);
        nft.setAddrForCoin(sub, DEFAULT_EVM, abi.encodePacked(hot2));
        vm.recordLogs();
        vm.prank(bob);
        nft.registerSubpageFor("pay", id, carol);
        _pairs("a new mint of a subpage");
        vm.recordLogs();
        vm.prank(carol);
        nft.transferFrom(carol, DEAD, sub);
        _pairs("a subpage to the dead address");

        _sellSetup(id, 0.01 ether);
        vm.recordLogs();
        vm.prank(buyer);
        reg.registerSubpage{value: 0.01 ether}(id, "shop", 0.01 ether, address(0));
        _pairs("a registrar sale");

        vm.recordLogs();
        vm.prank(bob);
        nft.transferFrom(bob, DEAD, id);
        assertEq(_pairs("a page to the dead address"), 1);
        vm.recordLogs();
        _lapseAndRegister(id, carol);
        _pairs("registered again");
    }

    // the main address is still announced, for the home chain coin type
    function test_theMainAddressIsStillAnnounced() public {
        uint256 id = _reg(alice, "alice");
        vm.recordLogs();
        vm.prank(alice);
        nft.setAddr(id, carol);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool seen;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] != T_ADDRESS) continue;
            (uint256 coin, bytes memory v) = abi.decode(logs[i].data, (uint256, bytes));
            if (coin == COIN_OP) {
                assertEq(v, abi.encodePacked(carol));
                seen = true;
            }
        }
        assertTrue(seen);
    }
}

// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Vm} from "forge-std/Test.sol";
import {PageNFT} from "../../src/PageNFT.sol";
import {RulesBase} from "../utils/RulesBase.sol";

contract PlainReceiver {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}

// The address logs a transfer emits, the EVM coin type range, the main address of zero, and who may move an
// unpaid trial.
contract AddressLogsTest is RulesBase {
    bytes32 constant T_ADDRESS = keccak256("AddressChanged(bytes32,uint256,bytes)");
    bytes32 constant T_ADDR = keccak256("AddrChanged(bytes32,address)");
    uint256 constant OP = 0x8000000a;

    // the AddressChanged logs of nft for one coin type, as their address bytes
    function _coinLogs(Vm.Log[] memory logs, uint256 coin) internal view returns (bytes[] memory out) {
        uint256 n;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(nft) && logs[i].topics[0] == T_ADDRESS) {
                (uint256 c,) = abi.decode(logs[i].data, (uint256, bytes));
                if (c == coin) ++n;
            }
        }
        out = new bytes[](n);
        n = 0;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(nft) && logs[i].topics[0] == T_ADDRESS) {
                (uint256 c, bytes memory a) = abi.decode(logs[i].data, (uint256, bytes));
                if (c == coin) out[n++] = a;
            }
        }
    }

    function _move(uint256 id, address from, address to) internal returns (Vm.Log[] memory) {
        vm.recordLogs();
        vm.prank(from);
        nft.transferFrom(from, to, id);
        return vm.getRecordedLogs();
    }

    // between two contracts with nothing saved the main address changes, so both answers are logged, each way
    function test_contractToContractLogsBothWays() public {
        address c1 = address(new PlainReceiver());
        address c2 = address(new PlainReceiver());
        uint256 id = _buy(bob, "alice", c1, 0);
        Vm.Log[] memory logs = _move(id, c1, c2);
        assertEq(_coinLogs(logs, 60).length, 1, "coin 60 logged");
        assertEq(_coinLogs(logs, 60)[0], "", "nothing saved, so coin 60 is empty");
        assertEq(_coinLogs(logs, OP)[0], abi.encodePacked(c2));
        logs = _move(id, c2, c1);
        assertEq(_coinLogs(logs, 60).length, 1, "coin 60 logged the other way");
        assertEq(_coinLogs(logs, OP)[0], abi.encodePacked(c1));
    }

    // the main address stays the same but the Ethereum answer changes: only coin 60 is logged
    function _ethOnly(address y) internal {
        string memory l = string.concat("eth", vm.toString(uint160(y) % 1000));
        uint256 id = _buy(bob, l);
        vm.startPrank(bob);
        nft.setAddr(id, carol);
        nft.setAddrForCoin(id, 60, abi.encodePacked(y));
        vm.stopPrank();
        Vm.Log[] memory logs = _move(id, bob, carol);
        assertEq(_coinLogs(logs, OP).length, 0, "the main address did not change");
        bytes[] memory eth = _coinLogs(logs, 60);
        assertEq(eth.length, 1, "coin 60 logged");
        assertEq(eth[0], "", "carol saved nothing for coin 60, so it is empty");
    }

    function test_ethereumAnswerChangesAlone() public {
        _ethOnly(address(1));
        _ethOnly(address(type(uint160).max));
    }

    // nothing changes: the old holder pointed the name at the new one, and neither saved anything for coin 60
    function test_unchangedAnswersLogNothing() public {
        uint256 id = _buy(bob, "alice");
        vm.prank(bob);
        nft.setAddr(id, carol);
        Vm.Log[] memory logs = _move(id, bob, carol);
        assertEq(_coinLogs(logs, OP).length, 0);
        assertEq(_coinLogs(logs, 60).length, 0, "no coin 60 log");
        for (uint256 i; i < logs.length; ++i) assertTrue(logs[i].topics[0] != T_ADDR, "no AddrChanged");
    }

    // an Ethereum address saved by a holder counts again when the name comes back to that holder
    function test_savedEthereumAddressCountsAgainForItsSaver() public {
        uint256 id = _buy(bob, "alice");
        address x = makeAddr("x");
        vm.startPrank(bob);
        nft.setAddrForCoin(id, 60, abi.encodePacked(x));
        nft.setAddr(id, makeAddr("m"));
        vm.stopPrank();
        _move(id, bob, carol);
        assertEq(nft.addr(id, 60), "", "bob's entry stops counting and carol saved none");
        Vm.Log[] memory logs = _move(id, carol, bob);
        bytes[] memory eth = _coinLogs(logs, 60);
        assertEq(eth.length, 1);
        assertEq(eth[0], abi.encodePacked(x), "the saved address answers again");
        assertEq(nft.addr(id, 60), abi.encodePacked(x));
    }

    // setting the main address logs the Ethereum answer, which is the address the holder saved for coin 60
    function test_setAddrLogsTheSavedEthereumAddress() public {
        uint256 id = _buy(bob, "alice");
        address x = makeAddr("x");
        vm.prank(bob);
        nft.setAddrForCoin(id, 60, abi.encodePacked(x));
        vm.recordLogs();
        vm.prank(bob);
        nft.setAddr(id, makeAddr("m"));
        bytes[] memory eth = _coinLogs(vm.getRecordedLogs(), 60);
        assertEq(eth.length, 1, "coin 60 logged");
        assertEq(eth[0], abi.encodePacked(x), "the saved Ethereum address");
    }

    // no OP and no coin 60 log when the holder points the name at address(1) and then moves it there
    function test_unchangedAnswersLogNothingForAddressOne() public {
        uint256 id = _buy(bob, "alice");
        vm.prank(bob);
        nft.setAddr(id, address(1));
        Vm.Log[] memory logs = _move(id, bob, address(1));
        assertEq(_coinLogs(logs, OP).length, 0);
        assertEq(_coinLogs(logs, 60).length, 0, "no coin 60 log");
    }

    // a main address of zero is logged as the holder, through the home chain coin type
    function test_zeroMainAddressIsLoggedAsTheHolder() public {
        uint256 id = _buy(bob, "alice");
        vm.prank(bob);
        nft.setAddr(id, carol);
        vm.expectEmit(true, false, false, true, address(nft));
        emit PageNFT.AddressChanged(bytes32(id), OP, abi.encodePacked(bob));
        vm.prank(bob);
        nft.setAddr(id, address(0));
        assertEq(nft.resolve(id), bob);
    }

    // an address saved for a chain that is not EVM counts only for the account that saved it
    function test_otherChainAddressNeedsItsSaver() public {
        address lo = address(0x1000);
        address hi = address(0x2000);
        uint256 id = _buy(bob, "alice", lo, 0);
        vm.prank(lo);
        nft.setAddrForCoin(id, 0, hex"0102");
        assertEq(nft.addr(id, 0), hex"0102");
        _move(id, lo, hi);
        assertEq(nft.addr(id, 0), "", "the saver no longer holds it");
        _move(id, hi, lo);
        assertEq(nft.addr(id, 0), hex"0102", "back with the saver");
    }

    // EVM coin types are 60 and 0x80000000 to 0xffffffff, and only they answer the saved default; an EVM address
    // is 20 bytes or empty
    function test_evmCoinTypeRange() public {
        uint256 id = _buy(bob, "alice");
        assertEq(nft.addr(id, 0xffffffff), "", "the last EVM coin type, with no default saved");
        assertEq(nft.addr(id, 0x80000001), "");
        address d = makeAddr("default");
        vm.prank(bob);
        nft.setAddrForCoin(id, 0x80000000, abi.encodePacked(d));
        assertEq(nft.addr(id, 0xffffffff), abi.encodePacked(d), "the last EVM coin type answers the default");
        assertEq(nft.addr(id, 0x80000001), abi.encodePacked(d));
        assertEq(nft.addr(id, 60), abi.encodePacked(d));
        assertEq(nft.addr(id, 0x100000000), "", "above the range");
        assertEq(nft.addr(id, 0x7fffffff), "", "below the range");
        vm.startPrank(bob);
        vm.expectRevert(PageNFT.InvalidLength.selector);
        nft.setAddrForCoin(id, 60, new bytes(21));
        vm.expectRevert(PageNFT.InvalidLength.selector);
        nft.setAddrForCoin(id, 60, new bytes(19));
        vm.expectRevert(PageNFT.InvalidLength.selector);
        nft.setAddrForCoin(id, 0xffffffff, new bytes(21));
        nft.setAddrForCoin(id, 0x100000000, new bytes(21));
        vm.stopPrank();
        assertEq(nft.addr(id, 0x100000000), new bytes(21));
    }

    // an unpaid trial moves only to DEAD, whatever the other address
    function test_unpaidTrialMovesOnlyToDead() public {
        uint256 id = _trial("alice", bob);
        address[3] memory to = [address(0x1234), address(1), address(0xdEaE)];
        for (uint256 i; i < 3; ++i) {
            vm.prank(bob);
            vm.expectRevert(PageNFT.Unpaid.selector);
            nft.transferFrom(bob, to[i], id);
        }
        vm.prank(bob);
        nft.transferFrom(bob, DEAD, id);
        assertEq(nft.ownerOf(id), DEAD);
    }
}

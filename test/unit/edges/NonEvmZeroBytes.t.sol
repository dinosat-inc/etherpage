// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Vm} from "forge-std/Test.sol";
import {EdgesBase} from "./EdgesBase.sol";
import {LogShapes} from "../../utils/LogShapes.sol";

// Twenty zero bytes clear an entry only on an EVM chain. A chain outside the EVM keeps them as given: they read
// back as saved, are logged as saved, stop counting when the name leaves their saver and count again when it comes
// back. The same twenty bytes saved for Ethereum, another EVM chain or OP clear the entry instead.
contract NonEvmZeroBytesTest is EdgesBase {
    uint256 constant ETH = 60;
    uint256 constant BASE = 0x80002105;
    uint256 constant OP = 0x8000000a;

    uint256 id;

    function setUp() public override {
        super.setUp();
        id = _buy(alice, "alpha", alice, 0);
    }

    // coin types outside the EVM, the ones next to the EVM range included
    function _nonEvm() internal pure returns (uint256[6] memory) {
        return [uint256(0), 2, 501, 0x7fffffff, 0x100000000, type(uint256).max];
    }

    // alice saves a for coinType; returns the logs of the save
    function _save(uint256 coinType, bytes memory a) internal returns (Vm.Log[] memory logs) {
        vm.recordLogs();
        vm.prank(alice);
        nft.setAddrForCoin(id, coinType, a);
        logs = vm.getRecordedLogs();
    }

    // the logs of an EVM save: AddressChanged with the answer after it, and for coin type 60 then AddrChanged with
    // the same address
    function _assertEvmSaveLogs(Vm.Log[] memory logs, uint256 coinType, bytes memory answer) internal view {
        assertEq(logs.length, coinType == ETH ? 2 : 1, "the number of logs");
        assertEq(LogShapes.hashOf(logs[0]), LogShapes.coin(id, coinType, answer), "logged as the answer after it");
        if (coinType == ETH) {
            address a = answer.length == 0 ? address(0) : address(bytes20(answer));
            assertEq(LogShapes.hashOf(logs[1]), LogShapes.addrChanged(id, a), "then AddrChanged with the same answer");
        }
    }

    function test_twentyZeroBytesForANonEvmChainReadBackAsSaved() public {
        bytes memory zeros = new bytes(20);
        uint256[6] memory chains = _nonEvm();
        for (uint256 i; i < chains.length; ++i) {
            string memory which = vm.toString(chains[i]);
            // half of them over an earlier entry, half from nothing
            if (i % 2 == 0) _save(chains[i], hex"0014aabbccdd");
            Vm.Log[] memory logs = _save(chains[i], zeros);
            assertEq(nft.addr(id, chains[i]), zeros, string.concat(which, ": read back as saved"));
            assertEq(nft.addr(bytes32(id), chains[i]), zeros, string.concat(which, ": the node view too"));
            assertEq(logs.length, 1, string.concat(which, ": one log"));
            assertEq(LogShapes.hashOf(logs[0]), LogShapes.coin(id, chains[i], zeros), string.concat(which, ": logged"));
        }

        // the entries stop counting when the name leaves alice and count again when it comes back
        vm.prank(alice);
        nft.transferFrom(alice, bob, id);
        for (uint256 i; i < chains.length; ++i) assertEq(nft.addr(id, chains[i]), "", "not the saver");
        vm.prank(bob);
        nft.transferFrom(bob, alice, id);
        for (uint256 i; i < chains.length; ++i) assertEq(nft.addr(id, chains[i]), zeros, "the saver again");
    }

    // the same twenty zero bytes clear an EVM entry, which then answers the default the holder saved, or nothing
    // while there is none
    function test_twentyZeroBytesClearEveryEvmEntry() public {
        bytes memory zeros = new bytes(20);
        bytes memory holder = abi.encodePacked(alice);
        bytes memory dflt = abi.encodePacked(dave);
        uint256[2] memory evm = [ETH, BASE];
        for (uint256 i; i < evm.length; ++i) {
            _save(evm[i], abi.encodePacked(hot));
            assertEq(nft.addr(id, evm[i]), abi.encodePacked(hot));
            Vm.Log[] memory logs = _save(evm[i], zeros);
            assertEq(nft.addr(id, evm[i]), "", "cleared, with no default saved");
            _assertEvmSaveLogs(logs, evm[i], "");
        }
        _save(0x80000000, dflt);
        for (uint256 i; i < evm.length; ++i) {
            _save(evm[i], abi.encodePacked(hot));
            assertEq(nft.addr(id, evm[i]), abi.encodePacked(hot), "the entry wins over the default");
            Vm.Log[] memory logs = _save(evm[i], zeros);
            assertEq(nft.addr(id, evm[i]), dflt, "cleared back to the default");
            _assertEvmSaveLogs(logs, evm[i], dflt);
        }
        vm.prank(alice);
        nft.setAddr(id, hot);
        _save(OP, zeros);
        assertEq(nft.resolve(id), alice, "twenty zero OP bytes point the name back at its holder");
        assertEq(nft.addr(id, OP), holder);
    }
}

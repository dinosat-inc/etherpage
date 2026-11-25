// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Vm} from "forge-std/Test.sol";
import {EdgesBase} from "./EdgesBase.sol";
import {LogShapes} from "../../utils/LogShapes.sol";

// A precompile has no code, which changes no answer. Saved as the main address, or holding the name, it is the
// answer for the home chain and for resolve only: coin type 60, every other EVM chain and the EVM default answer
// nothing until the holder saves an entry or a default, and the save and the move log coin type 60 empty. A saved
// default answers for every EVM chain but the home chain, and an entry for coin type 60 wins over it there.
contract PrecompileMainAddressTest is EdgesBase {
    uint256 constant ETH = 60;
    uint256 constant BASE = 0x80002105;
    uint256 constant DEFAULT_EVM = 0x80000000;
    uint256 constant OP = 0x8000000a;

    uint256 id;

    function setUp() public override {
        super.setUp();
        id = _buy(alice, "alpha", alice, 0);
    }

    // the precompiles of Prague, 0x01 to 0x11, and P256VERIFY at 0x100 on OP Mainnet
    function _precompiles() internal pure returns (address[] memory p) {
        p = new address[](18);
        for (uint256 i; i < 17; ++i) p[i] = address(uint160(i + 1));
        p[17] = address(0x100);
    }

    // main is the home chain answer and resolve, evm the answer of coin type 60, another EVM chain and the default
    function _assertAnswers(address main, address evm, string memory which) internal view {
        bytes memory e = evm == address(0) ? bytes("") : abi.encodePacked(evm);
        assertEq(nft.addr(id, ETH), e, string.concat(which, ": Ethereum"));
        assertEq(nft.addr(bytes32(id), ETH), e, string.concat(which, ": Ethereum by node"));
        assertEq(nft.addr(id, BASE), e, string.concat(which, ": another EVM chain"));
        assertEq(nft.addr(id, DEFAULT_EVM), e, string.concat(which, ": the EVM default"));
        assertEq(nft.addr(id, OP), abi.encodePacked(main), string.concat(which, ": OP"));
        assertEq(nft.resolve(id), main, string.concat(which, ": resolve"));
    }

    function _assertLogs(Vm.Log[] memory logs, bytes32[] memory want, string memory which) internal pure {
        assertEq(logs.length, want.length, string.concat(which, ": log count"));
        for (uint256 i; i < want.length; ++i) assertEq(LogShapes.hashOf(logs[i]), want[i], which);
    }

    function test_precompileMainAddressIsOnlyTheHomeChainAnswer() public {
        address[] memory p = _precompiles();
        for (uint256 i; i < p.length; ++i) {
            string memory which = vm.toString(p[i]);
            assertEq(p[i].code.length, 0, string.concat(which, ": a precompile has no code"));
            vm.recordLogs();
            vm.prank(alice);
            nft.setAddr(id, p[i]);
            Vm.Log[] memory logs = vm.getRecordedLogs();
            _assertAnswers(p[i], address(0), which);
            // the trio carries the precompile as the home chain answer and an empty coin type 60 answer, then
            // MetadataUpdate
            bytes32[] memory want = new bytes32[](4);
            LogShapes.trio(id, p[i], address(0), want, 0);
            want[3] = LogShapes.meta(id);
            _assertLogs(logs, want, which);
        }
        // a precompile alice saves as the default answers for every EVM chain but the home chain, which keeps the
        // main address
        vm.prank(alice);
        nft.setAddrForCoin(id, DEFAULT_EVM, abi.encodePacked(address(1)));
        _assertAnswers(address(0x100), address(1), "the default");
        // an Ethereum entry alice saves answers for Ethereum, and the other chains keep the default
        vm.prank(alice);
        nft.setAddrForCoin(id, ETH, abi.encodePacked(hot));
        assertEq(nft.addr(id, ETH), abi.encodePacked(hot));
        assertEq(nft.addr(id, BASE), abi.encodePacked(address(1)));
    }

    // address(1) as the holder: the move logs it as the home chain answer and an empty coin type 60 answer, and it
    // answers for the home chain only, until it saves itself as the default, which then answers for coin type 60 and
    // every other EVM chain
    function test_precompileHolderIsOnlyTheHomeChainAnswer() public {
        address one = address(1);
        vm.recordLogs();
        vm.prank(alice);
        nft.safeTransferFrom(alice, one, id);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32[] memory want = new bytes32[](5);
        want[0] = LogShapes.transfer(alice, one, id);
        LogShapes.trio(id, one, address(0), want, 1);
        want[4] = LogShapes.meta(id);
        _assertLogs(logs, want, "the move to address(1)");
        _assertAnswers(one, address(0), "address(1) holds it");
        assertEq(nft.payee(id), one);
        vm.prank(one);
        nft.setAddrForCoin(id, DEFAULT_EVM, abi.encodePacked(one));
        _assertAnswers(one, one, "address(1) saved itself as the default");
    }
}

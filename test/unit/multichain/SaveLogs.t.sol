// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Vm} from "forge-std/Test.sol";
import {PageNFT} from "../../../src/PageNFT.sol";
import {RulesBase} from "../../utils/RulesBase.sol";
import {Holder721} from "../../utils/MinterMocks.sol";

// The log of each address save: a chain entry announces its own answer, coin type 60 adds AddrChanged with the
// same answer, and the main address announces the trio and then MetadataUpdate.
contract SaveLogsTest is RulesBase {
    uint256 constant OP = 0x8000000a;
    uint256 constant DEFAULT_EVM = 0x80000000;
    bytes32 constant T_ADDRESS = keccak256("AddressChanged(bytes32,uint256,bytes)");
    bytes32 constant T_ADDR = keccak256("AddrChanged(bytes32,address)");

    function _isEvm(uint256 c) internal pure returns (bool) {
        return c == 60 || (c >= DEFAULT_EVM && c <= 0xffffffff);
    }

    // a save for any coin type but OP logs exactly one AddressChanged, for its coin type and carrying what
    // addr answers after the write, and no MetadataUpdate; for coin type 60 AddrChanged follows with the same
    // answer, and for any other coin type nothing else is logged; the main address is the holder, a codeless
    // account or a contract
    function testFuzz_everySaveEmitsItsAnswer(uint256 coinType, bytes memory value, uint8 kind, uint8 mainKind)
        public
    {
        vm.assume(coinType != OP && coinType != DEFAULT_EVM);
        if (kind % 4 == 0) coinType = 60;
        if (kind % 4 == 1) coinType = DEFAULT_EVM + 1 + coinType % 0x7fffffff;
        if (coinType == OP) coinType = OP + 1;
        if (_isEvm(coinType)) {
            // an EVM entry is 20 bytes, twenty zero bytes or empty
            uint256 v = uint256(keccak256(value)) % 3;
            value = v == 0 ? abi.encodePacked(bytes20(keccak256(value))) : v == 1 ? new bytes(20) : bytes("");
        }
        uint256 id = _buy(bob, "saves");
        if (mainKind % 3 == 1) {
            vm.prank(bob);
            nft.setAddr(id, carol);
        } else if (mainKind % 3 == 2) {
            address c = address(new Holder721());
            vm.prank(bob);
            nft.setAddr(id, c);
        }
        vm.recordLogs();
        vm.prank(bob);
        nft.setAddrForCoin(id, coinType, value);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, coinType == 60 ? 2 : 1, "one event, and AddrChanged after it for coin type 60");
        assertEq(logs[0].topics[0], T_ADDRESS);
        assertEq(logs[0].topics[1], bytes32(id), "the node");
        (uint256 c, bytes memory a) = abi.decode(logs[0].data, (uint256, bytes));
        assertEq(c, coinType, "its own coin type");
        assertEq(a, nft.addr(id, coinType), "the answer after the write");
        if (coinType == 60) {
            assertEq(logs[1].topics[0], T_ADDR, "then AddrChanged");
            assertEq(logs[1].topics[1], bytes32(id), "for the same node");
            address eth = abi.decode(logs[1].data, (address));
            assertEq(eth, nft.addr(bytes32(id)), "carrying addr by node after the write");
            assertEq(eth == address(0) ? bytes("") : abi.encodePacked(eth), a, "the same answer");
        }
        assertEq(_count(logs, T_META), 0, "no MetadataUpdate");
        if (!_isEvm(coinType)) assertEq(a, value, "a chain outside the EVM answers the bytes as given");
    }

    // setAddr and setAddrForCoin for OP log the trio and then MetadataUpdate as their last event, on every
    // call: the first save, another address, the same address again, zero, a contract and back to the holder
    function test_metadataUpdateOnSetAddr() public {
        uint256 id = _buy(bob, "mainaddr");
        address c = address(new Holder721());
        address[6] memory values = [carol, dave, dave, address(0), c, bob];
        for (uint256 i; i < values.length; ++i) {
            for (uint256 viaCoin; viaCoin < 2; ++viaCoin) {
                vm.recordLogs();
                vm.prank(bob);
                if (viaCoin == 0) nft.setAddr(id, values[i]);
                else nft.setAddrForCoin(id, OP, values[i] == address(0) ? bytes("") : abi.encodePacked(values[i]));
                Vm.Log[] memory logs = vm.getRecordedLogs();
                address main = values[i] == address(0) ? bob : values[i];
                assertEq(logs.length, 4, "the trio and MetadataUpdate");
                assertEq(logs[0].topics[0], T_ADDRESS);
                (uint256 coin, bytes memory a) = abi.decode(logs[0].data, (uint256, bytes));
                assertEq(coin, OP);
                assertEq(a, abi.encodePacked(main));
                assertEq(logs[1].topics[0], T_ADDRESS);
                (coin, a) = abi.decode(logs[1].data, (uint256, bytes));
                assertEq(coin, 60);
                assertEq(a, nft.addr(id, 60), "the Ethereum answer after the write");
                assertEq(logs[2].topics[0], T_ADDR);
                address eth = abi.decode(logs[2].data, (address));
                assertEq(eth, nft.addr(bytes32(id)), "AddrChanged carries the Ethereum answer");
                assertEq(eth == address(0) ? bytes("") : abi.encodePacked(eth), a, "the same answer as coin type 60");
                assertEq(logs[3].topics[0], T_META, "MetadataUpdate is last");
                assertEq(abi.decode(logs[3].data, (uint256)), id);
                assertEq(_count(logs, T_META), 1, "once");
                assertEq(nft.resolve(id), main);
            }
        }
    }
}

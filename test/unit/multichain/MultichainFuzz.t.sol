// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {PageCard} from "../../../src/PageCard.sol";
import {PageNFT} from "../../../src/PageNFT.sol";

contract ChainHolder {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    function call(address to, bytes calldata data) external {
        (bool ok, bytes memory ret) = to.call(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }
}

// an EVM chain other than the home chain with nothing saved answers what DEFAULT_EVM answers, which is the saved
// default or nothing, whatever the code at the holder or the main address
contract MultichainFuzzTest is Test {
    PageCard card;
    PageNFT nft;
    ChainHolder impl;
    address payer = makeAddr("payer");

    uint256 constant ETH = 60;
    uint256 constant OP = 0x8000000a;
    uint256 constant DEF = 0x80000000;

    function setUp() public {
        vm.warp(1_800_000_000);
        card = new PageCard();
        nft = new PageNFT(card);
        impl = new ChainHolder();
        vm.deal(payer, 100 ether);
    }

    function _register(address owner) internal returns (uint256 id) {
        bytes32 secret = keccak256(abi.encode(owner));
        bytes32 commitment = nft.makeCommitment("fuzzname", owner, 0, secret);
        vm.prank(payer);
        nft.commit(commitment);
        vm.warp(block.timestamp + 61);
        (,,, uint256 total) = nft.quote("fuzzname");
        vm.prank(payer);
        id = nft.reveal{value: total}("fuzzname", owner, 0, secret);
    }

    // 60 or any coin type from 0x80000001 to 0xffffffff
    function _evmCoin(uint256 seed) internal pure returns (uint256) {
        if (seed % 5 == 0) return ETH;
        return DEF + 1 + (seed % 0x7fffffff);
    }

    // the first candidate that is neither OP nor the saved chain
    function _unsaved(uint256 raw, uint256 saved) internal pure returns (uint256) {
        uint256[4] memory c = [raw, ETH, DEF + 7, DEF + 9];
        for (uint256 i; i < 4; ++i) {
            if (c[i] != OP && c[i] != saved) return c[i];
        }
        revert();
    }

    function testFuzz_unsavedChainMatchesDefault(
        uint8 kind,
        uint8 mainKind,
        address mainTo,
        uint256 savedSeed,
        address savedValue,
        uint256 readSeed
    ) public {
        vm.assume(mainTo.code.length == 0 && uint160(mainTo) > 0xffff);
        // the holder is a key wallet, a 7702 account or a deployed contract
        address h;
        if (kind % 3 == 2) {
            h = address(new ChainHolder());
        } else {
            h = makeAddr("holder");
            if (kind % 3 == 1) vm.etch(h, abi.encodePacked(hex"ef0100", address(impl)));
        }
        uint256 id = _register(h);

        uint256 savedCoin = _evmCoin(savedSeed);
        if (savedCoin == OP) savedCoin = ETH;
        _asHolder(h, abi.encodeCall(nft.setAddrForCoin, (id, savedCoin, abi.encodePacked(savedValue))));
        // the main address stays the holder, or becomes a codeless address, or a contract
        if (mainKind % 3 == 1) _asHolder(h, abi.encodeCall(nft.setAddr, (id, mainTo)));
        if (mainKind % 3 == 2) _asHolder(h, abi.encodeCall(nft.setAddr, (id, address(card))));

        uint256 readCoin = _unsaved(_evmCoin(readSeed), savedCoin);
        assertEq(nft.addr(id, readCoin), nft.addr(id, DEF), "an unsaved chain differs from the default");

        // with no default saved, the default answers nothing, for every kind of holder and main address
        address main = nft.resolve(id);
        assertEq(nft.addr(id, DEF), bytes(""), "default rule");
        // the saved chain answers its own entry, or nothing when the entry saved was zero
        bytes memory own = savedValue == address(0) ? bytes("") : abi.encodePacked(savedValue);
        assertEq(nft.addr(id, savedCoin), own, "the saved chain answers its own entry");

        // a saved default is the answer, for every kind of holder and main address, and a zero default leaves nothing
        address d = address(uint160(uint256(keccak256(abi.encode(savedSeed, readSeed)))));
        _asHolder(h, abi.encodeCall(nft.setAddrForCoin, (id, DEF, abi.encodePacked(d))));
        bytes memory def = d == address(0) ? bytes("") : abi.encodePacked(d);
        assertEq(nft.addr(id, DEF), def);
        assertEq(nft.addr(id, readCoin), nft.addr(id, DEF), "an unsaved chain differs from the saved default");
        assertEq(nft.addr(id, savedCoin), savedValue == address(0) ? def : own, "an own entry wins over the default");
        assertEq(nft.resolve(id), main, "the main address does not move");
        assertEq(nft.addr(id, OP), abi.encodePacked(main), "nor the OP answer");
    }

    function _asHolder(address h, bytes memory data) internal {
        if (h.code.length > 23) {
            ChainHolder(h).call(address(nft), data);
        } else {
            vm.prank(h);
            (bool ok, bytes memory ret) = address(nft).call(data);
            if (!ok) {
                assembly ("memory-safe") {
                    revert(add(ret, 0x20), mload(ret))
                }
            }
        }
    }
}

// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {PageNFT} from "../../../src/PageNFT.sol";
import {PageCard} from "../../../src/PageCard.sol";

// The root every id hangs from, pinned to its published literal.
contract RootConstantTest is Test {
    bytes32 constant LITERAL = 0x62460c06d95b73747abf6ea4f28aefd78b4ad2abee112e7cf15fe6a924cca3c6;

    function test_check_root_constant() public {
        PageNFT nft = new PageNFT(new PageCard());
        assertEq(nft.ROOT(), LITERAL, "ROOT is the published literal");
        assertEq(keccak256("etherpage.root.v1"), LITERAL, "the literal is keccak256 of etherpage.root.v1");
        assertEq(nft.computeNamehash(""), LITERAL, "the empty name hashes to ROOT");
        uint256 alice = uint256(keccak256(abi.encodePacked(LITERAL, keccak256("alice"))));
        assertEq(nft.computeId("alice"), alice, "a top level id hangs from ROOT");
        assertEq(nft.computeId("bob.alice"), uint256(keccak256(abi.encodePacked(bytes32(alice), keccak256("bob")))),
            "a subpage id hangs from its parent");
    }
}

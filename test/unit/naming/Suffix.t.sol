// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {WorkedExamplesTest} from "../core/WorkedExamples.t.sol";
import {PageNFT} from "../../../src/PageNFT.sol";

// What PageNFT does with a string such as alice.maple: a suffix reads as a parent name
contract SuffixTest is WorkedExamplesTest {
    function test_readsSuffixAsParent() public {
        uint256 realAlice = _register(alice, "alice", 0);
        assertTrue(nft.isAvailable("maple", 0), "anyone can take maple");
        uint256 parent = _register(carol, "maple", 0);
        vm.prank(carol);
        uint256 sub = nft.registerSubpage("alice", parent);

        uint256 looked = nft.computeId("alice.maple");
        assertEq(looked, sub, "alice.maple is carol's subpage");
        assertTrue(looked != realAlice, "not the real alice");
        assertEq(nft.ownerOf(looked), carol);
        assertEq(nft.resolve(looked), carol, "pays carol");
        assertEq(nft.addr(bytes32(looked), 0x8000000a), abi.encodePacked(carol), "carol is the main address");
        assertEq(nft.addr(bytes32(looked)), address(0), "carol saved nothing for coin type 60");
        assertEq(nft.resolve(realAlice), alice);
        assertEq(nft.getPageName(sub), "alice.maple");
        emit log_named_string("getPageName(sub)", nft.getPageName(sub));
    }

    function test_beforeAnyoneTakesTheParent() public view {
        uint256 looked = nft.computeId("alice.maple");
        assertEq(nft.resolve(looked), address(0), "no answer, not alice");
    }

    function test_sameForOtherParents() public {
        uint256 p = _register(carol, "cedar", 0);
        vm.prank(carol);
        uint256 s = nft.registerSubpage("alice", p);
        assertEq(nft.computeId("alice.cedar"), s);
        uint256 e = _register(carol, "oak", 0);
        vm.prank(carol);
        uint256 v = nft.registerSubpage("bob", e);
        assertEq(nft.getPageName(v), "bob.oak");
    }

    function test_anotherSuffixIsAParentToo() public {
        uint256 realAlice = _register(alice, "alice", 0);
        uint256 p = _register(carol, "birch", 0);
        vm.prank(carol);
        uint256 s = nft.registerSubpage("alice", p);
        assertEq(nft.computeId("alice.birch"), s);
        assertTrue(s != realAlice);
        assertEq(nft.resolve(s), carol);
    }

    function test_twoDotsRevert() public {
        vm.expectRevert(PageNFT.InvalidLabel.selector);
        nft.computeId("bob.alice.maple");
    }

    function test_normalizeRefusesDot() public {
        vm.expectRevert();
        nft.normalize("alice.maple");
    }
}

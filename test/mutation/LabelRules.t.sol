// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {PageNFT} from "../../src/PageNFT.sol";
import {RulesBase} from "../utils/RulesBase.sol";

// The label rules at each of their edges, the referrer check, and commit at any time.
contract LabelRulesTest is RulesBase {
    function _rep(bytes1 c, uint256 n) internal pure returns (string memory) {
        bytes memory b = new bytes(n);
        for (uint256 i; i < n; ++i) b[i] = c;
        return string(b);
    }

    // A to Z are lowercased, Z included, by normalize and by computeNamehash
    function test_upperCaseEdges() public view {
        assertEq(nft.normalize("AZ"), "az");
        assertEq(nft.normalize("Z9-A"), "z9-a");
        assertEq(nft.computeNamehash("Z"), nft.computeNamehash("z"));
        assertEq(nft.computeNamehash("AZ.BZ"), nft.computeNamehash("az.bz"));
    }

    // 1 to 63 bytes
    function test_lengthEdges() public {
        assertEq(nft.normalize(_rep("a", 63)), _rep("a", 63));
        assertEq(nft.normalize("a"), "a");
        vm.expectRevert(PageNFT.InvalidLength.selector);
        nft.normalize(_rep("a", 64));
        vm.expectRevert(PageNFT.InvalidLength.selector);
        nft.normalize("");
    }

    // every byte outside A to Z, a to z, 0 to 9 and the hyphen is refused, tried at the bytes next to each of
    // those ranges and at four more
    function test_bytesOutsideTheSet() public {
        bytes1[12] memory bad = [bytes1(0x20), 0x21, 0x2b, 0x2c, 0x2e, 0x2f, 0x3a, 0x40, 0x5b, 0x5f, 0x60, 0x7b];
        for (uint256 i; i < bad.length; ++i) {
            bytes memory l = abi.encodePacked("a", bad[i], "b");
            vm.expectRevert(PageNFT.InvalidLabel.selector);
            nft.normalize(string(l));
        }
        assertEq(nft.normalize("a-0"), "a-0");
    }

    // hyphens: not first, not last, not in both the 3rd and 4th place, which needs 4 bytes or more
    function test_hyphenEdges() public {
        string[4] memory bad = ["-a", "a-", "ab--", "ab--c"];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(PageNFT.InvalidLabel.selector);
            nft.normalize(bad[i]);
        }
        assertEq(nft.normalize("a--b"), "a--b");
        assertEq(nft.normalize("ab-c"), "ab-c");
        assertEq(nft.normalize("abc-d"), "abc-d");
    }

    // only 0x and exactly 40 hex characters read as an address
    function test_addressFormEdges() public {
        string memory hex40 = _rep("a", 40);
        vm.expectRevert(PageNFT.InvalidLabel.selector);
        nft.normalize(string.concat("0x", hex40));
        // one more character, another first byte, another second byte, or a byte beyond f
        assertEq(nft.normalize(string.concat("0x", hex40, "a")), string.concat("0x", hex40, "a"));
        assertEq(nft.normalize(string.concat("1x", hex40)), string.concat("1x", hex40));
        assertEq(nft.normalize(string.concat("ax", hex40)), string.concat("ax", hex40));
        assertEq(nft.normalize(string.concat("0y", hex40)), string.concat("0y", hex40));
        assertEq(nft.normalize(string.concat("0z", hex40)), string.concat("0z", hex40));
        assertEq(nft.normalize(string.concat("00", hex40)), string.concat("00", hex40));
        assertEq(nft.normalize(string.concat("0a", hex40)), string.concat("0a", hex40));
        assertEq(nft.normalize(string.concat("0x", _rep("a", 39), "g")), string.concat("0x", _rep("a", 39), "g"));
        // the third character is checked too
        assertEq(nft.normalize(string.concat("0xg", _rep("a", 39))), string.concat("0xg", _rep("a", 39)));
        // a hyphen is not a hex character
        string memory h = string.concat("0x", _rep("a", 20), "-", _rep("b", 19));
        assertEq(nft.normalize(h), h);
    }

    // a referrer is refused only when it is the name itself, whatever its value
    function test_referrerAboveOrBelowTheId() public {
        uint256 id = uint256(keccak256(abi.encodePacked(nft.ROOT(), keccak256("alice"))));
        uint256[3] memory refs = [id + 1, type(uint256).max, id - 1];
        for (uint256 i; i < 3; ++i) {
            nft.makeCommitment("alice", bob, refs[i], bytes32(0));
        }
        vm.expectRevert(PageNFT.SelfReferral.selector);
        nft.makeCommitment("alice", bob, id, bytes32(0));
        uint256 got = _buy(bob, "alice", bob, id + 1);
        assertEq(got, id);
        assertEq(nft.referrerOf(id), id + 1);
    }

    // commit works at any block time, also in the first day after time zero
    function test_commitAtAnyTime() public {
        vm.warp(1000);
        nft.commit(keccak256("early"));
        assertEq(nft.commitments(keccak256("early")), 1000);
        // and the same commitment cannot be made again within the day
        vm.warp(1000 + 3600);
        vm.expectRevert(PageNFT.AlreadyCommitted.selector);
        nft.commit(keccak256("early"));
    }

    // a live subpage held by any account other than DEAD is taken, a small address included
    function test_subpageHeldBySmallAddressIsTaken() public {
        uint256 parent = _buy(bob, "alice");
        vm.prank(bob);
        nft.registerSubpageFor("sub", parent, address(0x1234));
        assertFalse(nft.isAvailable("sub", parent), "held by 0x1234");
        vm.prank(bob);
        nft.registerSubpageFor("one", parent, address(1));
        assertFalse(nft.isAvailable("one", parent), "held by 0x1");
    }

    // at the very start of time a name that was never registered is free
    function test_freeAtTimeZero() public {
        vm.warp(0);
        assertTrue(nft.isAvailable("fresh", 0));
    }

    // a first trial can start at any time, also within fourteen days of time zero
    function test_trialEarlyInTime() public {
        vm.warp(1);
        uint256 id = _trial("alice", bob);
        assertEq(nft.ownerOf(id), bob);
        assertEq(block.timestamp, 62);
    }
}

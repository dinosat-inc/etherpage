// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {PageNFT} from "../../src/PageNFT.sol";
import {RulesBase} from "../utils/RulesBase.sol";

// computeNamehash refuses only an empty label and a third label and lowercases only A to Z; every other byte,
// the bytes just below the dot and next to A and Z included, is hashed as it is, at any place in a label.
contract NamehashInputsTest is RulesBase {
    function _top(string memory l) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(nft.ROOT(), keccak256(bytes(l))));
    }

    function test_bytesBelowTheDotAtTheEdgesOfALabel() public view {
        string[9] memory labels = ["-a", "a-", "!", " x ", ",y#", "-", "@", "[", "a@[b"];
        for (uint256 i; i < labels.length; ++i) {
            assertEq(nft.computeNamehash(labels[i]), _top(labels[i]), labels[i]);
        }
        // a byte below the dot just before or after the dot of a subpage
        bytes32 parent = _top("y");
        assertEq(nft.computeNamehash("x-.y"), keccak256(abi.encodePacked(parent, keccak256("x-"))));
        assertEq(nft.computeNamehash("x.-y"), keccak256(abi.encodePacked(_top("-y"), keccak256("x"))));
        assertEq(nft.computeNamehash("!.,"), keccak256(abi.encodePacked(_top(","), keccak256("!"))));
    }

    function test_emptyLabelsStillRevert() public {
        vm.expectRevert(PageNFT.EmptyLabel.selector);
        nft.computeNamehash(".a");
        vm.expectRevert(PageNFT.EmptyLabel.selector);
        nft.computeNamehash("a.");
        vm.expectRevert(PageNFT.EmptyLabel.selector);
        nft.computeNamehash("a..b");
    }
}

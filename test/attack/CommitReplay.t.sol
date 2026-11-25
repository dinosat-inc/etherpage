// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {PageNFT} from "../../src/PageNFT.sol";
import {RulesBase} from "../utils/RulesBase.sol";

// a receiving contract that reads one commitment from inside the mint hook
contract CommitmentReader {
    PageNFT public nft;
    bytes32 public watched;
    uint256 public seen;
    bool public called;

    function arm(PageNFT n, bytes32 c) external {
        nft = n;
        watched = c;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        seen = nft.commitments(watched);
        called = true;
        return this.onERC721Received.selector;
    }
}

// A paid reveal deletes its commitment before it hands control to anyone, so a second reveal of the
// same values finds no commitment, even once the name is free again, unless someone commits them again.
contract CommitReplayTest is RulesBase {
    function test_commitReplayAfterConsumption() public {
        CommitmentReader reader = new CommitmentReader();
        string memory l = "replayme";
        bytes32 secret = _s(l, address(reader), 0);
        bytes32 c = nft.makeCommitment(l, address(reader), 0, secret);
        reader.arm(nft, c);
        vm.prank(bob);
        nft.commit(c);
        vm.warp(vm.getBlockTimestamp() + 61);
        (,,, uint256 total) = nft.quote(l);
        vm.prank(bob);
        uint256 id = nft.reveal{value: total}(l, address(reader), 0, secret);
        assertTrue(reader.called(), "the mint ran the receiver hook");
        assertEq(reader.seen(), 0, "the commitment was gone before the hook ran");
        assertEq(nft.commitments(c), 0);

        // a second reveal of it, paid enough for any price check, finds no commitment
        uint256 enough = total + nft.depositOf(id) + 1 ether;
        vm.prank(bob);
        vm.expectRevert(PageNFT.CommitmentNotFound.selector);
        nft.reveal{value: enough}(l, address(reader), 0, secret);

        // nor once the name is free again
        vm.warp(nft.expiresAt(id) + 90 days + 21 days + 1);
        assertTrue(nft.isAvailable(l, 0));
        (,,, total) = nft.quote(l);
        vm.prank(bob);
        vm.expectRevert(PageNFT.CommitmentNotFound.selector);
        nft.reveal{value: total}(l, address(reader), 0, secret);
        assertEq(nft.ownerOf(id), address(reader));
    }
}

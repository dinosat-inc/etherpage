// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {PageNFT} from "../../src/PageNFT.sol";
import {RulesBase} from "../utils/RulesBase.sol";

// The money logs of an auction and of a renewal carry each value in its own place.
contract EventArgsTest is RulesBase {
    function test_auctionLogs() public {
        uint256 ref = _buy(carol, "carolname");
        uint256 id = _buy(bob, "alice", bob, ref);
        // keep the referrer live, and dave buys alice in its premium window
        vm.prank(carol);
        nft.renew{value: FEE5}(ref);
        vm.warp(nft.expiresAt(id) + 90 days + 3 days);
        string memory l = "alice";
        bytes32 commitment = nft.makeCommitment(l, dave, 0, _s(l, dave, 0));
        vm.prank(dave);
        nft.commit(commitment);
        vm.warp(block.timestamp + 61);
        uint256 premium = nft.getPremium(id);
        uint256 carried = nft.depositOf(id);
        uint256 refShare = premium * 2500 / 10_000;
        assertGt(refShare, 0);
        vm.expectEmit(true, true, true, true, address(nft));
        emit PageNFT.DepositBoughtOut(id, bob, carried);
        vm.expectEmit(true, true, true, true, address(nft));
        emit PageNFT.ReferrerPremiumCredited(id, ref, carol, refShare);
        vm.expectEmit(true, true, true, true, address(nft));
        emit PageNFT.OwnerPremiumCredited(id, bob, premium - refShare);
        vm.prank(dave);
        nft.reveal{value: FEE5 + carried + premium}(l, dave, 0, _s(l, dave, 0));
        assertEq(nft.owed(carol), refShare);
        assertEq(nft.owed(bob), carried + premium - refShare);
    }

    function test_renewLogs() public {
        uint256 id = _buy(bob, "alice");
        uint256 before = nft.depositOf(id);
        vm.expectEmit(true, true, true, true, address(nft));
        emit PageNFT.DepositAdded(id, carol, FEE5, before + FEE5);
        vm.expectEmit(true, true, true, true, address(nft));
        emit PageNFT.PageRenewed(id, nft.expiresAt(id) + 365 days);
        vm.prank(carol);
        nft.renew{value: FEE5}(id);
    }

    // a registration paid by one account for another logs the payer, and commit logs the committer
    function test_payerAndCommitterLogs() public {
        string memory l = "alice";
        bytes32 c = nft.makeCommitment(l, bob, 0, _s(l, bob, 0));
        vm.expectEmit(true, true, false, true, address(nft));
        emit PageNFT.Committed(c, carol);
        vm.prank(carol);
        nft.commit(c);
        vm.warp(block.timestamp + 61);
        uint256 id = uint256(keccak256(abi.encodePacked(nft.ROOT(), keccak256(bytes(l)))));
        vm.expectEmit(true, true, false, true, address(nft));
        emit PageNFT.DepositAdded(id, carol, FEE5, FEE5);
        vm.prank(carol);
        nft.reveal{value: FEE5}(l, bob, 0, _s(l, bob, 0));
        assertEq(nft.ownerOf(id), bob);
    }
}

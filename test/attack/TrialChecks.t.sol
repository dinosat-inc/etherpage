// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {trialCommitmentRaw} from "../utils/TrialCommitment.sol";

import {PageNFT} from "../../src/PageNFT.sol";
import {TrialBase} from "../utils/TrialBase.sol";

// trials: their own commitment form, the display name cleared when a trial moves, and an ended
// trial that answers nothing and stays in the wallet until someone takes the name
contract TrialChecksTest is TrialBase {
    // a trial consumes only its own commitment form, once, and a plain form for the same tuple stays
    // behind but cannot take the live name
    function test_trialConsumesOnlyItsOwnForm() public {
        bytes32 plain = nft.makeCommitment("alice", user, 0, _secret("alice", user));
        _commit(bob, "alice", user);
        _commitTrial(relayer, "alice", user);
        vm.warp(vm.getBlockTimestamp() + 61);
        vm.prank(relayer);
        uint256 id = nft.revealTrial{value: PRICE5}("alice", user, 0, _secret("alice", user));
        assertEq(nft.commitments(trialCommitmentRaw("alice", user, 0, _secret("alice", user))), 0, "the trial form is consumed");
        assertGt(nft.commitments(plain), 0, "the plain form is untouched");
        vm.prank(bob);
        vm.expectRevert(PageNFT.AlreadyRegistered.selector);
        nft.reveal{value: FEE5}("alice", user, 0, _secret("alice", user));
        vm.prank(relayer);
        vm.expectRevert(PageNFT.CommitmentNotFound.selector);
        nft.revealTrial{value: PRICE5}("alice", user, 0, _secret("alice", user));
        assertEq(nft.ownerOf(id), user);
        assertEq(nft.owed(DEAD), 0);
        (, uint256 held) = nft.trialPaymentOf(id);
        assertEq(held, PRICE5);
    }

    // throwing an unwanted trial away clears the holder's display name, and the name stays blocked
    // until its fourteen days end
    function test_throwingATrialAwayClearsTheDisplayName() public {
        uint256 id = _trial("alice", user);
        vm.prank(user);
        nft.setPrimaryPage(id);
        assertEq(nft.reverseResolve(user), "alice");
        vm.prank(user);
        nft.transferFrom(user, DEAD, id);
        assertEq(nft.primaryPage(user), 0);
        assertEq(nft.reverseResolve(user), "");
        assertEq(nft.ownerOf(id), DEAD);
        assertFalse(nft.isAvailable("alice", 0));
        vm.warp(nft.expiresAt(id) + 1);
        assertTrue(nft.isAvailable("alice", 0));
        assertEq(nft.resolve(id), address(0), "a lapsed trial answers nothing");
    }

    // once paid, a trial moves like any name, and the sender's display name is cleared
    function test_convertedTrialMovesLikeAnyName() public {
        uint256 id = _trial("alice", user);
        vm.prank(user);
        nft.setPrimaryPage(id);
        vm.prank(user);
        vm.expectRevert(PageNFT.Unpaid.selector);
        nft.transferFrom(user, bob, id);
        vm.prank(relayer);
        nft.renew{value: FEE5}(id);
        vm.prank(user);
        nft.transferFrom(user, bob, id);
        assertEq(nft.ownerOf(id), bob);
        assertEq(nft.primaryPage(user), 0);
        assertEq(nft.resolve(id), bob);
        assertEq(nft.depositOf(id), FEE5);
    }

    // a lapsed trial answers nothing until someone takes the name, so money sent in that gap fails
    // to resolve instead of reaching anyone
    function test_lapsedTrialAnswersNothing() public {
        uint256 id = _trial("alice", user);
        vm.prank(user);
        nft.setAddr(id, carol);
        uint256 e = nft.expiresAt(id);
        vm.warp(e);
        assertEq(nft.resolve(id), carol);
        vm.warp(e + 1);
        assertEq(nft.resolve(id), address(0));
        assertEq(nft.addr(bytes32(id)), address(0));
        assertEq(nft.addr(bytes32(id), 60).length, 0);
        assertEq(nft.ownerOf(id), user, "the expired NFT stays in the wallet");
    }

    // an unwanted trial can be thrown away only during its fourteen days; after that the expired NFT
    // stays in the wallet until someone takes the name, which burns it from there
    function test_unwantedTrialStaysAfterTheFourteenDaysUntilTaken() public {
        uint256 id = _trial("alice", user);
        uint256 e = nft.expiresAt(id);
        vm.warp(e + 1);
        vm.prank(user);
        vm.expectRevert(PageNFT.Expired.selector);
        nft.transferFrom(user, DEAD, id);
        assertEq(nft.balanceOf(user), 1);
        _commit(bob, "alice", bob);
        vm.warp(vm.getBlockTimestamp() + 61);
        _revealPaid(bob, "alice");
        assertEq(nft.balanceOf(user), 0);
        assertEq(nft.ownerOf(id), bob);
    }
}

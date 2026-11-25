// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {trialCommitment} from "../../utils/TrialCommitment.sol";

import {PageNFT} from "../../../src/PageNFT.sol";
import {TrialBase} from "../../utils/TrialBase.sol";

// the sponsored trial next to multicall, which is not payable
contract TrialMulticallTest is TrialBase {
    // multicall carries no ETH, so a trial inside a bundle cannot pay its price and reverts
    function test_trialInsideABundleCannotPay() public {
        _commitTrial(relayer, "alice", user);
        vm.warp(vm.getBlockTimestamp() + 61);
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeCall(PageNFT.revealTrial, ("alice", user, 0, _secret("alice", user)));
        vm.prank(relayer);
        vm.expectRevert(PageNFT.InsufficientFee.selector);
        nft.multicall(calls);
        vm.prank(relayer);
        (bool ok,) = address(nft).call{value: PRICE5}(abi.encodeCall(PageNFT.multicall, (calls)));
        assertFalse(ok, "multicall refuses ETH");
    }

    // a paid reveal in a bundle carries no ETH either, so it reverts InsufficientFee
    function test_paidRevealInsideABundleIsNotATrial() public {
        vm.deal(user, 1 ether);
        _commit(user, "alice", user);
        vm.warp(vm.getBlockTimestamp() + 61);
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeCall(PageNFT.reveal, ("alice", user, 0, _secret("alice", user)));
        vm.prank(user);
        vm.expectRevert(PageNFT.InsufficientFee.selector);
        nft.multicall(calls);
        assertEq(nft.owed(DEAD), 0);
    }

    // over a name in grace a trial stops at its own refusal and a paid reveal at the price, so the error of a
    // bundle shows the mode its entry ran in, which is the mode of the entry's own selector
    function test_bundledEntryRunsInTheModeOfItsSelector() public {
        uint256 id = _buy(bob, "vault");
        vm.warp(nft.expiresAt(id) + 30 days);
        assertTrue(nft.inGracePeriod(id));
        bytes32 s = _secret("vault", carol);
        bytes32 paid = nft.makeCommitment("vault", carol, 0, s);
        bytes32 trial = trialCommitment(address(nft), "vault", carol, 0, s);
        _commit(relayer, "vault", carol);
        _commitTrial(relayer, "vault", carol);
        uint256 committedAt = vm.getBlockTimestamp();
        vm.warp(committedAt + 61);

        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeCall(PageNFT.revealTrial, ("vault", carol, 0, s));
        vm.prank(relayer);
        vm.expectRevert(PageNFT.TrialNotAllowed.selector);
        nft.multicall(calls);
        calls[0] = abi.encodeCall(PageNFT.reveal, ("vault", carol, 0, s));
        vm.prank(relayer);
        vm.expectRevert(PageNFT.InsufficientFee.selector);
        nft.multicall(calls);

        // called directly, the two entries stop at the same two places
        vm.prank(relayer);
        vm.expectRevert(PageNFT.TrialNotAllowed.selector);
        nft.revealTrial{value: PRICE5}("vault", carol, 0, s);
        vm.prank(relayer);
        vm.expectRevert(PageNFT.InsufficientFee.selector);
        nft.reveal("vault", carol, 0, s);

        assertEq(nft.commitments(paid), committedAt, "the paid commitment is still there");
        assertEq(nft.commitments(trial), committedAt, "and so is the trial one");
        assertEq(nft.ownerOf(id), bob);
    }

    // the holder of a trial can set everything in one bundle
    function test_holderBundlesRecordsDuringTheTrial() public {
        uint256 id = _trial("alice", user);
        bytes[] memory calls = new bytes[](3);
        calls[0] = abi.encodeCall(PageNFT.setText, (id, "avatar", "ipfs://x"));
        calls[1] = abi.encodeCall(PageNFT.setAddr, (id, carol));
        calls[2] = abi.encodeWithSignature("setPrimaryPage(uint256)", id);
        vm.prank(user);
        nft.multicall(calls);
        assertEq(nft.text(id, "avatar"), "ipfs://x");
        assertEq(nft.resolve(id), carol);
        assertEq(nft.primaryPage(user), id);
    }

    // a bundle cannot move an unpaid name either
    function test_bundleCannotMoveATrial() public {
        uint256 id = _trial("alice", user);
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeCall(PageNFT.transferFrom, (user, bob, id));
        vm.prank(user);
        vm.expectRevert(PageNFT.Unpaid.selector);
        nft.multicall(calls);
    }
}

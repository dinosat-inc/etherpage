// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {trialCommitmentRaw} from "../../utils/TrialCommitment.sol";

import {Test} from "forge-std/Test.sol";
import {PageNFT} from "../../../src/PageNFT.sol";
import {PageCard} from "../../../src/PageCard.sol";

// A commitment binds the owner, the referrer and the secret it was made with. A reveal that changes any one
// of them finds no commitment, on the paid path and on the trial path; the commitment stays, and the
// committed values still register the name.
contract CommitmentBindingTest is Test {
    PageNFT nft;
    address relayer = makeAddr("relayer");
    string constant L = "alpha";

    function setUp() public {
        vm.warp(1_800_000_000);
        nft = new PageNFT(new PageCard());
        vm.deal(relayer, 10 ether);
    }

    // an owner that can take a plain mint
    function _keyWallet(address a) internal view {
        vm.assume(uint160(a) > 0xffff && a.code.length == 0 && a != address(vm) && a != relayer);
    }

    function testFuzz_paidCommitmentBindsOwnerReferrerAndSecret(
        address owner,
        address owner2,
        uint256 ref,
        uint256 ref2,
        bytes32 secret,
        bytes32 secret2
    ) public {
        uint256 id = nft.computeId(L);
        _keyWallet(owner);
        vm.assume(owner2 != owner && ref != id && ref2 != id && ref2 != ref && secret2 != secret);
        bytes32 c = nft.makeCommitment(L, owner, ref, secret);
        vm.prank(relayer);
        nft.commit(c);
        uint256 t = vm.getBlockTimestamp();
        vm.warp(t + 61);
        uint256 fee = nft.getFee(bytes(L).length);

        vm.prank(relayer);
        vm.expectRevert(PageNFT.CommitmentNotFound.selector);
        nft.reveal{value: fee}(L, owner2, ref, secret);
        vm.prank(relayer);
        vm.expectRevert(PageNFT.CommitmentNotFound.selector);
        nft.reveal{value: fee}(L, owner, ref2, secret);
        vm.prank(relayer);
        vm.expectRevert(PageNFT.CommitmentNotFound.selector);
        nft.reveal{value: fee}(L, owner, ref, secret2);
        assertEq(nft.commitments(c), t, "the commitment is still there");

        vm.prank(relayer);
        assertEq(nft.reveal{value: fee}(L, owner, ref, secret), id);
        assertEq(nft.ownerOf(id), owner);
        assertEq(nft.referrerOf(id), ref);
        assertEq(nft.depositOf(id), fee);
        assertEq(nft.commitments(c), 0, "used up");
    }

    function testFuzz_trialCommitmentBindsOwnerReferrerAndSecret(
        address owner,
        address owner2,
        uint256 ref,
        uint256 ref2,
        bytes32 secret,
        bytes32 secret2
    ) public {
        uint256 id = nft.computeId(L);
        _keyWallet(owner);
        vm.assume(owner2 != owner && ref != id && ref2 != id && ref2 != ref && secret2 != secret);
        bytes32 c = trialCommitmentRaw(L, owner, ref, secret);
        vm.prank(relayer);
        nft.commit(c);
        uint256 t = vm.getBlockTimestamp();
        vm.warp(t + 61);
        uint256 price = nft.getFee(bytes(L).length) / 10;

        vm.prank(relayer);
        vm.expectRevert(PageNFT.CommitmentNotFound.selector);
        nft.revealTrial{value: price}(L, owner2, ref, secret);
        vm.prank(relayer);
        vm.expectRevert(PageNFT.CommitmentNotFound.selector);
        nft.revealTrial{value: price}(L, owner, ref2, secret);
        vm.prank(relayer);
        vm.expectRevert(PageNFT.CommitmentNotFound.selector);
        nft.revealTrial{value: price}(L, owner, ref, secret2);
        assertEq(nft.commitments(c), t, "the commitment is still there");

        vm.prank(relayer);
        assertEq(nft.revealTrial{value: price}(L, owner, ref, secret), id);
        assertEq(nft.ownerOf(id), owner);
        assertEq(nft.referrerOf(id), ref);
        (address payer, uint96 held) = nft.trialPaymentOf(id);
        assertEq(payer, relayer);
        assertEq(held, price);
        assertEq(nft.commitments(c), 0, "used up");
    }
}

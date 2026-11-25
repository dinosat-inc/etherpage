// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {trialCommitment, trialCommitmentRaw} from "../utils/TrialCommitment.sol";

import {PageNFT} from "../../src/PageNFT.sol";
import {TrialBase} from "../utils/TrialBase.sol";

// a bot that watches every public commitment and every failed reveal, and tries to turn a paid
// registration into a trial
contract TrialCommitmentTest is TrialBase {
    address bot = makeAddr("bot");
    string constant L = "alice-smith";
    uint256 constant DERIVED = 6;

    function setUp() public override {
        super.setUp();
        vm.deal(bot, 1000 ether);
        vm.deal(user, 1 ether);
    }

    // values the bot can make from a paid commitment alone, without the label, owner, referrer or secret
    function _derived(bytes32 c, uint256 k, bytes32 salt) internal pure returns (bytes32) {
        k %= DERIVED;
        if (k == 0) return ~c;
        if (k == 1) return keccak256(abi.encode(c));
        if (k == 2) return keccak256(abi.encode(c, true));
        if (k == 3) return c ^ salt;
        if (k == 4) {
            unchecked {
                return bytes32(uint256(c) + uint256(salt));
            }
        }
        return keccak256(abi.encode(c, salt));
    }

    function _commitPaid(address owner) internal returns (bytes32 paid, uint256 t0) {
        paid = nft.makeCommitment(L, owner, 0, _secret(L, owner));
        vm.prank(owner);
        nft.commit(paid);
        t0 = vm.getBlockTimestamp();
    }

    function _assertPaidYear(uint256 id, address owner, uint256 start) internal view {
        assertEq(nft.ownerOf(id), owner);
        assertEq(nft.depositOf(id), FEE5);
        assertEq(nft.expiresAt(id), start + 365 days);
        (address p, uint96 a) = nft.trialPaymentOf(id);
        assertEq(p, address(0));
        assertEq(a, 0);
    }

    // the bot commits the bitwise NOT of the paid commitment and other values made from it as soon as it
    // sees the commit; the user's reveal is sent a second early and fails, which makes its values public
    function test_valuesMadeFromThePaidCommitmentCannotStartATrial() public {
        (bytes32 paid, uint256 t0) = _commitPaid(user);
        bytes32 tc = trialCommitmentRaw(L, user, 0, _secret(L, user));
        bytes32[DERIVED] memory ds;
        for (uint256 k; k < DERIVED; ++k) {
            ds[k] = _derived(paid, k, bytes32(uint256(7)));
            assertTrue(ds[k] != tc && ds[k] != paid);
            vm.prank(bot);
            nft.commit(ds[k]);
        }
        vm.warp(t0 + 19);
        vm.prank(user);
        vm.expectRevert(PageNFT.CommitmentTooNew.selector);
        nft.reveal{value: FEE5}(L, user, 0, _secret(L, user));
        // 20 seconds after the commit every value the bot committed is ripe, and none of them starts a trial
        vm.warp(t0 + 20);
        for (uint256 k; k < DERIVED; ++k) assertEq(nft.commitments(ds[k]), t0);
        vm.prank(bot);
        vm.expectRevert(PageNFT.CommitmentNotFound.selector);
        nft.revealTrial{value: PRICE5}(L, user, 0, _secret(L, user));
        // the user's retry in the same second wins a paid year
        vm.prank(user);
        _assertPaidYear(nft.reveal{value: FEE5}(L, user, 0, _secret(L, user)), user, t0 + 20);
    }

    // the same for any value made from the paid commitment, and a failed reveal at any time in its day
    function testFuzz_valueMadeFromThePaidCommitmentCannotStartATrial(uint256 k, bytes32 salt, uint256 leakAt)
        public
    {
        (bytes32 paid, uint256 t0) = _commitPaid(user);
        bytes32 d = _derived(paid, k, salt);
        vm.assume(d != paid && d != trialCommitmentRaw(L, user, 0, _secret(L, user)));
        vm.prank(bot);
        nft.commit(d);
        leakAt = bound(leakAt, 20, 86400);
        vm.warp(t0 + leakAt);
        // the user's reveal fails for too little money
        vm.prank(user);
        vm.expectRevert(PageNFT.InsufficientFee.selector);
        nft.reveal{value: FEE5 - 1}(L, user, 0, _secret(L, user));
        vm.prank(bot);
        vm.expectRevert(PageNFT.CommitmentNotFound.selector);
        nft.revealTrial{value: PRICE5}(L, user, 0, _secret(L, user));
        vm.prank(user);
        _assertPaidYear(nft.reveal{value: FEE5}(L, user, 0, _secret(L, user)), user, t0 + leakAt);
    }

    // after the leak the bot commits the true trial form, which must wait 20 seconds, and the user's
    // retry with the ripe paid commitment wins before it ripens
    function test_trueTrialFormAfterALeakWaitsAndLoses() public {
        (, uint256 t0) = _commitPaid(user);
        vm.warp(t0 + 19);
        vm.prank(user);
        vm.expectRevert(PageNFT.CommitmentTooNew.selector);
        nft.reveal{value: FEE5}(L, user, 0, _secret(L, user));
        _commitTrial(bot, L, user);
        vm.warp(t0 + 20);
        vm.prank(bot);
        vm.expectRevert(PageNFT.CommitmentTooNew.selector);
        nft.revealTrial{value: PRICE5}(L, user, 0, _secret(L, user));
        vm.prank(user);
        uint256 id = nft.reveal{value: FEE5}(L, user, 0, _secret(L, user));
        _assertPaidYear(id, user, t0 + 20);
        // once the bot's trial form is ripe the name holds a deposit, so no trial is possible
        vm.warp(t0 + 19 + 20);
        vm.prank(bot);
        vm.expectRevert(PageNFT.TrialNotAllowed.selector);
        nft.revealTrial{value: PRICE5}(L, user, 0, _secret(L, user));
        _assertPaidYear(id, user, t0 + 20);
    }

    // the same for a leak at any time after the commit and a retry up to 19 seconds later that still falls inside
    // the day of the commitment; after that day the retry is too old, as AcceptedLateRevealTest shows
    function testFuzz_trueTrialFormAfterALeakLosesToAnImmediateRetry(uint256 leakAt, uint256 delay) public {
        (, uint256 t0) = _commitPaid(user);
        delay = bound(delay, 0, 19);
        leakAt = bound(leakAt, 1, 86400 - delay);
        uint256 retryAt = leakAt + delay;
        if (retryAt < 20) retryAt = 20;
        vm.warp(t0 + leakAt);
        vm.prank(user);
        vm.expectRevert(leakAt < 20 ? PageNFT.CommitmentTooNew.selector : PageNFT.InsufficientFee.selector);
        nft.reveal{value: leakAt < 20 ? FEE5 : FEE5 - 1}(L, user, 0, _secret(L, user));
        _commitTrial(bot, L, user);
        vm.warp(t0 + retryAt);
        vm.prank(bot);
        vm.expectRevert(PageNFT.CommitmentTooNew.selector);
        nft.revealTrial{value: PRICE5}(L, user, 0, _secret(L, user));
        vm.prank(user);
        _assertPaidYear(nft.reveal{value: FEE5}(L, user, 0, _secret(L, user)), user, t0 + retryAt);
    }

    function _owner(address owner) internal view {
        vm.assume(owner != address(0) && owner.code.length == 0 && owner != DEAD);
    }

    // a paid commitment never serves revealTrial, and the same commitment still serves reveal
    function testFuzz_paidCommitmentNeverServesATrial(address owner, uint256 ref, bytes32 secret) public {
        _owner(owner);
        vm.assume(ref != nft.computeId(L));
        bytes32 commitment = nft.makeCommitment(L, owner, ref, secret);
        vm.prank(relayer);
        nft.commit(commitment);
        vm.warp(vm.getBlockTimestamp() + 61);
        vm.prank(relayer);
        vm.expectRevert(PageNFT.CommitmentNotFound.selector);
        nft.revealTrial{value: PRICE5}(L, owner, ref, secret);
        vm.prank(relayer);
        uint256 id = nft.reveal{value: FEE5}(L, owner, ref, secret);
        assertEq(nft.ownerOf(id), owner);
        assertEq(nft.depositOf(id), FEE5);
    }

    // a trial commitment never serves reveal, and the same commitment still serves revealTrial
    function testFuzz_trialCommitmentNeverServesAPaidYear(address owner, uint256 ref, bytes32 secret) public {
        _owner(owner);
        vm.assume(ref != nft.computeId(L));
        bytes32 commitment = trialCommitment(address(nft), L, owner, ref, secret);
        vm.prank(relayer);
        nft.commit(commitment);
        vm.warp(vm.getBlockTimestamp() + 61);
        vm.prank(relayer);
        vm.expectRevert(PageNFT.CommitmentNotFound.selector);
        nft.reveal{value: FEE5}(L, owner, ref, secret);
        vm.prank(relayer);
        uint256 id = nft.revealTrial{value: PRICE5}(L, owner, ref, secret);
        assertEq(nft.ownerOf(id), owner);
        (address p, uint96 a) = nft.trialPaymentOf(id);
        assertEq(p, relayer);
        assertEq(a, PRICE5);
    }

    // the trial commitment hashes the label in lowercase, as makeCommitment does
    function test_trialCommitmentUsesTheLabelInLowercase() public {
        bytes32 s = _secret(L, user);
        vm.prank(relayer);
        nft.commit(keccak256(abi.encode(bytes("Alice-Smith"), user, uint256(0), s, true)));
        vm.warp(vm.getBlockTimestamp() + 61);
        vm.prank(relayer);
        vm.expectRevert(PageNFT.CommitmentNotFound.selector);
        nft.revealTrial{value: PRICE5}("Alice-Smith", user, 0, s);
        vm.prank(relayer);
        nft.commit(keccak256(abi.encode(bytes("alice-smith"), user, uint256(0), s, true)));
        vm.warp(vm.getBlockTimestamp() + 61);
        vm.prank(relayer);
        uint256 id = nft.revealTrial{value: PRICE5}("Alice-Smith", user, 0, s);
        assertEq(nft.ownerOf(id), user);
        assertEq(id, nft.computeId(L));
    }

    // a paid preimage starts with 0x80, the offset of the label after four words, and a trial preimage
    // with 0xa0, after five, so the two preimages always differ and their hashes never collide
    function testFuzz_trialAndPaidCommitmentsNeverCollide(
        bytes memory l1,
        address o1,
        uint256 r1,
        bytes32 s1,
        bytes memory l2,
        address o2,
        uint256 r2,
        bytes32 s2
    ) public pure {
        bytes memory p1 = abi.encode(l1, o1, r1, s1);
        bytes memory p2 = abi.encode(l2, o2, r2, s2);
        bytes memory t1 = abi.encode(l1, o1, r1, s1, true);
        bytes memory t2 = abi.encode(l2, o2, r2, s2, true);
        assertEq(uint256(bytes32(p1)), 0x80);
        assertEq(uint256(bytes32(p2)), 0x80);
        assertEq(uint256(bytes32(t1)), 0xa0);
        assertEq(uint256(bytes32(t2)), 0xa0);
        assertNotEq(keccak256(p1), keccak256(t1));
        assertNotEq(keccak256(p1), keccak256(t2));
        assertNotEq(keccak256(p2), keccak256(t1));
        assertNotEq(keccak256(p2), keccak256(t2));
    }

    // the same through the contract, for valid labels in any case
    function testFuzz_contractCommitmentsNeverCollide(
        uint8 i1,
        address o1,
        uint256 r1,
        bytes32 s1,
        uint8 i2,
        address o2,
        uint256 r2,
        bytes32 s2
    ) public view {
        string[4] memory labels = ["alice-smith", "Alice-Smith", "bob", "x9-z"];
        string memory l1 = labels[i1 % 4];
        string memory l2 = labels[i2 % 4];
        vm.assume(r1 != nft.computeId(l1) && r2 != nft.computeId(l2));
        bytes32 p1 = nft.makeCommitment(l1, o1, r1, s1);
        bytes32 p2 = nft.makeCommitment(l2, o2, r2, s2);
        bytes32 t1 = trialCommitment(address(nft), l1, o1, r1, s1);
        bytes32 t2 = trialCommitment(address(nft), l2, o2, r2, s2);
        assertNotEq(p1, t1);
        assertNotEq(p1, t2);
        assertNotEq(p2, t1);
        assertNotEq(p2, t2);
    }
}

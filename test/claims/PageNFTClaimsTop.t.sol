// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {trialCommitmentRaw} from "../utils/TrialCommitment.sol";

import {PageNFT} from "../../src/PageNFT.sol";
import {ProfileBase} from "../utils/ProfileBase.sol";

// Claims of PageNFT from the top of the file through isAvailable, checked at their edges. A name registered again
// by the account that held it reads empty on every chain, a trial reveal needs 20 seconds and still works after
// exactly one day, and a label under a paid parent is free up to the parent's expiry second.
contract PageNFTClaimsTopTest is ProfileBase {
    uint256 constant BASE = 0x80002105;
    uint256 constant ARB = 0x8000a4b1;
    uint256 constant COIN_OP = 0x8000000a;
    uint256 constant DEFAULT_EVM = 0x80000000;

    address savedMain = makeAddr("savedMain");
    address savedEthereum = makeAddr("savedEthereum");
    address savedBase = makeAddr("savedBase");
    address savedDefault = makeAddr("savedDefault");

    // the holder saves a profile, a main address, addresses for coin type 60, Base and Bitcoin and a default for every
    // EVM chain, and each one counts
    function _saveAll(address who, uint256 id) internal {
        _write(who, id);
        vm.startPrank(who);
        nft.setAddr(id, savedMain);
        nft.setAddrForCoin(id, 60, abi.encodePacked(savedEthereum));
        nft.setAddrForCoin(id, BASE, abi.encodePacked(savedBase));
        nft.setAddrForCoin(id, DEFAULT_EVM, abi.encodePacked(savedDefault));
        vm.stopPrank();
        _assertFull(id);
        assertEq(nft.resolve(id), savedMain, "main address saved");
        assertEq(nft.addr(id, COIN_OP), abi.encodePacked(savedMain), "OP saved");
        assertEq(nft.addr(id, 60), abi.encodePacked(savedEthereum), "Ethereum saved");
        assertEq(nft.addr(id, BASE), abi.encodePacked(savedBase), "Base saved");
        assertEq(nft.addr(id, ARB), abi.encodePacked(savedDefault), "default saved");
        assertEq(nft.addr(id, BTC), bytes("bc1qalice"), "Bitcoin saved");
    }

    // the new registration of the same holder shows nothing saved before: the home chain answers the holder, and every
    // other chain answers empty
    function _assertAllEmpty(address who, uint256 id) internal view {
        assertEq(nft.ownerOf(id), who, "the same holder");
        assertEq(nft.epochOf(id), 2, "a second registration");
        assertEq(nft.recordVersion(id), 1, "the version went up");
        _assertEmpty(id);
        assertEq(nft.resolve(id), who, "main address");
        assertEq(nft.addr(id, COIN_OP), abi.encodePacked(who), "OP");
        assertEq(nft.addr(id, 60), "", "coin type 60");
        assertEq(nft.addr(id, BASE), "", "Base");
        assertEq(nft.addr(id, ARB), "", "a chain with only the default");
        assertEq(nft.addr(id, DEFAULT_EVM), "", "the default");
        assertEq(nft.addr(id, BTC), "", "Bitcoin");
    }

    // the holder registers its lapsed name again, paid or as a new trial, and nothing it saved before counts
    function test_sameHolderRegisteringAgainReadsEmptyOnEveryChain() public {
        uint256 paid = _paid(bob, "multi");
        uint256 tried = _trial("tryme", bob);
        _saveAll(bob, paid);
        _saveAll(bob, tried);

        // a new trial once the first one has ended and the pause is over
        vm.warp(nft.expiresAt(tried) + PAUSE + 1);
        assertEq(_trial("tryme", bob), tried);
        _assertAllEmpty(bob, tried);

        // a paid registration past grace and the premium window
        _lapseAndBuy(paid, bob, "multi");
        _assertAllEmpty(bob, paid);
    }

    // a trial reveal is refused 19 seconds after its commitment and taken at 20
    function test_trialRevealNeedsTwentySeconds() public {
        bytes32 s = _s("alpha", user, 0);
        _commitTrial(relayer, "alpha", user, 0);
        uint256 t0 = vm.getBlockTimestamp();
        vm.warp(t0 + 19);
        vm.prank(relayer);
        vm.expectRevert(PageNFT.CommitmentTooNew.selector);
        nft.revealTrial{value: PRICE5}("alpha", user, 0, s);
        vm.warp(t0 + 20);
        vm.prank(relayer);
        uint256 id = nft.revealTrial{value: PRICE5}("alpha", user, 0, s);
        assertEq(nft.ownerOf(id), user);
        assertEq(nft.expiresAt(id), t0 + 20 + TRIAL);
        assertEq(_heldAmount(id), PRICE5);
    }

    // a trial reveal still works exactly one day after its commitment, and uses it up
    function test_trialRevealStillWorksAfterExactlyOneDay() public {
        bytes32 s = _s("alpha", user, 0);
        bytes32 c = trialCommitmentRaw("alpha", user, 0, s);
        _commitTrial(relayer, "alpha", user, 0);
        uint256 t0 = vm.getBlockTimestamp();
        assertEq(nft.commitments(c), t0);
        vm.warp(t0 + 86400);
        vm.prank(relayer);
        uint256 id = nft.revealTrial{value: PRICE5}("alpha", user, 0, s);
        assertEq(nft.ownerOf(id), user);
        assertEq(nft.expiresAt(id), t0 + 86400 + TRIAL);
        assertEq(nft.commitments(c), 0, "the commitment is used up");
    }

    // a label under a paid parent is free at the parent's expiry second and not one second later, as the mint finds
    function test_subpageFreeUntilTheParentsLastSecond() public {
        uint256 p = _buy(bob, "club");
        uint256 e = nft.expiresAt(p);
        vm.warp(e);
        assertTrue(nft.isAvailable("x", p), "free at the parent's last second");
        uint256 snap = vm.snapshotState();
        vm.prank(bob);
        uint256 sub = nft.registerSubpage("x", p);
        assertEq(nft.ownerOf(sub), bob);
        vm.revertToState(snap);
        vm.warp(e + 1);
        assertFalse(nft.isAvailable("x", p), "not free once the parent has expired");
        vm.prank(bob);
        vm.expectRevert(PageNFT.Expired.selector);
        nft.registerSubpage("x", p);
    }
}

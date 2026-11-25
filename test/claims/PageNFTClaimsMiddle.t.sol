// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {trialCommitmentRaw} from "../utils/TrialCommitment.sol";

import {PageNFT} from "../../src/PageNFT.sol";
import {PageCard} from "../../src/PageCard.sol";
import {RulesBase} from "../utils/RulesBase.sol";

// A commitment made again once it is used, records of an earlier registration that stay empty when their saver
// gets the name back, a credit meant for the PageNFT itself that goes to the dead address, and the expiry and grace
// views of a trial and of a subpage.
contract PageNFTClaimsMiddleTest is RulesBase {
    uint256 constant COIN_OP = 0x8000000a;
    uint256 constant COIN_BASE = 0x80002105;
    uint256 constant COIN_ARB = 0x8000a4b1;
    uint256 constant DEFAULT_EVM = 0x80000000;
    uint256 constant COIN_BTC = 0;

    // a used commitment can be made again at once, in the paid form and in the trial form
    function test_usedCommitmentCanBeMadeAgainAtOnce() public {
        bytes32 s = _s("alpha", bob, 0);
        bytes32 c = nft.makeCommitment("alpha", bob, 0, s);
        vm.prank(bob);
        nft.commit(c);
        uint256 t0 = vm.getBlockTimestamp();
        vm.warp(t0 + 61);
        // refused while it waits for its reveal
        vm.prank(carol);
        vm.expectRevert(PageNFT.AlreadyCommitted.selector);
        nft.commit(c);
        vm.prank(bob);
        nft.reveal{value: FEE5}("alpha", bob, 0, s);
        assertEq(nft.commitments(c), 0, "used up");
        vm.prank(carol);
        nft.commit(c);
        assertEq(nft.commitments(c), t0 + 61, "made again in the second it was used");

        bytes32 ts = _s("bravo", user, 0);
        bytes32 tc = trialCommitmentRaw("bravo", user, 0, ts);
        vm.prank(relayer);
        nft.commit(tc);
        uint256 t1 = vm.getBlockTimestamp();
        vm.warp(t1 + 61);
        vm.prank(relayer);
        vm.expectRevert(PageNFT.AlreadyCommitted.selector);
        nft.commit(tc);
        vm.prank(relayer);
        nft.revealTrial{value: PRICE5}("bravo", user, 0, ts);
        assertEq(nft.commitments(tc), 0, "trial commitment used up");
        vm.prank(relayer);
        nft.commit(tc);
        assertEq(nft.commitments(tc), t1 + 61, "trial commitment made again");
    }

    // records saved in one registration stay empty when their saver gets the name back in the next one
    function test_recordsOfAnEarlierRegistrationStayEmptyWhenTheirSaverGetsTheNameBack() public {
        uint256 id = _buy(bob, "alpha");
        vm.startPrank(bob);
        nft.setAddr(id, carol);
        nft.setAddrForCoin(id, 60, abi.encodePacked(dave));
        nft.setAddrForCoin(id, COIN_BASE, abi.encodePacked(dave));
        nft.setAddrForCoin(id, DEFAULT_EVM, abi.encodePacked(carol));
        nft.setAddrForCoin(id, COIN_BTC, hex"0014aa");
        nft.setText(id, "url", "x");
        nft.setContenthash(id, hex"e301");
        vm.stopPrank();
        assertEq(nft.resolve(id), carol);
        assertEq(nft.addr(id, 60), abi.encodePacked(dave));
        assertEq(nft.addr(id, COIN_BASE), abi.encodePacked(dave));
        assertEq(nft.addr(id, COIN_ARB), abi.encodePacked(carol), "the default");
        assertEq(nft.addr(id, COIN_BTC), hex"0014aa");
        assertEq(nft.text(id, "url"), "x");
        assertEq(nft.contenthash(id), hex"e301");

        // dave registers it once it has lapsed and gives it to bob
        vm.warp(nft.expiresAt(id) + 111 days + 1);
        _buy(dave, "alpha");
        vm.prank(dave);
        nft.transferFrom(dave, bob, id);
        assertEq(nft.ownerOf(id), bob);
        assertEq(nft.epochOf(id), 2);
        assertEq(nft.profileWriter(id), bob, "bob still writes the profile");
        assertEq(nft.resolve(id), bob, "main address");
        assertEq(nft.addr(id, COIN_OP), abi.encodePacked(bob), "OP");
        // the entries and the default of the earlier registration do not count, and nothing else answers there
        assertEq(nft.addr(id, 60), "", "coin type 60");
        assertEq(nft.addr(id, COIN_BASE), "", "Base");
        assertEq(nft.addr(id, COIN_ARB), "", "a chain with only the default");
        assertEq(nft.addr(id, DEFAULT_EVM), "", "the default");
        assertEq(nft.addr(id, COIN_BTC), "", "Bitcoin");
        assertEq(nft.text(id, "url"), "", "text");
        assertEq(nft.contenthash(id), "", "website");
    }

    // trial money whose payer is the PageNFT itself is credited to the dead address. The PageNFT calls itself only
    // through the delegatecall of multicall, which keeps the caller, so only a test can make it the payer
    function test_trialMoneyOfTheContractItselfIsCreditedToDead() public {
        vm.deal(address(nft), PRICE5);
        uint256 id = _trial(address(nft), "alpha", user, 0);
        (address payer, uint256 held) = _held(id);
        assertEq(payer, address(nft));
        assertEq(held, PRICE5);

        vm.warp(nft.expiresAt(id) + 1);
        uint256 deadBefore = nft.owed(DEAD);
        vm.expectEmit(true, true, true, true, address(nft));
        emit PageNFT.TrialRefunded(id, DEAD, PRICE5);
        nft.release(id);
        assertEq(nft.owed(DEAD) - deadBefore, PRICE5, "credited to DEAD");
        assertEq(nft.owed(address(nft)), 0, "never to the PageNFT");
        assertEq(_heldAmount(id), 0);
    }

    // an unpaid trial is not expired at its last second and is expired one second later, with no grace between
    function test_trialIsExpiredFromTheSecondAfterItEnds() public {
        uint256 id = _trial("alpha", user);
        uint256 e = nft.expiresAt(id);
        vm.warp(e);
        assertFalse(nft.isExpired(id), "live at its last second");
        assertFalse(nft.inGracePeriod(id));
        vm.warp(e + 1);
        assertTrue(nft.isExpired(id), "ended one second later");
        assertFalse(nft.inGracePeriod(id));
        assertEq(nft.depositOf(id), 0, "still unpaid");
    }

    // bob holds alpha and carol holds sub.alpha
    function _subUnderAlpha() internal returns (uint256 parent, uint256 sub) {
        parent = _buy(bob, "alpha");
        vm.prank(bob);
        sub = nft.registerSubpageFor("sub", parent, carol);
    }

    // a subpage is never expired, also while its parent is past grace or registered again
    function test_subpageIsNeverExpired() public {
        (uint256 parent, uint256 sub) = _subUnderAlpha();
        uint256 e = nft.expiresAt(parent);
        uint256[4] memory at = [e, e + 90 days, e + 90 days + 1, e + 111 days + 1];
        for (uint256 i; i < at.length; ++i) {
            vm.warp(at[i]);
            assertEq(nft.isExpired(parent), at[i] > e + 90 days, "the parent");
            assertFalse(nft.isExpired(sub), "the subpage");
        }
        assertEq(uint256(nft.status(sub)), uint256(PageCard.Status.Expired), "its status follows the parent");
        _buy(dave, "alpha");
        assertEq(uint256(nft.status(sub)), uint256(PageCard.Status.Invalid), "stale");
        assertFalse(nft.isExpired(sub), "the stale subpage");
    }

    // a subpage is never in grace, also while its parent is and the status of the subpage reads Grace
    function test_subpageIsNeverInGrace() public {
        (uint256 parent, uint256 sub) = _subUnderAlpha();
        uint256 e = nft.expiresAt(parent);
        uint256[4] memory at = [e, e + 1, e + 90 days, e + 90 days + 1];
        for (uint256 i; i < at.length; ++i) {
            vm.warp(at[i]);
            bool grace = at[i] > e && at[i] <= e + 90 days;
            assertEq(nft.inGracePeriod(parent), grace, "the parent");
            assertEq(nft.status(sub) == PageCard.Status.Grace, grace, "the status of the subpage");
            assertFalse(nft.inGracePeriod(sub), "the subpage");
        }
        vm.warp(e + 111 days + 1);
        _buy(dave, "alpha");
        assertFalse(nft.inGracePeriod(sub), "the stale subpage");
    }
}

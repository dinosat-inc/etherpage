// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Vm} from "forge-std/Test.sol";
import {PageNFT} from "../../src/PageNFT.sol";
import {RulesBase} from "../utils/RulesBase.sol";

// The one second edges that the rest of the suite crosses without stopping on them.
contract BoundaryInstantsTest is RulesBase {
    // release and isReleasable stay shut at exactly the end of the premium window and open one second later
    function test_releaseOpensOneSecondAfterThePremiumWindow() public {
        uint256 id = _buy(bob, "alice");
        uint256 p = nft.expiresAt(id) + 90 days + 21 days;
        vm.warp(p);
        assertFalse(nft.isReleasable(id), "shut at the last second");
        vm.expectRevert(PageNFT.NotReleasable.selector);
        nft.release(id);
        vm.warp(p + 1);
        assertTrue(nft.isReleasable(id), "open one second later");
        nft.release(id);
        assertEq(nft.depositOf(id), 0);
    }

    // a subpage answers at the parent's expiry second and stops one second later
    function test_subpageActiveAtTheParentsLastSecond() public {
        uint256 parent = _buy(bob, "alice");
        vm.prank(bob);
        uint256 sub = nft.registerSubpage("sub", parent);
        uint256 t = nft.expiresAt(parent);
        vm.warp(t);
        assertEq(nft.resolve(sub), bob, "active at the last second");
        assertEq(nft.getPageName(sub), "sub.alice");
        vm.warp(t + 1);
        assertEq(nft.resolve(sub), address(0), "inactive one second later");
    }

    // the same commitment can be made again only once it is more than a day old
    function test_recommitOnlyAfterAFullDay() public {
        bytes32 c = keccak256("a commitment");
        nft.commit(c);
        uint256 t = vm.getBlockTimestamp();
        vm.warp(t + 86400);
        vm.expectRevert(PageNFT.AlreadyCommitted.selector);
        nft.commit(c);
        vm.warp(t + 86401);
        nft.commit(c);
        assertEq(nft.commitments(c), t + 86401);
    }

    // quote carries the deposit only once the grace period is over, as reveal does
    function test_quoteCarriesTheDepositOnlyAfterGrace() public {
        uint256 id = _buy(bob, "alice");
        uint256 g = nft.expiresAt(id) + 90 days;
        vm.warp(g);
        (uint256 fee, uint256 carried, uint256 premium, uint256 total) = nft.quote("alice");
        assertEq(carried, 0, "nothing carried at the last grace second");
        assertEq(premium, 0);
        assertEq(total, fee);
        vm.warp(g + 1);
        (fee, carried, premium, total) = nft.quote("alice");
        assertEq(carried, FEE5, "the deposit one second later");
        assertEq(total, fee + carried + premium);
        assertGt(premium, 0);
    }

    // renewing a live trial logs the refund of the trial money before the deposit it adds
    function test_renewingATrialLogsTheRefundFirst() public {
        uint256 id = _trial("alice", bob);
        vm.recordLogs();
        vm.prank(carol);
        nft.renew{value: FEE5}(id);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 refunded = type(uint256).max;
        uint256 added = type(uint256).max;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == T_REFUNDED) refunded = i;
            if (logs[i].topics[0] == T_DEPOSIT) added = i;
        }
        assertLt(refunded, added, "refund first");
        assertLt(added, logs.length, "deposit logged");
        assertEq(nft.owed(relayer), PRICE5, "the payer gets the trial money back");
    }

    // a paid name is in grace from one second after its expiry to the last grace second, a trial never is
    function test_graceSeconds() public {
        uint256 id = _buy(bob, "alice");
        uint256 t = nft.expiresAt(id);
        uint256 g = t + 90 days;
        vm.warp(t);
        assertFalse(nft.inGracePeriod(id), "not yet at the expiry second");
        assertFalse(nft.isExpired(id));
        vm.warp(t + 1);
        assertTrue(nft.inGracePeriod(id), "grace starts");
        vm.warp(g);
        assertTrue(nft.inGracePeriod(id), "still in grace at the last grace second");
        assertFalse(nft.isExpired(id));
        vm.warp(g + 1);
        assertFalse(nft.inGracePeriod(id), "grace over");
        assertTrue(nft.isExpired(id));
        uint256 tr = _trial("carol", bob);
        vm.warp(nft.expiresAt(tr) + 1);
        assertFalse(nft.inGracePeriod(tr), "a trial has no grace");
        assertTrue(nft.isExpired(tr));
    }

    // a renewal may end at most 3650 days from now, to the second
    function test_renewHorizonToTheSecond() public {
        uint256 id = _buy(bob, "alice");
        for (uint256 i; i < 9; ++i) nft.renew{value: FEE5}(id);
        uint256 e = nft.expiresAt(id);
        // the next renewal ends a year after e, which is exactly 3650 days ahead at the edge second
        uint256 edge = e + 365 days - 3650 days;
        vm.warp(edge - 1);
        vm.expectRevert(PageNFT.RenewalTooFar.selector);
        nft.renew{value: FEE5}(id);
        vm.warp(edge);
        nft.renew{value: FEE5}(id);
        assertEq(nft.expiresAt(id), e + 365 days);
    }

    // long after the premium window there is no premium, however far the clock has run
    function test_noPremiumLongAfterTheWindow() public {
        vm.warp(1000);
        uint256 id = _buy(bob, "alice");
        uint256 g = nft.expiresAt(id) + 90 days;
        vm.warp(g + 1);
        assertGt(nft.getPremium(id), 0, "premium just after grace");
        uint256[3] memory at = [2 * g + 1, 2 * g + 5 days, 3 * g + 1];
        for (uint256 i; i < 3; ++i) {
            vm.warp(at[i]);
            assertEq(nft.getPremium(id), 0, "no premium");
        }
    }
}

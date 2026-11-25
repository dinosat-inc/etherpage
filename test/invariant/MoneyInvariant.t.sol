// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {PageNFT} from "../../src/PageNFT.sol";
import {PageCard} from "../../src/PageCard.sol";
import {MoneyHandler} from "./MoneyHandler.sol";

contract MoneyInvariantTest is Test {
    PageNFT nft;
    MoneyHandler h;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    function setUp() public {
        vm.warp(1_800_000_000);
        nft = new PageNFT(new PageCard());
        h = new MoneyHandler(nft);
        vm.deal(address(h), 0);
        targetContract(address(h));
    }

    function _held(uint256 id) internal view returns (address p, uint256 a) {
        (p, a) = nft.trialPaymentOf(id);
    }

    // I1: the balance is every deposit, every credit and every trial price still held
    function invariant_conservation() public view {
        uint256 sum = nft.owed(DEAD);
        uint256 n = h.idsLength();
        for (uint256 i; i < n; ++i) {
            uint256 id = h.ids(i);
            (, uint256 a) = _held(id);
            sum += nft.depositOf(id) + a;
        }
        for (uint256 i; i < 3; ++i) sum += nft.owed(h.actors(i)) + nft.owed(h.payers(i));
        assertEq(address(nft).balance, sum);
    }

    // I2: a payer's trial money is held, owed or withdrawn, to the wei, and all other money is
    // deposits, the credits of everyone else and their withdrawals, to the wei
    function invariant_trialMoneyOnlyToPayer() public view {
        for (uint256 j; j < 3; ++j) {
            address p = h.payers(j);
            uint256 held;
            for (uint256 i; i < 5; ++i) {
                (address q, uint256 a) = _held(nft.computeId(h.labels(i)));
                if (q == p) held += a;
            }
            assertEq(held + nft.owed(p) + h.withdrawn(p), h.trialPaid(p), "payer ledger");
        }
        uint256 others = nft.owed(DEAD) + h.otherOut();
        uint256 n = h.idsLength();
        for (uint256 i; i < n; ++i) others += nft.depositOf(h.ids(i));
        for (uint256 i; i < 3; ++i) others += nft.owed(h.actors(i));
        assertEq(others, h.otherIn(), "non trial money");
    }

    // I3 says held money and a deposit never come together, and I4 that a live top level name has no
    // deposit exactly when it holds a price. Also a subpage never holds money, the money held for each
    // name and its payer match the model, and status follows the rule for top level names, Invalid for one DEAD holds
    function invariant_perName() public view {
        uint256 n = h.idsLength();
        for (uint256 i; i < n; ++i) {
            uint256 id = h.ids(i);
            (address p, uint256 a) = _held(id);
            assertEq(p, h.mPayer(id), "held payer equals the model");
            assertEq(a, h.mAmount(id), "held amount equals the model");
            uint256 dep = nft.depositOf(id);
            assertTrue(a == 0 || dep == 0, "held and deposit together");
            if (nft.parentOf(id) != 0) {
                assertEq(a, 0, "a subpage never holds money");
                continue;
            }
            uint256 e = nft.expiresAt(id);
            if (e == 0) {
                assertEq(a, 0);
                continue;
            }
            bool live = block.timestamp <= e;
            if (live) assertEq(dep == 0, a != 0, "live: no deposit exactly when a price is held");
            if (a != 0) assertEq(nft.getPremium(id), 0, "no premium while money is held");
            if (dep == 0) assertEq(nft.getPremium(id), 0, "no premium without a deposit");
            PageCard.Status s = nft.status(id);
            uint256 graceEnd = dep == 0 ? e : e + 90 days;
            // a name DEAD holds is deleted, so it is Invalid whatever the time
            PageCard.Status want = nft.ownerOf(id) == DEAD
                ? PageCard.Status.Invalid
                : live
                    ? (dep == 0 ? PageCard.Status.Trial : PageCard.Status.Active)
                    : block.timestamp <= graceEnd ? PageCard.Status.Grace : PageCard.Status.Expired;
            assertEq(uint256(s), uint256(want), "status rule");
            assertEq(nft.isReleasable(id), a != 0 ? !live : (block.timestamp > e + 111 days && dep != 0));
        }
    }

    // the walk's own checks, each recorded as a flag
    function invariant_walkFlags() public view {
        assertFalse(h.refLeak(), "the referrer of an unpaid trial was paid or kept");
        assertFalse(h.pauseBroken(), "a trial started inside the pause");
        assertFalse(h.releaseMismatch(), "release disagreed with isReleasable");
        assertFalse(h.refundWrong(), "a refund credited another amount or account");
        assertFalse(h.unpaidMoved(), "a live trial moved somewhere other than DEAD");
        assertFalse(h.subUnderTrial(), "a subpage was created under a trial");
        assertFalse(h.statusMismatch(), "status differs from the metadata Status");
        assertFalse(h.conversionWrong(), "a conversion or trial start had the wrong expiry or deposit");
        assertFalse(h.profileWrong(), "a profile call or read broke the writer rule");
    }

    function afterInvariant() public {
        string memory first = string.concat(
            vm.toString(h.trials()), " trials, ", vm.toString(h.conversions()), " conversions, ",
            vm.toString(h.trialReleases()), " trial releases, ", vm.toString(h.autoRefunds()),
            " refunds at a new registration, ", vm.toString(h.pausedRefusals()), " paused refusals, "
        );
        string memory second = string.concat(
            vm.toString(h.paidOverLapsedTrial()), " paid over a lapsed trial or released name, ",
            vm.toString(h.bundles()), " bundles, ", vm.toString(h.auctions()), " auctions, "
        );
        string memory third = string.concat(
            vm.toString(h.statusChecks()), " status checks (", vm.toString(h.trialStatusSeen()), " Trial, ",
            vm.toString(h.staleOrDeletedSeen()), " Invalid), ", vm.toString(h.profileWrites()), " profile writes, ",
            vm.toString(h.profileKeeps()), " keeps, ", vm.toString(h.profileShown()), " shown profile reads"
        );
        vm.createDir("logs", true);
        vm.writeLine("logs/money-inv-stats.txt", string.concat(first, second, third));
    }
}

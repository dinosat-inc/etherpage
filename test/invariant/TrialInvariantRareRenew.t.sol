// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

// TrialInvariantTest with the same handler and invariants, but with renew drawn rarely, so that long walks keep
// reaching lapsed names that a trial takes again.

import {Test, Vm} from "forge-std/Test.sol";
import {PageNFT} from "../../src/PageNFT.sol";
import {PageCard} from "../../src/PageCard.sol";
import {TrialHandler} from "./TrialInvariant.t.sol";

contract TrialInvariantRareRenewTest is Test {
    PageNFT nft;
    TrialHandler h;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    function setUp() public {
        vm.warp(1_800_000_000);
        nft = new PageNFT(new PageCard());
        h = new TrialHandler(nft);
        // renew is one entry in 22, so names lapse and are taken again by trials in long
        // walks; in the suite's own campaign every action is one entry in 8 and long walks keep every name renewed
        bytes4[] memory sels = new bytes4[](22);
        uint256 k;
        for (uint256 i; i < 4; ++i) sels[k++] = TrialHandler.trial.selector;
        for (uint256 i; i < 3; ++i) sels[k++] = TrialHandler.paid.selector;
        for (uint256 i; i < 2; ++i) sels[k++] = TrialHandler.transfer.selector;
        for (uint256 i; i < 2; ++i) sels[k++] = TrialHandler.sub.selector;
        for (uint256 i; i < 3; ++i) sels[k++] = TrialHandler.release.selector;
        for (uint256 i; i < 2; ++i) sels[k++] = TrialHandler.withdraw.selector;
        for (uint256 i; i < 5; ++i) sels[k++] = TrialHandler.warp.selector;
        sels[k++] = TrialHandler.renew.selector;
        targetContract(address(h));
        targetSelector(FuzzSelector({addr: address(h), selectors: sels}));
    }

    function _sums() internal view returns (uint256 deposits, uint256 owedOthers, uint256 held) {
        for (uint256 i; i < 5; ++i) {
            uint256 id = nft.computeId(h.labels(i));
            deposits += nft.depositOf(id);
            (, uint256 a) = nft.trialPaymentOf(id);
            held += a;
        }
        for (uint256 i; i < 4; ++i) owedOthers += nft.owed(h.actors(i));
    }

    // every wei held is a deposit, a credit or a trial price still held
    function invariant_balanceIsLedgers() public view {
        (uint256 d, uint256 o, uint256 held) = _sums();
        assertEq(address(nft).balance, d + o + nft.owed(DEAD) + held);
    }

    // trial money is held for its payer and goes back only to that payer: the contract holds exactly
    // what the model holds, every refund named the modelled payer and amount, and nothing is lost
    function invariant_trialMoneyGoesBackToItsPayer() public view {
        assertFalse(h.wrongRefund(), "a refund went to someone other than the payer, or with another amount");
        (,, uint256 held) = _sums();
        assertEq(held + h.refunded(), h.trialIn(), "every trial price is held or was refunded");
        for (uint256 i; i < 5; ++i) {
            uint256 id = nft.computeId(h.labels(i));
            (address p, uint256 a) = nft.trialPaymentOf(id);
            assertEq(p, h.heldPayer(id));
            assertEq(a, h.heldAmount(id));
        }
    }

    // per name: no premium and no grace without a deposit, isAvailable agrees with the grace end,
    // an unpaid live name is the trial's, and a paid name never loses its deposit while live
    function invariant_perName() public view {
        for (uint256 i; i < 5; ++i) {
            string memory l = h.labels(i);
            uint256 id = nft.computeId(l);
            uint256 e = nft.expiresAt(id);
            if (e == 0) {
                assertTrue(nft.isAvailable(l, 0));
                continue;
            }
            uint256 dep = nft.depositOf(id);
            uint256 graceEnd = dep == 0 ? e : e + 90 days;
            if (dep == 0) {
                assertEq(nft.getPremium(id), 0, "no premium without a deposit");
                assertFalse(nft.inGracePeriod(id), "no grace without a deposit");
            }
            assertEq(nft.isAvailable(l, 0), block.timestamp > graceEnd, "availability");
            assertEq(nft.isExpired(id), block.timestamp > graceEnd, "isExpired");
            bool live = block.timestamp <= e;
            (, uint256 held) = nft.trialPaymentOf(id);
            assertTrue(held == 0 || dep == 0, "held money and a deposit never together");
            if (live && dep == 0) {
                address o = nft.ownerOf(id);
                assertGt(held, 0, "a live trial holds its price");
                assertTrue(o == h.trialOwner(id) || o == DEAD, "an unpaid name stays with its trial owner");
                assertEq(e, h.trialStart(id) + 14 days, "a trial lasts fourteen days");
                assertEq(nft.epochOf(id), h.trialEpoch(id));
                assertFalse(h.paidInEpoch(id) && h.paidEpoch(id) == nft.epochOf(id), "a paid live name keeps a deposit");
            }
            // subpages of an unpaid parent never count
            for (uint256 j; j < 2; ++j) {
                uint256 sid = nft.computeId(string.concat(h.subLabels(j), ".", l));
                if (dep == 0 && live) assertEq(nft.resolve(sid), address(0), "no live subpage under a trial");
            }
        }
        assertFalse(h.subUnderUnpaid(), "no subpage minted under an unpaid parent");
    }

    function afterInvariant() public {
        vm.createDir("logs", true);
        vm.writeLine(
            "logs/trial-rare-renew-stats.txt",
            string.concat(
                vm.toString(h.trials()), " ", vm.toString(h.conversions()), " ", vm.toString(h.lapsesRetaken())
            )
        );
    }
}

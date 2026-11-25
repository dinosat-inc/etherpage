// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {PageNFT} from "../../../src/PageNFT.sol";
import {AcceptedBase} from "./AcceptedBase.sol";

// Anyone can start a trial for any wallet, one and two letter names included, and the trial money comes back to
// whoever paid it, so it costs only gas. The wallet can only throw an unpaid trial to DEAD while it runs, and after
// the end the expired name stays in the wallet until someone registers it. A referrer the starter chose stays on
// the name if the wallet pays the year.
contract AcceptedTrialsForOthersTest is AcceptedBase {
    // a stranger starts a trial for a wallet, naming the stranger's own name as referrer; the wallet pays the year,
    // the stranger gets the trial money back in full, and its referrer later earns a quarter of an auction premium
    function test_strangersTrialKeepsItsReferrerWhenTheWalletPays() public {
        uint256 sref = _buy(dave, "daveref", dave, 0);
        uint256 before = dave.balance;
        uint256 id = _trial(dave, "alpha", user, sref);
        uint256 fee = nft.getFee(bytes("alpha").length);
        vm.prank(user);
        nft.renew{value: fee}(id);
        assertEq(nft.referrerOf(id), sref, "the referrer stays");
        assertEq(nft.depositOf(id), fee);
        assertEq(nft.owed(dave), _trialPrice("alpha"), "the trial money is credited back");
        nft.withdraw(dave);
        assertEq(dave.balance, before, "the trial cost the stranger nothing");

        // the name lapses and bob buys it in the auction
        vm.warp(nft.expiresAt(id) + 90 days + 1);
        _commitPaid(bob, "alpha", bob, 0);
        vm.warp(vm.getBlockTimestamp() + 61);
        (,, uint256 premium, uint256 total) = nft.quote("alpha");
        assertGt(premium, 0);
        bytes32 s = _secret("alpha", bob);
        vm.prank(bob);
        nft.reveal{value: total}("alpha", bob, 0, s);
        assertEq(nft.owed(dave), premium * 2500 / 10_000, "the stranger's referrer earns a quarter of the premium");
    }

    // a relayer pushes five trials into a wallet that never asked: the wallet cannot pass them on, only throw them
    // to DEAD; after the last one ends anyone releases them and the relayer gets every price back, and the four
    // expired names stay in the wallet, where they can no longer be thrown away
    function test_unsolicitedTrialsCostTheStarterNothing() public {
        address wallet = makeAddr("wallet");
        uint256 before = relayer.balance;
        string[5] memory ls = ["spam1", "spam2", "spam3", "ab", "x"];
        uint256[5] memory ids;
        for (uint256 i; i < 5; ++i) ids[i] = _trial(relayer, ls[i], wallet, 0);
        assertEq(nft.balanceOf(wallet), 5);
        assertLt(relayer.balance, before);

        vm.prank(wallet);
        vm.expectRevert(PageNFT.Unpaid.selector);
        nft.transferFrom(wallet, bob, ids[0]);
        vm.prank(wallet);
        nft.transferFrom(wallet, DEAD, ids[0]);
        assertEq(nft.ownerOf(ids[0]), DEAD);

        vm.warp(nft.expiresAt(ids[4]) + 1);
        bytes[] memory b = new bytes[](6);
        for (uint256 i; i < 5; ++i) b[i] = abi.encodeCall(PageNFT.release, (ids[i]));
        b[5] = abi.encodeCall(PageNFT.withdraw, (relayer));
        vm.prank(stranger);
        nft.multicall(b);
        assertEq(relayer.balance, before, "five trials cost the relayer nothing");
        assertEq(nft.balanceOf(wallet), 4, "the expired names stay in the wallet");
        vm.prank(wallet);
        vm.expectRevert(PageNFT.Expired.selector);
        nft.transferFrom(wallet, DEAD, ids[1]);
    }
}

// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {PageNFT} from "../../../src/PageNFT.sol";
import {EdgesBase} from "./EdgesBase.sol";

// Under a live trial a subpage mint reverts Unpaid for every caller: the deposit check comes before the
// caller check, so a caller the caller check refuses gets Unpaid and not NotParentOwner. Under an ended
// trial or a released name the expiry check comes first and answers Expired.
contract TrialSubpageOrderTest is EdgesBase {
    uint256 club;
    uint256 e;

    function setUp() public override {
        super.setUp();
        club = _trial(relayer, "club", alice, 0);
        e = nft.expiresAt(club);
    }

    // a mint under parentId through both entry points, each expected to revert with err
    function _expectBoth(address who, uint256 parentId, bytes4 err) internal {
        vm.prank(who);
        vm.expectRevert(err);
        nft.registerSubpage("sub", parentId);
        vm.prank(who);
        vm.expectRevert(err);
        nft.registerSubpageFor("sub", parentId, who);
    }

    function testFuzz_everyCallerGetsUnpaidUnderALiveTrial(address caller, uint256 t) public {
        t = bound(t, vm.getBlockTimestamp(), e);
        vm.warp(t);
        _expectBoth(caller, club, PageNFT.Unpaid.selector);
        assertEq(nft.getPageName(_subId(club, "sub")), "", "no subpage was made");
    }

    // the callers the caller check refuses: a stranger, the account approved for the trial, an operator of its holder
    // and a minter picked in an earlier registration of the name. Each gets Unpaid while the trial runs,
    // like the holder and its counted minter, and NotParentOwner once the trial is paid, when the holder
    // and the counted minter mint
    function test_unpaidComesBeforeNotParentOwner() public {
        // an earlier registration of shop picked hot2, and a trial runs on shop now
        address hot2 = makeAddr("hot2");
        uint256 shop = _buy(carol, "shop", carol, 0);
        vm.prank(carol);
        nft.setSubpageMinter(shop, hot2);
        vm.warp(nft.expiresAt(shop) + GRACE + DECAY + 1);
        nft.release(shop);
        assertEq(_trial(relayer, "shop", alice, 0), shop);
        assertEq(nft.epochOf(shop), 2);
        assertEq(nft.subpageMinterOf(shop), address(0), "the earlier pick does not count");

        // a trial on plaza with an approved account, an operator and a counted minter
        uint256 plaza = _trial(relayer, "plaza", alice, 0);
        vm.startPrank(alice);
        nft.approve(carol, plaza);
        nft.setApprovalForAll(dave, true);
        nft.setSubpageMinter(plaza, hot);
        vm.stopPrank();
        assertEq(nft.subpageMinterOf(plaza), hot);

        _expectBoth(stranger, plaza, PageNFT.Unpaid.selector);
        _expectBoth(carol, plaza, PageNFT.Unpaid.selector);
        _expectBoth(dave, plaza, PageNFT.Unpaid.selector);
        _expectBoth(hot, plaza, PageNFT.Unpaid.selector);
        _expectBoth(alice, plaza, PageNFT.Unpaid.selector);
        _expectBoth(hot2, shop, PageNFT.Unpaid.selector);
        _expectBoth(stranger, shop, PageNFT.Unpaid.selector);
        // a bad label is refused first, before the deposit is read
        vm.prank(stranger);
        vm.expectRevert(PageNFT.InvalidLabel.selector);
        nft.registerSubpage("Not A Label", plaza);

        // paid by a stranger, the same calls reach the caller check
        uint256 feePlaza = nft.getFee(5);
        uint256 feeShop = nft.getFee(4);
        vm.prank(stranger);
        nft.renew{value: feePlaza}(plaza);
        vm.prank(stranger);
        nft.renew{value: feeShop}(shop);
        _expectBoth(stranger, plaza, PageNFT.NotParentOwner.selector);
        _expectBoth(carol, plaza, PageNFT.NotParentOwner.selector);
        _expectBoth(dave, plaza, PageNFT.NotParentOwner.selector);
        _expectBoth(hot2, shop, PageNFT.NotParentOwner.selector);
        _expectBoth(stranger, shop, PageNFT.NotParentOwner.selector);
        vm.prank(hot);
        uint256 byMinter = nft.registerSubpageFor("minted", plaza, bob);
        assertEq(nft.ownerOf(byMinter), bob);
        vm.prank(alice);
        uint256 byHolder = nft.registerSubpage("sub", plaza);
        assertEq(nft.ownerOf(byHolder), alice);
    }

    // a trial thrown to DEAD: the minter its earlier holder picked no longer counts, and every caller, DEAD
    // included, gets Unpaid until the name is paid. Once a stranger pays, every caller but DEAD, its holder,
    // gets NotParentOwner
    function test_trialHeldByDeadAnswersUnpaidToEveryCaller() public {
        vm.prank(alice);
        nft.setSubpageMinter(club, hot);
        vm.prank(alice);
        nft.transferFrom(alice, DEAD, club);
        assertEq(nft.subpageMinterOf(club), address(0));
        _expectBoth(hot, club, PageNFT.Unpaid.selector);
        _expectBoth(alice, club, PageNFT.Unpaid.selector);
        _expectBoth(stranger, club, PageNFT.Unpaid.selector);
        _expectBoth(DEAD, club, PageNFT.Unpaid.selector);
        uint256 fee = nft.getFee(4);
        vm.prank(stranger);
        nft.renew{value: fee}(club);
        _expectBoth(hot, club, PageNFT.NotParentOwner.selector);
        _expectBoth(alice, club, PageNFT.NotParentOwner.selector);
        _expectBoth(stranger, club, PageNFT.NotParentOwner.selector);
    }

    // the last second of the trial still answers Unpaid, the next one Expired
    function test_unpaidUpToTheLastSecondThenExpired() public {
        vm.warp(e);
        _expectBoth(stranger, club, PageNFT.Unpaid.selector);
        _expectBoth(alice, club, PageNFT.Unpaid.selector);
        vm.warp(e + 1);
        _expectBoth(stranger, club, PageNFT.Expired.selector);
        _expectBoth(alice, club, PageNFT.Expired.selector);
    }

    function testFuzz_endedTrialAnswersExpiredToEveryCaller(address caller, uint256 t) public {
        t = bound(t, e + 1, e + 10 * YEAR);
        vm.warp(t);
        _expectBoth(caller, club, PageNFT.Expired.selector);
    }

    function testFuzz_releasedNameAnswersExpiredToEveryCaller(address caller, uint256 t) public {
        uint256 id = _buy(carol, "gone", carol, 0);
        uint256 end = nft.expiresAt(id) + GRACE + DECAY;
        vm.warp(end + 1);
        nft.release(id);
        assertEq(nft.depositOf(id), 0);
        t = bound(t, end + 1, end + 10 * YEAR);
        vm.warp(t);
        _expectBoth(caller, id, PageNFT.Expired.selector);
    }
}

// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {SubpageRegistrar} from "../../src/SubpageRegistrar.sol";
import {MinterBase} from "../utils/MinterBase.sol";
import {RevertGate, ShortGate, LongGate} from "../utils/TokenMocks.sol";

// Pins the registrar lines that forge coverage does not attribute, and shows why no sale reaches
// the ParentNotTopLevel check in _sell.
contract RegistrarCoverageTest is MinterBase {
    uint256 club;
    uint256 sub;

    function setUp() public override {
        super.setUp();
        club = _reg(alice, "club");
        vm.prank(alice);
        sub = nft.registerSubpage("s", club);
        _setMinter(club, address(reg));
    }

    function _gate(address token, uint256 min) internal {
        vm.prank(alice);
        reg.configure(club, payout, address(0), 0, true, token, min, false);
    }

    // the gate reads balanceOf and treats a failed call or a short answer as zero
    function test_gateBalanceOutcomes() public {
        // a token that answers a full word
        usd.mint(buyer, 5);
        _gate(address(usd), 5);
        vm.prank(buyer);
        uint256 id = reg.registerSubpage(club, "ok", 0, address(0));
        assertEq(nft.ownerOf(id), buyer);
        _gate(address(usd), 6);
        vm.prank(buyer);
        vm.expectRevert(SubpageRegistrar.GateFailed.selector);
        reg.registerSubpage(club, "low", 0, address(0));

        // an account with no code answers nothing
        _gate(makeAddr("nocode"), 1);
        vm.prank(buyer);
        vm.expectRevert(SubpageRegistrar.GateFailed.selector);
        reg.registerSubpage(club, "eoa", 0, address(0));

        // a reverting token
        _gate(address(new RevertGate()), 1);
        vm.prank(buyer);
        vm.expectRevert(SubpageRegistrar.GateFailed.selector);
        reg.registerSubpage(club, "rev", 0, address(0));

        // an answer shorter than a word
        _gate(address(new ShortGate()), 1);
        vm.prank(buyer);
        vm.expectRevert(SubpageRegistrar.GateFailed.selector);
        reg.registerSubpage(club, "short", 0, address(0));

        // a longer answer is read by its first word
        _gate(address(new LongGate()), type(uint96).max);
        vm.prank(buyer);
        id = reg.registerSubpage(club, "long", 0, address(0));
        assertEq(nft.ownerOf(id), buyer);
    }

    // a zero payout is stored as the holder that configures
    function test_zeroPayoutIsTheHolder() public {
        vm.prank(alice);
        reg.configure(club, address(0), address(0), 1 ether, true, address(0), 0, false);
        (address controller,,,,,,, address p,) = reg.config(club);
        assertEq(controller, alice);
        assertEq(p, alice);
        vm.prank(alice);
        reg.configure(club, payout, address(0), 1 ether, true, address(0), 0, false);
        (,,,,,,, p,) = reg.config(club);
        assertEq(p, payout);
    }

    // terms can never be set for a subpage, so a sale under a subpage stops at NotEnabled
    function test_noSaleUnderASubpage() public {
        vm.prank(alice);
        vm.expectRevert(SubpageRegistrar.ParentNotTopLevel.selector);
        reg.configure(sub, payout, address(0), 0, true, address(0), 0, false);
        vm.prank(buyer);
        vm.expectRevert(SubpageRegistrar.NotEnabled.selector);
        reg.registerSubpage(sub, "x", 0, address(0));
        vm.prank(buyer);
        vm.expectRevert(SubpageRegistrar.NotEnabled.selector);
        reg.revealSubpage(sub, "x", bytes32(0), 0, address(0));
    }

    // a name stays top level through every registration: after it lapses and is registered again
    // its old terms are stale, never ParentNotTopLevel
    function test_parentStaysTopLevelAcrossRegistrations() public {
        vm.prank(alice);
        reg.configure(club, payout, address(0), 0, true, address(0), 0, false);
        vm.warp(nft.expiresAt(club) + 90 days + 21 days + 1);
        uint256 again = _reg(bob, "club");
        assertEq(again, club);
        assertEq(nft.parentOf(club), 0);
        vm.prank(buyer);
        vm.expectRevert(SubpageRegistrar.StaleConfig.selector);
        reg.registerSubpage(club, "late", 0, address(0));
    }

    // a top level id and a subpage id come from different hashes, so a label never gives a subpage the id
    // of a top level name
    function testFuzz_subpageIdIsNeverTopLevel(uint64 seed) public {
        bytes memory b = new bytes(1 + seed % 12);
        for (uint256 i; i < b.length; ++i) b[i] = bytes1(uint8(97 + (seed >> (i * 5)) % 26));
        string memory label = string(b);
        uint256 subId = _subId(label, club);
        assertTrue(subId != _id(label));
        assertEq(nft.parentOf(club), 0);
        if (nft.isAvailable(label, club)) {
            vm.prank(alice);
            uint256 got = nft.registerSubpage(label, club);
            assertEq(got, subId);
            assertEq(nft.parentOf(got), club);
            vm.prank(alice);
            vm.expectRevert(SubpageRegistrar.ParentNotTopLevel.selector);
            reg.configure(got, payout, address(0), 0, true, address(0), 0, false);
        }
    }
}

// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Vm} from "forge-std/Test.sol";
import {PageNFT} from "../../../src/PageNFT.sol";
import {MinterBase} from "../../utils/MinterBase.sol";
import {Holder721} from "../../utils/MinterMocks.sol";

// Who may pick the minter, when it counts, and when it stops counting.
contract MinterPermissionTest is MinterBase {
    uint256 club;

    function setUp() public override {
        super.setUp();
        club = _reg(alice, "club");
    }

    // set: the exact event, the view, the raw slots, and the minter mints
    function test_setEmitsCountsAndMints() public {
        _expectMinterSet(club, alice, hot, 1);
        vm.prank(alice);
        nft.setSubpageMinter(club, hot);
        address m = nft.subpageMinterOf(club);
        assertEq(m, hot);
        (address rm, uint64 re, address rs) = _raw(club);
        assertEq(rm, hot);
        assertEq(re, 1);
        assertEq(rs, alice);

        vm.prank(hot);
        uint256 s = nft.registerSubpageFor("guest", club, carol);
        assertEq(nft.ownerOf(s), carol);
        assertEq(nft.getPageName(s), "guest.club");
        assertEq(nft.resolve(s), carol);

        // picking the same minter again emits again and keeps it
        _expectMinterSet(club, alice, hot, 1);
        vm.prank(alice);
        nft.setSubpageMinter(club, hot);
        m = nft.subpageMinterOf(club);
        assertEq(m, hot);
    }

    // replace: the old minter stops at once, the new one mints
    function test_replace() public {
        _setMinter(club, hot);
        _setMinter(club, hot2);
        vm.prank(hot);
        vm.expectRevert(PageNFT.NotParentOwner.selector);
        nft.registerSubpageFor("a", club, hot);
        vm.prank(hot2);
        nft.registerSubpageFor("a", club, hot2);
        assertEq(_minter(club), hot2);
    }

    // clear: zero switches it off, what was minted stays
    function test_clearKeepsWhatWasMinted() public {
        _setMinter(club, hot);
        vm.prank(hot);
        uint256 s = nft.registerSubpageFor("kept", club, carol);
        _expectMinterSet(club, alice, address(0), 1);
        vm.prank(alice);
        nft.setSubpageMinter(club, address(0));
        address m = nft.subpageMinterOf(club);
        assertEq(m, address(0));
        vm.prank(hot);
        vm.expectRevert(PageNFT.NotParentOwner.selector);
        nft.registerSubpageFor("more", club, hot);
        assertEq(nft.ownerOf(s), carol);
        assertEq(nft.resolve(s), carol);
    }

    // clearing a minter that never minted: the view reports zero and the old minter cannot mint
    function test_clearGivesNoPower() public {
        _setMinter(club, hot);
        vm.prank(alice);
        nft.setSubpageMinter(club, address(0));
        address m = nft.subpageMinterOf(club);
        assertEq(m, address(0));
        vm.prank(hot);
        vm.expectRevert(PageNFT.NotParentOwner.selector);
        nft.registerSubpageFor("x", club, hot);
    }

    function _assertOff(uint256 id, address m) internal {
        address cm = nft.subpageMinterOf(id);
        assertEq(cm, address(0), "counted minter");
        vm.prank(m);
        vm.expectRevert(PageNFT.NotParentOwner.selector);
        nft.registerSubpageFor("probe", id, m);
    }

    function _assertOn(uint256 id, address m) internal view {
        address cm = nft.subpageMinterOf(id);
        assertEq(cm, m, "counted minter");
    }

    // every transfer route switches it off, the raw record is untouched, and it counts again back
    // with the account that picked it
    function test_offOnEveryTransferRouteAndBackOnReturn() public {
        _setMinter(club, hot);
        Holder721 h = new Holder721();
        for (uint256 route; route < 5; ++route) {
            address to = route >= 3 ? address(h) : bob;
            if (route == 0) {
                vm.prank(alice);
                nft.transferFrom(alice, to, club);
            } else if (route == 1) {
                vm.prank(alice);
                nft.approve(carol, club);
                vm.prank(carol);
                nft.transferFrom(alice, to, club);
            } else if (route == 2) {
                vm.prank(alice);
                nft.setApprovalForAll(dave, true);
                vm.prank(dave);
                nft.transferFrom(alice, to, club);
                vm.prank(alice);
                nft.setApprovalForAll(dave, false);
            } else if (route == 3) {
                vm.prank(alice);
                nft.safeTransferFrom(alice, to, club);
            } else {
                vm.prank(alice);
                nft.safeTransferFrom(alice, to, club, hex"1234");
            }
            _assertOff(club, hot);
            (address rm, uint64 re, address rs) = _raw(club);
            assertEq(rm, hot);
            assertEq(re, 1);
            assertEq(rs, alice);
            vm.prank(to);
            nft.transferFrom(to, alice, club);
            _assertOn(club, hot);
        }
    }

    // a holder in between who writes anything replaces the choice for good
    function test_holderInBetweenReplacesTheChoice() public {
        _setMinter(club, hot);
        vm.prank(alice);
        nft.transferFrom(alice, bob, club);
        vm.prank(bob);
        nft.setSubpageMinter(club, hot2);
        _assertOn(club, hot2);
        vm.prank(bob);
        nft.transferFrom(bob, alice, club);
        _assertOff(club, hot);
        _assertOff(club, hot2);
        // while carol holds club, alice cannot switch off the record bob wrote, and bob can
        vm.prank(alice);
        nft.transferFrom(alice, carol, club);
        vm.prank(alice);
        vm.expectRevert(PageNFT.Unauthorized.selector);
        nft.setSubpageMinter(club, address(0));
        vm.prank(bob);
        nft.setSubpageMinter(club, address(0));

        // a clear by the holder in between also ends it
        uint256 gold = _reg(alice, "gold");
        _setMinter(gold, hot);
        vm.prank(alice);
        nft.transferFrom(alice, bob, gold);
        vm.prank(bob);
        nft.setSubpageMinter(gold, address(0));
        vm.prank(bob);
        nft.transferFrom(bob, alice, gold);
        _assertOff(gold, hot);
    }

    // registering the name again switches it off, even for the same account, and the stored record
    // from before never counts again
    function test_offOnReRegistrationEvenForTheSameAccount() public {
        _setMinter(club, hot);
        uint256 again = _lapseAndRegister(club, alice);
        assertEq(again, club);
        assertEq(nft.epochOf(club), 2);
        _assertOff(club, hot);
        (address rm, uint64 re, address rs) = _raw(club);
        assertEq(rm, hot);
        assertEq(re, 1);
        assertEq(rs, alice);
        // a new pick in the new registration counts
        _expectMinterSet(club, alice, hot, 2);
        vm.prank(alice);
        nft.setSubpageMinter(club, hot);
        _assertOn(club, hot);

        // someone else buying it at auction: off too, even though the buyer later sends it to alice
        vm.warp(nft.expiresAt(club) + 90 days + 1);
        uint256 again2 = _reg(bob, "club");
        assertEq(again2, club);
        _assertOff(club, hot);
        vm.prank(bob);
        nft.transferFrom(bob, alice, club);
        _assertOff(club, hot);
    }

    // grace blocks minting and new picks, and renewal brings the minter back unchanged
    function test_graceThenRenewal() public {
        _setMinter(club, hot);
        uint256 e = nft.expiresAt(club);
        vm.warp(e);
        vm.prank(hot);
        nft.registerSubpageFor("last", club, hot);
        vm.warp(e + 1);
        vm.prank(hot);
        vm.expectRevert(PageNFT.Expired.selector);
        nft.registerSubpageFor("late", club, hot);
        // the view ignores expiry
        _assertOn(club, hot);
        vm.prank(alice);
        vm.expectRevert(PageNFT.Expired.selector);
        nft.setSubpageMinter(club, hot2);
        vm.prank(stranger);
        nft.renew{value: 0.001 ether}(club);
        vm.prank(hot);
        nft.registerSubpageFor("late", club, hot);
        assertEq(nft.epochOf(club), 1);
    }

    // switching off while away: only zero, only by the account that picked it
    function test_switchOffWhileAway() public {
        _setMinter(club, hot);
        vm.prank(alice);
        nft.transferFrom(alice, bob, club);

        vm.prank(alice);
        vm.expectRevert(PageNFT.Unauthorized.selector);
        nft.setSubpageMinter(club, hot2);
        vm.prank(alice);
        vm.expectRevert(PageNFT.Unauthorized.selector);
        nft.setSubpageMinter(club, hot);
        vm.prank(alice);
        vm.expectRevert(PageNFT.Unauthorized.selector);
        nft.setSubpageMinter(club, alice);

        // a non setter cannot switch off, here a stranger and the minter itself
        vm.prank(stranger);
        vm.expectRevert(PageNFT.Unauthorized.selector);
        nft.setSubpageMinter(club, address(0));
        vm.prank(hot);
        vm.expectRevert(PageNFT.Unauthorized.selector);
        nft.setSubpageMinter(club, address(0));

        _expectMinterSet(club, alice, address(0), 1);
        vm.prank(alice);
        nft.setSubpageMinter(club, address(0));
        (address rm,, address rs) = _raw(club);
        assertEq(rm, address(0));
        assertEq(rs, alice);
        vm.prank(bob);
        nft.transferFrom(bob, alice, club);
        _assertOff(club, hot);
        // repeating it is harmless
        vm.prank(alice);
        nft.transferFrom(alice, bob, club);
        vm.prank(alice);
        nft.setSubpageMinter(club, address(0));
    }

    // switching off while away also works while the name is inactive
    function test_switchOffWhileAwayAndInactive() public {
        _setMinter(club, hot);
        vm.prank(alice);
        nft.transferFrom(alice, bob, club);
        vm.warp(nft.expiresAt(club) + 30 days);
        vm.prank(alice);
        nft.setSubpageMinter(club, address(0));
        vm.prank(alice);
        vm.expectRevert(PageNFT.Expired.selector);
        nft.setSubpageMinter(club, hot);
    }

    // clearing works while inactive, in grace and after it
    function test_clearWhileInactive() public {
        _setMinter(club, hot);
        uint256 e = nft.expiresAt(club);
        vm.warp(e + 1);
        vm.prank(alice);
        nft.setSubpageMinter(club, address(0));
        assertEq(_minter(club), address(0));
        _setMinter(club, address(0));
        vm.warp(e + 200 days);
        vm.prank(alice);
        nft.setSubpageMinter(club, address(0));
        vm.prank(alice);
        vm.expectRevert(PageNFT.Expired.selector);
        nft.setSubpageMinter(club, hot);
    }

    // not settable on a subpage, a nonexistent id, by operators, approved accounts, the minter, strangers
    function test_notSettable() public {
        vm.prank(alice);
        uint256 s = nft.registerSubpageFor("sub", club, carol);
        vm.prank(carol);
        vm.expectRevert(PageNFT.NotTopLevel.selector);
        nft.setSubpageMinter(s, hot);
        vm.prank(alice);
        vm.expectRevert(PageNFT.NotTopLevel.selector);
        nft.setSubpageMinter(s, address(0));

        vm.expectRevert(TOKEN_DOES_NOT_EXIST);
        nft.setSubpageMinter(0, hot);
        vm.prank(alice);
        vm.expectRevert(TOKEN_DOES_NOT_EXIST);
        nft.setSubpageMinter(_id("nobody"), address(0));

        vm.prank(alice);
        nft.setApprovalForAll(dave, true);
        vm.prank(dave);
        vm.expectRevert(PageNFT.Unauthorized.selector);
        nft.setSubpageMinter(club, hot);
        vm.prank(dave);
        vm.expectRevert(PageNFT.Unauthorized.selector);
        nft.setSubpageMinter(club, address(0));

        vm.prank(alice);
        nft.approve(bob, club);
        vm.prank(bob);
        vm.expectRevert(PageNFT.Unauthorized.selector);
        nft.setSubpageMinter(club, hot);

        _setMinter(club, hot);
        vm.prank(hot);
        vm.expectRevert(PageNFT.Unauthorized.selector);
        nft.setSubpageMinter(club, hot2);
        vm.prank(hot);
        vm.expectRevert(PageNFT.Unauthorized.selector);
        nft.setSubpageMinter(club, address(0));
        vm.prank(stranger);
        vm.expectRevert(PageNFT.Unauthorized.selector);
        nft.setSubpageMinter(club, stranger);
        assertEq(_minter(club), hot);

        // an inactive parent refuses a nonzero minter
        vm.warp(nft.expiresAt(club) + 1);
        vm.prank(alice);
        vm.expectRevert(PageNFT.Expired.selector);
        nft.setSubpageMinter(club, hot2);
    }

    // the check order of setSubpageMinter
    function test_setterCheckOrder() public {
        // TokenDoesNotExist before anything, for any caller and any minter
        vm.prank(stranger);
        vm.expectRevert(TOKEN_DOES_NOT_EXIST);
        nft.setSubpageMinter(_id("ghost"), hot);
        // NotTopLevel before Expired: a subpage has expiresAt 0
        vm.prank(alice);
        uint256 s = nft.registerSubpageFor("sub", club, carol);
        vm.prank(stranger);
        vm.expectRevert(PageNFT.NotTopLevel.selector);
        nft.setSubpageMinter(s, hot);
        // Expired before Unauthorized
        vm.warp(nft.expiresAt(club) + 1);
        vm.prank(stranger);
        vm.expectRevert(PageNFT.Expired.selector);
        nft.setSubpageMinter(club, hot);
        // with a zero minter the expiry is skipped and Unauthorized is next
        vm.prank(stranger);
        vm.expectRevert(PageNFT.Unauthorized.selector);
        nft.setSubpageMinter(club, address(0));
    }

    // the check order of _registerSubpage with a minter in play
    function test_mintCheckOrder() public {
        _setMinter(club, hot);
        vm.prank(alice);
        nft.registerSubpageFor("live", club, carol);
        address[3] memory callers = [hot, stranger, alice];
        for (uint256 i; i < 3; ++i) {
            vm.startPrank(callers[i]);
            vm.expectRevert(PageNFT.InvalidLabel.selector);
            nft.registerSubpageFor("-bad", 0, hot);
            vm.expectRevert(PageNFT.InvalidLength.selector);
            nft.registerSubpageFor("", club, hot);
            vm.expectRevert(TOKEN_DOES_NOT_EXIST);
            nft.registerSubpageFor("ok", 0, hot);
            vm.expectRevert(TOKEN_DOES_NOT_EXIST);
            nft.registerSubpageFor("ok", _id("ghost"), hot);
            vm.expectRevert(PageNFT.NotTopLevel.selector);
            nft.registerSubpageFor("ok", _subId("live", club), hot);
            vm.stopPrank();
        }
        vm.prank(stranger);
        vm.expectRevert(PageNFT.NotParentOwner.selector);
        nft.registerSubpageFor("live", club, hot);
        vm.prank(hot);
        vm.expectRevert(PageNFT.AlreadyRegistered.selector);
        nft.registerSubpageFor("live", club, hot);
        vm.prank(hot);
        vm.expectRevert(PageNFT.AlreadyRegistered.selector);
        nft.registerSubpage("live", club);
        uint256 e = nft.expiresAt(club);
        vm.warp(e + 1);
        for (uint256 i; i < 3; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(PageNFT.Expired.selector);
            nft.registerSubpageFor("live", club, hot);
        }
    }

    // the storage record sits at slot 12: minter and epoch in word 0, the setter in word 1
    function test_storageSlot12() public {
        _setMinter(club, hot);
        bytes32 base = keccak256(abi.encode(club, uint256(12)));
        uint256 w0 = uint256(vm.load(address(nft), base));
        uint256 w1 = uint256(vm.load(address(nft), bytes32(uint256(base) + 1)));
        assertEq(w0, uint256(uint160(hot)) | (uint256(1) << 160));
        assertEq(w1, uint256(uint160(alice)));
        assertEq(uint256(vm.load(address(nft), bytes32(uint256(base) + 2))), 0);
    }

    // the view never reverts and answers zero for ids that cannot carry a minter
    function testFuzz_viewNeverReverts(uint256 id) public view {
        address m = nft.subpageMinterOf(id);
        if (id != club) assertEq(m, address(0));
    }

    // any caller and any minter: a call succeeds exactly when the rules allow it, and a
    // refused call changes nothing
    function testFuzz_setterRule(address caller, address m, bool away, bool expired, bool setterIsAlice) public {
        vm.assume(caller != address(0));
        if (setterIsAlice) _setMinter(club, hot);
        if (away) {
            vm.prank(alice);
            nft.transferFrom(alice, bob, club);
        }
        if (expired) vm.warp(nft.expiresAt(club) + 1);
        address holder = nft.ownerOf(club);
        (,, address setter) = _raw(club);
        address before = nft.subpageMinterOf(club);

        bool allowed = !(m != address(0) && expired) && (caller == holder || (m == address(0) && caller == setter));
        vm.recordLogs();
        vm.prank(caller);
        (bool ok,) = address(nft).call(abi.encodeCall(PageNFT.setSubpageMinter, (club, m)));
        assertEq(ok, allowed);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        if (ok) {
            assertEq(logs.length, 1);
            assertEq(logs[0].topics[0], T_MINTER_SET);
            // _raw also checks that no other bits are set in either storage word
            (address rm, uint64 re, address rs) = _raw(club);
            assertEq(rm, m);
            assertEq(re, 1);
            assertEq(rs, caller);
            // the pick counts only when the holder made it
            assertEq(nft.subpageMinterOf(club), caller == holder ? m : address(0));
        } else {
            assertEq(logs.length, 0);
            assertEq(nft.subpageMinterOf(club), before);
        }
    }
}

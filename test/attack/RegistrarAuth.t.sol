// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {PageNFT} from "../../src/PageNFT.sol";
import {SubpageRegistrar} from "../../src/SubpageRegistrar.sol";
import {MinterBase} from "../utils/MinterBase.sol";
import {HolderHook} from "./MinterAuth.t.sol";

// a fee token whose transferFrom calls whatever it was armed with
contract ReenteringToken {
    address public target;
    bytes public data;
    bool public ok;
    bytes public ret;

    function arm(address t, bytes calldata d) external {
        target = t;
        data = d;
    }

    function balanceOf(address) external pure returns (uint256) {
        return 1;
    }

    function transferFrom(address, address, uint256) external returns (bool) {
        if (target != address(0)) {
            address t = target;
            target = address(0);
            (ok, ret) = t.call(data);
        }
        return true;
    }
}

contract RegistrarAuthTest is MinterBase {
    uint256 club;
    uint256 gold;

    function setUp() public override {
        super.setUp();
        club = _reg(alice, "club");
        gold = _reg(bob, "gold");
    }

    // R1: a new holder who picks the registrar never sells on the old holder's config, and a buy back revives nothing old
    function test_R1_newHolderAndBuyBack() public {
        _sellSetup(club, 0.01 ether);
        vm.prank(alice);
        nft.transferFrom(alice, bob, club);
        _setMinter(club, address(reg));
        vm.prank(buyer);
        vm.expectRevert(SubpageRegistrar.StaleController.selector);
        reg.registerSubpage{value: 0.01 ether}(club, "a", 0.01 ether, address(0));
        vm.prank(bob);
        reg.configure(club, bob, address(0), 0.02 ether, true, address(0), 0, false);
        vm.prank(buyer);
        reg.registerSubpage{value: 0.02 ether}(club, "a", 0.02 ether, address(0));
        assertEq(reg.proceedsOf(bob), 0.02 ether);
        assertEq(reg.proceedsOf(payout), 0);
        vm.prank(bob);
        nft.transferFrom(bob, alice, club);
        vm.prank(buyer);
        vm.expectRevert(SubpageRegistrar.StaleController.selector);
        reg.registerSubpage{value: 0.02 ether}(club, "b", 0.02 ether, address(0));
        assertEq(_minter(club), address(0));
    }

    // R2: the registrar only mints where both the pick and the config are the holder's own
    function test_R2_crossParent() public {
        // alice picks the registrar for club but configures nothing
        _setMinter(club, address(reg));
        vm.prank(buyer);
        vm.expectRevert(SubpageRegistrar.NotEnabled.selector);
        reg.registerSubpage(club, "x", 0, address(0));
        // bob configures gold but picks nothing
        _configure(gold, bob, address(0), 0, false);
        vm.prank(buyer);
        vm.expectRevert(SubpageRegistrar.NotMinter.selector);
        reg.registerSubpage(gold, "x", 0, address(0));
        // strangers cannot configure or disable
        vm.prank(stranger);
        vm.expectRevert(SubpageRegistrar.NotAuthorized.selector);
        reg.configure(club, stranger, address(0), 0, true, address(0), 0, false);
        vm.prank(stranger);
        vm.expectRevert(SubpageRegistrar.NotAuthorized.selector);
        reg.disable(gold);
        // subpage and ghost ids
        vm.prank(alice);
        uint256 sub = nft.registerSubpageFor("sub", club, alice);
        vm.prank(alice);
        vm.expectRevert(SubpageRegistrar.ParentNotTopLevel.selector);
        reg.configure(sub, alice, address(0), 0, true, address(0), 0, false);
        vm.prank(stranger);
        vm.expectRevert(TOKEN_DOES_NOT_EXIST);
        reg.configure(_id("ghost"), stranger, address(0), 0, true, address(0), 0, false);
    }

    // R3: a new registration by the same holder: the old config is stale, a fresh config without a fresh pick sells nothing
    function test_R3_reRegistrationSameHolder() public {
        _sellSetup(club, 0);
        vm.warp(nft.expiresAt(club) + 90 days + 21 days + 1);
        _reg(alice, "club");
        vm.prank(buyer);
        vm.expectRevert(SubpageRegistrar.StaleConfig.selector);
        reg.registerSubpage(club, "x", 0, address(0));
        _configure(club, payout, address(0), 0, false);
        vm.prank(buyer);
        vm.expectRevert(SubpageRegistrar.NotMinter.selector);
        reg.registerSubpage(club, "x", 0, address(0));
    }

    // R4: a holder hook inside a sale cannot reconfigure, disable or claim through the registrar
    function test_R4_holderHookIntoRegistrar() public {
        HolderHook h = new HolderHook();
        uint256 p = _regTo(alice, "hooked", address(h));
        h.exec(address(nft), 0, abi.encodeCall(PageNFT.setSubpageMinter, (p, address(reg))));
        h.exec(address(reg), 0, abi.encodeCall(SubpageRegistrar.configure, (p, address(h), address(0), 0.01 ether, true, address(0), 0, false)));
        bytes[3] memory calls = [
            abi.encodeCall(SubpageRegistrar.configure, (p, address(h), address(0), 0, true, address(0), 0, false)),
            abi.encodeCall(SubpageRegistrar.disable, (p)),
            abi.encodeCall(SubpageRegistrar.claimProceeds, (address(h)))
        ];
        string[3] memory labels = ["one", "two", "three"];
        for (uint256 i; i < 3; ++i) {
            h.arm(address(reg), calls[i]);
            vm.prank(buyer);
            reg.registerSubpageFor{value: 0.01 ether}(p, labels[i], address(h), 0.01 ether, address(0));
            assertFalse(h.ok());
            assertEq(bytes4(h.ret()), REENTRANCY);
        }
        (, bool enabled,,,,,,,) = reg.config(p);
        assertTrue(enabled);
        assertEq(reg.proceedsOf(address(h)), 0.03 ether);
    }

    // R5: a fee token that calls PageNFT after the mint is just another account: no mint, no pick
    function test_R5_feeTokenReentry() public {
        ReenteringToken t = new ReenteringToken();
        _setMinter(club, address(reg));
        _configure(club, payout, address(t), 1, false);
        vm.prank(alice);
        uint256 live = nft.registerSubpageFor("live", club, carol);
        t.arm(address(nft), abi.encodeCall(PageNFT.registerSubpageFor, ("live", club, address(t))));
        vm.prank(buyer);
        reg.registerSubpage(club, "new", 1, address(t));
        assertFalse(t.ok());
        assertEq(bytes4(t.ret()), PageNFT.NotParentOwner.selector);
        assertEq(nft.ownerOf(live), carol);
        t.arm(address(nft), abi.encodeCall(PageNFT.setSubpageMinter, (club, address(t))));
        vm.prank(buyer);
        reg.registerSubpage(club, "new2", 1, address(t));
        assertFalse(t.ok());
        assertEq(bytes4(t.ret()), PageNFT.Unauthorized.selector);
        // the registrar itself called again from the token: guarded
        t.arm(address(reg), abi.encodeCall(SubpageRegistrar.registerSubpage, (club, "new3", 1, address(t))));
        vm.prank(buyer);
        reg.registerSubpage(club, "new4", 1, address(t));
        assertFalse(t.ok());
        assertEq(bytes4(t.ret()), REENTRANCY);
    }
}

// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {SubpageRegistrar} from "../../src/SubpageRegistrar.sol";
import {MinterBase} from "../utils/MinterBase.sol";

contract RegistrarResumeTest is MinterBase {
    // Clearing the minter stops sales but the config still reads enabled, and picking the registrar
    // again resumes the old price and payout with no new configure call.
    function test_clearedMinterLeavesEnabledConfigThatResumes() public {
        uint256 p = _reg(alice, "club");
        _sellSetup(p, 0.01 ether);
        _setMinter(p, address(0));
        (, bool enabled,,, uint96 price,,, address pay,) = reg.config(p);
        assertTrue(enabled, "config still enabled");
        assertEq(price, 0.01 ether);
        vm.prank(buyer);
        vm.expectRevert(SubpageRegistrar.NotMinter.selector);
        reg.registerSubpage{value: 0.01 ether}(p, "a", 0.01 ether, address(0));

        _setMinter(p, address(reg));
        vm.prank(buyer);
        reg.registerSubpage{value: 0.01 ether}(p, "a", 0.01 ether, address(0));
        assertEq(reg.proceedsOf(pay), 0.01 ether, "old payout paid");
    }

    // A round trip of the parent through another wallet turns sales off and then back on with no
    // registrar or minter event.
    function test_roundTripRevivesSalesSilently() public {
        uint256 p = _reg(alice, "club");
        _sellSetup(p, 0);
        vm.prank(alice);
        nft.transferFrom(alice, bob, p);
        vm.prank(buyer);
        vm.expectRevert(SubpageRegistrar.StaleController.selector);
        reg.registerSubpage(p, "a", 0, address(0));
        vm.recordLogs();
        vm.prank(bob);
        nft.transferFrom(bob, alice, p);
        assertFalse(_has(vm.getRecordedLogs(), T_MINTER_SET));
        vm.prank(buyer);
        reg.registerSubpage(p, "a", 0, address(0));
        assertEq(nft.ownerOf(_subId("a", p)), buyer);
    }

    // A sale leaves SubpageSold naming the buyer, so registrar mints are attributable in logs,
    // unlike a direct minter mint.
    function test_saleIsAttributableInLogs() public {
        uint256 p = _reg(alice, "club");
        _sellSetup(p, 0);
        vm.recordLogs();
        vm.prank(buyer);
        reg.registerSubpageFor(p, "a", carol, 0, address(0));
        assertTrue(_has(vm.getRecordedLogs(), keccak256("SubpageSold(uint256,uint256,address,address,address,address,uint256,string)")));
    }
}

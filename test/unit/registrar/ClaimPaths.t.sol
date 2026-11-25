// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {SubpageRegistrar} from "../../../src/SubpageRegistrar.sol";
import {MinterBase} from "../../utils/MinterBase.sol";

// Claims of registrar proceeds: both claim functions refuse a zero balance, and a claim sent with value is
// refused even while a balance is owed, so it moves nothing.
contract ClaimPathsTest is MinterBase {
    uint256 constant PRICE = 0.01 ether;
    uint256 club;

    function setUp() public override {
        super.setUp();
        club = _reg(alice, "club");
        _setMinter(club, address(reg));
    }

    function _sell(uint256 parentId, string memory label) internal {
        (,,,, uint96 price,,,,) = reg.config(parentId);
        vm.prank(buyer);
        reg.registerSubpage{value: price}(parentId, label, price, address(0));
    }

    function _terms(uint256 parentId, address pay, address feeToken, uint256 price) internal {
        vm.prank(nft.ownerOf(parentId));
        reg.configure(parentId, pay, feeToken, price, true, address(0), 0, false);
    }

    // Nothing owed means NothingToClaim, for a fresh account, the three accounts nothing is ever credited to, DEAD
    // and a random address, after a free sale and straight after a claim. A claim sent with value fails, as neither
    // claim takes ETH, and moves nothing.
    function test_claimForZeroBalanceReverts() public {
        address[6] memory never = [
            makeAddr("fresh"), address(0), address(reg), address(nft), DEAD,
            address(uint160(uint256(keccak256("a random address"))))
        ];
        for (uint256 i; i < never.length; ++i) {
            vm.prank(stranger);
            vm.expectRevert(SubpageRegistrar.NothingToClaim.selector);
            reg.claimProceedsFor(never[i]);
        }

        _terms(club, payout, address(0), 0);
        vm.prank(buyer);
        reg.registerSubpage(club, "free", 0, address(0));
        assertEq(reg.proceedsOf(payout), 0, "a free sale credits nothing");
        vm.prank(stranger);
        vm.expectRevert(SubpageRegistrar.NothingToClaim.selector);
        reg.claimProceedsFor(payout);
        vm.prank(payout);
        vm.expectRevert(SubpageRegistrar.NothingToClaim.selector);
        reg.claimProceeds(address(0));

        _terms(club, payout, address(0), PRICE);
        _sell(club, "paid");
        vm.prank(stranger);
        (bool ok,) = address(reg).call{value: 1}(abi.encodeCall(SubpageRegistrar.claimProceedsFor, (payout)));
        assertFalse(ok, "claimProceedsFor with value");
        vm.deal(payout, 1);
        vm.prank(payout);
        (ok,) = address(reg).call{value: 1}(abi.encodeCall(SubpageRegistrar.claimProceeds, (address(0))));
        assertFalse(ok, "claimProceeds with value");
        assertEq(reg.proceedsOf(payout), PRICE, "the balance stays");
        assertEq(address(reg).balance, PRICE);
        assertEq(payout.balance, 1);

        vm.prank(stranger);
        reg.claimProceedsFor(payout);
        assertEq(payout.balance, 1 + PRICE);
        vm.prank(stranger);
        vm.expectRevert(SubpageRegistrar.NothingToClaim.selector);
        reg.claimProceedsFor(payout);
    }
}

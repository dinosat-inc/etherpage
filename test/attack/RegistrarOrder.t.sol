// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {SubpageRegistrar} from "../../src/SubpageRegistrar.sol";
import {MinterBase} from "../utils/MinterBase.sol";
import {GasBurnGate} from "../utils/TokenMocks.sol";

// The buyer's two guards come in a fixed order, and a gate that burns all the gas it is given fails the
// sale with GateFailed under an ordinary gas limit.
contract RegistrarOrderTest is MinterBase {
    uint256 club;

    function setUp() public override {
        super.setUp();
        club = _reg(alice, "club");
        _setMinter(club, address(reg));
    }

    function _cfg(address feeToken, uint256 price, address gate, uint256 minGate, bool commitReveal) internal {
        vm.prank(alice);
        reg.configure(club, payout, feeToken, price, true, gate, minGate, commitReveal);
    }

    function _sale(uint256 path, address expected, uint256 maxPrice) internal returns (bool ok, bytes memory ret) {
        bytes memory data;
        if (path == 0) data = abi.encodeCall(SubpageRegistrar.registerSubpage, (club, "a", maxPrice, expected));
        else if (path == 1) data = abi.encodeCall(SubpageRegistrar.registerSubpageFor, (club, "a", bob, maxPrice, expected));
        else if (path == 2) data = abi.encodeCall(SubpageRegistrar.revealSubpage, (club, "a", bytes32(0), maxPrice, expected));
        else data = abi.encodeCall(SubpageRegistrar.revealSubpageFor, (club, "a", bob, bytes32(0), maxPrice, expected));
        vm.prank(buyer);
        (ok, ret) = address(reg).call(data);
    }

    // a call that fails both guards reverts UnexpectedFeeToken on all four entry points, for a token sale and
    // for an ETH sale; each guard alone gives its own error
    function test_feeTokenCheckedBeforePrice() public {
        for (uint256 path; path < 4; ++path) {
            bool commitReveal = path >= 2;
            _cfg(address(usd), 10, address(0), 0, commitReveal);
            (bool ok, bytes memory ret) = _sale(path, address(0), 9);
            assertFalse(ok);
            assertEq(bytes4(ret), SubpageRegistrar.UnexpectedFeeToken.selector, "the fee token first");
            (ok, ret) = _sale(path, address(usd), 9);
            assertEq(bytes4(ret), SubpageRegistrar.PriceTooHigh.selector, "then the price");
            (ok, ret) = _sale(path, address(0), 10);
            assertEq(bytes4(ret), SubpageRegistrar.UnexpectedFeeToken.selector);

            _cfg(address(0), 10, address(0), 0, commitReveal);
            (ok, ret) = _sale(path, address(usd), 9);
            assertEq(bytes4(ret), SubpageRegistrar.UnexpectedFeeToken.selector, "the fee token first on an ETH sale");
            (ok, ret) = _sale(path, address(0), 9);
            assertEq(bytes4(ret), SubpageRegistrar.PriceTooHigh.selector);
        }
        assertTrue(nft.isAvailable("a", club), "nothing was sold");
    }

    // a gate whose balanceOf burns all the gas it is given: under gas limits of half a million to thirty
    // million the sale reverts with the GateFailed selector, mints nothing and moves no money
    function test_gasBurningGateFailsClosed() public {
        GasBurnGate gate = new GasBurnGate();
        uint256[4] memory limits = [uint256(500_000), 1_000_000, 10_000_000, 30_000_000];
        for (uint256 t; t < 2; ++t) {
            bool token = t == 1;
            _cfg(token ? address(usd) : address(0), 0.01 ether, address(gate), 1, false);
            if (token) {
                usd.mint(buyer, 1 ether);
                vm.prank(buyer);
                usd.approve(address(reg), 1 ether);
            }
            for (uint256 i; i < 4; ++i) {
                uint256 balance = buyer.balance;
                uint256 tokens = usd.balanceOf(buyer);
                vm.prank(buyer);
                (bool ok, bytes memory ret) = address(reg).call{value: token ? 0 : 0.01 ether, gas: limits[i]}(
                    abi.encodeCall(SubpageRegistrar.registerSubpage, (club, "gated", 0.01 ether, token ? address(usd) : address(0)))
                );
                assertFalse(ok, "the sale fails");
                assertEq(ret, abi.encodeWithSelector(SubpageRegistrar.GateFailed.selector), "with GateFailed");
                assertTrue(nft.isAvailable("gated", club), "nothing minted");
                assertEq(buyer.balance, balance, "no ETH moved");
                assertEq(usd.balanceOf(buyer), tokens, "no token moved");
                assertEq(usd.balanceOf(payout), 0);
                assertEq(reg.proceedsOf(payout), 0);
                assertEq(address(reg).balance, 0);
            }
        }
    }
}

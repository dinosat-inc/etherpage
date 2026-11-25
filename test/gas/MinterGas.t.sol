// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {PageCard} from "../../src/PageCard.sol";
import {PageNFT} from "../../src/PageNFT.sol";
import {SubpageRegistrar, IPageNFT} from "../../src/SubpageRegistrar.sol";
import {PageNFTNoMinter} from "../differential/harness/PageNFTNoMinter.sol";
import {MockERC20} from "../utils/MinterMocks.sol";

// Run with the isolate option so each call is its own transaction, base cost included.
contract MinterGasTest is Test {
    PageNFT nft;
    PageNFTNoMinter base;
    SubpageRegistrar reg;
    MockERC20 usd;
    address seller = makeAddr("seller");
    address buyer = makeAddr("buyer");
    address hot = makeAddr("hot");
    address carol = makeAddr("carol");

    function setUp() public {
        vm.warp(1_800_000_000);
        PageCard card = new PageCard();
        nft = new PageNFT(card);
        base = new PageNFTNoMinter(card);
        reg = new SubpageRegistrar(IPageNFT(address(nft)));
        usd = new MockERC20();
        vm.deal(seller, 100 ether);
        vm.deal(buyer, 100 ether);
    }

    function _g() internal view returns (uint256) {
        return vm.lastCallGas().gasTotalUsed;
    }

    function _reg(address n, string memory label) internal returns (uint256 id) {
        bytes32 s = keccak256(abi.encode(label));
        bytes32 c = PageNFT(n).makeCommitment(label, seller, 0, s);
        vm.prank(seller);
        PageNFT(n).commit(c);
        vm.warp(vm.getBlockTimestamp() + 61);
        (,,, uint256 total) = PageNFT(n).quote(label);
        vm.prank(seller);
        id = PageNFT(n).reveal{value: total}(label, seller, 0, s);
    }

    function test_gas_ownerPathBothBuilds() public {
        uint256 a = _reg(address(nft), "club");
        uint256 b = _reg(address(base), "club");
        vm.prank(seller);
        nft.registerSubpageFor("abcd", a, carol);
        uint256 withMinter = _g();
        vm.prank(seller);
        base.registerSubpageFor("abcd", b, carol);
        uint256 without = _g();
        emit log_named_uint("owner mint, fresh label, with minter", withMinter);
        emit log_named_uint("owner mint, fresh label, without minter", without);
        vm.prank(seller);
        nft.registerSubpageFor("abcd", a, seller);
        withMinter = _g();
        vm.prank(seller);
        base.registerSubpageFor("abcd", b, seller);
        without = _g();
        emit log_named_uint("owner take-back, with minter", withMinter);
        emit log_named_uint("owner take-back, without minter", without);
    }

    function test_gas_minterPaths() public {
        uint256 club = _reg(address(nft), "club");
        vm.prank(seller);
        nft.setSubpageMinter(club, hot);
        emit log_named_uint("setSubpageMinter, first pick", _g());
        vm.prank(seller);
        nft.setSubpageMinter(club, hot);
        emit log_named_uint("setSubpageMinter, same pick again", _g());
        vm.prank(hot);
        nft.registerSubpageFor("abcd", club, carol);
        emit log_named_uint("minter mint, fresh label", _g());
        vm.prank(hot);
        vm.expectRevert(PageNFT.AlreadyRegistered.selector);
        nft.registerSubpageFor("abcd", club, hot);
        emit log_named_uint("minter take-back, refused", _g());
        vm.prank(seller);
        nft.setSubpageMinter(club, address(0));
        emit log_named_uint("setSubpageMinter, clear", _g());
        address m = nft.subpageMinterOf(club);
        assertEq(m, address(0));
    }

    function test_gas_registrarSales() public {
        uint256 club = _reg(address(nft), "club");
        vm.prank(seller);
        nft.setSubpageMinter(club, address(reg));
        uint256 t = _g();
        vm.prank(seller);
        reg.configure(club, seller, address(0), 0.01 ether, true, address(0), 0, false);
        t += _g();
        emit log_named_uint("sale setup, 2 tx", t);
        vm.prank(buyer);
        reg.registerSubpage{value: 0.01 ether}(club, "abcd", 0.01 ether, address(0));
        emit log_named_uint("ETH sale, first", _g());
        vm.prank(buyer);
        reg.registerSubpage{value: 0.02 ether}(club, "efgh", 0.01 ether, address(0));
        emit log_named_uint("ETH sale, second, with refund", _g());
        vm.prank(seller);
        nft.registerSubpageFor("abcd", club, seller);
        emit log_named_uint("owner take-back of a sold subpage, 1 tx", _g());
        vm.prank(buyer);
        reg.claimProceedsFor(seller);
        emit log_named_uint("claimProceedsFor", _g());

        vm.prank(seller);
        reg.configure(club, seller, address(0), 0, true, address(0), 0, false);
        vm.prank(buyer);
        reg.registerSubpage(club, "free1", 0, address(0));
        emit log_named_uint("free sale", _g());

        vm.prank(seller);
        reg.configure(club, seller, address(usd), 5e6, true, address(0), 0, false);
        usd.mint(buyer, 100e6);
        vm.prank(buyer);
        usd.approve(address(reg), type(uint256).max);
        vm.prank(buyer);
        reg.registerSubpage(club, "coin1", 5e6, address(usd));
        emit log_named_uint("ERC20 sale", _g());

        vm.prank(seller);
        reg.configure(club, seller, address(0), 0.01 ether, true, address(0), 0, true);
        bytes32 c = reg.makeSubpageCommitment(club, "rev1", buyer, bytes32("s"));
        vm.prank(buyer);
        reg.commitSubpage(c);
        emit log_named_uint("commitSubpage", _g());
        vm.warp(vm.getBlockTimestamp() + 61);
        vm.prank(buyer);
        reg.revealSubpage{value: 0.01 ether}(club, "rev1", bytes32("s"), 0.01 ether, address(0));
        emit log_named_uint("reveal sale", _g());
    }
}

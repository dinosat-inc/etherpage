// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {PageNFT} from "../../src/PageNFT.sol";
import {PageCard} from "../../src/PageCard.sol";
import {SubpageRegistrar, IPageNFT} from "../../src/SubpageRegistrar.sol";

// Run with the isolate option so each call is its own transaction, base cost included.
contract MinterSaleGasTest is Test {
    PageNFT nft;
    SubpageRegistrar reg;
    address seller = makeAddr("seller");
    address buyer = makeAddr("buyer");

    function setUp() public {
        vm.warp(1_800_000_000);
        nft = new PageNFT(new PageCard());
        reg = new SubpageRegistrar(IPageNFT(address(nft)));
        vm.deal(seller, 100 ether);
        vm.deal(buyer, 100 ether);
    }

    function _reg(string memory label) internal returns (uint256 id) {
        bytes32 s = keccak256(abi.encode(label));
        bytes32 commitment = nft.makeCommitment(label, seller, 0, s);
        vm.prank(seller);
        nft.commit(commitment);
        vm.warp(block.timestamp + 61);
        (,,, uint256 total) = nft.quote(label);
        vm.prank(seller);
        id = nft.reveal{value: total}(label, seller, 0, s);
        vm.prank(seller);
        nft.setAddr(id, seller);
    }

    function _g() internal view returns (uint256) {
        return vm.lastCallGas().gasTotalUsed;
    }

    function test_gas_minter() public {
        uint256 club = _reg("club");
        uint256 t;
        vm.prank(seller);
        nft.setSubpageMinter(club, address(reg));
        t = _g();
        vm.prank(seller);
        reg.configure(club, seller, address(0), 0.01 ether, true, address(0), 0, false);
        t += _g();
        emit log_named_uint("minter setup, 2 tx", t);
        vm.prank(buyer);
        reg.registerSubpage{value: 0.01 ether}(club, "abcd", 0.01 ether, address(0));
        emit log_named_uint("minter first sale", _g());
        vm.prank(buyer);
        reg.registerSubpage{value: 0.01 ether}(club, "efgh", 0.01 ether, address(0));
        emit log_named_uint("minter second sale", _g());
        vm.prank(seller);
        nft.registerSubpageFor("abcd", club, seller);
        emit log_named_uint("minter take-back, 1 tx", _g());
        vm.prank(seller);
        nft.setSubpageMinter(club, address(0));
        emit log_named_uint("stop selling, 1 tx", _g());
    }
}

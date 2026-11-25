// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {PageNFT} from "../../src/PageNFT.sol";
import {PageCard} from "../../src/PageCard.sol";

// gas of the paid paths; run with the isolate option so each call is its own transaction
contract PaidGasTest is Test {
    PageNFT nft;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        vm.warp(1_800_000_000);
        nft = new PageNFT(new PageCard());
        vm.deal(alice, 10 ether);
    }

    function _call(address from, uint256 value, bytes memory data, string memory what) internal {
        vm.prank(from);
        (bool ok,) = address(nft).call{value: value}(data);
        assertTrue(ok, what);
        emit log_named_uint(what, vm.lastCallGas().gasTotalUsed);
    }

    function test_gas_paidPaths() public {
        bytes32 s = keccak256("s");
        _call(alice, 0, abi.encodeCall(PageNFT.commit, (nft.makeCommitment("alice-name", alice, 0, s))), "commit");
        vm.warp(vm.getBlockTimestamp() + 61);
        _call(alice, nft.getFee(10), abi.encodeCall(PageNFT.reveal, ("alice-name", alice, 0, s)), "reveal paid");
        uint256 id = nft.computeId("alice-name");
        _call(alice, 0, abi.encodeCall(PageNFT.registerSubpage, ("sub", id)), "registerSubpage");
        uint256 sub = nft.computeId("sub.alice-name");
        _call(alice, 0, abi.encodeWithSignature("isAvailable(string,uint256)", "alice-name", 0), "isAvailable top-level");
        _call(alice, 0, abi.encodeWithSignature("isAvailable(string,uint256)", "sub2", id), "isAvailable subpage");
        _call(alice, nft.getFee(10), abi.encodeCall(PageNFT.renew, (id)), "renew");
        _call(alice, 0, abi.encodeCall(PageNFT.transferFrom, (alice, bob, sub)), "transfer subpage");
        _call(alice, 0, abi.encodeCall(PageNFT.transferFrom, (alice, bob, id)), "transfer top-level");
        _call(bob, 0, abi.encodeCall(PageNFT.setPrimaryPage, (id)), "setPrimaryPage");
        _call(bob, 0, abi.encodeCall(PageNFT.tokenURI, (id)), "tokenURI top-level");
        _call(bob, 0, abi.encodeCall(PageNFT.isExpired, (id)), "isExpired");
        _call(bob, 0, abi.encodeCall(PageNFT.getPremium, (id)), "getPremium");
    }
}

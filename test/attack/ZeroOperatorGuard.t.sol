// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {PageCard} from "../../src/PageCard.sol";
import {PageNFT} from "../../src/PageNFT.sol";

interface IZO {
    function makeCommitment(string calldata, address, uint256, bytes32) external pure returns (bytes32);
    function commit(bytes32) external;
    function reveal(string calldata, address, uint256, bytes32) external payable returns (uint256);
    function quote(string calldata) external view returns (uint256, uint256, uint256, uint256);
    function approve(address, uint256) external payable;
    function setApprovalForAll(address, bool) external;
    function transferFrom(address, address, uint256) external payable;
    function ownerOf(uint256) external view returns (address);
}

// The zero caller when the holder has made address(0) an operator and the name also has an approved account. The
// library then lets address(0) through as an operator, not as the unset approval, so only a guard that refuses
// address(0) whatever the approvals stops it: a guard that refuses address(0) only when the name has no approved
// account fails this test.
contract ZeroOperatorGuardTest is Test {
    address nft;
    address alice = makeAddr("zo-alice");
    address bob = makeAddr("zo-bob");
    address thief = makeAddr("zo-thief");

    function setUp() public {
        vm.warp(1_800_000_000);
        address card = address(new PageCard());
        nft = address(new PageNFT(PageCard(card)));
        vm.deal(alice, 10 ether);
    }

    function test_zeroOperatorAndAnApprovalMoveNothing() public {
        bytes32 c = IZO(nft).makeCommitment("gold", alice, 0, bytes32("s"));
        vm.prank(alice);
        IZO(nft).commit(c);
        vm.warp(vm.getBlockTimestamp() + 61);
        (,,, uint256 total) = IZO(nft).quote("gold");
        vm.prank(alice);
        uint256 id = IZO(nft).reveal{value: total}("gold", alice, 0, bytes32("s"));
        vm.startPrank(alice);
        IZO(nft).setApprovalForAll(address(0), true);
        IZO(nft).approve(bob, id);
        vm.stopPrank();
        vm.prank(address(0));
        (bool ok, bytes memory ret) = nft.call(abi.encodeWithSignature("transferFrom(address,address,uint256)", alice, thief, id));
        assertFalse(ok, "the zero caller moves nothing");
        assertEq(ret, abi.encodeWithSelector(bytes4(0x4b6e7f18)), "NotOwnerNorApproved");
        assertEq(IZO(nft).ownerOf(id), alice);
    }
}

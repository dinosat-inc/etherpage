// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Test, Vm} from "forge-std/Test.sol";
import {PageCard} from "../../../src/PageCard.sol";
import {PageNFT} from "../../../src/PageNFT.sol";

interface IH {
    function makeCommitment(string calldata, address, uint256, bytes32) external pure returns (bytes32);
    function commit(bytes32) external;
    function reveal(string calldata, address, uint256, bytes32) external payable returns (uint256);
    function quote(string calldata) external view returns (uint256, uint256, uint256, uint256);
    function setAddr(uint256, address) external;
    function setAddrForCoin(uint256, uint256, bytes calldata) external;
    function transferFrom(address, address, uint256) external payable;
    function addr(uint256, uint256) external view returns (bytes memory);
}

// The two moves where only the saved default decides the Ethereum announcement of the transfer hook. A build whose
// hook ignored the default would pass every test of the changes in the repository, while an indexer that follows the
// logs would end on a wrong coin 60 answer.
contract HookAnnouncementsTest is Test {
    address nft;
    address alice = makeAddr("h-alice");
    address bob = makeAddr("h-bob");
    address cold = makeAddr("h-cold");
    bytes32 constant T_ADDRESS = keccak256("AddressChanged(bytes32,uint256,bytes)");

    function setUp() public {
        vm.warp(1_800_000_000);
        address card = address(new PageCard());
        nft = address(new PageNFT(PageCard(card)));
        vm.deal(alice, 10 ether);
    }

    function _reg() internal returns (uint256 id) {
        bytes32 c = IH(nft).makeCommitment("hook", alice, 0, bytes32("s"));
        vm.prank(alice);
        IH(nft).commit(c);
        vm.warp(vm.getBlockTimestamp() + 61);
        (,,, uint256 total) = IH(nft).quote("hook");
        vm.prank(alice);
        id = IH(nft).reveal{value: total}("hook", alice, 0, bytes32("s"));
    }

    // the coin 60 logs of a move, in order
    function _move(address from, address to, uint256 id) internal returns (bytes[] memory eth) {
        vm.recordLogs();
        vm.prank(from);
        IH(nft).transferFrom(from, to, id);
        Vm.Log[] memory l = vm.getRecordedLogs();
        uint256 n;
        eth = new bytes[](l.length);
        for (uint256 i; i < l.length; ++i) {
            if (l[i].topics[0] != T_ADDRESS) continue;
            (uint256 coin, bytes memory a) = abi.decode(l[i].data, (uint256, bytes));
            if (coin == 60) eth[n++] = a;
        }
        assembly ("memory-safe") {
            mstore(eth, n)
        }
    }

    // back with its saver, the default answers coin 60 again, and the move announces it
    function test_moveBackAnnouncesTheSaversDefault() public {
        uint256 id = _reg();
        vm.prank(alice);
        IH(nft).setAddrForCoin(id, 0x80000000, abi.encodePacked(cold));
        _move(alice, bob, id);
        bytes[] memory eth = _move(bob, alice, id);
        assertEq(IH(nft).addr(id, 60), abi.encodePacked(cold), "coin 60 answers the default of the holder");
        assertEq(eth.length, 1, "one Ethereum announcement");
        assertEq(eth[0], abi.encodePacked(cold), "the move announces the default");
    }

    // the main address stays the same across the move, and only the default makes the coin 60 answer change, from the
    // seller's default to nothing, as the buyer saved nothing, so the move must announce it
    function test_sameMainButTheDefaultLeaves() public {
        uint256 id = _reg();
        vm.startPrank(alice);
        IH(nft).setAddr(id, bob);
        IH(nft).setAddrForCoin(id, 0x80000000, abi.encodePacked(cold));
        vm.stopPrank();
        assertEq(IH(nft).addr(id, 60), abi.encodePacked(cold));
        bytes[] memory eth = _move(alice, bob, id);
        assertEq(IH(nft).addr(id, 60), "", "the new holder saved nothing, so coin 60 answers nothing");
        assertEq(eth.length, 1, "the move announces the Ethereum answer it changed");
        assertEq(eth[0], "", "the move announces the empty answer");
    }
}

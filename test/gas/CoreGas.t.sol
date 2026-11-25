// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {PageCard} from "../../src/PageCard.sol";
import {PageNFT} from "../../src/PageNFT.sol";
import {MinterBase} from "../utils/MinterBase.sol";

contract CoreGasTest is Test {
    function test_clearRecordsCold() public {
        vm.warp(1_800_000_000);
        PageNFT nft = new PageNFT(new PageCard());
        address alice = address(0xA11CE);
        vm.deal(alice, 1 ether);
        bytes32 commitment = nft.makeCommitment("alice", alice, 0, bytes32("s"));
        vm.prank(alice);
        nft.commit(commitment);
        vm.warp(1_800_000_100);
        vm.prank(alice);
        uint256 id = nft.reveal{value: 0.001 ether}("alice", alice, 0, bytes32("s"));
        vm.prank(alice);
        nft.setText(id, "k", "v");
        vm.cool(address(nft));
        vm.prank(alice);
        uint256 g = gasleft();
        nft.clearRecords(id);
        g = g - gasleft();
        emit log_named_uint("clearRecords cold, inner call gas", g);
    }
}

// A write that stores the block time in holderSince or addressesUpdatedAt costs 2800 more gas for each such slot
// when the slot was last written in an earlier second. In the same second the write leaves the slot as it was, which
// is cheaper. So a gas estimate made in the second of the last write can be that much short when the transaction is
// mined a second later. A 25 percent headroom covers it on every path. Each slot was last written in setUp, and each
// call is measured from one snapshot on a cold contract, so the figures are the same whether or not forge runs each
// call of a test on its own.
contract HolderTimeGasTest is MinterBase {
    uint256 shop;
    uint256 moved;
    uint256 sub;
    uint256 gone;

    function setUp() public override {
        super.setUp();
        shop = _reg(alice, "shop");
        moved = _reg(alice, "moved");
        vm.startPrank(alice);
        sub = nft.registerSubpageFor("sub", shop, bob);
        gone = nft.registerSubpageFor("gone", shop, bob);
        vm.stopPrank();
        // every account a measured transfer touches already holds a page
        _reg(carol, "carolpage");
        _reg(dave, "davepage");
        // the last writes of each time slot, all in the second the test runs in
        vm.prank(alice);
        nft.transferFrom(alice, carol, moved);
        vm.prank(carol);
        nft.setAddr(moved, hot);
        vm.prank(bob);
        nft.transferFrom(bob, carol, sub);
        vm.prank(bob);
        nft.transferFrom(bob, DEAD, gone);
        vm.prank(alice);
        nft.setAddr(shop, hot);
    }

    // the gas of one call in the second of the last write, and a second later, from the same state
    function _measure(uint256 snap, address who, bytes memory data) internal returns (uint256 same, uint256 later) {
        vm.revertToState(snap);
        vm.cool(address(nft));
        vm.prank(who);
        (bool ok,) = address(nft).call(data);
        require(ok, "the call in the same second failed");
        same = vm.lastCallGas().gasTotalUsed;
        vm.revertToState(snap);
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.cool(address(nft));
        vm.prank(who);
        (ok,) = address(nft).call(data);
        require(ok, "the call a second later failed");
        later = vm.lastCallGas().gasTotalUsed;
    }

    function _check(string memory what, uint256 slots, uint256 same, uint256 later) internal {
        emit log_named_uint(string.concat(what, ", in the second of the last write"), same);
        emit log_named_uint(string.concat(what, ", a second later"), later);
        assertEq(later - same, slots * 2800, string.concat(what, ": 2800 for each time slot"));
        assertGt(same / 4, later - same, string.concat(what, ": a 25 percent headroom covers it"));
    }

    function test_gas_blockTimeWrites() public {
        uint256 snap = vm.snapshotState();
        (uint256 s, uint256 l) =
            _measure(snap, carol, abi.encodeWithSignature("transferFrom(address,address,uint256)", carol, dave, moved));
        _check("transferFrom", 1, s, l);
        (s, l) = _measure(
            snap, carol, abi.encodeWithSignature("safeTransferFrom(address,address,uint256)", carol, dave, moved)
        );
        _check("safeTransferFrom", 1, s, l);
        (s, l) =
            _measure(snap, carol, abi.encodeWithSignature("transferFrom(address,address,uint256)", carol, DEAD, sub));
        _check("a subpage sent to the dead address", 1, s, l);
        (s, l) = _measure(snap, alice, abi.encodeCall(nft.registerSubpageFor, ("gone", shop, carol)));
        _check("a subpage the dead address holds minted again", 1, s, l);
        (s, l) = _measure(snap, alice, abi.encodeCall(nft.setAddr, (shop, hot)));
        _check("setAddr with the same address", 1, s, l);
        (s, l) = _measure(snap, alice, abi.encodeCall(nft.setAddrForCoin, (shop, 0, "")));
        _check("setAddrForCoin with an empty value for a chain outside the EVM", 1, s, l);
        (s, l) = _measure(snap, alice, abi.encodeCall(nft.clearRecords, (shop)));
        _check("clearRecords", 1, s, l);
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(nft.setAddr, (moved, hot));
        calls[1] = abi.encodeWithSignature("transferFrom(address,address,uint256)", carol, dave, moved);
        (s, l) = _measure(snap, carol, abi.encodeCall(nft.multicall, (calls)));
        _check("setAddr and a transfer in one batch", 2, s, l);
    }
}

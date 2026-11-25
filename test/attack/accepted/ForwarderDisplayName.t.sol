// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {IMulticall3} from "forge-std/interfaces/IMulticall3.sol";
import {PageNFT} from "../../../src/PageNFT.sol";
import {AcceptedBase} from "./AcceptedBase.sol";

// calls anything for anyone, as a public batcher or a cross domain messenger does
contract CallForwarder {
    function forward(address target, bytes calldata data) external returns (bytes memory ret) {
        bool ok;
        (ok, ret) = target.call(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }
}

// Whoever holds a name can give a public forwarder a display name the forwarder never chose. It points the name at
// the forwarder and relays setPrimaryPage through it, so PageNFT sees the forwarder, the name's main address, as the
// caller. The display name shows only while that holder keeps the name pointed at the forwarder, and anyone can
// switch it to another name pointed there.
contract AcceptedForwarderDisplayTest is AcceptedBase {
    function test_holderGivesAForwarderADisplayName() public {
        CallForwarder fwd = new CallForwarder();
        uint256 id = _buy(stranger, "official-bridge", stranger, 0);
        vm.prank(stranger);
        nft.setAddr(id, address(fwd));
        bytes memory choose = abi.encodeCall(PageNFT.setPrimaryPage, (id));
        vm.prank(stranger);
        fwd.forward(address(nft), choose);
        assertEq(nft.primaryPage(address(fwd)), id);
        assertEq(nft.reverseResolve(address(fwd)), "official-bridge");

        // anyone can drive the forwarder, so any name pointed at it can take over
        uint256 id2 = _buy(stranger, "coinbase", stranger, 0);
        vm.prank(stranger);
        nft.setAddr(id2, address(fwd));
        choose = abi.encodeCall(PageNFT.setPrimaryPage, (id2));
        vm.prank(carol);
        fwd.forward(address(nft), choose);
        assertEq(nft.reverseResolve(address(fwd)), "coinbase");

        // it stops showing once the holder points the name elsewhere
        vm.prank(stranger);
        nft.setAddr(id2, stranger);
        assertEq(nft.reverseResolve(address(fwd)), "");
    }

    // the same through the code deployed as Multicall3 on OP Mainnet
    function test_holderGivesMulticall3ADisplayName() public {
        _etchMulticall3();
        uint256 id = _buy(stranger, "optimism-treasury", stranger, 0);
        vm.prank(stranger);
        nft.setAddr(id, MULTICALL3);
        IMulticall3.Call3[] memory c = new IMulticall3.Call3[](1);
        c[0] = IMulticall3.Call3(address(nft), false, abi.encodeCall(PageNFT.setPrimaryPage, (id)));
        vm.prank(stranger);
        IMulticall3(MULTICALL3).aggregate3(c);
        assertEq(nft.primaryPage(MULTICALL3), id);
        assertEq(nft.reverseResolve(MULTICALL3), "optimism-treasury");
    }
}

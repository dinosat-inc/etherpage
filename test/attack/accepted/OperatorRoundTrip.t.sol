// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {PageNFT} from "../../../src/PageNFT.sol";
import {AcceptedBase} from "./AcceptedBase.sol";

// An approved operator can, in one bundle, take a name, save its own addresses and profile on it, and give it back.
// The holder still holds the name, but the addresses it saved and its hot wallet's display name stop counting, the
// planted profile reads empty, and keepProfile would adopt it. All of it is within an operator's power.
contract AcceptedOperatorRoundTripTest is AcceptedBase {
    uint256 constant BTC = 0;

    function test_operatorRoundTripRetiresTheSavesAndKeepAdoptsThePlant() public {
        uint256 id = _buy(alice, "alice", alice, 0);
        vm.startPrank(alice);
        nft.setAddr(id, hot);
        nft.setAddrForCoin(id, BTC, bytes("bc1qalice"));
        nft.setText(id, "url", "https://alice.example");
        nft.setPrimaryPage(id);
        nft.setApprovalForAll(dave, true);
        vm.stopPrank();
        vm.prank(hot);
        nft.setPrimaryPage(id);
        assertEq(nft.reverseResolve(hot), "alice");

        bytes[] memory d = new bytes[](5);
        d[0] = abi.encodeCall(PageNFT.transferFrom, (alice, dave, id));
        d[1] = abi.encodeCall(PageNFT.setAddr, (id, dave));
        d[2] = abi.encodeCall(PageNFT.setAddrForCoin, (id, BTC, bytes("bc1qdave")));
        d[3] = abi.encodeCall(PageNFT.setText, (id, "url", "https://phish.example"));
        d[4] = abi.encodeCall(PageNFT.transferFrom, (dave, alice, id));
        vm.prank(dave);
        nft.multicall(d);

        assertEq(nft.ownerOf(id), alice, "the holder still holds it");
        assertEq(nft.resolve(id), alice, "the address alice saved no longer counts");
        assertEq(nft.addr(id, BTC).length, 0, "nor her Bitcoin entry");
        assertEq(nft.reverseResolve(hot), "", "the hot wallet's display name is hidden");
        assertEq(nft.primaryPage(alice), 0, "the move out cleared alice's own choice");
        assertEq(nft.text(id, "url"), "", "the planted profile reads empty");
        assertEq(nft.profileWriter(id), dave);
        vm.prank(alice);
        nft.keepProfile(id);
        assertEq(nft.text(id, "url"), "https://phish.example", "keep adopts the planted site");
    }
}

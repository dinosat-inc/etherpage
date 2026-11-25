// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {PageNFT} from "../../src/PageNFT.sol";
import {RulesBase} from "../utils/RulesBase.sol";

// receives a name and, from its receiver hook, makes each call it was given and records which ones worked
contract HookHolder {
    PageNFT immutable nft;
    bytes[] calls;
    bool[] public ok;

    constructor(PageNFT n) {
        nft = n;
    }

    function load(bytes[] calldata c) external {
        delete calls;
        for (uint256 i; i < c.length; ++i) calls.push(c[i]);
    }

    function count() external view returns (uint256) {
        return ok.length;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        for (uint256 i; i < calls.length; ++i) {
            (bool s,) = address(nft).call(calls[i]);
            ok.push(s);
        }
        return this.onERC721Received.selector;
    }
}

// Every record writer, approve and transferFrom stay unguarded: the holder can use them from its receiver hook
// while reveal still holds the reentrancy lock.
contract UnguardedFromHookTest is RulesBase {
    function test_writersRunInsideTheMintHook() public {
        HookHolder h = new HookHolder(nft);
        string memory l = "hookname";
        uint256 id = uint256(keccak256(abi.encodePacked(nft.ROOT(), keccak256(bytes(l)))));
        bytes[] memory c = new bytes[](10);
        c[0] = abi.encodeCall(nft.keepProfile, (id));
        c[1] = abi.encodeCall(nft.setContenthash, (id, hex"e301"));
        c[2] = abi.encodeCall(nft.setText, (id, "k", "v"));
        c[3] = abi.encodeCall(nft.setAddrForCoin, (id, 0, hex"0102"));
        c[4] = abi.encodeCall(nft.setAddr, (id, address(0xA11)));
        c[5] = abi.encodeCall(nft.clearRecords, (id));
        c[6] = abi.encodeCall(nft.setPrimaryPage, (id));
        c[7] = abi.encodeCall(nft.commit, (keccak256("from the hook")));
        c[8] = abi.encodeCall(nft.approve, (dave, id));
        c[9] = abi.encodeWithSignature("transferFrom(address,address,uint256)", address(h), carol, id);
        h.load(c);
        _buy(bob, l, address(h), 0);
        assertEq(h.count(), 10, "every call ran");
        for (uint256 i; i < 10; ++i) assertTrue(h.ok(i), string.concat("call ", vm.toString(i)));
        // the last call moved the name on, so its effects are visible
        assertEq(nft.ownerOf(id), carol);
        assertEq(nft.commitments(keccak256("from the hook")), block.timestamp);
    }
}

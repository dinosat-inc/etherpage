// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {AcceptedBase} from "./AcceptedBase.sol";

// An L1 contract that registers through an OptimismPortal deposit reaches PageNFT as its alias, its L1 address plus
// 0x1111000000000000000000000000000000001111. Nothing is deployed at the alias on the home chain, so it looks like a
// key wallet, but no answer is computed from the code at an address any more. The name answers the alias only for the
// home chain, where the L1 contract controls it through deposits. Coin type 60 and every other EVM chain answer empty
// until the contract saves an entry for that chain or a default, and then exactly what it saved. The risk an earlier
// build accepted, the alias answered on every EVM chain where nobody controls that address, is gone.
contract AcceptedL1AliasTest is AcceptedBase {
    uint160 constant ALIAS_OFFSET = uint160(0x1111000000000000000000000000000000001111);
    uint256 constant COIN_HOME = 0x8000000a;
    uint256 constant COIN_BASE = 0x80002105;
    uint256 constant DEFAULT_EVM = 0x80000000;

    function test_l1ContractAliasAnswersOnlyOnTheHomeChain() public {
        address l1Dao = address(0xDa0da0Da0dA0da0DA0DA0da0dA0da0DA0DA0dA0D);
        address aliasAddr;
        unchecked {
            aliasAddr = address(uint160(l1Dao) + ALIAS_OFFSET);
        }
        assertEq(aliasAddr.code.length, 0, "nothing is deployed at the alias");
        vm.deal(aliasAddr, 1 ether);
        uint256 id = _buy(aliasAddr, "daoname", aliasAddr, 0);
        assertEq(nft.ownerOf(id), aliasAddr);
        assertEq(nft.resolve(id), aliasAddr);
        assertEq(nft.addr(id, COIN_HOME), abi.encodePacked(aliasAddr), "the home chain answers the alias");
        assertEq(nft.addr(id, 60), "", "coin type 60 answers nothing");
        assertEq(nft.addr(id, COIN_BASE), "", "nor does Base");
        assertEq(nft.addr(id, DEFAULT_EVM), "", "nor the default for every EVM chain");

        // the contract saves its own L1 address for coin type 60; the other chains still answer nothing
        vm.prank(aliasAddr);
        nft.setAddrForCoin(id, 60, abi.encodePacked(l1Dao));
        assertEq(nft.addr(id, 60), abi.encodePacked(l1Dao));
        assertEq(nft.addr(id, COIN_BASE), "");
        assertEq(nft.addr(id, COIN_HOME), abi.encodePacked(aliasAddr));

        // a saved default answers on every EVM chain with no entry of its own; coin type 60 keeps its entry
        vm.prank(aliasAddr);
        nft.setAddrForCoin(id, DEFAULT_EVM, abi.encodePacked(l1Dao));
        assertEq(nft.addr(id, COIN_BASE), abi.encodePacked(l1Dao));
        assertEq(nft.addr(id, DEFAULT_EVM), abi.encodePacked(l1Dao));
        assertEq(nft.addr(id, 60), abi.encodePacked(l1Dao));
        assertEq(nft.addr(id, COIN_HOME), abi.encodePacked(aliasAddr));
    }
}

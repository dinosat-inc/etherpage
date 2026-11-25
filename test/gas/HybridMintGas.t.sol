// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {trialCommitmentRaw} from "../utils/TrialCommitment.sol";

import {console} from "forge-std/Test.sol";
import {SafeMintBase} from "../differential/SafeMintBase.sol";
import {PageNFT} from "../../src/PageNFT.sol";

// Run with the isolate option so every call is its own transaction. Every build gets labels of the same
// length, so the figures differ only by the mint rule.
contract HybridMintGasTest is SafeMintBase {
    function _g() internal view returns (uint256) {
        return vm.lastCallGas().gasTotalUsed;
    }

    function _reveal(uint256 v, string memory l, address to, bool trial) internal returns (uint256) {
        PageNFT nft = nfts[v];
        bytes32 c = nft.makeCommitment(l, to, 0, _s(l, to));
        vm.prank(bob);
        nft.commit(trial ? trialCommitmentRaw(l, to, 0, _s(l, to)) : c);
        vm.warp(vm.getBlockTimestamp() + 61);
        vm.prank(bob);
        if (trial) nft.revealTrial{value: PRICE5}(l, to, 0, _s(l, to));
        else nft.reveal{value: FEE5}(l, to, 0, _s(l, to));
        return _g();
    }

    function _sub(uint256 v, string memory l, address to) internal returns (uint256) {
        uint256 parent = _aliceParent(v);
        vm.prank(alice);
        nfts[v].registerSubpageFor(l, parent, to);
        return _g();
    }

    function test_gas_sameLabelLength() public {
        string[4] memory tag = ["a", "b", "c", "d"];
        for (uint256 v; v < 4; ++v) {
            uint256 k = _reveal(v, string.concat("gaskey", tag[v]), keyWallet, false);
            uint256 s = _reveal(v, string.concat("gassaf", tag[v]), address(safe), false);
            uint256 h = _reveal(v, string.concat("gashok", tag[v]), vaultHook, false);
            uint256 t = _reveal(v, string.concat("gastri", tag[v]), keyWallet, true);
            uint256 u = _sub(v, string.concat("gassub", tag[v]), keyWallet);
            console.log(string.concat("GAS ", vname[v], ": reveal to key, Safe-like, 7702 with hook"), k, s, h);
            console.log(string.concat("GAS ", vname[v], ": trial to key, subpage to key"), t, u);
        }
    }

    // SafeMintGas gives H1 and H2 labels three characters longer than S and P; each figure
    // here is the first mint to a fresh key wallet, so only the label length differs
    function test_gas_labelLengthAlone() public {
        address k1 = makeAddr("fresh key one");
        address k2 = makeAddr("fresh key two");
        uint256 a = _reveal(S, "gaskeys", k1, false);
        uint256 b = _reveal(S, "gaskeyhtwo", k2, false);
        console.log("S reveal to a fresh key, 7 then 10 characters", a, b);
    }
}

// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {trialCommitmentRaw} from "../utils/TrialCommitment.sol";

import {console} from "forge-std/Test.sol";
import {SafeMintBase} from "../differential/SafeMintBase.sol";
import {PageNFT} from "../../src/PageNFT.sol";
import {PQAccountLike} from "../utils/WalletMocks.sol";

// Run with the isolate option so every call is its own transaction and cold access counts as on chain;
// each figure is vm.lastCallGas().gasTotalUsed of the measured call.
contract SafeMintGasTest is SafeMintBase {
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

    function _selfPq(uint256 v, string memory l) internal returns (uint256) {
        PageNFT nft = nfts[v];
        address to = address(pq);
        bytes32 commitment = nft.makeCommitment(l, to, 0, _s(l, to));
        vm.prank(bob);
        nft.commit(commitment);
        vm.warp(vm.getBlockTimestamp() + 61);
        vm.prank(entryPoint);
        pq.execute(address(nft), FEE5, abi.encodeCall(PageNFT.reveal, (l, to, 0, _s(l, to))));
        return _g();
    }

    function _sub(uint256 v, string memory l, address to) internal returns (uint256) {
        PageNFT nft = nfts[v];
        uint256 parent = _aliceParent(v);
        vm.prank(alice);
        nft.registerSubpageFor(l, parent, to);
        return _g();
    }

    function _row(uint256 v) internal {
        string[4] memory x = ["s", "p", "hone", "htwo"];
        string memory t = x[v];
        uint256 a = _reveal(v, string.concat("gaskey", t), keyWallet, false);
        uint256 b = _reveal(v, string.concat("gassafe", t), address(safe), false);
        uint256 c = _reveal(v, string.concat("gasvhook", t), vaultHook, false);
        uint256 d = v == S ? 0 : _reveal(v, string.concat("gasvnone", t), vaultNoHook, false);
        uint256 e = _reveal(v, string.concat("trialkey", t), keyWallet, true);
        uint256 f = _reveal(v, string.concat("trialsafe", t), address(safe), true);
        uint256 g = _sub(v, string.concat("subkey", t), keyWallet);
        uint256 h = _sub(v, string.concat("subsafe", t), address(safe));
        uint256 i = (v == P || v == H2) ? _selfPq(v, string.concat("pqself", t)) : 0;
        console.log(string.concat("GAS ", vname[v]));
        console.log("  reveal to key, Safe-like, 7702 hook, 7702 no hook:", a, b);
        console.log("                                                    ", c, d);
        console.log("  trial to key, Safe-like:", e, f);
        console.log("  subpage to key, Safe-like:", g, h);
        console.log("  self reveal by PQ account through execute:", i);
    }

    function test_gas_S() public { _row(S); }
    function test_gas_P() public { _row(P); }
    function test_gas_H1() public { _row(H1); }
    function test_gas_H2() public { _row(H2); }
}

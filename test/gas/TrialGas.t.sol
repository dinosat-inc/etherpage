// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {trialCommitment} from "../utils/TrialCommitment.sol";

import {PageNFT} from "../../src/PageNFT.sol";
import {TrialBase} from "../utils/TrialBase.sol";

// a bot contract that starts many trials in one transaction, paying each price
contract TrialBot {
    PageNFT immutable nft;

    constructor(PageNFT n) payable {
        nft = n;
    }

    function commitMany(bytes32[] calldata cs) external {
        for (uint256 i; i < cs.length; ++i) nft.commit(cs[i]);
    }

    function trialMany(string[] calldata labels, address owner, bytes32[] calldata secrets, uint256 price) external {
        for (uint256 i; i < labels.length; ++i) nft.revealTrial{value: price}(labels[i], owner, 0, secrets[i]);
    }

    receive() external payable {}
}

// gas of the trial path; run with the isolate option so each call is its own transaction
contract TrialGasTest is TrialBase {
    address botWallet = makeAddr("botWallet");

    function test_gas_singleTrialPath() public {
        bytes32 c = trialCommitment(address(nft), "alice-smith", user, 0, _secret("alice-smith", user));
        vm.prank(relayer);
        nft.commit(c);
        vm.warp(vm.getBlockTimestamp() + 61);
        vm.prank(relayer);
        uint256 id = nft.revealTrial{value: PRICE5}("alice-smith", user, 0, _secret("alice-smith", user));
        vm.prank(relayer);
        nft.renew{value: FEE5}(id);
    }

    function test_gas_paidPath() public {
        vm.deal(user, 1 ether);
        bytes32 c = nft.makeCommitment("alice-smith", user, 0, _secret("alice-smith", user));
        vm.prank(user);
        nft.commit(c);
        vm.warp(vm.getBlockTimestamp() + 61);
        vm.prank(user);
        nft.reveal{value: FEE5}("alice-smith", user, 0, _secret("alice-smith", user));
    }

    function _batch(uint256 n, string memory prefix) internal returns (uint256 commitGas, uint256 trialGas) {
        uint256 already = nft.balanceOf(botWallet);
        TrialBot bot = new TrialBot{value: 10 ether}(nft);
        string[] memory labels = new string[](n);
        bytes32[] memory secrets = new bytes32[](n);
        bytes32[] memory cs = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            labels[i] = string.concat(prefix, vm.toString(i));
            secrets[i] = bytes32(i + 1);
            cs[i] = trialCommitment(address(nft), labels[i], botWallet, 0, secrets[i]);
        }
        uint256 g = gasleft();
        bot.commitMany(cs);
        commitGas = g - gasleft();
        vm.warp(vm.getBlockTimestamp() + 61);
        g = gasleft();
        bot.trialMany(labels, botWallet, secrets, PRICE5);
        trialGas = g - gasleft();
        assertEq(nft.balanceOf(botWallet), n + already);
    }

    // marginal gas per trial when a bot batches them, from the difference between 100 and 200
    function test_gas_botBatch() public {
        (uint256 c1, uint256 t1) = _batch(100, "squat-a-");
        emit log_named_uint("commits, 100 in one call", c1);
        emit log_named_uint("trials, 100 in one call", t1);
        (uint256 c2, uint256 t2) = _batch(200, "squat-b-");
        emit log_named_uint("commits, 200 in one call", c2);
        emit log_named_uint("trials, 200 in one call", t2);
        emit log_named_uint("marginal commit gas per name", (c2 - c1) / 100);
        emit log_named_uint("marginal trial gas per name", (t2 - t1) / 100);
    }
}

// a second trial by the same relayer: each trial price is held for its own name, in a slot of its own
contract TrialGasSteadyTest is TrialBase {
    function test_gas_secondTrial() public {
        _trial("first-name", user);
        bytes32 c = trialCommitment(address(nft), "alice-smith", user, 0, _secret("alice-smith", user));
        vm.prank(relayer);
        (bool ok,) = address(nft).call(abi.encodeCall(PageNFT.commit, (c)));
        assertTrue(ok);
        emit log_named_uint("commit", vm.lastCallGas().gasTotalUsed);
        vm.warp(vm.getBlockTimestamp() + 61);
        vm.prank(relayer);
        (ok,) = address(nft).call{value: PRICE5}(abi.encodeCall(PageNFT.revealTrial, ("alice-smith", user, 0, _secret("alice-smith", user))));
        assertTrue(ok);
        emit log_named_uint("revealTrial, after another trial", vm.lastCallGas().gasTotalUsed);
        uint256 id = nft.computeId("alice-smith");
        vm.prank(relayer);
        (ok,) = address(nft).call{value: FEE5}(abi.encodeCall(PageNFT.renew, (id)));
        assertTrue(ok);
        emit log_named_uint("renew that converts", vm.lastCallGas().gasTotalUsed);
    }
}

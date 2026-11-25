// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Script, console} from "forge-std/Script.sol";
import {PageCard} from "../src/PageCard.sol";
import {PageNFT} from "../src/PageNFT.sol";
import {SubpageRegistrar, IPageNFT} from "../src/SubpageRegistrar.sol";

// Deploys PageCard, PageNFT and SubpageRegistrar with three plain CREATE transactions from the deployer and
// sends nothing else. DEPLOYER and EXPECTED_NONCE come from the environment of the run.
// Forge runs the script as the deployer when the deployer's raw private key is the only signer. With a
// keystore it runs it as its own default sender, which the script refuses, unless the sender flag names
// the deployer.
contract Deploy is Script {
    function run() external returns (PageCard card, PageNFT nft, SubpageRegistrar registrar) {
        require(block.chainid == 10 || block.chainid == 31337, "wrong chain");
        address DEPLOYER = vm.envAddress("DEPLOYER");
        uint256 EXPECTED_NONCE = vm.envUint("EXPECTED_NONCE");
        require(msg.sender == DEPLOYER && vm.getNonce(msg.sender) == EXPECTED_NONCE, "wrong deployer or nonce");

        // the account checked above is the account that sends
        vm.startBroadcast(msg.sender);
        card = new PageCard();
        nft = new PageNFT(card);
        registrar = new SubpageRegistrar(IPageNFT(address(nft)));
        vm.stopBroadcast();

        console.log("PageCard", address(card));
        console.log("PageNFT", address(nft));
        console.log("SubpageRegistrar", address(registrar));
    }
}

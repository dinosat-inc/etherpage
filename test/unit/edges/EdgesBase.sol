// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {trialCommitment} from "../../utils/TrialCommitment.sol";

import {Test} from "forge-std/Test.sol";
import {Base64} from "solady/utils/Base64.sol";
import {LibString} from "solady/utils/LibString.sol";
import {PageNFT} from "../../../src/PageNFT.sol";
import {PageCard} from "../../../src/PageCard.sol";

// shared setup and helpers for the edge tests
abstract contract EdgesBase is Test {
    PageNFT nft;
    PageCard card;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address dave = makeAddr("dave");
    address relayer = makeAddr("relayer");
    address stranger = makeAddr("stranger");
    address hot = makeAddr("hot");
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    uint256 constant YEAR = 365 days;
    uint256 constant GRACE = 90 days;
    uint256 constant DECAY = 21 days;
    uint256 constant TRIAL = 14 days;
    uint256 constant PAUSE = 14 days;

    string[5] statusNames = ["Active", "Grace", "Expired", "Invalid", "Trial"];

    function setUp() public virtual {
        vm.warp(1_800_000_000);
        card = new PageCard();
        nft = new PageNFT(card);
        vm.deal(alice, 1000 ether);
        vm.deal(bob, 1000 ether);
        vm.deal(carol, 1000 ether);
        vm.deal(dave, 1000 ether);
        vm.deal(relayer, 1000 ether);
        vm.deal(stranger, 1000 ether);
    }

    function _secret(string memory l, address owner, uint256 ref) internal pure returns (bytes32) {
        return keccak256(abi.encode("edges", l, owner, ref));
    }

    function _commitPaid(address sender, string memory l, address owner, uint256 ref) internal {
        bytes32 c = nft.makeCommitment(l, owner, ref, _secret(l, owner, ref));
        vm.prank(sender);
        nft.commit(c);
    }

    function _commitTrial(address sender, string memory l, address owner, uint256 ref) internal {
        bytes32 c = trialCommitment(address(nft), l, owner, ref, _secret(l, owner, ref));
        vm.prank(sender);
        nft.commit(c);
    }

    // payer commits, 61 seconds pass, and payer registers a paid year for owner at the quote
    function _buy(address payer, string memory l, address owner, uint256 ref) internal returns (uint256 id) {
        _commitPaid(payer, l, owner, ref);
        vm.warp(vm.getBlockTimestamp() + 61);
        (,,, uint256 total) = nft.quote(l);
        vm.prank(payer);
        id = nft.reveal{value: total}(l, owner, ref, _secret(l, owner, ref));
    }

    // payer commits the trial form, 61 seconds pass, and payer starts a trial for owner at its price
    function _trial(address payer, string memory l, address owner, uint256 ref) internal returns (uint256 id) {
        _commitTrial(payer, l, owner, ref);
        vm.warp(vm.getBlockTimestamp() + 61);
        uint256 price = _trialPrice(l);
        vm.prank(payer);
        id = nft.revealTrial{value: price}(l, owner, ref, _secret(l, owner, ref));
    }

    function _trialPrice(string memory l) internal view returns (uint256) {
        return nft.getFee(bytes(l).length) / 10;
    }

    function _held(uint256 id) internal view returns (address payer, uint256 amount) {
        (payer, amount) = nft.trialPaymentOf(id);
    }

    function _subId(uint256 parentId, string memory l) internal pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(bytes32(parentId), keccak256(bytes(l)))));
    }

    function _json(uint256 id) internal view returns (string memory) {
        return string(Base64.decode(LibString.slice(nft.tokenURI(id), 29)));
    }

    // the Status the metadata shows, read from the JSON
    function _metaStatus(uint256 id) internal view returns (string memory) {
        string memory json = _json(id);
        for (uint256 i; i < 5; ++i) {
            if (LibString.contains(json, string.concat('"Status","value":"', statusNames[i], '"'))) return statusNames[i];
        }
        return "";
    }

    function _one(bytes memory call) internal pure returns (bytes[] memory calls) {
        calls = new bytes[](1);
        calls[0] = call;
    }
}

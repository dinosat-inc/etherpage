// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {trialCommitment} from "./TrialCommitment.sol";

import {Test, Vm} from "forge-std/Test.sol";
import {Base64} from "solady/utils/Base64.sol";
import {LibString} from "solady/utils/LibString.sol";
import {PageNFT} from "../../src/PageNFT.sol";
import {PageCard} from "../../src/PageCard.sol";
import {SubpageRegistrar, IPageNFT} from "../../src/SubpageRegistrar.sol";

// shared setup and helpers for the rules tests
abstract contract RulesBase is Test {
    PageNFT nft;
    PageCard card;
    SubpageRegistrar shop;
    address user = makeAddr("user");
    address relayer = makeAddr("relayer");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address dave = makeAddr("dave");
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    uint256 constant FEE1 = 0.01 ether;
    uint256 constant FEE3 = 0.001 ether;
    uint256 constant FEE5 = 0.0001 ether;
    uint256 constant PRICE1 = 0.001 ether;
    uint256 constant PRICE3 = 0.0001 ether;
    uint256 constant PRICE5 = 0.00001 ether;
    uint256 constant TRIAL = 14 days;
    uint256 constant PAUSE = 14 days;

    bytes32 constant T_REFUNDED = keccak256("TrialRefunded(uint256,address,uint256)");
    bytes32 constant T_STARTED = keccak256("TrialStarted(uint256,address,uint256)");
    bytes32 constant T_DEPOSIT = keccak256("DepositAdded(uint256,address,uint256,uint256)");
    bytes32 constant T_RENEWED = keccak256("PageRenewed(uint256,uint256)");
    bytes32 constant T_META = keccak256("MetadataUpdate(uint256)");
    bytes32 constant T_RELEASED = keccak256("DepositReleased(uint256,address,uint256)");
    bytes32 constant T_REF_PREMIUM = keccak256("ReferrerPremiumCredited(uint256,uint256,address,uint256)");
    bytes32 constant T_OWNER_PREMIUM = keccak256("OwnerPremiumCredited(uint256,address,uint256)");
    bytes32 constant T_BOUGHT = keccak256("DepositBoughtOut(uint256,address,uint256)");
    bytes32 constant T_REFERRER = keccak256("ReferrerSet(uint256,uint256)");

    string[5] statusNames = ["Active", "Grace", "Expired", "Invalid", "Trial"];

    function setUp() public virtual {
        vm.warp(1_800_000_000);
        card = new PageCard();
        nft = new PageNFT(card);
        shop = new SubpageRegistrar(IPageNFT(address(nft)));
        vm.deal(relayer, 1000 ether);
        vm.deal(bob, 1000 ether);
        vm.deal(carol, 1000 ether);
        vm.deal(dave, 1000 ether);
    }

    function _s(string memory l, address o, uint256 r) internal pure returns (bytes32) {
        return keccak256(abi.encode(l, o, r));
    }

    function _commitPaid(address sender, string memory l, address owner, uint256 ref) internal {
        bytes32 commitment = nft.makeCommitment(l, owner, ref, _s(l, owner, ref));
        vm.prank(sender);
        nft.commit(commitment);
    }

    function _commitTrial(address sender, string memory l, address owner, uint256 ref) internal {
        bytes32 commitment = trialCommitment(address(nft), l, owner, ref, _s(l, owner, ref));
        vm.prank(sender);
        nft.commit(commitment);
    }

    // commits, waits 61 seconds and registers a paid year for owner, paid by payer
    function _buy(address payer, string memory l, address owner, uint256 ref) internal returns (uint256 id) {
        _commitPaid(payer, l, owner, ref);
        vm.warp(vm.getBlockTimestamp() + 61);
        (,,, uint256 total) = nft.quote(l);
        vm.prank(payer);
        id = nft.reveal{value: total}(l, owner, ref, _s(l, owner, ref));
    }

    function _buy(address who, string memory l) internal returns (uint256) {
        return _buy(who, l, who, 0);
    }

    // commits the trial form, waits 61 seconds and starts a trial for owner, paid by payer
    function _trial(address payer, string memory l, address owner, uint256 ref) internal returns (uint256 id) {
        _commitTrial(payer, l, owner, ref);
        vm.warp(vm.getBlockTimestamp() + 61);
        uint256 price = _price(l);
        vm.prank(payer);
        id = nft.revealTrial{value: price}(l, owner, ref, _s(l, owner, ref));
    }

    function _trial(string memory l, address owner) internal returns (uint256) {
        return _trial(relayer, l, owner, 0);
    }

    function _price(string memory l) internal view returns (uint256) {
        return nft.getFee(bytes(l).length) / 10;
    }

    function _held(uint256 id) internal view returns (address p, uint256 a) {
        (p, a) = nft.trialPaymentOf(id);
    }

    function _heldAmount(uint256 id) internal view returns (uint256 a) {
        (, a) = nft.trialPaymentOf(id);
    }

    function _json(uint256 id) internal view returns (string memory) {
        return string(Base64.decode(LibString.slice(nft.tokenURI(id), 29)));
    }

    function _svg(uint256 id) internal view returns (string memory) {
        string memory json = _json(id);
        uint256 a = LibString.indexOf(json, "base64,") + 7;
        uint256 b = LibString.indexOf(json, '","attributes');
        return string(Base64.decode(LibString.slice(json, a, b)));
    }

    // the Status the metadata shows, read from the JSON
    function _metaStatus(uint256 id) internal view returns (string memory) {
        string memory json = _json(id);
        for (uint256 i; i < 5; ++i) {
            if (LibString.contains(json, string.concat('"Status","value":"', statusNames[i], '"'))) return statusNames[i];
        }
        return "";
    }

    function _statusName(uint256 id) internal view returns (string memory) {
        return statusNames[uint256(nft.status(id))];
    }

    function _assertStatus(uint256 id, PageCard.Status want) internal view {
        assertEq(uint256(nft.status(id)), uint256(want), "status view");
        assertEq(_metaStatus(id), statusNames[uint256(want)], "metadata Status");
    }

    function _count(Vm.Log[] memory logs, bytes32 topic) internal view returns (uint256 n) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(nft) && logs[i].topics.length > 0 && logs[i].topics[0] == topic) ++n;
        }
    }

    function _one(bytes memory call) internal pure returns (bytes[] memory calls) {
        calls = new bytes[](1);
        calls[0] = call;
    }
}

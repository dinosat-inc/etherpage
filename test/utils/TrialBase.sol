// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {trialCommitment} from "./TrialCommitment.sol";

import {Test, Vm} from "forge-std/Test.sol";
import {Base64} from "solady/utils/Base64.sol";
import {LibString} from "solady/utils/LibString.sol";
import {PageNFT} from "../../src/PageNFT.sol";
import {PageCard} from "../../src/PageCard.sol";
import {SubpageRegistrar, IPageNFT} from "../../src/SubpageRegistrar.sol";

// shared setup for the sponsored trial: an app's relayer pays a tenth of the yearly fee, which is held
// and later credited back to it, and the user holds no ETH at all
abstract contract TrialBase is Test {
    PageNFT nft;
    SubpageRegistrar shop;
    address user = makeAddr("user");
    address relayer = makeAddr("relayer");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    bytes32 constant DEPOSIT_ADDED = keccak256("DepositAdded(uint256,address,uint256,uint256)");
    bytes32 constant BOUGHT_OUT = keccak256("DepositBoughtOut(uint256,address,uint256)");
    bytes32 constant DEPOSIT_RELEASED = keccak256("DepositReleased(uint256,address,uint256)");
    bytes32 constant OWNER_PREMIUM = keccak256("OwnerPremiumCredited(uint256,address,uint256)");
    bytes32 constant REF_PREMIUM = keccak256("ReferrerPremiumCredited(uint256,uint256,address,uint256)");
    bytes32 constant TRIAL_STARTED = keccak256("TrialStarted(uint256,address,uint256)");
    bytes32 constant NAME_REGISTERED = keccak256("PageRegistered(uint256,string,address,uint256)");
    bytes32 constant REFERRER_SET = keccak256("ReferrerSet(uint256,uint256)");
    bytes32 constant TRANSFER = keccak256("Transfer(address,address,uint256)");
    bytes32 constant ADDRESS_CHANGED = keccak256("AddressChanged(bytes32,uint256,bytes)");
    bytes32 constant ADDR_CHANGED = keccak256("AddrChanged(bytes32,address)");
    bytes32 constant METADATA = keccak256("MetadataUpdate(uint256)");
    bytes32 constant PRIMARY_SET = keccak256("PrimaryPageSet(address,uint256)");
    bytes32 constant VERSION_CHANGED = keccak256("VersionChanged(bytes32,uint64)");
    bytes32 constant NAME_RENEWED = keccak256("PageRenewed(uint256,uint256)");
    bytes32 constant TRIAL_REFUNDED = keccak256("TrialRefunded(uint256,address,uint256)");

    uint256 constant FEE5 = 0.0001 ether;
    uint256 constant PRICE5 = 0.00001 ether;

    function setUp() public virtual {
        vm.warp(1_800_000_000);
        nft = new PageNFT(new PageCard());
        shop = new SubpageRegistrar(IPageNFT(address(nft)));
        vm.deal(relayer, 100 ether);
        vm.deal(bob, 1000 ether);
        vm.deal(carol, 1000 ether);
    }

    function _secret(string memory label, address owner) internal pure returns (bytes32) {
        return keccak256(abi.encode(label, owner));
    }

    function _commit(address sender, string memory label, address owner) internal {
        bytes32 commitment = nft.makeCommitment(label, owner, 0, _secret(label, owner));
        vm.prank(sender);
        nft.commit(commitment);
    }

    // a trial consumes its own commitment, which carries a trial flag, so a paid commitment never becomes a trial
    function _commitTrial(address sender, string memory label, address owner) internal {
        bytes32 commitment = trialCommitment(address(nft), label, owner, 0, _secret(label, owner));
        vm.prank(sender);
        nft.commit(commitment);
    }

    function _price(string memory label) internal view returns (uint256) {
        return nft.getFee(bytes(label).length) / 10;
    }

    // relayer commits, waits 61 seconds, then starts the trial paying exactly the price
    function _trial(string memory label, address owner) internal returns (uint256 id) {
        _commitTrial(relayer, label, owner);
        vm.warp(vm.getBlockTimestamp() + 61);
        uint256 p = _price(label);
        vm.prank(relayer);
        id = nft.revealTrial{value: p}(label, owner, 0, _secret(label, owner));
    }

    function _revealPaid(address who, string memory label) internal returns (uint256 id) {
        (,,, uint256 total) = nft.quote(label);
        vm.prank(who);
        id = nft.reveal{value: total}(label, who, 0, _secret(label, who));
    }

    function _buy(address who, string memory label) internal returns (uint256 id) {
        _commit(who, label, who);
        vm.warp(vm.getBlockTimestamp() + 61);
        id = _revealPaid(who, label);
    }

    function _status(uint256 id) internal view returns (string memory) {
        string memory json = _json(id);
        if (LibString.contains(json, '"Status","value":"Active"')) return "Active";
        if (LibString.contains(json, '"Status","value":"Grace"')) return "Grace";
        if (LibString.contains(json, '"Status","value":"Expired"')) return "Expired";
        if (LibString.contains(json, '"Status","value":"Trial"')) return "Trial";
        return "Invalid";
    }

    function _json(uint256 id) internal view returns (string memory) {
        string memory uri = nft.tokenURI(id);
        return string(Base64.decode(LibString.slice(uri, 29)));
    }

    function _countTopic(Vm.Log[] memory logs, bytes32 topic) internal pure returns (uint256 n) {
        for (uint256 i; i < logs.length; ++i) if (logs[i].topics.length > 0 && logs[i].topics[0] == topic) ++n;
    }

    function _topics(Vm.Log[] memory logs) internal pure returns (bytes32[] memory t) {
        t = new bytes32[](logs.length);
        for (uint256 i; i < logs.length; ++i) t[i] = logs[i].topics[0];
    }
}

// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {trialCommitmentRaw} from "../utils/TrialCommitment.sol";

import {Test, Vm} from "forge-std/Test.sol";
import {PageNFT} from "../../src/PageNFT.sol";
import {PageCard} from "../../src/PageCard.sol";
import {PageNFTManualRelease} from "./harness/PageNFTManualRelease.sol";

// src (nft) and the manual release build (manual), in which a deposit left after the auction stays in its name until
// release is called, with helpers that drive both and compare a name between them
abstract contract ReleaseFirstBase is Test {
    PageNFT nft;
    PageNFT manual;
    PageCard card;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address dave = makeAddr("dave");
    address saved = makeAddr("saved");
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    uint256 constant G = 90 days;
    uint256 constant D = 21 days;
    uint256 constant PAUSE = 14 days;
    uint256 constant FEE5 = 0.0001 ether;

    bytes32 constant T_RELEASED = keccak256("DepositReleased(uint256,address,uint256)");
    bytes32 constant T_BOUGHT = keccak256("DepositBoughtOut(uint256,address,uint256)");
    bytes32 constant T_REF = keccak256("ReferrerPremiumCredited(uint256,uint256,address,uint256)");
    bytes32 constant T_OWNER = keccak256("OwnerPremiumCredited(uint256,address,uint256)");
    bytes32 constant T_REFUND = keccak256("TrialRefunded(uint256,address,uint256)");
    bytes32 constant T_ADDED = keccak256("DepositAdded(uint256,address,uint256,uint256)");
    bytes32 constant T_STARTED = keccak256("TrialStarted(uint256,address,uint256)");
    bytes32 constant T_TRANSFER = keccak256("Transfer(address,address,uint256)");
    bytes32 constant T_REGISTERED = keccak256("PageRegistered(uint256,string,address,uint256)");
    bytes32 constant T_WITHDRAWN = keccak256("Withdrawn(address,address,uint256)");

    function setUp() public virtual {
        vm.warp(1_800_000_000);
        card = new PageCard();
        nft = new PageNFT(card);
        manual = PageNFT(address(new PageNFTManualRelease(card)));
        vm.deal(alice, 1e6 ether);
        vm.deal(bob, 1e6 ether);
        vm.deal(carol, 1e6 ether);
        vm.deal(dave, 1e6 ether);
    }

    function _now() internal view returns (uint256) {
        return vm.getBlockTimestamp();
    }

    function _secret(string memory l, address o, uint256 r) internal pure returns (bytes32) {
        return keccak256(abi.encode(l, o, r));
    }

    function _commitment(PageNFT n, string memory l, address o, uint256 r, bool trial) internal pure returns (bytes32) {
        if (trial) return trialCommitmentRaw(l, o, r, _secret(l, o, r));
        return n.makeCommitment(l, o, r, _secret(l, o, r));
    }

    function _commit(PageNFT n, address sender, string memory l, address o, uint256 r, bool trial) internal {
        bytes32 c = _commitment(n, l, o, r, trial);
        vm.prank(sender);
        n.commit(c);
    }

    function _call(PageNFT n, address payer, string memory l, address o, uint256 r, bool trial, uint256 value)
        internal
        returns (bool ok, bytes memory ret)
    {
        bytes memory data = trial
            ? abi.encodeCall(PageNFT.revealTrial, (l, o, r, _secret(l, o, r)))
            : abi.encodeCall(PageNFT.reveal, (l, o, r, _secret(l, o, r)));
        vm.prank(payer);
        (ok, ret) = address(n).call{value: value}(data);
    }

    function _mustCall(PageNFT n, address payer, string memory l, address o, uint256 r, bool trial, uint256 value)
        internal
    {
        (bool ok,) = _call(n, payer, l, o, r, trial, value);
        assertTrue(ok, "registration failed");
    }

    function _price(PageNFT n, string memory l, bool trial) internal pure returns (uint256 p) {
        p = n.getFee(bytes(l).length);
        if (trial) p /= 10;
    }

    function _total(PageNFT n, string memory l) internal view returns (uint256 t) {
        (,,, t) = n.quote(l);
    }

    function _held(PageNFT n, uint256 id) internal view returns (uint256 a) {
        (, a) = n.trialPaymentOf(id);
    }

    function _sel(bytes memory ret) internal pure returns (bytes4 s) {
        if (ret.length >= 4) s = bytes4(ret);
    }

    function _count(Vm.Log[] memory logs, address emitter, bytes32 topic) internal pure returns (uint256 k) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == emitter && logs[i].topics.length > 0 && logs[i].topics[0] == topic) ++k;
        }
    }

    function _index(Vm.Log[] memory logs, address emitter, bytes32 topic) internal pure returns (uint256) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == emitter && logs[i].topics.length > 0 && logs[i].topics[0] == topic) return i;
        }
        return type(uint256).max;
    }

    function _ownerOr0(PageNFT n, uint256 id) internal view returns (address) {
        try n.ownerOf(id) returns (address o) {
            return o;
        } catch {
            return address(0);
        }
    }

    function _statusOr(PageNFT n, uint256 id) internal view returns (uint256) {
        try n.status(id) returns (PageCard.Status s) {
            return uint256(s);
        } catch {
            return 99;
        }
    }

    // the money, record, holder, payee, time and resolver views of a name, compared between the two builds
    function _sameName(uint256 id, string memory l) internal view {
        assertEq(nft.depositOf(id), manual.depositOf(id), "depositOf");
        (address pN, uint96 aN) = nft.trialPaymentOf(id);
        (address pM, uint96 aM) = manual.trialPaymentOf(id);
        assertEq(pN, pM, "trial payer");
        assertEq(uint256(aN), uint256(aM), "trial amount");
        assertEq(nft.expiresAt(id), manual.expiresAt(id), "expiresAt");
        assertEq(_ownerOr0(nft, id), _ownerOr0(manual, id), "owner");
        assertEq(nft.epochOf(id), manual.epochOf(id), "epoch");
        assertEq(nft.recordVersion(id), manual.recordVersion(id), "recordVersion");
        assertEq(nft.referrerOf(id), manual.referrerOf(id), "referrerOf");
        assertEq(nft.payee(id), manual.payee(id), "payee");
        assertEq(nft.isReleasable(id), manual.isReleasable(id), "isReleasable");
        assertEq(nft.isExpired(id), manual.isExpired(id), "isExpired");
        assertEq(nft.inGracePeriod(id), manual.inGracePeriod(id), "inGracePeriod");
        assertEq(nft.getPremium(id), manual.getPremium(id), "getPremium");
        assertEq(nft.isAvailable(l, 0), manual.isAvailable(l, 0), "isAvailable");
        assertEq(_statusOr(nft, id), _statusOr(manual, id), "status");
        assertEq(nft.resolve(id), manual.resolve(id), "resolve");
        assertEq(nft.addr(id, 60), manual.addr(id, 60), "Ethereum address");
        assertEq(nft.getPageName(id), manual.getPageName(id), "full name");
        assertEq(nft.profileWriter(id), manual.profileWriter(id), "profile writer");
        assertEq(nft.subpageMinterOf(id), manual.subpageMinterOf(id), "subpage minter");
    }

    function _sameOwed(address[] memory who) internal view {
        for (uint256 i; i < who.length; ++i) {
            assertEq(nft.owed(who[i]), manual.owed(who[i]), "owed");
            assertEq(nft.primaryPage(who[i]), manual.primaryPage(who[i]), "primaryPage");
        }
        assertEq(address(nft).balance, address(manual).balance, "balance");
    }
}

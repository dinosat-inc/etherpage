// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {trialCommitment} from "../utils/TrialCommitment.sol";

import {MinterBase} from "../utils/MinterBase.sol";
import {NoHook} from "../utils/MinterMocks.sol";
import {PageNFT} from "../../src/PageNFT.sol";

// a receiver that counts the ERC721 hook calls it gets
contract CountingReceiver {
    uint256 public calls;

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        ++calls;
        return this.onERC721Received.selector;
    }
}

// The zero caller's refusal comes first. In approve, transferFrom and both forms of safeTransferFrom it follows only
// the value check, whatever else is wrong with the call: an unknown token, a wrong sender, the zero or this contract
// as receiver, an expired name or an unpaid trial. In a subpage mint it stands where the minter check stands: after
// the checks of the label and the parent, before the check of a live subpage and before any call to the receiver.
// Every other call of the zero caller works as it did before the guard.
contract ZeroCallerOrderTest is MinterBase {
    address constant ZERO = address(0);
    bytes4 constant UNEXPECTED_VALUE = PageNFT.UnexpectedValue.selector;

    // calls nft as the zero caller and returns the revert data, failing on success
    function _refusal(uint256 value, bytes memory data) internal returns (bytes memory ret) {
        vm.deal(ZERO, value);
        bool ok;
        vm.prank(ZERO);
        (ok, ret) = address(nft).call{value: value}(data);
        assertFalse(ok, "the zero caller is refused");
    }

    // the four ways to move or approve a name, for one set of arguments
    function _forms(address from, address to, uint256 id) internal pure returns (bytes[4] memory f) {
        f[0] = abi.encodeWithSignature("transferFrom(address,address,uint256)", from, to, id);
        f[1] = abi.encodeWithSignature("safeTransferFrom(address,address,uint256)", from, to, id);
        f[2] = abi.encodeWithSignature("safeTransferFrom(address,address,uint256,bytes)", from, to, id, bytes("x"));
        f[3] = abi.encodeWithSignature("approve(address,uint256)", to, id);
    }

    function _trialFor(address to, string memory label) internal returns (uint256 id) {
        bytes32 secret = keccak256(abi.encode("trial", label, to));
        bytes32 c = trialCommitment(address(nft), label, to, 0, secret);
        vm.prank(stranger);
        nft.commit(c);
        vm.warp(vm.getBlockTimestamp() + 61);
        uint256 price = nft.getFee(bytes(label).length) / 10;
        vm.prank(stranger);
        id = nft.revealTrial{value: price}(label, to, 0, secret);
    }

    function test_guardBeforeEveryOtherCheck() public {
        uint256 lapsed = _reg(alice, "lapse");
        vm.warp(nft.expiresAt(lapsed) + 1);
        uint256 gold = _reg(alice, "gold");
        uint256 plain = _reg(alice, "plain");
        uint256 trial = _trialFor(alice, "tria");
        uint256 ghost = _id("ghost");
        vm.prank(alice);
        nft.approve(bob, gold);
        CountingReceiver rec = new CountingReceiver();

        // from, to and id of each case, with the error a caller with no approval issue would meet first
        address[9] memory froms = [alice, alice, bob, ZERO, alice, alice, alice, alice, alice];
        address[9] memory tos = [stranger, stranger, stranger, stranger, ZERO, address(nft), stranger, bob, address(rec)];
        uint256[9] memory idsOf = [ghost, gold, plain, plain, plain, plain, lapsed, trial, plain];
        for (uint256 i; i < 9; ++i) {
            bytes[4] memory f = _forms(froms[i], tos[i], idsOf[i]);
            for (uint256 k; k < 4; ++k) {
                assertEq(_refusal(0, f[k]), abi.encodePacked(NOT_OWNER_NOR_APPROVED), "the guard's error first");
                assertEq(_refusal(1, f[k]), abi.encodePacked(UNEXPECTED_VALUE), "only the value check before it");
            }
        }
        assertEq(rec.calls(), 0, "no receiver was called");
        assertEq(nft.ownerOf(gold), alice);
        assertEq(nft.ownerOf(plain), alice);
        assertEq(nft.ownerOf(trial), alice);
        assertEq(nft.getApproved(gold), bob, "the approval stays");
        assertEq(nft.getApproved(plain), address(0));
    }

    // in a subpage mint the zero caller meets the label and parent checks first, then the guard, and never the check
    // of a live subpage or the receiver
    function test_subpageRefusalOrder() public {
        uint256 lapsed = _reg(alice, "lapse");
        vm.warp(nft.expiresAt(lapsed) + 1);
        uint256 club = _reg(alice, "club");
        uint256 trial = _trialFor(alice, "tria");
        vm.prank(alice);
        uint256 live = nft.registerSubpageFor("live", club, carol);
        vm.prank(alice);
        uint256 gone = nft.registerSubpageFor("gone", club, carol);
        vm.prank(carol);
        nft.transferFrom(carol, DEAD, gone);
        CountingReceiver rec = new CountingReceiver();
        address noHook = address(new NoHook());

        string[11] memory labels = ["", "Bad_", "fine", "fine", "fine", "fine", "fine", "free", "live", "gone", "free"];
        uint256[11] memory parents = [club, club, 0, _id("ghost"), live, lapsed, trial, club, club, club, club];
        address[11] memory tos = [stranger, stranger, stranger, stranger, stranger, stranger, stranger, address(rec), stranger, stranger, noHook];
        bytes4[11] memory want = [
            PageNFT.InvalidLength.selector,
            PageNFT.InvalidLabel.selector,
            TOKEN_DOES_NOT_EXIST,
            TOKEN_DOES_NOT_EXIST,
            PageNFT.NotTopLevel.selector,
            PageNFT.Expired.selector,
            PageNFT.Unpaid.selector,
            PageNFT.NotParentOwner.selector,
            PageNFT.NotParentOwner.selector,
            PageNFT.NotParentOwner.selector,
            PageNFT.NotParentOwner.selector
        ];
        for (uint256 i; i < 11; ++i) {
            bytes memory r = _refusal(0, abi.encodeCall(PageNFT.registerSubpageFor, (labels[i], parents[i], tos[i])));
            assertEq(r, abi.encodePacked(want[i]), string.concat("registerSubpageFor case ", vm.toString(i)));
            r = _refusal(0, abi.encodeCall(PageNFT.registerSubpage, (labels[i], parents[i])));
            assertEq(r, abi.encodePacked(want[i]), string.concat("registerSubpage case ", vm.toString(i)));
        }
        assertEq(rec.calls(), 0, "no receiver was called");
        assertEq(nft.ownerOf(live), carol);
        assertEq(nft.ownerOf(gone), DEAD);
        assertTrue(nft.isAvailable("free", club));
    }

    // An observation on code the change left as it was: setSubpageMinter lets a caller that is not the holder clear a
    // record it set, and an unwritten record has the zero address as its setter, so the zero caller may clear a minter
    // that no one ever picked. It writes an empty pick and logs it, and nothing else changes: no minter counts before or
    // after, the holder still picks one, and a pick of the holder cannot be cleared by the zero caller.
    function test_zeroCallerClearsOnlyAnUnwrittenMinterRecord() public {
        uint256 p = _reg(alice, "club");
        uint64 epoch = nft.epochOf(p);
        (address m0,, address s0) = _raw(p);
        assertEq(m0, address(0), "no pick was ever written");
        assertEq(s0, address(0), "so its setter reads as the zero address");
        _expectMinterSet(p, ZERO, address(0), epoch);
        vm.prank(ZERO);
        nft.setSubpageMinter(p, address(0));
        (address m, uint64 e, address setter) = _raw(p);
        assertEq(m, address(0));
        assertEq(e, epoch);
        assertEq(setter, ZERO, "an empty pick by the zero address");
        assertEq(nft.subpageMinterOf(p), address(0), "no minter counts");
        // the zero caller still mints nothing, and the holder still picks a minter that counts
        vm.prank(ZERO);
        vm.expectRevert(PageNFT.NotParentOwner.selector);
        nft.registerSubpageFor("free", p, stranger);
        _setMinter(p, hot);
        assertEq(nft.subpageMinterOf(p), hot);
        vm.prank(ZERO);
        vm.expectRevert(PageNFT.Unauthorized.selector);
        nft.setSubpageMinter(p, address(0));
        assertEq(nft.subpageMinterOf(p), hot, "the holder's pick stays");
        vm.prank(hot);
        nft.registerSubpageFor("free", p, stranger);
    }

    // every call outside transfers, approvals and subpage mints works for the zero caller as before: commit, reveal
    // and a trial for another account, renew, setApprovalForAll, release, withdraw and a bundle of them
    function test_zeroCallerOtherCallsUnchanged() public {
        vm.deal(ZERO, 10 ether);
        bytes32 secret = keccak256("zero");
        bytes32 c = nft.makeCommitment("zeroed", alice, 0, secret);
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeCall(PageNFT.commit, (c));
        vm.prank(ZERO);
        nft.multicall(calls);
        vm.warp(vm.getBlockTimestamp() + 61);
        (,,, uint256 total) = nft.quote("zeroed");
        vm.prank(ZERO);
        uint256 id = nft.reveal{value: total}("zeroed", alice, 0, secret);
        assertEq(nft.ownerOf(id), alice, "the zero caller registers a name for another account");

        bytes32 tsecret = keccak256("zero trial");
        bytes32 tc = trialCommitment(address(nft), "zerot", bob, 0, tsecret);
        vm.prank(ZERO);
        nft.commit(tc);
        vm.warp(vm.getBlockTimestamp() + 61);
        uint256 price = nft.getFee(5) / 10;
        vm.prank(ZERO);
        uint256 tid = nft.revealTrial{value: price}("zerot", bob, 0, tsecret);
        assertEq(nft.ownerOf(tid), bob, "and starts a trial for one");

        uint256 before = nft.expiresAt(id);
        vm.prank(ZERO);
        nft.renew{value: nft.getFee(6)}(id);
        assertEq(nft.expiresAt(id), before + 365 days, "and renews");

        vm.prank(ZERO);
        nft.setApprovalForAll(stranger, true);
        assertTrue(nft.isApprovedForAll(ZERO, stranger), "and picks an operator for itself");

        vm.warp(nft.expiresAt(id) + 90 days + 21 days + 1);
        uint256 deposit = nft.depositOf(id);
        vm.prank(ZERO);
        nft.release(id);
        assertEq(nft.owed(alice), deposit, "and releases a deposit to its payee");
        uint256 bal = alice.balance;
        vm.prank(ZERO);
        nft.withdraw(alice);
        assertEq(alice.balance, bal + deposit, "and withdraws for another account");
    }
}

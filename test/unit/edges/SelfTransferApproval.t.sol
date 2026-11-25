// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Vm} from "forge-std/Test.sol";
import {EdgesBase} from "./EdgesBase.sol";
import {LogShapes} from "../../utils/LogShapes.sol";

// A self transfer of a paid name, on the five transfer paths. Solady clears the token's approval on every transfer,
// a self transfer included, so with an account approved the move writes the owner slot and the holder's balance
// slot with the values they already held and the approval slot with zero, and nothing else. The after-transfer hook
// returns at its top, so Transfer is the only log and the holder keeps its display name. The operator approval stays,
// as no transfer writes it.
contract SelfTransferApprovalTest is EdgesBase {
    enum Path {
        Owner,
        Approved,
        Operator,
        Safe,
        SafeWithData
    }

    bytes4 constant NOT_OWNER_NOR_APPROVED = 0x4b6e7f18; // NotOwnerNorApproved()

    uint256 id;

    function setUp() public override {
        super.setUp();
        id = _buy(alice, "myself", alice, 0);
        // dave is an operator of alice, and carol is approved for the token in the tests that need it
        vm.startPrank(alice);
        nft.setPrimaryPage(id);
        nft.setApprovalForAll(dave, true);
        vm.stopPrank();
    }

    // solady ERC721 slots
    function _ownerSlot(uint256 tokenId) internal pure returns (bytes32 s) {
        assembly ("memory-safe") {
            mstore(0x00, tokenId)
            mstore(0x1c, shl(192, 0x7d8825530a5a2e7a))
            s := add(tokenId, add(tokenId, keccak256(0x00, 0x20)))
        }
    }

    function _approvalSlot(uint256 tokenId) internal pure returns (bytes32) {
        return bytes32(uint256(_ownerSlot(tokenId)) + 1);
    }

    function _balanceSlot(address a) internal pure returns (bytes32 s) {
        assembly ("memory-safe") {
            mstore(0x1c, shl(192, 0x7d8825530a5a2e7a))
            mstore(0x00, a)
            s := keccak256(0x0c, 0x1c)
        }
    }

    function _unique(bytes32[] memory w) internal pure returns (bytes32[] memory out) {
        out = new bytes32[](w.length);
        uint256 n;
        for (uint256 i; i < w.length; ++i) {
            bool dup;
            for (uint256 j; j < n; ++j) if (out[j] == w[i]) dup = true;
            if (!dup) out[n++] = w[i];
        }
        assembly ("memory-safe") {
            mstore(out, n)
        }
    }

    function _has(bytes32[] memory set, bytes32 s) internal pure returns (bool) {
        for (uint256 i; i < set.length; ++i) if (set[i] == s) return true;
        return false;
    }

    function _caller(Path p) internal view returns (address) {
        if (p == Path.Approved) return carol;
        if (p == Path.Operator) return dave;
        return alice;
    }

    // alice's name moves to alice on path p; returns the slots of PageNFT the move wrote, each once, and its logs
    function _selfMove(Path p) internal returns (bytes32[] memory w, Vm.Log[] memory logs) {
        address sender = _caller(p);
        vm.record();
        vm.recordLogs();
        vm.prank(sender);
        if (p == Path.Safe) nft.safeTransferFrom(alice, alice, id);
        else if (p == Path.SafeWithData) nft.safeTransferFrom(alice, alice, id, "listing");
        else nft.transferFrom(alice, alice, id);
        logs = vm.getRecordedLogs();
        (, w) = vm.accesses(address(nft));
        vm.stopRecord();
        w = _unique(w);
    }

    // Transfer(alice, alice, id) from PageNFT is the only log, and alice keeps everything but the approval
    function _assertOnlyTransferAndKept(Vm.Log[] memory logs, string memory which) internal view {
        assertEq(logs.length, 1, string.concat(which, ": one log"));
        assertEq(logs[0].emitter, address(nft), which);
        assertEq(LogShapes.hashOf(logs[0]), LogShapes.transfer(alice, alice, id), string.concat(which, ": Transfer"));
        assertEq(nft.ownerOf(id), alice, which);
        assertEq(nft.balanceOf(alice), 1, which);
        assertTrue(nft.isApprovedForAll(alice, dave), string.concat(which, ": the operator approval stays"));
        assertEq(nft.primaryPage(alice), id, string.concat(which, ": the display name stays"));
        assertEq(nft.reverseResolve(alice), "myself", which);
    }

    function test_selfTransferClearsTheApprovalOnEveryPath() public {
        for (uint256 i; i < 5; ++i) {
            Path p = Path(i);
            string memory which = string.concat("path ", vm.toString(i));
            vm.prank(alice);
            nft.approve(carol, id);
            assertEq(nft.getApproved(id), carol, string.concat(which, ": carol is approved before the move"));
            bytes32 ownerWord = vm.load(address(nft), _ownerSlot(id));
            bytes32 balanceWord = vm.load(address(nft), _balanceSlot(alice));
            assertEq(vm.load(address(nft), _approvalSlot(id)), bytes32(uint256(uint160(carol))), "the approval slot");

            (bytes32[] memory w, Vm.Log[] memory logs) = _selfMove(p);
            assertEq(w.length, 3, string.concat(which, ": three slots written"));
            assertTrue(_has(w, _ownerSlot(id)), string.concat(which, ": the owner slot"));
            assertTrue(_has(w, _balanceSlot(alice)), string.concat(which, ": the balance slot"));
            assertTrue(_has(w, _approvalSlot(id)), string.concat(which, ": the approval slot"));
            assertEq(vm.load(address(nft), _ownerSlot(id)), ownerWord, string.concat(which, ": owner word kept"));
            assertEq(vm.load(address(nft), _balanceSlot(alice)), balanceWord, string.concat(which, ": balance kept"));
            assertEq(vm.load(address(nft), _approvalSlot(id)), bytes32(0), string.concat(which, ": approval cleared"));
            assertEq(nft.getApproved(id), address(0), string.concat(which, ": nobody is approved after the move"));
            _assertOnlyTransferAndKept(logs, which);

            // the cleared approval no longer moves the name
            vm.prank(carol);
            vm.expectRevert(NOT_OWNER_NOR_APPROVED);
            nft.transferFrom(alice, bob, id);
        }
    }

    // with nobody approved for the token, the self transfer on the four paths open to it writes only the owner slot
    // and the balance slot, each with its own value, and logs Transfer alone, through both safeTransferFrom forms too
    function test_selfTransferWithNoApprovalLogsTransferAloneOnEveryPath() public {
        Path[4] memory paths = [Path.Owner, Path.Operator, Path.Safe, Path.SafeWithData];
        for (uint256 i; i < paths.length; ++i) {
            string memory which = string.concat("path ", vm.toString(uint256(paths[i])));
            assertEq(nft.getApproved(id), address(0), which);
            bytes32 ownerWord = vm.load(address(nft), _ownerSlot(id));
            bytes32 balanceWord = vm.load(address(nft), _balanceSlot(alice));
            (bytes32[] memory w, Vm.Log[] memory logs) = _selfMove(paths[i]);
            assertEq(w.length, 2, string.concat(which, ": two slots written"));
            assertTrue(_has(w, _ownerSlot(id)), string.concat(which, ": the owner slot"));
            assertTrue(_has(w, _balanceSlot(alice)), string.concat(which, ": the balance slot"));
            assertFalse(_has(w, _approvalSlot(id)), string.concat(which, ": no approval write"));
            assertEq(vm.load(address(nft), _ownerSlot(id)), ownerWord, which);
            assertEq(vm.load(address(nft), _balanceSlot(alice)), balanceWord, which);
            _assertOnlyTransferAndKept(logs, which);
        }
    }
}

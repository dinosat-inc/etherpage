// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {PageNFT} from "../src/PageNFT.sol";
import {DefaultProofsBase} from "./DefaultProofs.t.sol";

/// @notice The refusal of the zero caller in approve, transferFrom and both forms of safeTransferFrom. The start
/// state is one active name of any holder kind, with any approved account and any operator, address 0 included,
/// and the call takes any arguments and any value. MPZ of MinterProofsTest covers the subpage mint.
/// Halmos: FOUNDRY_PROFILE=proofs halmos --contract ZeroCallerProofsTest --function test_check_ZC --forge-build-out out-proofs --loop 4 --storage-layout generic
contract ZeroCallerProofsTest is DefaultProofsBase {
    bytes4 constant NOT_OWNER_NOR_APPROVED = 0x4b6e7f18;

    function _built(uint8 hPick, address approved, address operator, bool on) internal {
        W memory w = _w(type(uint64).max, hPick, 0, 0, 0, 0, address(0), 0, address(0));
        _world(w, DEFAULT_EVM);
        vm.startPrank(w.holder);
        n.approve(approved, id);
        n.setApprovalForAll(operator, on);
        vm.stopPrank();
    }

    // the call from address 0 fails: with UnexpectedValue when it carries ETH, else with NotOwnerNorApproved
    function _refused(bytes memory data, uint256 value) internal {
        vm.deal(address(0), value);
        vm.prank(address(0));
        (bool ok, bytes memory ret) = address(n).call{value: value}(data);
        assert(!ok);
        assert(ret.length == 4);
        assert(bytes4(ret) == (value != 0 ? PageNFT.UnexpectedValue.selector : NOT_OWNER_NOR_APPROVED));
    }

    /// @notice ZC1: transferFrom by address 0 always reverts, for any token, from and to.
    /// @dev Technique: built symbolic state, one symbolic call. Classification: DIRECT.
    function test_check_ZC1_transferFrom(uint8 hPick, address approved, address operator, bool on, address from,
        address to, uint256 tokenId, uint256 value) public
    {
        _built(hPick, approved, operator, on);
        _refused(abi.encodeWithSignature("transferFrom(address,address,uint256)", from, to, tokenId), value);
    }

    /// @notice ZC2: safeTransferFrom(from, to, id) by address 0 always reverts.
    /// @dev Technique: built symbolic state, one symbolic call. Classification: DIRECT.
    function test_check_ZC2_safeTransferFrom(uint8 hPick, address approved, address operator, bool on, address from,
        address to, uint256 tokenId, uint256 value) public
    {
        _built(hPick, approved, operator, on);
        _refused(abi.encodeWithSignature("safeTransferFrom(address,address,uint256)", from, to, tokenId), value);
    }

    /// @notice ZC3: safeTransferFrom(from, to, id, data) by address 0 always reverts.
    /// @dev Technique: built symbolic state, one symbolic call. Classification: DIRECT.
    function test_check_ZC3_safeTransferFromData(uint8 hPick, address approved, address operator, bool on,
        address from, address to, uint256 tokenId, uint256 value, bytes32 data) public
    {
        _built(hPick, approved, operator, on);
        _refused(abi.encodeWithSignature("safeTransferFrom(address,address,uint256,bytes)", from, to, tokenId,
            abi.encodePacked(data)), value);
    }

    /// @notice ZC4: approve by address 0 always reverts, for any token and account.
    /// @dev Technique: built symbolic state, one symbolic call. Classification: DIRECT.
    function test_check_ZC4_approve(uint8 hPick, address approved, address operator, bool on, address account,
        uint256 tokenId, uint256 value) public
    {
        _built(hPick, approved, operator, on);
        _refused(abi.encodeWithSignature("approve(address,uint256)", account, tokenId), value);
    }
}

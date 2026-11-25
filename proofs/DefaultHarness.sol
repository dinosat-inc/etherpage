// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {PageNFT} from "../src/PageNFT.sol";
import {PageCard} from "../src/PageCard.sol";

/// @notice src PageNFT with writers for any start state of the default address proofs. The h_ functions exist
/// only in this test harness.
contract DefaultHarness is PageNFT {
    constructor(PageCard c) PageNFT(c) {}

    function h_setRecord(uint256 id, string calldata label, uint256 parent, uint64 exp, uint64 epoch, uint64 pe)
        external
    {
        records[id] = PageRecord({label: label, parent: parent, expiresAt: exp, epoch: epoch, parentEpoch: pe});
    }

    function h_mint(address to, uint256 id) external {
        _mint(to, id);
    }

    function h_setDeposit(uint256 id, uint256 v) external {
        depositOf[id] = v;
    }

    function h_setVersion(uint256 id, uint256 v) external {
        recordVersion[id] = v;
    }

    function h_setResolved(uint256 id, address a, address saver) external {
        _resolvedAddress[id][recordVersion[id]] = a;
        _addrSaver[id][recordVersion[id]] = saver;
    }

    // an entry as setAddrForCoin leaves it: 20 bytes, or empty for zero
    function h_setCoin(uint256 id, uint256 coinType, address saver, address value) external {
        ChainAddress storage c = _coinAddr[id][recordVersion[id]][coinType];
        c.saver = saver;
        c.value = value == address(0) ? bytes("") : abi.encodePacked(value);
    }

    function h_entry(uint256 id, uint256 coinType) external view returns (address saver, bytes memory value) {
        ChainAddress storage c = _coinAddr[id][recordVersion[id]][coinType];
        return (c.saver, c.value);
    }

    function h_ownerOf(uint256 id) external view returns (address) {
        return _ownerOf(id);
    }

    function h_profile(uint256 id) external view returns (address, uint96) {
        Profile storage p = _profile[id];
        return (p.writer, p.version);
    }
}

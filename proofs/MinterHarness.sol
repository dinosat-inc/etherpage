// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {PageNFT} from "../src/PageNFT.sol";
import {PageCard} from "../src/PageCard.sol";

/// @notice PageNFT plus entry points that write records, tokens, minter records, deposits,
/// credits, display name pointers, main addresses, held trial money and record versions directly,
/// so a proof can start from symbolic parents, subpages and minter records. Every PageNFT function
/// is inherited unchanged; the h_ functions exist only in this test harness.
contract PageNFTHarness is PageNFT {
    constructor(PageCard c) PageNFT(c) {}

    function h_setRecord(uint256 id, string calldata label, uint256 parent, uint64 exp, uint64 epoch, uint64 pe)
        external
    {
        records[id] = PageRecord({label: label, parent: parent, expiresAt: exp, epoch: epoch, parentEpoch: pe});
        // a top level name the proofs start from is a paid one; a name with no deposit is a trial or a released name
        if (parent == 0) depositOf[id] = 1;
    }

    function h_mint(address to, uint256 id) external {
        _mint(to, id);
    }

    function h_setMinter(uint256 parentId, address m, uint64 e, address s) external {
        _subpageMinter[parentId] = SubpageMinter(m, e, s);
    }

    function h_rawMinter(uint256 parentId) external view returns (address, uint64, address) {
        SubpageMinter storage x = _subpageMinter[parentId];
        return (x.minter, x.epoch, x.setter);
    }

    function h_setDeposit(uint256 id, uint256 v) external {
        depositOf[id] = v;
    }

    function h_setOwed(address a, uint256 v) external {
        owed[a] = v;
    }

    function h_setPrimary(address a, uint256 id) external {
        primaryPage[a] = id;
        _primaryHolder[a] = _ownerOf(id);
    }

    function h_setResolved(uint256 id, address a, address saver) external {
        _resolvedAddress[id][recordVersion[id]] = a;
        _addrSaver[id][recordVersion[id]] = saver;
    }

    function h_setHeld(uint256 id, address payer, uint96 amount) external {
        trialPaymentOf[id] = TrialPayment(payer, amount);
    }

    function h_setVersion(uint256 id, uint256 v) external {
        recordVersion[id] = v;
    }

    function h_ownerOf(uint256 id) external view returns (address) {
        return _ownerOf(id);
    }

    function h_getApproved(uint256 id) external view returns (address) {
        return _getApproved(id);
    }

    function h_extraData(uint256 id) external view returns (uint96) {
        return _getExtraData(id);
    }

    function h_aux(address a) external view returns (uint224) {
        return _getAux(a);
    }

    function h_resolved(uint256 id, uint256 v) external view returns (address a, address s) {
        return (_resolvedAddress[id][v], _addrSaver[id][v]);
    }
}

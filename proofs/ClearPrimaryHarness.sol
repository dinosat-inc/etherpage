// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {PageCard} from "../src/PageCard.sol";
import {MulticallHarness} from "./MulticallHarness.sol";
import {PageNFTMulticall} from "../test/differential/harness/PageNFTMulticall.sol";

/// @notice World b of the proofs that a transfer clears the sender's pointer: src with the
/// harness writers.
contract ClearHarnessB is MulticallHarness {
    constructor(PageCard c) MulticallHarness(c) {}
}

/// @notice World a: the PageNFTMulticall reference build with the writers of world b except
/// h_setHeld and h_setWriter, as it has no trials and no profile writer. Its h_setRecord sets no
/// deposit, while world b gives a top level name a deposit of 1. The h_ functions exist only in
/// this test harness.
contract ClearHarnessA is PageNFTMulticall {
    constructor(PageCard c) PageNFTMulticall(c) {}

    function h_setRecord(uint256 id, string calldata label, uint256 parent, uint64 exp, uint64 epoch, uint64 pe)
        external
    {
        records[id] = PageRecord({label: label, parent: parent, expiresAt: exp, epoch: epoch, parentEpoch: pe});
    }

    function h_mint(address to, uint256 id) external {
        _mint(to, id);
    }

    function h_setMinter(uint256 parentId, address m, uint64 e, address s) external {
        _subpageMinter[parentId] = SubpageMinter(m, e, s);
    }

    function h_setResolved(uint256 id, address a, address saver) external {
        _resolvedAddress[id][recordVersion[id]] = a;
        _addrSaver[id][recordVersion[id]] = saver;
    }

    function h_setCoin(uint256 id, uint256 coin, address saver, bytes calldata v) external {
        _coinAddr[id][recordVersion[id]][coin] = ChainAddress(saver, v);
    }

    function h_setProfile(uint256 id) external {
        _text[id][recordVersion[id]]["k"] = "v";
        _contenthash[id][recordVersion[id]] = hex"e301";
    }

    function h_setPrimary(address a, uint256 id) external {
        primaryPage[a] = id;
    }

    function h_ownerOf(uint256 id) external view returns (address) {
        return _ownerOf(id);
    }

    function h_setCommit(bytes32 c, uint256 t) external {
        commitments[c] = t;
    }

    function h_setOwed(address a, uint256 v) external {
        owed[a] = v;
    }

    function h_setDeposit(uint256 id, uint256 v) external {
        depositOf[id] = v;
    }

    function h_setApprovalForAll(address by, address operator, bool on) external {
        _setApprovalForAll(by, operator, on);
    }

    function h_approve(address account, uint256 id) external {
        _approve(account, id);
    }
}

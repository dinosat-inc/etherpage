// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {PageCard} from "../src/PageCard.sol";
import {MulticallHarness} from "./MulticallHarness.sol";
import {PageNFTNoHolder} from "../test/differential/harness/PageNFTNoHolder.sol";

/// @notice World b of the holder proofs: src with the harness writers.
contract HolderHarnessB is MulticallHarness {
    constructor(PageCard c) MulticallHarness(c) {}

    function h_setHolder(address a, address h) external {
        _primaryHolder[a] = h;
    }

    function h_holder(address a) external view returns (address) {
        return _primaryHolder[a];
    }
}

/// @notice World a: the PageNFTNoHolder reference build, which keeps no holder with the display
/// name pointer, with some of the writers of world b. Its h_setRecord sets no deposit, while world b
/// gives a top level name a deposit of 1. The h_ functions exist only in this test harness.
contract HolderHarnessA is PageNFTNoHolder {
    constructor(PageCard c) PageNFTNoHolder(c) {}

    function h_setRecord(uint256 id, string calldata label, uint256 parent, uint64 exp, uint64 epoch, uint64 pe)
        external
    {
        records[id] = PageRecord({label: label, parent: parent, expiresAt: exp, epoch: epoch, parentEpoch: pe});
    }

    function h_mint(address to, uint256 id) external {
        _mint(to, id);
    }

    function h_setResolved(uint256 id, address a, address saver) external {
        _resolvedAddress[id][recordVersion[id]] = a;
        _addrSaver[id][recordVersion[id]] = saver;
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

    function h_setApprovalForAll(address by, address operator, bool on) external {
        _setApprovalForAll(by, operator, on);
    }

    function h_approve(address account, uint256 id) external {
        _approve(account, id);
    }
}

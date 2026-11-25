// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {PageNFT} from "../src/PageNFT.sol";
import {PageCard} from "../src/PageCard.sol";
import {PageNFTRecycle} from "../test/differential/harness/PageNFTRecycle.sol";

/// @notice The same state writers on src (the deleted rule) and on the PageNFTRecycle reference
/// build, so a proof can give both the same symbolic start state. The h_ functions exist only in
/// this test harness.
contract DeletedHarnessB is PageNFT {
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

    function h_setResolved(uint256 id, address a, address saver) external {
        _resolvedAddress[id][recordVersion[id]] = a;
        _addrSaver[id][recordVersion[id]] = saver;
    }

    function h_setCoin(uint256 id, uint256 coin, address saver, bytes calldata v) external {
        _coinAddr[id][recordVersion[id]][coin] = ChainAddress(saver, v);
    }

    // a data record under the key k, in the record version it reads
    function h_setData(uint256 id, address saver) external {
        _data[id][recordVersion[id]]["k"] = DataRecord(saver, hex"da7a");
    }

    // a profile written by the name's holder at that moment, in the slot it reads
    function h_setProfile(uint256 id) external {
        uint256 slot = recordVersion[id] << 96 | _profile[id].version;
        _text[id][slot]["k"] = "v";
        _contenthash[id][slot] = hex"e301";
        _profile[id].writer = _ownerOf(id);
    }

    function h_setWriter(uint256 id, address w) external {
        _profile[id].writer = w;
    }

    // the pointer as setPrimaryPage leaves it: stored with the name's holder at that moment
    function h_setPrimary(address a, uint256 id) external {
        primaryPage[a] = id;
        _primaryHolder[a] = _ownerOf(id);
    }

    function h_ownerOf(uint256 id) external view returns (address) {
        return _ownerOf(id);
    }
}

contract DeletedHarnessA is PageNFTRecycle {
    constructor(PageCard c) PageNFTRecycle(c) {}

    function h_setRecord(uint256 id, string calldata label, uint256 parent, uint64 exp, uint64 epoch, uint64 pe)
        external
    {
        records[id] = PageRecord({label: label, parent: parent, expiresAt: exp, epoch: epoch, parentEpoch: pe});
        // a top level name the proofs start from is a paid one, with the same deposit of 1 as in DeletedHarnessB
        if (parent == 0) depositOf[id] = 1;
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

    function h_setData(uint256 id, address saver) external {
        _data[id][recordVersion[id]]["k"] = DataRecord(saver, hex"da7a");
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
}

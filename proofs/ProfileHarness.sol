// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {PageNFT} from "../src/PageNFT.sol";
import {PageCard} from "../src/PageCard.sol";
import {PageNFTNoProfileReset} from "../test/differential/harness/PageNFTNoProfileReset.sol";

/// @notice src PageNFT with writers for any start state of the profile, data record and holder time proofs.
/// The h_ functions exist only in this test harness.
contract ProfileHarness is PageNFT {
    constructor(PageCard c) PageNFT(c) {}

    function h_setRecord(uint256 id, string calldata label, uint256 parent, uint64 exp, uint64 epoch, uint64 pe)
        external
    {
        records[id] = PageRecord({label: label, parent: parent, expiresAt: exp, epoch: epoch, parentEpoch: pe});
    }

    function h_mint(address to, uint256 id) external {
        _mint(to, id);
    }

    function h_setDeposit(uint256 id, uint256 v) external payable {
        depositOf[id] = v;
    }

    function h_setVersion(uint256 id, uint256 v) external {
        recordVersion[id] = v;
    }

    function h_setProfile(uint256 id, address writer, uint96 version) external {
        _profile[id] = Profile(writer, version);
    }

    function h_profile(uint256 id) external view returns (address, uint96) {
        Profile storage p = _profile[id];
        return (p.writer, p.version);
    }

    function h_key(uint256 rv, uint256 version) external pure returns (uint256) {
        return rv << 96 | version;
    }

    function h_slotOf(uint256 id) external view returns (uint256) {
        return _slot(id, _profile[id].version);
    }

    // the current profile: "k" is "v" and the website is e301
    function h_put(uint256 id, uint256 slot) external {
        _text[id][slot]["k"] = "v";
        _contenthash[id][slot] = hex"e301";
    }

    // a discarded profile in an older slot
    function h_putOld(uint256 id, uint256 slot) external {
        _text[id][slot]["k"] = "old";
        _contenthash[id][slot] = hex"0bad";
    }

    function h_setResolved(uint256 id, address a, address saver) external {
        _resolvedAddress[id][recordVersion[id]] = a;
        _addrSaver[id][recordVersion[id]] = saver;
    }

    // a data record under the key "k" in one record version, as setData leaves it
    function h_putData(uint256 id, uint256 rv, address saver, bytes calldata value) external {
        DataRecord storage d = _data[id][rv]["k"];
        d.saver = saver;
        d.value = value;
    }

    function h_data(uint256 id, uint256 rv) external view returns (address, bytes memory) {
        DataRecord storage d = _data[id][rv]["k"];
        return (d.saver, d.value);
    }

    function h_setTimes(uint256 id, uint256 since, uint256 updated) external {
        holderSince[id] = since;
        addressesUpdatedAt[id] = updated;
    }

    function h_setPrimary(address a, uint256 id, address holder) external {
        primaryPage[a] = id;
        _primaryHolder[a] = holder;
    }

    function h_setCommit(bytes32 c, uint256 t) external {
        commitments[c] = t;
    }

    function h_ownerOf(uint256 id) external view returns (address) {
        return _ownerOf(id);
    }

    function h_getApproved(uint256 id) external view returns (address) {
        return _getApproved(id);
    }

    function h_setApprovalForAll(address by, address operator, bool on) external {
        _setApprovalForAll(by, operator, on);
    }

    function h_approve(address account, uint256 id) external {
        _approve(account, id);
    }
}

/// @notice The PageNFTNoProfileReset reference build, which keeps a profile across a new writer,
/// with the record, mint, deposit, record version, main address, display name and approval writers
/// of ProfileHarness, for the differential proofs.
contract NoProfileResetHarness is PageNFTNoProfileReset {
    constructor(PageCard c) PageNFTNoProfileReset(c) {}

    function h_setRecord(uint256 id, string calldata label, uint256 parent, uint64 exp, uint64 epoch, uint64 pe)
        external
    {
        records[id] = PageRecord({label: label, parent: parent, expiresAt: exp, epoch: epoch, parentEpoch: pe});
    }

    function h_mint(address to, uint256 id) external {
        _mint(to, id);
    }

    function h_setDeposit(uint256 id, uint256 v) external payable {
        depositOf[id] = v;
    }

    function h_setVersion(uint256 id, uint256 v) external {
        recordVersion[id] = v;
    }

    function h_setResolved(uint256 id, address a, address saver) external {
        _resolvedAddress[id][recordVersion[id]] = a;
        _addrSaver[id][recordVersion[id]] = saver;
    }

    function h_setPrimary(address a, uint256 id, address holder) external {
        primaryPage[a] = id;
        _primaryHolder[a] = holder;
    }

    function h_ownerOf(uint256 id) external view returns (address) {
        return _ownerOf(id);
    }

    function h_getApproved(uint256 id) external view returns (address) {
        return _getApproved(id);
    }

    function h_setApprovalForAll(address by, address operator, bool on) external {
        _setApprovalForAll(by, operator, on);
    }

    function h_approve(address account, uint256 id) external {
        _approve(account, id);
    }
}

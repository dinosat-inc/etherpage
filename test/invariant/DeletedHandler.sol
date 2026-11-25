// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {PageNFT} from "../../src/PageNFT.sol";
import {PageCard} from "../../src/PageCard.sol";

// a contract account that holds names; the handler acts for it with prank
contract DeletedWallet {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}

// Random walks over two parents and three subpages of each. Holders write every kind of record, data
// records included, and choose display names, then pages move between accounts and to the dead address,
// subpages get created again by the parent's holder or its minter, and parents lapse, renew, move and get
// registered again. A page held by the dead address is deleted, a parent as well as a subpage. The checks
// in checkDeleted and checkData run after every call.
contract DeletedHandler is Test {
    PageNFT public nft;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 constant GRACE = 90 days;

    string[2] parentLabels = ["alpha", "bravo"];
    string[3] subLabels = ["a", "b", "c"];
    string[3] keys = ["avatar", "url", "com.twitter"];
    string[2] dataKeys = ["pay", "com.wallet"];
    uint256[7] coins = [uint256(0), 60, 501, 0x80000000, 0x8000000a, 0x80002105, 0xffffffff];

    address[4] public actors;
    address public payer = makeAddr("payer");
    uint256[2] public parents;
    uint256[6] public subs;
    // the parents, then the subpages
    uint256[8] public all;
    // every address a record or a display name ever named, checked against reverseResolve
    address[] public seen;
    mapping(address => bool) internal isSeen;
    uint256 internal secrets;

    // the record version of each page, and its data records per record version and key with the account
    // that saved each, followed from the calls that worked
    mapping(uint256 => uint256) internal mVersion;
    mapping(uint256 => mapping(uint256 => mapping(uint256 => address))) internal mSaver;
    mapping(uint256 => mapping(uint256 => mapping(uint256 => bytes))) internal mData;

    // must stay false
    bool public deletedWriteWorked;
    bool public deadMoveWorked;
    bool public deadParentMintWorked;
    bool public strangerDataWorked;

    // what the walk reached
    uint256 public deletions;
    uint256 public parentDeletions;
    uint256 public recreations;
    uint256 public recordWrites;
    uint256 public dataWrites;
    uint256 public primaryChoices;
    uint256 public parentRegistrations;
    uint256 public deadParentsRegisteredAgain;
    uint256 public deletedStates;
    uint256 public liveSubpagesUnderADeadParent;

    constructor(PageNFT n) {
        nft = n;
        actors = [makeAddr("k0"), makeAddr("k1"), makeAddr("k2"), address(new DeletedWallet())];
        for (uint256 i; i < actors.length; ++i) {
            vm.deal(actors[i], 1e9 ether);
            _see(actors[i]);
        }
        vm.deal(payer, 1e9 ether);
        _see(DEAD);
        for (uint256 p; p < 2; ++p) {
            parents[p] = _register(parentLabels[p], actors[p]);
            all[p] = parents[p];
            for (uint256 s; s < 3; ++s) {
                subs[p * 3 + s] = uint256(keccak256(abi.encodePacked(bytes32(parents[p]), keccak256(bytes(subLabels[s])))));
                all[2 + p * 3 + s] = subs[p * 3 + s];
            }
        }
        // every run starts with one deleted subpage that had a full profile, data records and two display names;
        // the transfer clears the holder's own choice, and the choice of the address it pointed at stays
        uint256 id = _mint(0, 0, actors[3]);
        _writeAll(id, actors[3], actors[2]);
        _call(actors[3], abi.encodeCall(PageNFT.setPrimaryPage, (id)));
        _call(actors[2], abi.encodeCall(PageNFT.setPrimaryPage, (id)));
        _call(actors[3], abi.encodeCall(PageNFT.transferFrom, (actors[3], DEAD, id)));
        ++deletions;
        // and one live subpage with records under the other parent
        uint256 live = _mint(1, 1, actors[0]);
        _writeAll(live, actors[0], actors[1]);
    }

    // helpers

    function _see(address a) internal {
        if (!isSeen[a]) {
            isSeen[a] = true;
            seen.push(a);
        }
    }

    function seenLength() external view returns (uint256) {
        return seen.length;
    }

    function _call(address from, bytes memory data) internal returns (bool ok) {
        vm.prank(from);
        (ok,) = address(nft).call(data);
    }

    function _owner(uint256 id) internal view returns (address o) {
        try nft.ownerOf(id) returns (address x) {
            o = x;
        } catch {}
    }

    function _register(string memory label, address to) internal returns (uint256 id) {
        bytes32 secret = bytes32(++secrets);
        bytes32 commitment = nft.makeCommitment(label, to, 0, secret);
        vm.prank(payer);
        nft.commit(commitment);
        vm.warp(vm.getBlockTimestamp() + 61);
        (,,, uint256 total) = nft.quote(label);
        vm.prank(payer);
        id = nft.reveal{value: total}(label, to, 0, secret);
        ++parentRegistrations;
    }

    function _mint(uint256 p, uint256 s, address to) internal returns (uint256 id) {
        vm.prank(_owner(parents[p]));
        id = nft.registerSubpageFor(subLabels[s], parents[p], to);
    }

    function _writeAll(uint256 id, address holder, address pointee) internal {
        _call(holder, abi.encodeWithSignature("setAddr(uint256,address)", id, pointee));
        _call(holder, abi.encodeCall(PageNFT.setAddrForCoin, (id, 60, abi.encodePacked(pointee))));
        _call(holder, abi.encodeCall(PageNFT.setAddrForCoin, (id, 0x80002105, abi.encodePacked(holder))));
        _call(holder, abi.encodeCall(PageNFT.setAddrForCoin, (id, 0, hex"0014aabbccddeeff00112233445566778899aabbccdd")));
        _call(holder, abi.encodeCall(PageNFT.setAddrForCoin, (id, 501, hex"1234")));
        for (uint256 k; k < 3; ++k) {
            _call(holder, abi.encodeWithSignature("setText(uint256,string,string)", id, keys[k], "value"));
        }
        _call(holder, abi.encodeWithSignature("setContenthash(uint256,bytes)", id, hex"e3010170"));
        _setData(holder, id, 0, abi.encodePacked(pointee));
        _setData(holder, id, 1, hex"c0ffee");
        recordWrites += 11;
    }

    function _setData(address holder, uint256 id, uint256 k, bytes memory v) internal returns (bool ok) {
        ok = _call(holder, abi.encodeCall(PageNFT.setData, (id, dataKeys[k], v)));
        if (ok) {
            mSaver[id][mVersion[id]][k] = holder;
            mData[id][mVersion[id]][k] = v;
            ++dataWrites;
        }
    }

    function _exists(uint256 id) internal view returns (bool) {
        (string memory label,,,,) = nft.records(id);
        return bytes(label).length != 0;
    }

    // whether a page is active, worked out from its record, its holder and the time rather than asked of the contract
    function _active(uint256 id) internal view returns (bool) {
        address o = _owner(id);
        if (o == address(0) || o == DEAD) return false;
        (, uint256 parent, uint64 exp,, uint64 pe) = nft.records(id);
        if (parent == 0) return vm.getBlockTimestamp() <= exp;
        (,, uint64 pexp, uint64 pep,) = nft.records(parent);
        return pe == pep && vm.getBlockTimestamp() <= pexp;
    }

    function _deleted(uint256 id) internal view returns (bool) {
        return _owner(id) == DEAD;
    }

    // counts the calls that end with a deleted subpage, and the live subpages under a deleted parent at their end
    function _countDeleted() internal {
        for (uint256 i; i < 6; ++i) {
            if (_deleted(subs[i])) {
                ++deletedStates;
                break;
            }
        }
        for (uint256 p; p < 2; ++p) {
            if (!_deleted(parents[p])) continue;
            for (uint256 s; s < 3; ++s) {
                if (_active(subs[p * 3 + s])) ++liveSubpagesUnderADeadParent;
            }
        }
    }

    // actions

    // the parent's holder creates a subpage, or creates a deleted one again; under a deleted parent an actor tries
    function mintSub(uint256 pSeed, uint256 sSeed, uint256 toSeed) external {
        uint256 p = pSeed % 2;
        uint256 id = subs[p * 3 + sSeed % 3];
        address holder = _owner(parents[p]);
        bool deadParent = holder == DEAD;
        bool wasDeleted = _deleted(id);
        bool existed = _exists(id);
        address caller = deadParent ? actors[toSeed % 4] : holder;
        if (_call(caller, abi.encodeCall(PageNFT.registerSubpageFor, (subLabels[sSeed % 3], parents[p], actors[toSeed % 4])))) {
            if (deadParent) deadParentMintWorked = true;
            if (existed) ++mVersion[id];
            if (wasDeleted) ++recreations;
        }
        _countDeleted();
    }

    // the parent's holder picks a minter, which then creates a free or deleted subpage; the dead address picks
    // none, so under a deleted parent the minter tries with no pick that counts
    function minterMint(uint256 pSeed, uint256 sSeed, uint256 mSeed, uint256 toSeed) external {
        uint256 p = pSeed % 2;
        uint256 mi = mSeed % 4;
        address m = actors[mi];
        address holder = _owner(parents[p]);
        if (m == holder) m = actors[(mi + 1) % 4];
        bool deadParent = holder == DEAD;
        if (!deadParent) _call(holder, abi.encodeCall(PageNFT.setSubpageMinter, (parents[p], m)));
        uint256 id = subs[p * 3 + sSeed % 3];
        bool wasDeleted = _deleted(id);
        bool existed = _exists(id);
        if (_call(m, abi.encodeCall(PageNFT.registerSubpageFor, (subLabels[sSeed % 3], parents[p], actors[toSeed % 4])))) {
            if (deadParent) deadParentMintWorked = true;
            if (existed) ++mVersion[id];
            if (wasDeleted) ++recreations;
        }
        _countDeleted();
    }

    // the holder of a page writes one record or data record, keeps the profile or clears every record, or an
    // account that does not hold it tries to write a data record
    function write(uint256 sSeed, uint256 kind, uint256 vSeed) external {
        uint256 id = all[sSeed % 8];
        address holder = _owner(id);
        if (holder == address(0) || holder == DEAD) return;
        address a = actors[vSeed % 4];
        uint256 k = kind % 12;
        bool ok;
        if (k == 0) ok = _call(holder, abi.encodeWithSignature("setAddr(uint256,address)", id, a));
        else if (k == 1) ok = _call(holder, abi.encodeCall(PageNFT.setAddrForCoin, (id, coins[vSeed % 7] == 0x80000000 ? 60 : coins[vSeed % 7], abi.encodePacked(a))));
        else if (k == 2) ok = _call(holder, abi.encodeCall(PageNFT.setAddrForCoin, (id, 0, abi.encodePacked(bytes32(vSeed)))));
        else if (k == 3) ok = _call(holder, abi.encodeWithSignature("setText(uint256,string,string)", id, keys[vSeed % 3], vm.toString(vSeed)));
        else if (k == 4) ok = _call(holder, abi.encodeWithSignature("setContenthash(uint256,bytes)", id, abi.encodePacked(vSeed)));
        else if (k == 5) ok = _call(holder, abi.encodeCall(PageNFT.keepProfile, (id)));
        else if (k == 6) {
            ok = _call(holder, abi.encodeCall(PageNFT.clearRecords, (id)));
            if (ok) ++mVersion[id];
        } else if (k < 11) {
            ok = _setData(holder, id, vSeed % 2, vSeed % 5 == 0 ? bytes("") : abi.encodePacked(vSeed));
        } else {
            address other = a == holder ? actors[(vSeed % 4 + 1) % 4] : a;
            if (_call(other, abi.encodeCall(PageNFT.setData, (id, dataKeys[vSeed % 2], hex"ee")))) strangerDataWorked = true;
        }
        if (ok) ++recordWrites;
        _countDeleted();
    }

    // the holder or the address a page points at chooses it as its display name
    function choose(uint256 sSeed, bool byPointee) external {
        uint256 id = all[sSeed % 8];
        address holder = _owner(id);
        address who = byPointee ? nft.resolve(id) : holder;
        if (who == address(0)) return;
        _see(who);
        if (_call(who, abi.encodeCall(PageNFT.setPrimaryPage, (id)))) ++primaryChoices;
        _countDeleted();
    }

    // the holder moves a page to another account or deletes it; half of the moves go to the dead address
    function move(uint256 sSeed, uint256 toSeed, bool safe) external {
        uint256 id = all[sSeed % 8];
        address holder = _owner(id);
        if (holder == address(0) || holder == DEAD) return;
        address to = toSeed % 2 == 0 ? DEAD : actors[(toSeed / 2) % 4];
        bool ok = safe
            ? _call(holder, abi.encodeWithSignature("safeTransferFrom(address,address,uint256)", holder, to, id))
            : _call(holder, abi.encodeCall(PageNFT.transferFrom, (holder, to, id)));
        if (ok && to == DEAD) {
            ++deletions;
            if (sSeed % 8 < 2) ++parentDeletions;
        }
        _countDeleted();
    }

    // anyone, the dead address included, tries to write to a deleted page, choose it as a display name or move it;
    // under a deleted parent an actor tries to create a subpage or pick a minter
    function touchDeleted(uint256 sSeed, uint256 whoSeed, uint256 kind) external {
        uint256 id = all[sSeed % 8];
        if (!_deleted(id)) return;
        address who = whoSeed % 5 == 4 ? DEAD : actors[whoSeed % 5];
        uint256 k = kind % 10;
        bool ok;
        if (k == 0) ok = _call(who, abi.encodeWithSignature("setAddr(uint256,address)", id, who));
        else if (k == 1) ok = _call(who, abi.encodeCall(PageNFT.setAddrForCoin, (id, 60, abi.encodePacked(who))));
        else if (k == 2) ok = _call(who, abi.encodeWithSignature("setText(uint256,string,string)", id, "avatar", "x"));
        else if (k == 3) ok = _call(who, abi.encodeWithSignature("setContenthash(uint256,bytes)", id, hex"01"));
        else if (k == 4) ok = _call(who, abi.encodeCall(PageNFT.keepProfile, (id)));
        else if (k == 5) ok = _call(who, abi.encodeCall(PageNFT.setPrimaryPage, (id)));
        else if (k == 6) ok = _call(who, abi.encodeCall(PageNFT.setData, (id, dataKeys[0], hex"01")));
        else if (k == 7) ok = _call(who, abi.encodeCall(PageNFT.clearRecords, (id)));
        else if (k == 8) {
            // nobody can sign as the dead address, so only the actors try
            if (sSeed % 8 < 2 && who != DEAD) {
                if (_call(who, abi.encodeCall(PageNFT.registerSubpageFor, (subLabels[kind % 3], id, who)))) {
                    deadParentMintWorked = true;
                }
                if (_call(who, abi.encodeCall(PageNFT.setSubpageMinter, (id, who)))) deadParentMintWorked = true;
            }
        } else {
            ok = _call(who, abi.encodeCall(PageNFT.transferFrom, (DEAD, actors[0], id)));
            if (ok) deadMoveWorked = true;
            ok = false;
        }
        if (ok) deletedWriteWorked = true;
        _countDeleted();
    }

    // time passes, up to about 200 days a step
    function warp(uint256 t) external {
        vm.warp(vm.getBlockTimestamp() + 1 + t % 200 days);
        _countDeleted();
    }

    function renewParent(uint256 pSeed) external {
        uint256 id = parents[pSeed % 2];
        uint256 fee = nft.getFee(5);
        vm.prank(payer);
        (bool ok,) = address(nft).call{value: fee}(abi.encodeCall(PageNFT.renew, (id)));
        ok;
        _countDeleted();
    }

    // the holder moves a parent to another account, or one time in four deletes it
    function moveParent(uint256 pSeed, uint256 toSeed) external {
        uint256 id = parents[pSeed % 2];
        address holder = _owner(id);
        address to = toSeed % 4 == 0 ? DEAD : actors[(toSeed / 4) % 4];
        if (holder == address(0) || holder == DEAD || holder == to) return;
        if (_call(holder, abi.encodeCall(PageNFT.transferFrom, (holder, to, id))) && to == DEAD) {
            ++deletions;
            ++parentDeletions;
        }
        _countDeleted();
    }

    // a lapsed parent is registered again, which leaves its old subpages behind; one time in three a deleted parent
    // is first waited out to the first second after its grace period
    function reregisterParent(uint256 pSeed, uint256 toSeed) external {
        uint256 p = pSeed % 2;
        bool wasDeleted = _deleted(parents[p]);
        if (wasDeleted && (pSeed / 2) % 3 == 0) {
            (,, uint64 exp,,) = nft.records(parents[p]);
            if (uint256(exp) + GRACE + 1 > vm.getBlockTimestamp()) vm.warp(uint256(exp) + GRACE + 1);
        }
        if (!nft.isAvailable(parentLabels[p], 0)) return;
        _register(parentLabels[p], actors[toSeed % 4]);
        ++mVersion[parents[p]];
        if (wasDeleted) ++deadParentsRegisteredAgain;
        _countDeleted();
    }

    // the checks

    // a page held by the dead address answers nothing, and its money goes to the dead address; a deleted parent
    // stays taken until its grace period ends, with no minter and no subpage free under it
    function checkDeleted() external view {
        for (uint256 i; i < 8; ++i) {
            uint256 id = all[i];
            if (!_deleted(id)) continue;
            bytes32 node = bytes32(id);
            assertEq(nft.resolve(id), address(0), "resolve");
            assertEq(nft.addr(node), address(0), "addr(node)");
            for (uint256 a; a < seen.length; ++a) {
                assertEq(nft.resolveAs(id, seen[a]), address(0), "resolveAs");
            }
            for (uint256 c; c < coins.length; ++c) {
                assertEq(nft.addr(id, coins[c]).length, 0, "addr for a coin");
                assertEq(nft.addr(node, coins[c]).length, 0, "addr(node) for a coin");
            }
            for (uint256 k; k < keys.length; ++k) {
                assertEq(bytes(nft.text(id, keys[k])).length, 0, "text");
                assertEq(bytes(nft.text(node, keys[k])).length, 0, "text(node)");
            }
            assertEq(nft.contenthash(id).length, 0, "contenthash");
            assertEq(nft.contenthash(node).length, 0, "contenthash(node)");
            for (uint256 k; k < dataKeys.length; ++k) {
                assertEq(nft.data(node, dataKeys[k]).length, 0, "data(node)");
            }
            assertEq(nft.payee(id), DEAD, "payee");
            assertEq(uint256(nft.status(id)), uint256(PageCard.Status.Invalid), "status");
            string memory full = nft.getPageName(id);
            for (uint256 a; a < seen.length; ++a) {
                string memory shown = nft.reverseResolve(seen[a]);
                if (nft.primaryPage(seen[a]) == id) assertEq(bytes(shown).length, 0, "reverseResolve of a chooser");
                if (bytes(full).length != 0) assertNotEq(keccak256(bytes(shown)), keccak256(bytes(full)), "reverseResolve shows it");
            }
            if (i < 2) {
                (string memory label,, uint64 exp,,) = nft.records(id);
                assertEq(nft.isAvailable(label, 0), vm.getBlockTimestamp() > uint256(exp) + GRACE, "when a deleted parent is free");
                assertEq(nft.subpageMinterOf(id), address(0), "a deleted parent has a minter");
                for (uint256 s; s < 3; ++s) {
                    assertFalse(nft.isAvailable(subLabels[s], id), "a subpage is free under a deleted parent");
                }
            }
        }
    }

    // the record version follows the model, a page is active exactly when the model says so, and a data record
    // shows only while the page is active and the account that saved it in this record version holds it
    function checkData() external view {
        for (uint256 i; i < 8; ++i) {
            uint256 id = all[i];
            if (!_exists(id)) continue;
            uint256 v = mVersion[id];
            assertEq(nft.recordVersion(id), v, "record version");
            address o = _owner(id);
            bool active = _active(id);
            assertEq(nft.resolve(id) != address(0), active, "active");
            for (uint256 k; k < 2; ++k) {
                bytes memory want = active && mSaver[id][v][k] == o ? mData[id][v][k] : bytes("");
                assertEq(nft.data(bytes32(id), dataKeys[k]), want, "data");
            }
        }
    }
}

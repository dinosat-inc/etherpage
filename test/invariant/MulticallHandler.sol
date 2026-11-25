// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Vm} from "forge-std/Test.sol";
import {ERC721} from "solady/tokens/ERC721.sol";
import {PageNFT} from "../../src/PageNFT.sol";
import {SubpageRegistrar} from "../../src/SubpageRegistrar.sol";
import {MinterHandler} from "./MinterHandler.sol";

// Adds bundles to the minter campaign. A bundle of random actions by one actor runs as one
// multicall; the state is then rolled back and the same actions run one by one through the model,
// each predicted and checked as a single call. The bundle must match: it succeeds exactly when
// every single call does, with the same results, the same logs and the same state, and otherwise
// fails with the first failing call's revert data and changes nothing. The state kept is the one
// by one run, which the invariants then check against the model.
contract MulticallHandler is MinterHandler {
    uint256 constant K_ADDR = 0;
    uint256 constant K_PROFILE = 1;
    uint256 constant K_CLEAR = 2;
    uint256 constant K_PRIMARY = 3;
    uint256 constant K_MINTER = 4;
    uint256 constant K_MINT = 5;
    uint256 constant K_TRANSFER = 6;
    uint256 constant K_APPROVE = 7;
    uint256 constant K_APPROVE_ALL = 8;
    uint256 constant K_WITHDRAW = 9;
    uint256 constant K_RELEASE = 10;
    uint256 constant K_RENEW = 11;
    uint256 constant K_REVEAL = 12;
    uint256 constant K_COMMIT = 13;
    uint256 constant K_VIEW = 14;
    uint256 constant KINDS = 15;

    struct Entry {
        uint256 kind;
        uint256 id;
        address a;
        address b;
        uint256 k;
        uint256 s;
        Label L;
        bytes data;
    }

    uint256 internal nonce;
    bytes32[] internal commits;

    constructor(PageNFT n, SubpageRegistrar r) MinterHandler(n, r) {}

    // entry choice

    // a name the caller holds and that is active, else any pool id
    function _mine(address caller, uint256 s, bool topOnly) internal view returns (uint256) {
        uint256 n = ids.length;
        for (uint256 i; i < n; ++i) {
            uint256 id = ids[(s + i) % n];
            if (topOnly && g[id].parent != 0) continue;
            if (g[id].exists && gOwner[id] == caller && _mActive(id)) return id;
        }
        return topOnly ? parents[s % 5] : ids[s % n];
    }

    // a parent the caller holds or mints for
    function _mintParent(address caller, uint256 s) internal view returns (uint256) {
        for (uint256 i; i < 5; ++i) {
            uint256 P = parents[(s + i) % 5];
            address m = _mMinter(P);
            if (g[P].exists && _mActive(P) && (gOwner[P] == caller || m == caller)) return P;
        }
        return _pickParent(s);
    }

    function _build(address caller, uint256 seed) internal returns (Entry memory e) {
        e.kind = seed % KINDS;
        e.s = seed >> 8;
        uint256 s = e.s;
        bool likely = (s >> 200) % 8 != 0;
        if (e.kind == K_ADDR) {
            e.id = likely ? _mine(caller, s, false) : _pickAnyId(s);
            e.a = addrPool[(s >> 16) % addrPool.length];
            e.k = (s >> 32) % 7;
            if (e.k < 3) {
                e.data = abi.encodeCall(PageNFT.setAddr, (e.id, e.a));
            } else if (e.k == 3) {
                bytes memory v = e.a == address(0) && (s >> 40) % 2 == 0 ? bytes("") : abi.encodePacked(e.a);
                e.data = abi.encodeCall(PageNFT.setAddrForCoin, (e.id, COIN_OP, v));
            } else if (e.k < 6) {
                bytes memory v = e.a == address(0) && (s >> 40) % 2 == 0 ? bytes("") : abi.encodePacked(e.a);
                e.data = abi.encodeCall(PageNFT.setAddrForCoin, (e.id, COIN_ETH, v));
            } else if ((s >> 40) % 2 == 0) {
                e.data = abi.encodeCall(PageNFT.setAddrForCoin, (e.id, DEFAULT_EVM, abi.encodePacked(e.a)));
            } else {
                e.k = 7;
                e.data = abi.encodeCall(PageNFT.setAddrForCoin, (e.id, COIN_ETH, hex"0102"));
            }
        } else if (e.kind == K_PROFILE) {
            e.id = likely ? _mine(caller, s, false) : _pickAnyId(s);
            e.k = (s >> 16) % 2;
            e.data = e.k == 0
                ? abi.encodeCall(PageNFT.setText, (e.id, "url", string.concat("b", vm.toString((s >> 24) % 1000))))
                : abi.encodeCall(PageNFT.setContenthash, (e.id, abi.encodePacked(uint16((s >> 24) % 65536))));
        } else if (e.kind == K_CLEAR) {
            e.id = likely ? _mine(caller, s, false) : _pickAnyId(s);
            e.data = abi.encodeCall(PageNFT.clearRecords, (e.id));
        } else if (e.kind == K_PRIMARY) {
            e.id = (s >> 16) % 5 == 0 ? 0 : likely ? _mine(caller, s, false) : _pickAnyId(s);
            e.data = abi.encodeCall(PageNFT.setPrimaryPage, (e.id));
        } else if (e.kind == K_MINTER) {
            e.id = likely ? _mine(caller, s, true) : _pickParent(s);
            address[6] memory ms = [address(reg), hot, address(bot), hot2, address(0), address(safe)];
            e.a = ms[(s >> 16) % 6];
            e.data = abi.encodeCall(PageNFT.setSubpageMinter, (e.id, e.a));
        } else if (e.kind == K_MINT) {
            e.id = likely ? _mintParent(caller, s) : _pickParent(s);
            uint256 lk = (s >> 16) % 4;
            e.L = lk == 0 ? _existingSubLabel(e.id, s >> 24) : lk == 1 ? _deadSubLabel(e.id, s >> 24) : _subLabel(s >> 24);
            e.a = (s >> 64) % 3 == 0 ? caller : _recipient(s >> 72);
            e.data = e.a == caller && (s >> 80) % 2 == 0
                ? abi.encodeCall(PageNFT.registerSubpage, (e.L.raw, e.id))
                : abi.encodeCall(PageNFT.registerSubpageFor, (e.L.raw, e.id, e.a));
        } else if (e.kind == K_TRANSFER) {
            e.id = likely ? _mine(caller, s, false) : _pickAnyId(s);
            // the single transfer model covers names that exist, as the minter campaign does
            if (!g[e.id].exists) e.id = parents[s % 5];
            e.b = (s >> 16) % 11 == 0 ? _actor(s >> 24) : gOwner[e.id];
            e.a = _recipient(s >> 32);
            e.k = (s >> 96) % 3;
            e.data = e.k == 0
                ? abi.encodeWithSignature("transferFrom(address,address,uint256)", e.b, e.a, e.id)
                : e.k == 1
                    ? abi.encodeWithSignature("safeTransferFrom(address,address,uint256)", e.b, e.a, e.id)
                    : abi.encodeWithSignature("safeTransferFrom(address,address,uint256,bytes)", e.b, e.a, e.id, hex"beef");
        } else if (e.kind == K_APPROVE) {
            e.id = likely ? _mine(caller, s, false) : _pickAnyId(s);
            address[5] memory sp = [op, hot, stranger, address(bot), address(0)];
            e.a = sp[(s >> 16) % 5];
            e.data = abi.encodeCall(PageNFT.approve, (e.a, e.id));
        } else if (e.kind == K_APPROVE_ALL) {
            address[4] memory ops = [op, hot, address(bot), stranger];
            e.a = ops[(s >> 16) % 4];
            e.k = (s >> 24) % 2;
            e.data = abi.encodeCall(ERC721.setApprovalForAll, (e.a, e.k == 0));
        } else if (e.kind == K_WITHDRAW) {
            e.a = accts[(s >> 16) % accts.length];
            if (likely) {
                for (uint256 i; i < accts.length; ++i) {
                    address x = accts[(s + i) % accts.length];
                    if (gOwed[x] != 0 && _takesETH(x)) {
                        e.a = x;
                        break;
                    }
                }
            }
            e.data = abi.encodeCall(PageNFT.withdraw, (e.a));
        } else if (e.kind == K_RELEASE) {
            e.id = _pickParent(s);
            if (likely) {
                for (uint256 i; i < 5; ++i) {
                    uint256 P = parents[(s + i) % 5];
                    if (g[P].exists && gDeposit[P] != 0 && _now() > uint256(g[P].expiresAt) + GRACE + DECAY) e.id = P;
                }
            }
            e.data = abi.encodeCall(PageNFT.release, (e.id));
        } else if (e.kind == K_RENEW) {
            e.id = _pickParent(s);
            e.data = abi.encodeCall(PageNFT.renew, (e.id));
        } else if (e.kind == K_REVEAL) {
            e.L = _topLabel(s);
            uint256 id = e.L.err == 0 ? _topId(e.L.norm) : 0;
            e.k = _pickRef(s >> 16, id);
            e.a = _recipient(s >> 32);
            bytes32 secret = keccak256(abi.encode(s, "secret"));
            e.data = abi.encodeCall(PageNFT.reveal, (e.L.raw, e.a, e.k, secret));
            e.id = id;
        } else if (e.kind == K_COMMIT) {
            bytes32 c = keccak256(abi.encode("bundle commit", ++nonce));
            commits.push(c);
            e.data = abi.encodeCall(PageNFT.commit, (c));
        } else {
            e.id = _pickAnyId(s);
            e.k = (s >> 16) % 3;
            e.data = e.k == 0
                ? abi.encodeCall(PageNFT.getPageName, (e.id))
                : e.k == 1 ? abi.encodeCall(PageNFT.resolve, (e.id)) : abi.encodeCall(PageNFT.isAvailable, ("a", e.id));
        }
    }

    // one entry as a single call

    function _unwrap(address caller, bool ok, bytes memory ret) internal view returns (bytes memory) {
        if (ok && (caller == address(bot) || caller == address(safe))) return abi.decode(ret, (bytes));
        return ret;
    }

    function _single(address caller, Entry memory e) internal returns (bool, bytes memory) {
        uint256 kd = e.kind;
        if (kd == K_PRIMARY) {
            _doSetPrimary(caller, e.id);
        } else if (kd == K_MINTER) {
            _doSetMinter(caller, e.id, e.a);
        } else if (kd == K_MINT) {
            _doMint(caller, e.id, e.L, e.a, e.data);
        } else if (kd == K_TRANSFER) {
            _doTransfer(caller, e.id, e.b, e.a, e.k);
        } else {
            bytes4 exp = _predict(caller, e);
            (bool ok, bytes memory ret) = _call(caller, address(nft), 0, e.data);
            _logs();
            _expect(string.concat("bundle entry ", vm.toString(kd)), exp, ok, ret);
            if (ok) _apply(caller, e);
        }
        _logs();
        return (lastOk, _unwrap(caller, lastOk, lastRet));
    }

    function _predict(address caller, Entry memory e) internal view returns (bytes4 exp) {
        uint256 kd = e.kind;
        uint256 id = e.id;
        if (kd == K_ADDR || kd == K_PROFILE || kd == K_CLEAR) {
            if (!_mActive(id)) return PageNFT.Expired.selector;
            if (gOwner[id] != caller) return PageNFT.Unauthorized.selector;
            if (kd == K_ADDR) {
                if (e.k <= 3 && e.a == address(nft)) return PageNFT.InvalidRecipient.selector;
                if (e.k == 7) return PageNFT.InvalidLength.selector;
            }
        } else if (kd == K_APPROVE) {
            if (!g[id].exists) return ERC721.TokenDoesNotExist.selector;
            if (caller != gOwner[id] && !nft.isApprovedForAll(gOwner[id], caller)) {
                return ERC721.NotOwnerNorApproved.selector;
            }
        } else if (kd == K_WITHDRAW) {
            if (gOwed[e.a] == 0) return PageNFT.NothingToWithdraw.selector;
            if (!_takesETH(e.a)) return ETH_FAILED;
        } else if (kd == K_RELEASE) {
            if (!g[id].exists) return ERC721.TokenDoesNotExist.selector;
            if (g[id].parent != 0) return PageNFT.NotTopLevel.selector;
            if (_now() <= uint256(g[id].expiresAt) + GRACE + DECAY) return PageNFT.NotReleasable.selector;
            if (gDeposit[id] == 0) return PageNFT.NothingToRelease.selector;
        } else if (kd == K_RENEW) {
            // a bundle carries no value, so a renewal can only fail
            if (!g[id].exists) return ERC721.TokenDoesNotExist.selector;
            if (g[id].parent != 0) return PageNFT.NotTopLevel.selector;
            if (_now() > uint256(g[id].expiresAt) + GRACE) return PageNFT.Expired.selector;
            return PageNFT.InsufficientFee.selector;
        } else if (kd == K_REVEAL) {
            // every fee is above zero, so an unpaid registration fails before its commitment is read
            if (e.L.err != 0) return e.L.err;
            if (e.k == id) return PageNFT.SelfReferral.selector;
            return PageNFT.InsufficientFee.selector;
        }
    }

    // ETHTransferFailed()
    bytes4 constant ETH_FAILED = 0xb12d13eb;

    function _apply(address caller, Entry memory e) internal {
        uint256 kd = e.kind;
        uint256 id = e.id;
        if (kd == K_ADDR) {
            if (e.k <= 3) gAddr[id][gVersion[id]] = Saved(e.a, caller);
            else if (e.k < 6) gCoin60[id][gVersion[id]] = Saved(e.a, caller);
            else gDefault[id][gVersion[id]] = Saved(e.a, caller);
        } else if (kd == K_PROFILE) {
            _pWrite(id, caller);
            if (e.k == 0) gText[id][_pSlot(id)] = string.concat("b", vm.toString((e.s >> 24) % 1000));
            else gHash[id][_pSlot(id)] = abi.encodePacked(uint16((e.s >> 24) % 65536));
        } else if (kd == K_CLEAR) {
            gVersion[id] += 1;
        } else if (kd == K_WITHDRAW) {
            gOwed[e.a] = 0;
        } else if (kd == K_RELEASE) {
            _mCredit(_mPayee(id), gDeposit[id]);
            gDeposit[id] = 0;
        }
    }

    // the observable state

    function _obsHash() internal view returns (bytes32 h) {
        h = _ledgerHash();
        for (uint256 i; i < ids.length; ++i) {
            uint256 id = ids[i];
            (string memory label, uint256 parent, uint64 exp, uint64 ep, uint64 pep) = nft.records(id);
            h = keccak256(abi.encode(h, label, parent, exp, ep, pep, nft.recordVersion(id)));
            try nft.ownerOf(id) returns (address o) {
                h = keccak256(abi.encode(h, o, nft.getApproved(id)));
            } catch {
                h = keccak256(abi.encode(h, "none"));
            }
            bytes32 base = keccak256(abi.encode(id, uint256(12)));
            h = keccak256(abi.encode(h, vm.load(address(nft), base), vm.load(address(nft), bytes32(uint256(base) + 1))));
            h = keccak256(abi.encode(h, nft.resolve(id), nft.payee(id), nft.addr(id, COIN_OP), nft.addr(id, COIN_ETH)));
            h = keccak256(abi.encode(h, nft.text(id, "url"), nft.contenthash(id)));
            h = keccak256(abi.encode(h, nft.holderSince(id), nft.addressesUpdatedAt(id)));
        }
        address[4] memory ops = [op, hot, address(bot), stranger];
        for (uint256 i; i < accts.length; ++i) {
            address a = accts[i];
            h = keccak256(abi.encode(h, a.balance, nft.primaryPage(a), a == address(0) ? 0 : nft.balanceOf(a)));
            for (uint256 j; j < 4; ++j) h = keccak256(abi.encode(h, nft.isApprovedForAll(a, ops[j])));
        }
        for (uint256 i; i < commits.length; ++i) h = keccak256(abi.encode(h, nft.commitments(commits[i])));
    }

    function _hashLogs(Vm.Log[] memory logs) internal pure returns (bytes32 h) {
        for (uint256 i; i < logs.length; ++i) h = keccak256(abi.encode(h, logs[i].emitter, logs[i].topics, logs[i].data));
    }

    // the bundle action

    struct BundleCtx {
        address caller;
        uint256 n;
        bool withValue;
        uint256 gStart;
        uint256 gEnd;
        bool nested;
        bytes[] datas;
        bool bok;
        bytes bret;
        bytes32 blogs;
        bytes32 bstate;
        bool sok;
        bytes sret;
        uint256 failKind;
        bytes[] rets;
    }

    function act_bundle(uint256 whoS, uint256 nS, uint256 seed, uint256 mode) external step(true) {
        whoS = _h(whoS, 0);
        nS = _h(nS, 1);
        seed = _h(seed, 2);
        mode = _h(mode, 3);
        BundleCtx memory c;
        uint256 r = whoS % 6;
        // mostly the holder of a pool parent, so entries that act on the caller's own names can succeed
        c.caller = r < 4 && _isActor(gOwner[parents[(whoS >> 8) % 5]]) ? gOwner[parents[(whoS >> 8) % 5]] : _actor(whoS >> 16);
        c.n = mode % 13 == 0 ? 0 : 1 + nS % 6;
        c.withValue = mode % 29 == 1;
        Entry[] memory es = new Entry[](c.n);
        for (uint256 i; i < c.n; ++i) es[i] = _build(c.caller, _h(seed, 100 + i));

        // one contiguous run of entries may go in as a nested bundle
        c.nested = c.n >= 2 && (mode >> 8) % 4 == 0;
        if (c.nested) {
            c.gStart = (mode >> 16) % c.n;
            c.gEnd = c.gStart + 1 + (mode >> 24) % (c.n - c.gStart);
        }
        c.datas = _pack(es, c);

        if (c.withValue) vm.deal(c.caller, c.caller.balance + 1);
        uint256 snap = vm.snapshotState();
        (c.bok, c.bret) = _call(c.caller, address(nft), c.withValue ? 1 : 0, abi.encodeCall(PageNFT.multicall, (c.datas)));
        if (c.bok) {
            c.bret = _unwrap(c.caller, true, c.bret);
            c.blogs = _hashLogs(vm.getRecordedLogs());
            c.bstate = _obsHash();
            // the address writes read from the bundle's calls give the times it left
            for (uint256 i; i < ids.length; ++i) {
                require(nft.addressesUpdatedAt(ids[i]) == gAddrAt[ids[i]], "addressesUpdatedAt after a bundle");
            }
        }
        vm.revertToState(snap);

        if (c.withValue) {
            require(!c.bok && c.bret.length == 0, "a bundle with value was not refused");
            vm.deleteStateSnapshot(snap);
            _bump("bundle.valueRefused");
            return;
        }

        // the same entries one by one
        capturing = true;
        capHash = bytes32(0);
        c.sok = true;
        c.rets = new bytes[](c.n);
        for (uint256 i; i < c.n; ++i) {
            (bool ok, bytes memory ret) = _single(c.caller, es[i]);
            if (!ok) {
                c.sok = false;
                c.sret = ret;
                c.failKind = es[i].kind;
                break;
            }
            c.rets[i] = ret;
        }
        capturing = false;
        if (!c.sok) {
            require(!c.bok, "a bundle succeeded where a single call failed");
            require(keccak256(c.bret) == keccak256(c.sret), "the bundle failed with other data than the first failing call");
            vm.revertToStateAndDelete(snap);
            _bump("bundle.failed");
            _bump(string.concat("bundle.failed.atKind.", vm.toString(c.failKind)));
            return;
        }
        vm.deleteStateSnapshot(snap);
        require(c.bok, "a bundle failed where every single call worked");
        _checkResults(c);
        require(c.blogs == capHash, "bundle logs differ from the calls one by one");
        require(_obsHash() == c.bstate, "bundle state differs from the calls one by one");
        _bump(c.n == 0 ? "bundle.empty" : "bundle.ok");
        if (c.nested) _bump("bundle.ok.nested");
        if (c.n >= 4) _bump("bundle.ok.4plus");
        for (uint256 i; i < c.n; ++i) _bump(string.concat("bundle.ok.kind.", vm.toString(es[i].kind)));
    }

    function _pack(Entry[] memory es, BundleCtx memory c) internal pure returns (bytes[] memory datas) {
        if (!c.nested) {
            datas = new bytes[](es.length);
            for (uint256 i; i < es.length; ++i) datas[i] = es[i].data;
            return datas;
        }
        uint256 g = c.gEnd - c.gStart;
        datas = new bytes[](es.length - g + 1);
        bytes[] memory inner = new bytes[](g);
        uint256 j;
        for (uint256 i; i < es.length; ++i) {
            if (i < c.gStart || i >= c.gEnd) datas[j++] = es[i].data;
            else {
                inner[i - c.gStart] = es[i].data;
                if (i == c.gEnd - 1) datas[j++] = abi.encodeCall(PageNFT.multicall, (inner));
            }
        }
    }

    function _checkResults(BundleCtx memory c) internal pure {
        bytes[] memory res = abi.decode(c.bret, (bytes[]));
        uint256 j;
        for (uint256 i; i < c.n; ++i) {
            if (c.nested && i >= c.gStart && i < c.gEnd) {
                if (i != c.gEnd - 1) continue;
                bytes[] memory inner = new bytes[](c.gEnd - c.gStart);
                for (uint256 k = c.gStart; k < c.gEnd; ++k) inner[k - c.gStart] = c.rets[k];
                require(keccak256(res[j++]) == keccak256(abi.encode(inner)), "nested bundle result");
            } else {
                require(keccak256(res[j++]) == keccak256(c.rets[i]), "bundle result");
            }
        }
        require(j == res.length, "bundle result count");
    }
}

// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {trialCommitment} from "../utils/TrialCommitment.sol";

import {Test, Vm} from "forge-std/Test.sol";
import {PageNFT} from "../../src/PageNFT.sol";
import {PageCard} from "../../src/PageCard.sol";
import {PageNFTNoProfileReset} from "./harness/PageNFTNoProfileReset.sol";

contract DiffVault {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}

// World A is PageNFTNoProfileReset, world B is src with the profile rule. Every call goes to both
// worlds and must succeed or fail alike, with the same return data, and every view must agree after
// every call, except what the profile rule predicts. B logs ProfileWriterChanged(node, caller, true)
// right before a text or website event whenever the caller is not the stored writer, and nothing else
// differs in the logs. B's text and contenthash equal A's when the stored writer holds the name and the
// entry was written after the last fresh start, and are empty otherwise. keepProfile exists only in B:
// it succeeds exactly for the holder of an active name that is not the writer, logs one
// ProfileWriterChanged(node, caller, false) and changes only the writer.
// A second model, built only from B's logs as an indexer would (Transfer, ProfileWriterChanged,
// VersionChanged, TextChanged, ContenthashChanged), must give the same text and contenthash as B.
contract ProfileWorlds is Test {
    PageNFTNoProfileReset public A;
    PageNFT public B;
    DiffVault public vault;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 constant COIN_BASE = 0x80002105;
    bytes32 constant T_PWC = keccak256("ProfileWriterChanged(bytes32,address,bool)");
    bytes32 constant T_TEXT = keccak256("TextChanged(bytes32,string,string,string)");
    bytes32 constant T_SITE = keccak256("ContenthashChanged(bytes32,bytes)");
    bytes32 constant T_VERSION = keccak256("VersionChanged(bytes32,uint64)");
    bytes32 constant T_TRANSFER = keccak256("Transfer(address,address,uint256)");
    address[4] public actors;
    address[2] public payers;
    string[4] public tops = ["a", "ab", "abc", "alpha"];
    string[2] public subs = ["x", "yy"];
    string[2] public keys = ["avatar", "url"];
    uint256[] public ids;

    // the profile model, predicted from A's logs and the caller
    mapping(uint256 => address) public mWriter;
    mapping(uint256 => uint256) public mFresh;
    mapping(uint256 => mapping(uint256 => uint256)) public mKeySeq;
    mapping(uint256 => uint256) public mSiteSeq;
    uint256 seq;

    // the indexer, built from B's logs only
    mapping(uint256 => address) public iOwner;
    mapping(uint256 => address) public iWriter;
    mapping(uint256 => mapping(uint256 => string)) iText;
    mapping(uint256 => bytes) iSite;

    uint256 public calls;
    uint256 public okCalls;
    uint256 public freshStarts;
    uint256 public keepsOk;
    uint256 public keepsRefused;
    uint256 public bundles;
    uint256 public bundlesWithKeep;
    uint256 public vaultTrips;
    uint256 public hiddenSeen;
    uint256 public shownSeen;
    uint256 public uriChecks;
    uint256 vals;
    uint256 rot;

    constructor(PageNFTNoProfileReset a_, PageNFT b_) {
        A = a_;
        B = b_;
        vault = new DiffVault();
        actors = [makeAddr("d0"), makeAddr("d1"), makeAddr("d2"), makeAddr("d3")];
        payers = [makeAddr("pay0"), makeAddr("pay1")];
        for (uint256 i; i < 4; ++i) vm.deal(actors[i], 1e9 ether);
        for (uint256 i; i < 2; ++i) vm.deal(payers[i], 1e9 ether);
        for (uint256 t; t < 4; ++t) {
            ids.push(B.computeId(tops[t]));
            for (uint256 s; s < 2; ++s) ids.push(B.computeId(string.concat(subs[s], ".", tops[t])));
        }
    }

    // the paired call
    function _keyIndex(string memory k) internal view returns (uint256) {
        return keccak256(bytes(k)) == keccak256(bytes(keys[0])) ? 0 : 1;
    }

    function _isPwc(Vm.Log memory l, uint256 id, address w, bool fresh) internal pure returns (bool) {
        return l.topics.length == 2 && l.topics[0] == T_PWC && l.topics[1] == bytes32(id)
            && keccak256(l.data) == keccak256(abi.encode(w, fresh));
    }

    // B's logs must be A's logs with the predicted writer events; the model follows A's writes
    function _logsMatch(Vm.Log[] memory la, Vm.Log[] memory lb, address from) internal returns (bool) {
        uint256 j;
        for (uint256 i; i < la.length; ++i) {
            bytes32 t = la[i].topics.length > 0 ? la[i].topics[0] : bytes32(0);
            if (t == T_TEXT || t == T_SITE) {
                uint256 id = uint256(la[i].topics[1]);
                if (mWriter[id] != from) {
                    if (j >= lb.length || !_isPwc(lb[j], id, from, true)) return false;
                    ++j;
                    mWriter[id] = from;
                    mFresh[id] = ++seq;
                    ++freshStarts;
                }
                if (t == T_TEXT) {
                    (string memory k,) = abi.decode(la[i].data, (string, string));
                    mKeySeq[id][_keyIndex(k)] = ++seq;
                } else {
                    mSiteSeq[id] = ++seq;
                }
            }
            if (j >= lb.length) return false;
            if (keccak256(abi.encode(la[i].topics, la[i].data)) != keccak256(abi.encode(lb[j].topics, lb[j].data))) {
                return false;
            }
            ++j;
        }
        return j == lb.length;
    }

    // the indexer reads B's logs only
    function _index(Vm.Log[] memory lb) internal {
        for (uint256 i; i < lb.length; ++i) {
            if (lb[i].emitter != address(B) || lb[i].topics.length == 0) continue;
            bytes32 t = lb[i].topics[0];
            if (t == T_TRANSFER && lb[i].topics.length == 4) {
                iOwner[uint256(lb[i].topics[3])] = address(uint160(uint256(lb[i].topics[2])));
            } else if (t == T_PWC) {
                uint256 id = uint256(lb[i].topics[1]);
                (address w, bool fresh) = abi.decode(lb[i].data, (address, bool));
                iWriter[id] = w;
                if (fresh) _iClear(id);
            } else if (t == T_VERSION) {
                _iClear(uint256(lb[i].topics[1]));
            } else if (t == T_TEXT) {
                (string memory k, string memory v) = abi.decode(lb[i].data, (string, string));
                iText[uint256(lb[i].topics[1])][_keyIndex(k)] = v;
            } else if (t == T_SITE) {
                iSite[uint256(lb[i].topics[1])] = abi.decode(lb[i].data, (bytes));
            }
        }
    }

    function _iClear(uint256 id) internal {
        delete iText[id][0];
        delete iText[id][1];
        delete iSite[id];
    }

    function _both(address from, uint256 value, bytes memory data) internal returns (bool) {
        vm.recordLogs();
        vm.prank(from);
        (bool okA, bytes memory ra) = address(A).call{value: value}(data);
        Vm.Log[] memory la = vm.getRecordedLogs();
        vm.prank(from);
        (bool okB, bytes memory rb) = address(B).call{value: value}(data);
        Vm.Log[] memory lb = vm.getRecordedLogs();
        ++calls;
        assertEq(okA, okB, "same success");
        assertEq(ra, rb, "same return or revert data");
        // the recording keeps the logs of a reverted call, which no indexer ever sees
        if (!okA) return false;
        assertTrue(_logsMatch(la, lb, from), "B logs are A logs plus the predicted writer events");
        _index(lb);
        ++okCalls;
        return true;
    }

    // helpers
    function _owner(uint256 id) internal view returns (address o) {
        try B.ownerOf(id) returns (address x) {
            o = x;
        } catch {}
    }

    function _top(uint256 r) internal view returns (uint256) {
        return ids[(r % 4) * 3];
    }

    function _anyId(uint256 r) internal view returns (uint256) {
        return ids[r % ids.length];
    }

    function _actor(uint256 r) internal view returns (address) {
        return actors[r % 4];
    }

    function _active(uint256 id) internal view returns (bool) {
        return A.resolve(id) != address(0);
    }

    function _val() internal returns (string memory) {
        return string.concat("v", vm.toString(++vals));
    }

    modifier meta() {
        _;
        _uri(ids[rot % ids.length]);
        _uri(ids[(rot + 5) % ids.length]);
        _profileView(ids[rot % ids.length], true);
        _profileView(ids[(rot + 5) % ids.length], true);
        ++rot;
    }

    // actions
    function register(uint256 r1, uint256 r2, uint256 r3) external meta {
        _register(r1, r2, r3);
    }

    // waits until the trial pause of a name with no deposit, or the premium period of a paid name,
    // is over, then registers it
    function retake(uint256 r1, uint256 r2, uint256 r3) external meta {
        uint256 id = _top(r1);
        uint256 e = B.expiresAt(id);
        if (e != 0) {
            uint256 t = B.depositOf(id) == 0 ? e + 14 days + 1 : e + 111 days + 1;
            if (t > block.timestamp) vm.warp(t);
        }
        _register(r1, r2, r3);
    }

    function _register(uint256 r1, uint256 r2, uint256 r3) internal {
        string memory l = tops[r1 % 4];
        address who = _actor(r1 >> 8);
        address to = (r2 % 3 == 0) ? _actor(r2 >> 8) : who;
        if (r2 % 17 == 5) to = DEAD;
        uint256 ref = r3 % 3 == 0 ? 0 : _top(r3 >> 8);
        if (ref == B.computeId(l)) ref = 0;
        bytes32 s = keccak256(abi.encode(r1, r2, r3, block.timestamp));
        bytes memory mc = abi.encodeWithSignature("makeCommitment(string,address,uint256,bytes32)", l, to, ref, s);
        (bool okm, bytes memory cm) = address(B).staticcall(mc);
        if (!okm) return;
        _both(who, 0, abi.encodeWithSignature("commit(bytes32)", abi.decode(cm, (bytes32))));
        vm.warp(block.timestamp + (r2 % 13 == 0 ? 19 : 61));
        (,,, uint256 total) = B.quote(l);
        uint256 value = r3 % 11 == 0 ? total - 1 : total + (r3 % 4 == 0 ? (r3 >> 16) % 1 ether : 0);
        _both(who, value, abi.encodeWithSignature("reveal(string,address,uint256,bytes32)", l, to, ref, s));
    }

    function trial(uint256 r1, uint256 r2, uint256 r3) external meta {
        for (uint256 i; i < 4; ++i) {
            if (B.isAvailable(tops[(r1 % 4 + i) % 4], 0)) {
                r1 = (r1 & ~uint256(3)) | ((r1 % 4 + i) % 4);
                break;
            }
        }
        string memory l = tops[r1 % 4];
        uint256 id = B.computeId(l);
        address payer = payers[r1 >> 8 & 1];
        address to = r2 % 9 == 0 ? DEAD : _actor(r2 >> 8);
        uint256 ref = r3 % 3 == 0 ? 0 : _top(r3 >> 8);
        if (ref == id) ref = 0;
        bytes32 s = keccak256(abi.encode("trial", r1, r2, r3, block.timestamp));
        bytes32 c = trialCommitment(address(B), l, to, ref, s);
        _both(payer, 0, abi.encodeWithSignature("commit(bytes32)", c));
        vm.warp(block.timestamp + 61);
        uint256 price = B.getFee(bytes(l).length) / 10;
        uint256 value = r3 % 7 == 0 ? price - 1 : price + (r3 % 5 == 0 ? (r3 >> 16) % 1 ether : 0);
        _both(payer, value, abi.encodeWithSignature("revealTrial(string,address,uint256,bytes32)", l, to, ref, s));
    }

    function renew(uint256 r1, uint256 r2) external meta {
        uint256 id = r2 % 5 == 0 ? _anyId(r1) : _top(r1);
        address who = r2 % 4 == 0 ? payers[r2 >> 4 & 1] : _actor(r1 >> 8);
        uint256 fee = B.getFee(bytes(tops[r1 % 4]).length);
        uint256 value = r2 % 9 == 0 ? fee - 1 : fee + (r2 % 3 == 0 ? (r2 >> 8) % 1 ether : 0);
        _both(who, value, abi.encodeWithSignature("renew(uint256)", id));
    }

    // moves by the holder, or now and then by a random actor, with transferFrom or safeTransferFrom
    // with or without data, to an actor, DEAD or the vault
    function transfer(uint256 r1, uint256 r2) external meta {
        uint256 id = _anyId(r1);
        address from = _owner(id);
        if (from == address(0)) return;
        address caller = r2 % 7 == 0 ? _actor(r2 >> 8) : from;
        address to = r2 % 5 == 0 ? DEAD : r2 % 11 == 0 ? address(vault) : _actor(r2 >> 16);
        uint256 k = r2 % 3;
        if (k == 0) {
            _both(caller, 0, abi.encodeWithSignature("safeTransferFrom(address,address,uint256)", from, to, id));
        } else if (k == 1) {
            _both(caller, 0, abi.encodeWithSignature("transferFrom(address,address,uint256)", from, to, id));
        } else {
            _both(caller, 0, abi.encodeWithSignature("safeTransferFrom(address,address,uint256,bytes)", from, to, id, hex"5ea9"));
        }
    }

    function approveAndMove(uint256 r1, uint256 r2) external meta {
        uint256 id = _anyId(r1);
        address from = _owner(id);
        if (from == address(0) || from == DEAD) return;
        address op = _actor(r2);
        if (r2 % 2 == 0) _both(from, 0, abi.encodeWithSignature("approve(address,uint256)", op, id));
        else _both(from, 0, abi.encodeWithSignature("setApprovalForAll(address,bool)", op, true));
        _both(op, 0, abi.encodeWithSignature("safeTransferFrom(address,address,uint256,bytes)", from, _actor(r2 >> 8), id, hex"01"));
    }

    // into the vault and back to the same holder, the vault never writing
    function vaultTrip(uint256 r1) external meta {
        uint256 id = _anyId(r1);
        address from = _owner(id);
        if (from == address(0) || from == DEAD || from == address(vault)) return;
        if (!_both(from, 0, abi.encodeWithSignature("safeTransferFrom(address,address,uint256)", from, address(vault), id))) return;
        if (_both(address(vault), 0, abi.encodeWithSignature("transferFrom(address,address,uint256)", address(vault), from, id))) {
            ++vaultTrips;
        }
    }

    function records(uint256 r1, uint256 r2) external meta {
        uint256 id = _anyId(r1);
        address o = _owner(id);
        address who = (r2 % 5 == 0 || o == address(0)) ? _actor(r2 >> 8) : o;
        uint256 k = (r2 >> 16) % 7;
        bytes memory d;
        if (k == 0) d = abi.encodeWithSignature("setAddr(uint256,address)", id, r2 % 2 == 0 ? address(0) : _actor(r2 >> 24));
        else if (k == 1) d = abi.encodeWithSignature("setAddrForCoin(uint256,uint256,bytes)", id, COIN_BASE, abi.encodePacked(_actor(r2 >> 24)));
        else if (k == 2) d = abi.encodeWithSignature("setAddrForCoin(uint256,uint256,bytes)", id, 60, abi.encodePacked(_actor(r2 >> 24)));
        else if (k == 3 || k == 4) d = abi.encodeWithSignature("setText(uint256,string,string)", id, keys[k - 3], _val());
        else if (k == 5) d = abi.encodeWithSignature("setContenthash(uint256,bytes)", id, bytes(_val()));
        else d = abi.encodeWithSignature("clearRecords(uint256)", id);
        _both(who, 0, d);
    }

    // a profile write by the holder of a name that exists, or now and then by someone else
    function profile(uint256 r1, uint256 r2) external meta {
        uint256 id = _anyId(r1);
        for (uint256 i; i < ids.length && _owner(id) == address(0); ++i) id = ids[(r1 % ids.length + i) % ids.length];
        address o = _owner(id);
        address who = (r2 % 6 == 0 || o == address(0)) ? _actor(r2 >> 8) : o;
        bytes memory d = r2 % 3 == 2
            ? abi.encodeWithSignature("setContenthash(uint256,bytes)", id, bytes(_val()))
            : abi.encodeWithSignature("setText(uint256,string,string)", id, keys[r2 % 3], _val());
        _both(who, 0, d);
    }

    function profile2(uint256 r1, uint256 r2) external {
        this.profile(r1, r2);
    }

    function keep2(uint256 r1, uint256 r2) external {
        this.keep(r1, r2);
    }

    // B only: the modelled outcome, the one log, and only the writer changes
    function keep(uint256 r1, uint256 r2) external meta {
        uint256 id = _anyId(r1);
        address o = _owner(id);
        address who = r2 % 4 == 0 ? _actor(r2 >> 8) : r2 % 13 == 0 ? address(vault) : o;
        if (who == address(0)) who = _actor(r2);
        _keepB(id, who);
    }

    function _keepErr(uint256 id, address who) internal view returns (bytes4) {
        if (!_active(id)) return PageNFT.Expired.selector;
        if (_owner(id) != who) return PageNFT.Unauthorized.selector;
        if (mWriter[id] == who) return PageNFT.AlreadyKept.selector;
        return bytes4(0);
    }

    function _keepB(uint256 id, address who) internal {
        bytes4 want = _keepErr(id, who);
        vm.recordLogs();
        vm.prank(who);
        (bool ok, bytes memory ret) = address(B).call(abi.encodeCall(PageNFT.keepProfile, (id)));
        Vm.Log[] memory lb = vm.getRecordedLogs();
        ++calls;
        assertEq(ok, want == bytes4(0), "keep succeeds exactly as modelled");
        if (!ok) {
            assertEq(ret, abi.encodePacked(want), "keep error as modelled");
            ++keepsRefused;
            return;
        }
        assertEq(lb.length, 1);
        assertTrue(_isPwc(lb[0], id, who, false), "keep log");
        _index(lb);
        mWriter[id] = who;
        ++keepsOk;
    }

    function primary(uint256 r1, uint256 r2) external meta {
        uint256 id = r2 % 6 == 0 ? 0 : _anyId(r1);
        _both(_actor(r2 >> 8), 0, abi.encodeWithSignature("setPrimaryPage(uint256)", id));
    }

    function subpage(uint256 r1, uint256 r2) external meta {
        uint256 p = _top(r1);
        address o = _owner(p);
        address who = r2 % 4 == 0 ? _actor(r2 >> 8) : (o == address(0) ? _actor(r2) : o);
        string memory l = subs[(r1 >> 8) % 2];
        address to = r2 % 6 == 0 ? DEAD : _actor(r2 >> 16);
        if (r2 % 2 == 0) _both(who, 0, abi.encodeWithSignature("registerSubpage(string,uint256)", l, p));
        else _both(who, 0, abi.encodeWithSignature("registerSubpageFor(string,uint256,address)", l, p, to));
    }

    function minter(uint256 r1, uint256 r2) external meta {
        uint256 p = _top(r1);
        address o = _owner(p);
        address who = r2 % 4 == 0 ? _actor(r2 >> 8) : (o == address(0) ? _actor(r2) : o);
        address m = r2 % 3 == 0 ? address(0) : _actor(r2 >> 16);
        _both(who, 0, abi.encodeWithSignature("setSubpageMinter(uint256,address)", p, m));
    }

    function release(uint256 r1) external meta {
        uint256 id = r1 % 5 == 0 ? _anyId(r1 >> 8) : _top(r1);
        _both(_actor(r1 >> 16), 0, abi.encodeWithSignature("release(uint256)", id));
    }

    function withdraw(uint256 r1) external meta {
        address a = r1 % 5 == 0 ? payers[r1 >> 4 & 1] : _actor(r1);
        _both(_actor(r1 >> 8), 0, abi.encodeWithSignature("withdraw(address)", a));
    }

    // a bundle of up to three calls; B may get a keepProfile in front, which A cannot take
    function bundle(uint256 r1, uint256 r2) external meta {
        uint256 n = 1 + r1 % 3;
        bytes[] memory d = new bytes[](n);
        for (uint256 i; i < n; ++i) {
            uint256 r = uint256(keccak256(abi.encode(r1, r2, i)));
            uint256 id = _anyId(r);
            uint256 k = (r >> 8) % 8;
            if (k == 0 || k == 6) d[i] = abi.encodeWithSignature("setText(uint256,string,string)", id, keys[k == 0 ? 0 : 1], _val());
            else if (k == 7) d[i] = abi.encodeWithSignature("setContenthash(uint256,bytes)", id, bytes(_val()));
            else if (k == 1) d[i] = abi.encodeWithSignature("setAddr(uint256,address)", id, _actor(r >> 16));
            else if (k == 2) d[i] = abi.encodeWithSignature("setPrimaryPage(uint256)", id);
            else if (k == 3) d[i] = abi.encodeWithSignature("transferFrom(address,address,uint256)", _owner(id), _actor(r >> 24), id);
            else if (k == 4) d[i] = abi.encodeWithSignature("clearRecords(uint256)", id);
            else d[i] = abi.encodeWithSignature("registerSubpage(string,uint256)", subs[(r >> 24) % 2], _top(r >> 32));
        }
        uint256 kid = _anyId(r1 >> 8);
        address who = r2 % 3 == 0 ? _actor(r2 >> 8) : _owner(kid);
        if (who == address(0)) who = _actor(r2);
        if (r2 % 2 == 0) {
            if (_both(who, 0, abi.encodeWithSignature("multicall(bytes[])", d))) ++bundles;
            return;
        }
        _bundleWithKeep(kid, who, d);
    }

    function _bundleWithKeep(uint256 kid, address who, bytes[] memory d) internal {
        bytes[] memory db = new bytes[](d.length + 1);
        db[0] = abi.encodeCall(PageNFT.keepProfile, (kid));
        for (uint256 i; i < d.length; ++i) db[i + 1] = d[i];
        bytes4 want = _keepErr(kid, who);
        if (want != bytes4(0)) {
            // the keep fails first, so B's bundle fails with its error and A is not called
            vm.prank(who);
            (bool okB, bytes memory rb) = address(B).call(abi.encodeWithSignature("multicall(bytes[])", db));
            ++calls;
            assertFalse(okB, "a bundle starting with a failing keep fails");
            assertEq(rb, abi.encodePacked(want));
            return;
        }
        vm.recordLogs();
        vm.prank(who);
        (bool okA, bytes memory ra) = address(A).call(abi.encodeWithSignature("multicall(bytes[])", d));
        Vm.Log[] memory la = vm.getRecordedLogs();
        vm.prank(who);
        (bool okB, bytes memory rb) = address(B).call(abi.encodeWithSignature("multicall(bytes[])", db));
        Vm.Log[] memory lb = vm.getRecordedLogs();
        ++calls;
        assertEq(okA, okB, "same bundle success");
        if (!okA) {
            assertEq(ra, rb, "same revert data");
            return;
        }
        bytes[] memory resA = abi.decode(ra, (bytes[]));
        bytes[] memory resB = abi.decode(rb, (bytes[]));
        assertEq(resB.length, resA.length + 1);
        assertEq(resB[0].length, 0);
        for (uint256 i; i < resA.length; ++i) assertEq(resA[i], resB[i + 1]);
        assertTrue(_isPwc(lb[0], kid, who, false), "keep log first");
        mWriter[kid] = who;
        Vm.Log[] memory rest = new Vm.Log[](lb.length - 1);
        for (uint256 i = 1; i < lb.length; ++i) rest[i - 1] = lb[i];
        assertTrue(_logsMatch(la, rest, who), "the rest of B's logs as predicted");
        _index(lb);
        ++keepsOk;
        ++bundlesWithKeep;
        ++bundles;
    }

    function warp(uint256 r) external meta {
        uint256 k = r % 8;
        if (k == 0) vm.warp(block.timestamp + bound(r >> 8, 1, 130 days));
        else if (k == 1) {
            uint256 e = B.expiresAt(_top(r >> 8));
            uint256 m = (r >> 16) % 6;
            uint256 t = m == 0 ? e : m == 1 ? e + 1 : m == 2 ? e + 14 days + 1 : m == 3 ? e + 90 days + 1 + (r >> 24) % 21 days : m == 4 ? e + 111 days + 1 : e + 90 days;
            if (t > block.timestamp) vm.warp(t);
        } else vm.warp(block.timestamp + bound(r >> 8, 1, 6 days));
    }

    // the view comparison
    function _sameView(bytes memory data) internal view {
        (bool okA, bytes memory ra) = address(A).staticcall(data);
        (bool okB, bytes memory rb) = address(B).staticcall(data);
        assertEq(okA, okB, "view success differs");
        assertEq(ra, rb, "view differs");
    }

    function _profileView(uint256 id, bool count) internal {
        address o = _owner(id);
        bool counts = o != address(0) && mWriter[id] == o;
        assertEq(B.profileWriter(id), mWriter[id], "writer as modelled");
        bool idxCounts = _active(id) && iWriter[id] == iOwner[id];
        assertEq(iOwner[id], o, "indexer owner");
        for (uint256 k; k < 2; ++k) {
            string memory a = A.text(id, keys[k]);
            string memory b = B.text(id, keys[k]);
            string memory want = counts && mKeySeq[id][k] > mFresh[id] ? a : "";
            assertEq(b, want, "text as predicted");
            assertEq(b, idxCounts ? iText[id][k] : "", "indexer text");
            assertEq(B.text(bytes32(id), keys[k]), b, "bytes32 form");
            if (bytes(b).length != 0) {
                assertEq(B.profileWriter(id), o, "a shown entry belongs to the holder's profile");
                if (count) ++shownSeen;
            } else if (bytes(a).length != 0) {
                if (count) ++hiddenSeen;
            }
        }
        bytes memory sa = A.contenthash(id);
        bytes memory sb = B.contenthash(id);
        assertEq(sb, counts && mSiteSeq[id] > mFresh[id] ? sa : bytes(""), "website as predicted");
        assertEq(sb, idxCounts ? iSite[id] : bytes(""), "indexer website");
        if (sb.length != 0) assertEq(B.profileWriter(id), o);
    }

    function checkAll() external {
        assertEq(address(A).balance, address(B).balance, "balance");
        for (uint256 k; k < ids.length; ++k) {
            uint256 id = ids[k];
            _sameView(abi.encodeWithSignature("ownerOf(uint256)", id));
            _sameView(abi.encodeWithSignature("getApproved(uint256)", id));
            _sameView(abi.encodeWithSignature("records(uint256)", id));
            _sameView(abi.encodeWithSignature("recordVersion(uint256)", id));
            _sameView(abi.encodeWithSignature("payee(uint256)", id));
            _sameView(abi.encodeWithSignature("resolve(uint256)", id));
            _sameView(abi.encodeWithSignature("addr(bytes32)", bytes32(id)));
            _sameView(abi.encodeWithSignature("addr(uint256,uint256)", id, 60));
            _sameView(abi.encodeWithSignature("addr(uint256,uint256)", id, 0x8000000a));
            _sameView(abi.encodeWithSignature("addr(uint256,uint256)", id, COIN_BASE));
            _sameView(abi.encodeWithSignature("depositOf(uint256)", id));
            _sameView(abi.encodeWithSignature("trialPaymentOf(uint256)", id));
            _sameView(abi.encodeWithSignature("getPremium(uint256)", id));
            _sameView(abi.encodeWithSignature("isExpired(uint256)", id));
            _sameView(abi.encodeWithSignature("inGracePeriod(uint256)", id));
            _sameView(abi.encodeWithSignature("isReleasable(uint256)", id));
            _sameView(abi.encodeWithSignature("referrerOf(uint256)", id));
            _sameView(abi.encodeWithSignature("getPageName(uint256)", id));
            _sameView(abi.encodeWithSignature("subpageMinterOf(uint256)", id));
            _sameView(abi.encodeWithSignature("status(uint256)", id));
            _profileView(id, false);
        }
        for (uint256 t; t < 4; ++t) {
            _sameView(abi.encodeWithSignature("isAvailable(string,uint256)", tops[t], 0));
            _sameView(abi.encodeWithSignature("quote(string)", tops[t]));
            for (uint256 s; s < 2; ++s) {
                _sameView(abi.encodeWithSignature("isAvailable(string,uint256)", subs[s], ids[t * 3]));
            }
        }
        for (uint256 a; a < 4; ++a) {
            _sameView(abi.encodeWithSignature("owed(address)", actors[a]));
            _sameView(abi.encodeWithSignature("balanceOf(address)", actors[a]));
            _sameView(abi.encodeWithSignature("primaryPage(address)", actors[a]));
            _sameView(abi.encodeWithSignature("reverseResolve(address)", actors[a]));
        }
        for (uint256 p; p < 2; ++p) _sameView(abi.encodeWithSignature("owed(address)", payers[p]));
        _sameView(abi.encodeWithSignature("owed(address)", DEAD));
        _sameView(abi.encodeWithSignature("balanceOf(address)", address(vault)));
    }

    function _uri(uint256 id) internal {
        _sameView(abi.encodeWithSignature("tokenURI(uint256)", id));
        ++uriChecks;
    }
}

contract ProfileDifferentialTest is Test {
    ProfileWorlds h;

    function setUp() public {
        vm.warp(1_800_000_000);
        PageCard card = new PageCard();
        h = new ProfileWorlds(new PageNFTNoProfileReset(card), new PageNFT(card));
        targetContract(address(h));
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = ProfileWorlds.checkAll.selector;
        excludeSelector(FuzzSelector({addr: address(h), selectors: sels}));
    }

    function invariant_sameWorldsButTheProfile() public {
        h.checkAll();
    }

    function afterInvariant() public {
        string memory s1 = string.concat(
            vm.toString(h.calls()), " calls, ", vm.toString(h.okCalls()), " ok, ", vm.toString(h.freshStarts()),
            " fresh starts, ", vm.toString(h.keepsOk()), " keeps, ", vm.toString(h.keepsRefused()), " keeps refused, "
        );
        string memory s2 = string.concat(
            vm.toString(h.bundles()), " bundles, ", vm.toString(h.bundlesWithKeep()), " with keep, ",
            vm.toString(h.vaultTrips()), " vault trips, ", vm.toString(h.shownSeen()), " shown, ",
            vm.toString(h.hiddenSeen()), " hidden that A shows, ", vm.toString(h.uriChecks()), " tokenURI"
        );
        vm.createDir("logs", true);
        vm.writeLine("logs/profile-diff-stats.txt", string.concat(s1, s2));
    }
}

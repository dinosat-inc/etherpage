// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {trialCommitment} from "../utils/TrialCommitment.sol";

import {Test, Vm} from "forge-std/Test.sol";
import {Base64} from "solady/utils/Base64.sol";
import {LibString} from "solady/utils/LibString.sol";
import {PageNFT} from "../../src/PageNFT.sol";
import {PageCard} from "../../src/PageCard.sol";
import {PageNFTBurnedTrial} from "./harness/PageNFTBurnedTrial.sol";
import {ProfileLogs} from "./ProfileLogs.sol";

// World A is PageNFTBurnedTrial, which burns the price of a trial. World B is src. Every call goes to
// both worlds and must succeed or fail alike, with the same return data and the same logs, and every
// view must agree after every call. Only these differences are allowed. B has the profile writer rule,
// so ProfileLogs checks and removes its writer events before every log comparison, and its text and
// contenthash must be A's or empty. Each other difference is modelled.
// A stale subpage shows its full name in the metadata and on the card of B, in paid and trial mode.
// With trials, in trial mode only, B holds each trial price for its payer instead of burning it,
// credits it back at conversion, at release after the end, or at the next registration or trial
// (B logs TrialRefunded there, and apart from its profile writer events nothing else differs in the
// logs), refuses a new trial inside the pause (such calls are not made, only counted), reports Trial
// where A reports Active, and says a lapsed trial with money held is releasable.
contract DiffWorlds is Test {
    PageNFTBurnedTrial public A;
    PageNFT public B;
    bool public trialsOn;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 constant COIN_OP = 0x8000000a;
    uint256 constant COIN_BASE = 0x80002105;
    bytes32 constant T_REFUNDED = keccak256("TrialRefunded(uint256,address,uint256)");
    address[4] public actors;
    address[2] public payers;
    string[4] public tops = ["a", "ab", "abc", "alpha"];
    string[2] public subs = ["x", "yy"];
    string[5] statusNames = ["Active", "Grace", "Expired", "Invalid", "Trial"];
    uint256[] public ids;

    // the trial money model: held in B per id, burned in A, credited in B per payer
    mapping(uint256 => address) public heldPayer;
    mapping(uint256 => uint256) public heldAmount;
    mapping(address => uint256) public refundedTo;
    uint256 public burnedInA;

    uint256 public calls;
    uint256 public okCalls;
    uint256 public trialCalls;
    uint256 public trialReleases;
    uint256 public refundsInB;
    uint256 public pauseSkips;
    uint256 public staleSeen;
    uint256 public trialSeen;
    uint256 public uriChecks;
    uint256 public bundles;
    uint256 rot;

    constructor(PageNFTBurnedTrial a_, PageNFT b_, bool trials_) {
        A = a_;
        B = b_;
        trialsOn = trials_;
        actors = [makeAddr("d0"), makeAddr("d1"), makeAddr("d2"), makeAddr("d3")];
        payers = [makeAddr("pay0"), makeAddr("pay1")];
        for (uint256 i; i < 4; ++i) vm.deal(actors[i], 1e9 ether);
        for (uint256 i; i < 2; ++i) vm.deal(payers[i], 1e9 ether);
        for (uint256 t; t < 4; ++t) {
            uint256 top = B.computeId(tops[t]);
            ids.push(top);
            for (uint256 s; s < 2; ++s) ids.push(B.computeId(string.concat(subs[s], ".", tops[t])));
        }
    }

    function idsLength() external view returns (uint256) {
        return ids.length;
    }

    // the paired call
    function _logsEqual(Vm.Log[] memory la, Vm.Log[] memory lb, bool dropRefund) internal returns (bool) {
        uint256 j;
        for (uint256 i; i < la.length; ++i) {
            while (dropRefund && j < lb.length && lb[j].topics.length > 0 && lb[j].topics[0] == T_REFUNDED) {
                _takeRefund(lb[j]);
                ++j;
            }
            if (j >= lb.length) return false;
            if (keccak256(abi.encode(la[i].topics, la[i].data)) != keccak256(abi.encode(lb[j].topics, lb[j].data))) {
                return false;
            }
            ++j;
        }
        while (dropRefund && j < lb.length && lb[j].topics.length > 0 && lb[j].topics[0] == T_REFUNDED) {
            _takeRefund(lb[j]);
            ++j;
        }
        return j == lb.length;
    }

    // a TrialRefunded log of B must match the model exactly
    function _takeRefund(Vm.Log memory l) internal {
        uint256 id = uint256(l.topics[1]);
        address to = address(uint160(uint256(l.topics[2])));
        uint256 amount = abi.decode(l.data, (uint256));
        assertEq(to, heldPayer[id], "refund to the modelled payer");
        assertEq(amount, heldAmount[id], "refund of the modelled amount");
        assertGt(amount, 0);
        refundedTo[to] += amount;
        heldPayer[id] = address(0);
        heldAmount[id] = 0;
        ++refundsInB;
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
        assertTrue(_logsEqual(la, ProfileLogs.strip(lb), trialsOn), "same logs");
        if (okA) ++okCalls;
        return okA;
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

    function _heldB(uint256 id) internal view returns (uint256 a) {
        (, a) = B.trialPaymentOf(id);
    }

    // after every action, the metadata of two names in turn
    modifier meta() {
        _;
        _uri(ids[rot % ids.length]);
        _uri(ids[(rot + 5) % ids.length]);
        ++rot;
    }

    // actions
    function register(uint256 r1, uint256 r2, uint256 r3) external meta {
        _register(r1, r2, r3);
    }

    // waits until the trial pause of a name with no deposit, or the premium period of a paid name,
    // is over, then registers it, which makes its subpages stale
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
        _trial(r1, r2, r3);
    }

    function trialAgain(uint256 r1, uint256 r2, uint256 r3) external meta {
        _trial(r1, r2, r3);
    }

    function _trial(uint256 r1, uint256 r2, uint256 r3) internal {
        if (!trialsOn) return;
        // prefer a label that is free now, so most trials start
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
        uint256 e = B.expiresAt(id);
        if (e != 0 && B.depositOf(id) == 0 && block.timestamp > e && block.timestamp <= e + 14 days) {
            // B refuses this trial, A would accept it
            ++pauseSkips;
            return;
        }
        uint256 price = B.getFee(bytes(l).length) / 10;
        uint256 value = r3 % 7 == 0 ? price - 1 : price + (r3 % 5 == 0 ? (r3 >> 16) % 1 ether : 0);
        if (_both(payer, value, abi.encodeWithSignature("revealTrial(string,address,uint256,bytes32)", l, to, ref, s))) {
            burnedInA += price;
            heldPayer[id] = payer;
            heldAmount[id] = price;
            ++trialCalls;
        }
    }

    function renew(uint256 r1, uint256 r2) external meta {
        uint256 id = r2 % 5 == 0 ? _anyId(r1) : _top(r1);
        address who = _actor(r1 >> 8);
        uint256 fee = B.getFee(bytes(tops[r1 % 4]).length);
        uint256 value = r2 % 9 == 0 ? fee - 1 : fee + (r2 % 3 == 0 ? (r2 >> 8) % 1 ether : 0);
        _both(who, value, abi.encodeWithSignature("renew(uint256)", id));
    }

    function transfer(uint256 r1, uint256 r2) external meta {
        uint256 id = _anyId(r1);
        address from = _owner(id);
        if (from == address(0)) return;
        address caller = r2 % 7 == 0 ? _actor(r2 >> 8) : from;
        address to = r2 % 5 == 0 ? DEAD : _actor(r2 >> 16);
        if (r2 % 3 == 0) {
            _both(caller, 0, abi.encodeWithSignature("safeTransferFrom(address,address,uint256)", from, to, id));
        } else {
            _both(caller, 0, abi.encodeWithSignature("transferFrom(address,address,uint256)", from, to, id));
        }
    }

    function approveAndMove(uint256 r1, uint256 r2) external meta {
        uint256 id = _anyId(r1);
        address from = _owner(id);
        if (from == address(0) || from == DEAD) return;
        address op = _actor(r2);
        if (r2 % 2 == 0) _both(from, 0, abi.encodeWithSignature("approve(address,uint256)", op, id));
        else _both(from, 0, abi.encodeWithSignature("setApprovalForAll(address,bool)", op, true));
        _both(op, 0, abi.encodeWithSignature("transferFrom(address,address,uint256)", from, _actor(r2 >> 8), id));
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
        else if (k == 3) d = abi.encodeWithSignature("setText(uint256,string,string)", id, "k", "v");
        else if (k == 4) d = abi.encodeWithSignature("setContenthash(uint256,bytes)", id, hex"e301");
        else if (k == 5) d = abi.encodeWithSignature("clearRecords(uint256)", id);
        else d = abi.encodeWithSignature("setAddrForCoin(uint256,uint256,bytes)", id, COIN_OP, abi.encodePacked(_actor(r2 >> 24)));
        _both(who, 0, d);
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
        address caller = _actor(r1 >> 16);
        uint256 held = _heldB(id);
        if (trialsOn && held != 0) {
            // B credits the payer after the end; A has nothing to release there
            vm.prank(caller);
            (bool okA,) = address(A).call(abi.encodeWithSignature("release(uint256)", id));
            vm.recordLogs();
            vm.prank(caller);
            (bool okB,) = address(B).call(abi.encodeWithSignature("release(uint256)", id));
            Vm.Log[] memory lb = vm.getRecordedLogs();
            ++calls;
            assertFalse(okA, "A has nothing to release for a lapsed trial");
            assertEq(okB, block.timestamp > B.expiresAt(id), "B releases trial money exactly after the end");
            if (okB) {
                assertEq(lb.length, 1);
                _takeRefund(lb[0]);
                ++trialReleases;
            }
            return;
        }
        _both(caller, 0, abi.encodeWithSignature("release(uint256)", id));
    }

    function withdraw(uint256 r1) external meta {
        address a = (!trialsOn && r1 % 5 == 0) ? DEAD : _actor(r1);
        _both(_actor(r1 >> 8), 0, abi.encodeWithSignature("withdraw(address)", a));
    }

    // a bundle of up to three calls that carry no value
    function bundle(uint256 r1, uint256 r2) external meta {
        uint256 n = 1 + r1 % 3;
        bytes[] memory d = new bytes[](n);
        for (uint256 i; i < n; ++i) {
            uint256 r = uint256(keccak256(abi.encode(r1, r2, i)));
            uint256 id = _anyId(r);
            uint256 k = (r >> 8) % 6;
            if (k == 0) d[i] = abi.encodeWithSignature("setText(uint256,string,string)", id, "k", "b");
            else if (k == 1) d[i] = abi.encodeWithSignature("setAddr(uint256,address)", id, _actor(r >> 16));
            else if (k == 2) d[i] = abi.encodeWithSignature("setPrimaryPage(uint256)", id);
            else if (k == 3) d[i] = abi.encodeWithSignature("transferFrom(address,address,uint256)", _owner(id), _actor(r >> 24), id);
            else if (k == 4) d[i] = abi.encodeWithSignature("withdraw(address)", _actor(r >> 24));
            else d[i] = abi.encodeWithSignature("registerSubpage(string,uint256)", subs[(r >> 24) % 2], _top(r >> 32));
        }
        address who = r2 % 3 == 0 ? _actor(r2 >> 8) : _owner(_anyId(r1 >> 8));
        if (who == address(0)) who = _actor(r2);
        if (_both(who, 0, abi.encodeWithSignature("multicall(bytes[])", d))) ++bundles;
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

    // B's profile answer is A's or empty, and one that is not empty only while B's writer holds the name
    function _sameProfile(bytes memory data, uint256 id) internal view {
        (bool okA, bytes memory ra) = address(A).staticcall(data);
        (bool okB, bytes memory rb) = address(B).staticcall(data);
        assertEq(okA, okB, "view success differs");
        (bool same, bool hidden) = ProfileLogs.subset(ra, rb);
        assertTrue(same || hidden, "B profile is A's or empty");
        if (keccak256(rb) != keccak256(abi.encode(""))) assertEq(B.profileWriter(id), B.ownerOf(id));
    }

    function _json(address w, uint256 id) internal view returns (string memory) {
        return string(Base64.decode(LibString.slice(PageNFT(w).tokenURI(id), 29)));
    }

    function _stale(uint256 id) internal view returns (bool) {
        uint256 p = B.parentOf(id);
        if (p == 0) return false;
        (,,,, uint64 pe) = B.records(id);
        return pe != B.epochOf(p);
    }

    function checkAll() external view {
        assertEq(address(A).balance, address(B).balance, "balance");
        uint256 heldSum;
        for (uint256 k; k < ids.length; ++k) {
            uint256 id = ids[k];
            _sameView(abi.encodeWithSignature("ownerOf(uint256)", id));
            _sameView(abi.encodeWithSignature("records(uint256)", id));
            _sameView(abi.encodeWithSignature("recordVersion(uint256)", id));
            _sameView(abi.encodeWithSignature("payee(uint256)", id));
            _sameView(abi.encodeWithSignature("resolve(uint256)", id));
            _sameView(abi.encodeWithSignature("addr(uint256,uint256)", id, 60));
            _sameView(abi.encodeWithSignature("addr(uint256,uint256)", id, COIN_BASE));
            _sameProfile(abi.encodeWithSignature("text(uint256,string)", id, "k"), id);
            _sameProfile(abi.encodeWithSignature("contenthash(uint256)", id), id);
            _sameView(abi.encodeWithSignature("depositOf(uint256)", id));
            _sameView(abi.encodeWithSignature("getPremium(uint256)", id));
            _sameView(abi.encodeWithSignature("isExpired(uint256)", id));
            _sameView(abi.encodeWithSignature("inGracePeriod(uint256)", id));
            _sameView(abi.encodeWithSignature("referrerOf(uint256)", id));
            _sameView(abi.encodeWithSignature("getPageName(uint256)", id));
            _sameView(abi.encodeWithSignature("subpageMinterOf(uint256)", id));
            uint256 held = _heldB(id);
            assertEq(held, heldAmount[id], "B holds what the model holds");
            heldSum += held;
            bool relA = A.isReleasable(id);
            bool relB = B.isReleasable(id);
            if (held != 0) assertEq(relB, block.timestamp > B.expiresAt(id), "trial money releasable after the end");
            else assertEq(relA, relB, "isReleasable");
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
        for (uint256 p; p < 2; ++p) {
            assertEq(A.owed(payers[p]), 0);
            assertEq(B.owed(payers[p]), refundedTo[payers[p]], "B credits each payer what was refunded to it");
        }
        uint256 refunded = refundedTo[payers[0]] + refundedTo[payers[1]];
        assertEq(A.owed(DEAD), B.owed(DEAD) + burnedInA, "A burns what B holds or refunded");
        assertEq(burnedInA, heldSum + refunded, "every trial price is held or refunded in B");
    }

    // the metadata of both worlds, equal except the allowed differences
    function _uri(uint256 id) internal {
        (bool okA, bytes memory ra) = address(A).staticcall(abi.encodeWithSignature("tokenURI(uint256)", id));
        (bool okB,) = address(B).staticcall(abi.encodeWithSignature("tokenURI(uint256)", id));
        assertEq(okA, okB, "tokenURI success");
        (bool okS, bytes memory rs) = address(B).staticcall(abi.encodeWithSignature("status(uint256)", id));
        assertEq(okS, okB, "status reverts exactly when tokenURI does");
        if (!okA) return;
        ++uriChecks;
        PageCard.Status s = abi.decode(rs, (PageCard.Status));
        string memory jb = _json(address(B), id);
        assertTrue(LibString.contains(jb, string.concat('"Status","value":"', statusNames[uint256(s)], '"')), "status equals B metadata");
        string memory ja = _json(address(A), id);
        if (s == PageCard.Status.Trial) {
            ++trialSeen;
            assertTrue(trialsOn);
            assertTrue(LibString.contains(ja, '"Status","value":"Active"'), "A shows a live trial as Active");
            return;
        }
        if (_stale(id)) {
            ++staleSeen;
            (string memory label, uint256 parent,,,) = B.records(id);
            (string memory plabel,,,,) = B.records(parent);
            assertTrue(LibString.contains(jb, string.concat('"name":"', label, ".", plabel, '"')), "B full name");
            assertTrue(LibString.contains(ja, string.concat('"name":"', label, '"')), "A label only");
            assertTrue(LibString.contains(ja, '"Status","value":"Invalid"'));
            return;
        }
        assertEq(abi.decode(ra, (string)), PageNFT(address(B)).tokenURI(id), "tokenURI");
    }
}

contract PaidDifferentialTest is Test {
    DiffWorlds h;

    function setUp() public {
        vm.warp(1_800_000_000);
        PageCard card = new PageCard();
        h = new DiffWorlds(new PageNFTBurnedTrial(card), new PageNFT(card), false);
        targetContract(address(h));
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = DiffWorlds.checkAll.selector;
        excludeSelector(FuzzSelector({addr: address(h), selectors: sels}));
    }

    function invariant_sameWorlds() public {
        h.checkAll();
    }

    function afterInvariant() public {
        vm.createDir("logs", true);
        vm.writeLine(
            "logs/paid-diff-stats.txt",
            string.concat(
                vm.toString(h.calls()), " calls, ", vm.toString(h.okCalls()), " ok, ", vm.toString(h.bundles()),
                " bundles, ", vm.toString(h.uriChecks()), " metadata checks, ", vm.toString(h.staleSeen()), " stale"
            )
        );
    }
}

contract TrialMoneyDifferentialTest is Test {
    DiffWorlds h;

    function setUp() public {
        vm.warp(1_800_000_000);
        PageCard card = new PageCard();
        h = new DiffWorlds(new PageNFTBurnedTrial(card), new PageNFT(card), true);
        targetContract(address(h));
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = DiffWorlds.checkAll.selector;
        excludeSelector(FuzzSelector({addr: address(h), selectors: sels}));
    }

    function invariant_sameWorldsButTheTrialRules() public {
        h.checkAll();
    }

    function afterInvariant() public {
        vm.createDir("logs", true);
        vm.writeLine(
            "logs/trial-money-diff-stats.txt",
            string.concat(
                vm.toString(h.calls()), " calls, ", vm.toString(h.okCalls()), " ok, ", vm.toString(h.trialCalls()),
                " trials, ", vm.toString(h.refundsInB()), " refunds, ", vm.toString(h.trialReleases()),
                " trial releases, ", vm.toString(h.pauseSkips()), " trials skipped in the pause, ",
                vm.toString(h.trialSeen()), " Trial metadata, ", vm.toString(h.staleSeen()), " stale"
            )
        );
    }
}

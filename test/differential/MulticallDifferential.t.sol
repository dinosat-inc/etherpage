// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Test, Vm} from "forge-std/Test.sol";
import {Base64} from "solady/utils/Base64.sol";
import {PageCard} from "../../src/PageCard.sol";
import {PageNFT} from "../../src/PageNFT.sol";
import {ProfileLogs} from "./ProfileLogs.sol";
import {SubpageRegistrar, IPageNFT} from "../../src/SubpageRegistrar.sol";
import {PageNFTDeleted} from "./harness/PageNFTDeleted.sol";
import {SubpageRegistrarDeleted, IPageNFTDeleted} from "./harness/SubpageRegistrarDeleted.sol";
import {Holder721} from "../utils/MinterMocks.sol";

// World A is PageNFTDeleted, which has no multicall, and world B is src.
// Every plain call goes to both worlds and must succeed or fail alike, with the same return data and
// the same logs, and the views the test reads must agree, apart from the differences named at the end,
// which apply to bundles too. Views are compared after every step, a few of them, such as contenthash
// and tokenURI, only every 20 or 25 steps and when the walk ends. A bundle goes to B as one multicall
// and to A as the same calls one by one, in order, stopping at the first failure. If every call in A
// succeeds, B's bundle must succeed, each result must equal A's return data and B's logs must equal A's
// logs in order. Otherwise B's bundle must fail with the first failing call's revert data and A is
// rolled back, so both worlds stay equal. A bundle sent with value must always fail in B.
// B also clears the sender's primary name when a transfer moves the name it names, shows a display name
// only while the name is held by the account that held it when it was chosen, and counts text and
// website only while their writer holds the name. Every log and pointer check passes through the
// predictor below, which allows exactly the primary name change, once ProfileLogs has checked and
// removed B's writer events. Where the pointers agree, B's reverseResolve must equal A's under that
// holder check, and B's text and contenthash must be A's or empty.
contract MulticallDifferentialTest is Test {
    PageCard card;
    address NA;
    address NB;
    address RA;
    address RB;
    Holder721 holder;
    address[6] actors;
    string[4] tops = ["club", "gold", "ab", "q"];
    string[6] subs = ["a", "b", "sub", "Live", "c", "d"];
    uint256[] tids;
    uint256[] ids;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 constant COIN_OP = 0x8000000a;
    uint256 constant COIN_BASE = 0x80002105;
    bytes32 constant T_TRANSFER = keccak256("Transfer(address,address,uint256)");
    bytes32 constant T_ADDRESS = keccak256("AddressChanged(bytes32,uint256,bytes)");
    bytes32 constant T_ADDR = keccak256("AddrChanged(bytes32,address)");
    bytes32 constant T_PRIMARY = keccak256("PrimaryPageSet(address,uint256)");
    bytes32 constant T_META = keccak256("MetadataUpdate(uint256)");

    // B's pointers as the rules predict them, by account
    mapping(address => uint256) predB;
    uint256 public inserted;
    uint256 public skippedClears;
    uint256 public pointerDiffs;

    uint256 public okCalls;
    uint256 public failCalls;
    uint256 public deadSubsMade;
    uint256 public bundleOks;
    uint256 public bundleFails;
    uint256 public bundleEntries;
    uint256 public bundleValueRefused;
    uint256 public bundleNested;
    uint256 public deletedViewChecks;
    uint256 public recreations;
    uint256 public deadTops;
    uint256 public deletions;
    uint256 step;
    // pointer checks where B hid a name A shows, because the holder changed
    uint256 public holderHidden;

    // the indexers, per node: OP bytes, AddrChanged address, coin 60 bytes
    mapping(uint256 => bytes) idxOpA;
    mapping(uint256 => bytes) idxOpB;
    mapping(uint256 => address) idxAddrA;
    mapping(uint256 => address) idxAddrB;
    mapping(uint256 => bytes) idx60A;
    mapping(uint256 => bytes) idx60B;

    function setUp() public {
        vm.warp(1_800_000_000);
        card = new PageCard();
        NA = address(new PageNFTDeleted(card));
        NB = address(new PageNFT(card));
        RA = address(new SubpageRegistrarDeleted(IPageNFTDeleted(NA)));
        RB = address(new SubpageRegistrar(IPageNFT(NB)));
        holder = new Holder721();
        actors = [makeAddr("r0"), makeAddr("r1"), makeAddr("r2"), makeAddr("r3"), makeAddr("r4"), address(holder)];
        for (uint256 i; i < 6; ++i) vm.deal(actors[i], 1_000_000 ether);
        bytes32 root = PageNFT(NB).ROOT();
        for (uint256 t; t < 4; ++t) {
            uint256 top = uint256(keccak256(abi.encodePacked(root, keccak256(bytes(tops[t])))));
            tids.push(top);
            ids.push(top);
            for (uint256 s; s < 6; ++s) ids.push(_sid(top, subs[s]));
        }
    }

    // address mapping

    function _mapA(address a) internal view returns (address) {
        if (a == NA) return NB;
        if (a == RA) return RB;
        return a;
    }

    function _mapBytes(bytes memory b) internal view returns (bytes memory out) {
        out = bytes.concat(b);
        bytes20 na = bytes20(NA);
        bytes20 nb = bytes20(NB);
        bytes20 ra = bytes20(RA);
        bytes20 rb = bytes20(RB);
        if (out.length < 20) return out;
        for (uint256 i; i + 20 <= out.length; ++i) {
            bytes20 w;
            assembly ("memory-safe") {
                w := mload(add(add(out, 0x20), i))
            }
            bytes20 rep;
            if (w == na) rep = nb;
            else if (w == ra) rep = rb;
            else continue;
            for (uint256 k; k < 20; ++k) out[i + k] = rep[k];
            i += 19;
        }
    }

    // the deleted state in B

    function _sid(uint256 parent, string memory label) internal pure returns (uint256) {
        bytes memory b = bytes.concat(bytes(label));
        for (uint256 i; i < b.length; ++i) if (b[i] >= 0x41 && b[i] <= 0x5a) b[i] = bytes1(uint8(b[i]) + 32);
        return uint256(keccak256(abi.encodePacked(bytes32(parent), keccak256(b))));
    }

    function _owner(uint256 id) internal view returns (address) {
        (bool ok, bytes memory r) = NB.staticcall(abi.encodeWithSignature("ownerOf(uint256)", id));
        return ok ? abi.decode(r, (address)) : address(0);
    }

    // the owner as world A sees it, for calldata written for world A
    function _ownerA(uint256 id) internal view returns (address) {
        address o = _owner(id);
        if (o == RB) return RA;
        if (o == NB) return NA;
        return o;
    }

    // a page held by the dead address is deleted, a top level page too
    function _deleted(uint256 id) internal view returns (bool) {
        return id != 0 && _owner(id) == DEAD;
    }

    // logs

    function _isAddrLog(Vm.Log memory l) internal pure returns (bool) {
        if (l.topics.length == 0) return false;
        if (l.topics[0] == T_ADDR) return true;
        if (l.topics[0] != T_ADDRESS) return false;
        (uint256 coin,) = abi.decode(l.data, (uint256, bytes));
        return coin == COIN_OP || coin == 60;
    }

    function _replay(Vm.Log[] memory logs, bool isA) internal {
        address n = isA ? NA : NB;
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory l = logs[i];
            if (l.emitter != n || !_isAddrLog(l)) continue;
            uint256 node = uint256(l.topics[1]);
            if (l.topics[0] == T_ADDR) {
                address v = abi.decode(l.data, (address));
                if (isA) idxAddrA[node] = v;
                else idxAddrB[node] = v;
            } else {
                (uint256 coin, bytes memory v) = abi.decode(l.data, (uint256, bytes));
                if (coin == COIN_OP) {
                    if (isA) idxOpA[node] = v;
                    else idxOpB[node] = v;
                } else {
                    if (isA) idx60A[node] = v;
                    else idx60B[node] = v;
                }
            }
        }
    }

    function _logHash(Vm.Log memory l, bool mapA) internal view returns (bytes32) {
        bytes32[] memory t = new bytes32[](l.topics.length);
        for (uint256 k; k < t.length; ++k) t[k] = mapA ? bytes32(_mapBytes(abi.encode(l.topics[k]))) : l.topics[k];
        return keccak256(abi.encode(mapA ? _mapA(l.emitter) : l.emitter, t, mapA ? _mapBytes(l.data) : l.data));
    }

    function _cmpLogs(Vm.Log[] memory la, Vm.Log[] memory lb) internal view {
        assertEq(la.length, lb.length, "log count differs");
        for (uint256 i; i < la.length; ++i) assertEq(_logHash(la[i], true), _logHash(lb[i], false), "log differs");
    }

    // the predicted difference

    struct Ov {
        address[] k;
        uint256[] v;
        uint256 n;
    }

    function _get(Ov memory o, address a) internal view returns (uint256) {
        for (uint256 i = o.n; i > 0; --i) if (o.k[i - 1] == a) return o.v[i - 1];
        return predB[a];
    }

    function _set(Ov memory o, address a, uint256 v) internal pure {
        o.k[o.n] = a;
        o.v[o.n] = v;
        ++o.n;
    }

    function _primaryLog(address from) internal view returns (Vm.Log memory l) {
        l.topics = new bytes32[](3);
        l.topics[0] = T_PRIMARY;
        l.topics[1] = bytes32(uint256(uint160(from)));
        l.emitter = NA;
    }

    // A's logs of one call turned into the logs B must emit, in A's address space. With commit the
    // predicted pointers are kept, else they are thrown away (a failed call).
    function _expectB(Vm.Log[] memory la, bool setPrimaryCall, bool commit) internal returns (Vm.Log[] memory out) {
        Ov memory o = Ov(new address[](la.length + 1), new uint256[](la.length + 1), 0);
        out = new Vm.Log[](la.length * 2 + 1);
        uint256 n;
        bool pend;
        address pendFrom;
        uint256 pendId;
        for (uint256 i; i < la.length; ++i) {
            Vm.Log memory l = la[i];
            if (l.emitter == NA && l.topics.length > 0) {
                bytes32 t0 = l.topics[0];
                if (t0 == T_PRIMARY) {
                    address x = _mapA(address(uint160(uint256(l.topics[1]))));
                    uint256 v = uint256(l.topics[2]);
                    if (setPrimaryCall) {
                        _set(o, x, v);
                    } else {
                        // a clear at a mint or a registration: the burn of the same id comes next
                        require(v == 0 && i + 1 < la.length, "clear site shape");
                        Vm.Log memory nx = la[i + 1];
                        require(
                            nx.emitter == NA && nx.topics.length == 4 && nx.topics[0] == T_TRANSFER
                                && nx.topics[1] == l.topics[1] && nx.topics[2] == bytes32(0),
                            "a clear not followed by the burn"
                        );
                        if (_get(o, x) != uint256(nx.topics[3])) {
                            // B's pointer was already cleared by a transfer, so B clears nothing here
                            if (commit) ++skippedClears;
                            continue;
                        }
                        _set(o, x, 0);
                    }
                } else if (t0 == T_TRANSFER && l.topics.length == 4) {
                    address f = address(uint160(uint256(l.topics[1])));
                    address t = address(uint160(uint256(l.topics[2])));
                    uint256 id = uint256(l.topics[3]);
                    if (f != address(0) && t != address(0) && f != t && _get(o, _mapA(f)) == id) {
                        require(!pend, "two open transfers");
                        pend = true;
                        pendFrom = f;
                        pendId = id;
                    }
                } else if (t0 == T_META && pend && abi.decode(l.data, (uint256)) == pendId) {
                    out[n++] = _primaryLog(pendFrom);
                    _set(o, _mapA(pendFrom), 0);
                    pend = false;
                    if (commit) ++inserted;
                }
            }
            out[n++] = l;
        }
        require(!pend, "a transfer ended without its MetadataUpdate");
        assembly ("memory-safe") {
            mstore(out, n)
        }
        if (commit) for (uint256 i; i < o.n; ++i) predB[o.k[i]] = o.v[i];
    }

    function _isSetPrimary(address t, bytes memory d) internal view returns (bool) {
        return t == NA && d.length >= 4 && bytes4(d) == PageNFT.setPrimaryPage.selector;
    }

    // B shows a display name only while the name is held by the account that held it when the name
    // was chosen (slot 13 of B); where that holds, B must answer what A answers, otherwise nothing
    function _rrWant(address a) internal view returns (string memory want, bool hidden) {
        (bool okA, bytes memory ra) = NA.staticcall(abi.encodeWithSignature("reverseResolve(address)", a));
        require(okA, "A reverseResolve reverted");
        want = abi.decode(ra, (string));
        uint256 t = PageNFT(NB).primaryPage(a);
        address held = address(uint160(uint256(vm.load(NB, keccak256(abi.encode(a, uint256(13)))))));
        (bool okO, bytes memory ro) = NB.staticcall(abi.encodeWithSignature("ownerOf(uint256)", t));
        address o = okO ? abi.decode(ro, (address)) : address(0);
        if (o != held) {
            hidden = bytes(want).length != 0;
            want = "";
        }
    }

    function _checkPtr(address a) internal {
        uint256 pa = PageNFT(NA).primaryPage(a);
        uint256 pb = PageNFT(NB).primaryPage(a);
        assertEq(pb, predB[a], "B pointer differs from the prediction");
        assertTrue(pb == pa || pb == 0, "B pointer is neither A's nor zero");
        if (pb == pa) {
            (string memory want, bool hidden) = _rrWant(a);
            assertEq(PageNFT(NB).reverseResolve(a), want, "B reverseResolve under the holder check");
            if (hidden) ++holderHidden;
        } else {
            assertEq(PageNFT(NB).reverseResolve(a), "", "a cleared pointer still shows a name");
            ++pointerDiffs;
        }
    }

    // the paired call

    function _both(address who, uint256 value, address ta, bytes memory da, address tb, bytes memory db, uint256 target)
        internal
        returns (bool)
    {
        bool deletedBefore = _deleted(target);
        vm.recordLogs();
        vm.getRecordedLogs();
        vm.prank(who);
        (bool okA, bytes memory retA) = ta.call{value: value}(da);
        Vm.Log[] memory la = vm.getRecordedLogs();
        vm.prank(who);
        (bool okB, bytes memory retB) = tb.call{value: value}(db);
        Vm.Log[] memory lb = vm.getRecordedLogs();
        if (okA != okB) {
            emit log_named_uint("step", step);
            emit log_named_bytes("ret A", retA);
            emit log_named_bytes("ret B", retB);
        }
        assertEq(okA, okB, "success differs");
        assertEq(_mapBytes(retA), retB, "return data differs");
        // A's logs with the predicted change
        _cmpLogs(_expectB(la, _isSetPrimary(ta, da), okA), ProfileLogs.strip(lb));
        if (!deletedBefore && _deleted(target)) ++deletions;
        // the recording keeps the logs of a reverted call, an indexer never sees them
        if (okA) {
            _replay(la, true);
            _replay(lb, false);
        }
        if (okA) ++okCalls;
        else ++failCalls;
        return okA;
    }

    function _sameN(bytes memory data) internal view {
        (bool okA, bytes memory ra) = NA.staticcall(data);
        (bool okB, bytes memory rb) = NB.staticcall(data);
        assertEq(okA, okB, "view success differs");
        assertEq(_mapBytes(ra), rb, "view differs");
    }

    // B's profile answer is A's or empty, and one that is not empty only while B's writer holds the name
    function _sameProfileN(bytes memory data, uint256 id) internal view {
        (bool okA, bytes memory ra) = NA.staticcall(data);
        (bool okB, bytes memory rb) = NB.staticcall(data);
        assertEq(okA, okB, "view success differs");
        (bool same, bool hidden) = ProfileLogs.subset(_mapBytes(ra), rb);
        assertTrue(same || hidden, "B profile is A's or empty");
        if (keccak256(rb) != keccak256(abi.encode(""))) {
            assertEq(PageNFT(NB).profileWriter(id), PageNFT(NB).ownerOf(id), "B shows a profile only for its writer");
        }
    }

    function _sameR(bytes memory data) internal view {
        (bool okA, bytes memory ra) = RA.staticcall(data);
        (bool okB, bytes memory rb) = RB.staticcall(data);
        assertEq(okA, okB, "registrar view success differs");
        assertEq(_mapBytes(ra), rb, "registrar view differs");
    }

    function _json(uint256 id) internal view returns (string memory) {
        bytes memory uri = bytes(PageNFT(NB).tokenURI(id));
        bytes memory b64 = new bytes(uri.length - 29);
        for (uint256 i; i < b64.length; ++i) b64[i] = uri[29 + i];
        return string(Base64.decode(string(b64)));
    }

    function _checkDeleted(uint256 id, bool deep) internal {
        PageNFT b = PageNFT(NB);
        assertEq(b.resolve(id), address(0), "deleted resolve");
        assertEq(b.addr(bytes32(id)), address(0), "deleted addr(node)");
        assertEq(b.addr(id, COIN_OP), "", "deleted addr OP");
        assertEq(b.addr(id, 60), "", "deleted addr 60");
        assertEq(b.addr(id, COIN_BASE), "", "deleted addr other EVM");
        assertEq(b.addr(id, 0), "", "deleted addr non-EVM");
        assertEq(b.text(id, "k"), "", "deleted text");
        assertEq(b.contenthash(id), "", "deleted contenthash");
        assertEq(b.resolveAs(id, actors[0]), address(0), "deleted resolveAs");
        assertEq(idxOpB[id], "", "indexer OP of a deleted page");
        assertEq(idxAddrB[id], address(0), "indexer addr of a deleted page");
        assertEq(idx60B[id], "", "indexer 60 of a deleted page");
        if (deep) {
            string memory j = _json(id);
            assertTrue(vm.indexOf(j, '"trait_type":"Status","value":"Invalid"') != type(uint256).max, "deleted card");
        }
        ++deletedViewChecks;
    }

    function _check(bool deep) internal {
        assertEq(NA.balance, NB.balance, "PageNFT balance");
        assertEq(RA.balance, RB.balance, "registrar balance");
        for (uint256 k; k < ids.length; ++k) {
            uint256 id = ids[k];
            _sameN(abi.encodeWithSignature("ownerOf(uint256)", id));
            _sameN(abi.encodeWithSignature("records(uint256)", id));
            _sameN(abi.encodeWithSignature("recordVersion(uint256)", id));
            _sameN(abi.encodeWithSignature("payee(uint256)", id));
            _sameN(abi.encodeWithSignature("depositOf(uint256)", id));
            _sameN(abi.encodeWithSignature("referrerOf(uint256)", id));
            _sameN(abi.encodeWithSignature("subpageMinterOf(uint256)", id));
            _sameN(abi.encodeWithSignature("getPageName(uint256)", id));
            _sameN(abi.encodeWithSignature("getApproved(uint256)", id));
            _sameN(abi.encodeWithSignature("isExpired(uint256)", id));
            _sameN(abi.encodeWithSignature("inGracePeriod(uint256)", id));
            _sameN(abi.encodeWithSignature("getPremium(uint256)", id));
            bytes32 base = keccak256(abi.encode(id, uint256(12)));
            assertEq(
                _mapBytes(abi.encode(vm.load(NA, base), vm.load(NA, bytes32(uint256(base) + 1)))),
                abi.encode(vm.load(NB, base), vm.load(NB, bytes32(uint256(base) + 1))),
                "raw slot 12"
            );
            if (_deleted(id)) _checkDeleted(id, deep);
            _sameN(abi.encodeWithSignature("resolve(uint256)", id));
            _sameN(abi.encodeWithSignature("addr(uint256,uint256)", id, COIN_OP));
            _sameN(abi.encodeWithSignature("addr(uint256,uint256)", id, 60));
            _sameProfileN(abi.encodeWithSignature("text(uint256,string)", id, "k"), id);
            _sameN(abi.encodeWithSignature("resolveAs(uint256,address)", id, actors[1]));
            assertEq(_mapBytes(idxOpA[id]), idxOpB[id], "indexer OP");
            assertEq(_mapA(idxAddrA[id]), idxAddrB[id], "indexer addr");
            assertEq(_mapBytes(idx60A[id]), idx60B[id], "indexer 60");
            if (deep) {
                _sameN(abi.encodeWithSignature("addr(uint256,uint256)", id, COIN_BASE));
                _sameN(abi.encodeWithSignature("addr(uint256,uint256)", id, 0));
                _sameProfileN(abi.encodeWithSignature("contenthash(uint256)", id), id);
                (bool okP, bytes memory pa) = NA.staticcall(abi.encodeWithSignature("payee(uint256)", id));
                if (okP && abi.decode(pa, (address)) != RA && abi.decode(pa, (address)) != NA) {
                    _sameN(abi.encodeWithSignature("tokenURI(uint256)", id));
                }
            }
        }
        for (uint256 t; t < 4; ++t) {
            _sameR(abi.encodeWithSignature("config(uint256)", tids[t]));
            _sameN(abi.encodeWithSignature("isAvailable(string,uint256)", tops[t], 0));
            _sameN(abi.encodeWithSignature("quote(string)", tops[t]));
            for (uint256 s; s < 6; ++s) {
                _sameN(abi.encodeWithSignature("isAvailable(string,uint256)", subs[s], tids[t]));
            }
            _sameN(abi.encodeWithSignature("isAvailable(string,uint256)", "x", ids[t * 7 + 1]));
        }
        for (uint256 a; a < actors.length; ++a) {
            _sameN(abi.encodeWithSignature("owed(address)", actors[a]));
            _sameN(abi.encodeWithSignature("balanceOf(address)", actors[a]));
            _checkPtr(actors[a]);
            _sameR(abi.encodeWithSignature("proceedsOf(address)", actors[a]));
        }
        _sameN(abi.encodeWithSignature("owed(address)", DEAD));
        _sameN(abi.encodeWithSignature("balanceOf(address)", DEAD));
        _checkPtr(DEAD);
    }

    // helpers

    function _now() internal view returns (uint256) {
        return vm.getBlockTimestamp();
    }

    function _setter(uint256 id) internal view returns (address) {
        bytes32 base = keccak256(abi.encode(id, uint256(12)));
        return address(uint160(uint256(vm.load(NB, bytes32(uint256(base) + 1)))));
    }

    function _actor(uint256 r) internal view returns (address) {
        return actors[r % 6];
    }

    function _isActor(address a) internal view returns (bool) {
        for (uint256 i; i < 6; ++i) if (actors[i] == a) return true;
        return false;
    }

    // operations

    function _register(uint256 r) internal {
        uint256 t = r % 4;
        address payer = _actor(r >> 8);
        uint256 k = (r >> 16) % 8;
        address to = k == 7 ? DEAD : _actor(r >> 24);
        bytes32 secret = keccak256(abi.encode(step, r));
        bytes32 c = PageNFT(NB).makeCommitment(tops[t], to, 0, secret);
        _both(payer, 0, NA, abi.encodeWithSignature("commit(bytes32)", c), NB, abi.encodeWithSignature("commit(bytes32)", c), 0);
        vm.warp(_now() + 61);
        (,,, uint256 total) = PageNFT(NB).quote(tops[t]);
        bool ok = _both(
            payer, total,
            NA, abi.encodeWithSignature("reveal(string,address,uint256,bytes32)", tops[t], to, 0, secret),
            NB, abi.encodeWithSignature("reveal(string,address,uint256,bytes32)", tops[t], to, 0, secret),
            tids[t]
        );
        if (ok && to == DEAD) ++deadTops;
    }

    function _transferTop(uint256 r) internal {
        uint256 p = tids[r % 4];
        address from = _owner(p);
        if (from == address(0) || from == RB || from == DEAD) return;
        uint256 k = (r >> 8) % 10;
        address toA;
        if (k < 5) toA = _actor(r >> 16);
        else if (k < 7) toA = _setter(p) == address(0) ? _actor(r >> 16) : _setter(p);
        else if (k == 7) toA = RA;
        else toA = DEAD;
        address by = (r >> 24) % 5 == 0 ? _actor(r >> 32) : from;
        bool safe = (r >> 40) % 3 == 0;
        string memory sig = safe ? "safeTransferFrom(address,address,uint256)" : "transferFrom(address,address,uint256)";
        bool ok = _both(by, 0, NA, abi.encodeWithSignature(sig, from, toA, p), NB, abi.encodeWithSignature(sig, from, _mapA(toA), p), p);
        if (ok && toA == DEAD) ++deadTops;
    }

    // a subpage holder deletes or gives its subpage away; now and then someone tries to move a deleted one
    function _transferSub(uint256 r) internal {
        uint256 p = tids[r % 4];
        uint256 sid = _sid(p, subs[(r >> 8) % 6]);
        address from = _owner(sid);
        if (from == address(0) || from == RB) return;
        uint256 k = (r >> 16) % 10;
        address to = k < 6 ? DEAD : _actor(r >> 24);
        if (from == DEAD) to = _actor(r >> 24);
        address by = (r >> 32) % 7 == 0 || from == DEAD ? _actor(r >> 40) : from;
        bool safe = (r >> 48) % 3 == 0;
        string memory sig = safe ? "safeTransferFrom(address,address,uint256)" : "transferFrom(address,address,uint256)";
        bool ok = _both(by, 0, NA, abi.encodeWithSignature(sig, from, to, sid), NB, abi.encodeWithSignature(sig, from, to, sid), sid);
        if (ok && to == DEAD) ++deadSubsMade;
    }

    function _setMinter(uint256 r) internal {
        uint256 p = (r >> 48) % 13 == 0 ? ids[(r >> 52) % ids.length] : tids[r % 4];
        address o = _owner(p);
        uint256 k = (r >> 8) % 10;
        address caller;
        if (k < 6 && _isActor(o)) caller = o;
        else if (k < 8 && _setter(p) != address(0)) caller = _setter(p);
        else caller = _actor(r >> 16);
        uint256 j = (r >> 24) % 8;
        address mA = j < 1 ? address(0) : j < 3 ? RA : j == 3 ? DEAD : _actor(r >> 32);
        _both(
            caller, 0,
            NA, abi.encodeWithSignature("setSubpageMinter(uint256,address)", p, mA),
            NB, abi.encodeWithSignature("setSubpageMinter(uint256,address)", p, _mapA(mA)),
            p
        );
    }

    function _mint(uint256 r) internal {
        uint256 p = tids[r % 4];
        string memory label = subs[(r >> 8) % 6];
        address o = _owner(p);
        address m = PageNFT(NB).subpageMinterOf(p);
        uint256 k = (r >> 16) % 10;
        address caller;
        if (k < 4 && _isActor(o)) caller = o;
        else if (k < 8 && _isActor(m)) caller = m;
        else caller = _actor(r >> 24);
        uint256 tk = (r >> 32) % 12;
        address toA = tk < 3 ? DEAD : tk == 3 ? RA : _actor(r >> 40);
        bool self = (r >> 56) % 4 == 0;
        _mintAs(p, label, caller, toA, self);
    }

    function _mintAs(uint256 p, string memory label, address caller, address toA, bool self) internal {
        bytes memory dA = self
            ? abi.encodeWithSignature("registerSubpage(string,uint256)", label, p)
            : abi.encodeWithSignature("registerSubpageFor(string,uint256,address)", label, p, toA);
        bytes memory dB = self
            ? dA
            : abi.encodeWithSignature("registerSubpageFor(string,uint256,address)", label, p, _mapA(toA));
        uint256 sid = _sid(p, label);
        bool wasDeleted = _deleted(sid);
        bool ok = _both(caller, 0, NA, dA, NB, dB, sid);
        if (ok && wasDeleted && !_deleted(sid)) ++recreations;
    }

    function _configure(uint256 r) internal {
        uint256 p = tids[r % 4];
        address o = _owner(p);
        address caller = (r >> 8) % 4 == 0 || !_isActor(o) ? _actor(r >> 16) : o;
        address pay = (r >> 24) % 3 == 0 ? address(0) : _actor(r >> 32);
        uint256 price = (r >> 40) % 3 == 0 ? 0 : 0.01 ether;
        bool enabled = (r >> 48) % 5 != 0;
        bool cr = (r >> 56) % 4 == 0;
        _both(
            caller, 0,
            RA, abi.encodeWithSignature("configure(uint256,address,address,uint256,bool,address,uint256,bool)", p, pay, address(0), price, enabled, address(0), 0, cr),
            RB, abi.encodeWithSignature("configure(uint256,address,address,uint256,bool,address,uint256,bool)", p, pay, address(0), price, enabled, address(0), 0, cr),
            0
        );
    }

    function _setupSale(uint256 r) internal {
        uint256 p = tids[r % 4];
        address o = _owner(p);
        if (!_isActor(o)) return;
        _both(
            o, 0,
            NA, abi.encodeWithSignature("setSubpageMinter(uint256,address)", p, RA),
            NB, abi.encodeWithSignature("setSubpageMinter(uint256,address)", p, RB),
            p
        );
        _configure((r & ~uint256(0xff << 8)) | (uint256(1) << 8));
    }

    function _sell(uint256 r) internal {
        uint256 p = tids[r % 4];
        string memory label = subs[(r >> 8) % 6];
        address buyer = _actor(r >> 16);
        address toA = (r >> 24) % 11 == 0 ? RA : (r >> 24) % 11 == 1 ? DEAD : _actor(r >> 32);
        uint256 value = (r >> 40) % 4 == 0 ? 0.02 ether : 0.01 ether;
        bool reveal = (r >> 48) % 3 == 0;
        bytes memory dA;
        bytes memory dB;
        if (reveal) {
            bytes32 secret = keccak256(abi.encode(step, r));
            (bool okCA, bytes memory cA) = RA.staticcall(abi.encodeWithSignature("makeSubpageCommitment(uint256,string,address,bytes32)", p, label, toA, secret));
            (bool okCB, bytes memory cB) = RB.staticcall(abi.encodeWithSignature("makeSubpageCommitment(uint256,string,address,bytes32)", p, label, _mapA(toA), secret));
            assertEq(okCA, okCB, "commitment view");
            if (!okCA) return;
            _both(buyer, 0, RA, abi.encodeWithSignature("commitSubpage(bytes32)", abi.decode(cA, (bytes32))), RB, abi.encodeWithSignature("commitSubpage(bytes32)", abi.decode(cB, (bytes32))), 0);
            vm.warp(_now() + 61);
            dA = abi.encodeWithSignature("revealSubpageFor(uint256,string,address,bytes32,uint256,address)", p, label, toA, secret, 1 ether, address(0));
            dB = abi.encodeWithSignature("revealSubpageFor(uint256,string,address,bytes32,uint256,address)", p, label, _mapA(toA), secret, 1 ether, address(0));
        } else {
            dA = abi.encodeWithSignature("registerSubpageFor(uint256,string,address,uint256,address)", p, label, toA, 1 ether, address(0));
            dB = abi.encodeWithSignature("registerSubpageFor(uint256,string,address,uint256,address)", p, label, _mapA(toA), 1 ether, address(0));
        }
        uint256 sid = _sid(p, label);
        bool wasDeleted = _deleted(sid);
        bool ok = _both(buyer, value, RA, dA, RB, dB, sid);
        if (ok && wasDeleted && !_deleted(sid)) ++recreations;
    }

    // record writes by the holder or a stranger, deleted pages included
    function _records(uint256 r) internal {
        uint256 sid = ids[r % ids.length];
        // half the time a deleted page when there is one
        if ((r >> 60) % 2 == 0) {
            for (uint256 i; i < ids.length; ++i) {
                uint256 c = ids[(r + i) % ids.length];
                if (_deleted(c)) {
                    sid = c;
                    break;
                }
            }
        }
        address o = _owner(sid);
        address by = (r >> 8) % 5 == 0 || o == DEAD || o == address(0) || o == RB ? _actor(r >> 16) : o;
        uint256 k = (r >> 24) % 9;
        bytes memory d;
        if (k == 0) d = abi.encodeWithSignature("setText(uint256,string,string)", sid, "k", "v");
        else if (k == 1) d = abi.encodeWithSignature("setAddr(uint256,address)", sid, _actor(r >> 32));
        else if (k == 2) d = abi.encodeWithSignature("setPrimaryPage(uint256)", sid);
        else if (k == 3) d = abi.encodeWithSignature("clearRecords(uint256)", sid);
        else if (k == 4) d = abi.encodeWithSignature("setContenthash(uint256,bytes)", sid, hex"e30101");
        else if (k == 5) d = abi.encodeWithSignature("setAddrForCoin(uint256,uint256,bytes)", sid, 60, abi.encodePacked(_actor(r >> 32)));
        else if (k == 6) d = abi.encodeWithSignature("setAddrForCoin(uint256,uint256,bytes)", sid, COIN_BASE, abi.encodePacked(_actor(r >> 32)));
        else if (k == 7) d = abi.encodeWithSignature("setAddrForCoin(uint256,uint256,bytes)", sid, 0, hex"0014beef");
        else d = abi.encodeWithSignature("approve(address,uint256)", _actor(r >> 32), sid);
        _both(by, 0, NA, d, NB, d, sid);
    }

    function _warp(uint256 r) internal {
        uint256 k = r % 10;
        if (k < 7) vm.warp(_now() + 1 + (r >> 8) % 3 days);
        else if (k < 8) vm.warp(_now() + 200 days);
        else {
            uint256 p = tids[(r >> 8) % 4];
            uint256 e = PageNFT(NB).expiresAt(p);
            if (e != 0 && e + 90 days + 21 days + 1 > _now()) vm.warp(e + 90 days + 21 days + 1);
        }
    }

    function _renew(uint256 r) internal {
        uint256 p = tids[r % 4];
        _both(_actor(r >> 8), 0.05 ether, NA, abi.encodeWithSignature("renew(uint256)", p), NB, abi.encodeWithSignature("renew(uint256)", p), p);
    }

    function _claim(uint256 r) internal {
        address a = _actor(r);
        _both(a, 0, RA, abi.encodeWithSignature("claimProceeds(address)", address(0)), RB, abi.encodeWithSignature("claimProceeds(address)", address(0)), 0);
        _both(a, 0, NA, abi.encodeWithSignature("withdraw(address)", DEAD), NB, abi.encodeWithSignature("withdraw(address)", DEAD), 0);
    }

    // bundles

    // one random PageNFT call as who would send it, written for world A
    function _entry(address who, uint256 r, bool tame) internal view returns (bytes memory) {
        uint256 k = r % 18;
        // tame bundles use the writers a holder normally bundles, so most of them succeed
        if (tame) k = [uint256(0), 1, 2, 3, 5, 7, 11, 12, 17][r % 9];
        uint256 p = tids[(r >> 8) % 4];
        // mostly a parent the sender holds
        if ((r >> 56) % 4 != 0) {
            for (uint256 j; j < 4; ++j) {
                if (_owner(tids[(r + j) % 4]) == who) {
                    p = tids[(r + j) % 4];
                    break;
                }
            }
        }
        string memory label = subs[(r >> 12) % 6];
        uint256 sid = _sid(p, label);
        uint256 id = (r >> 16) % 2 == 0 ? p : sid;
        // mostly a name the sender holds
        if ((r >> 20) % 4 != 0) {
            for (uint256 j; j < ids.length; ++j) {
                uint256 c = ids[(r + j) % ids.length];
                if (_owner(c) == who) {
                    id = c;
                    break;
                }
            }
        }
        address x = _actor(r >> 24);
        uint256 t = (r >> 32) % 10;
        address toA = t < 7 ? x : t < 9 ? DEAD : (r >> 36) % 2 == 0 ? RA : address(holder);
        if (k == 0) return abi.encodeWithSignature("setText(uint256,string,string)", id, "k", vm.toString(r % 97));
        if (k == 1) return abi.encodeWithSignature("setAddr(uint256,address)", id, (r >> 40) % 9 == 0 ? NA : x);
        if (k == 2) return abi.encodeWithSignature("setAddrForCoin(uint256,uint256,bytes)", id, 60, abi.encodePacked(x));
        if (k == 3) return abi.encodeWithSignature("setContenthash(uint256,bytes)", id, hex"e30101");
        if (k == 4) return abi.encodeWithSignature("clearRecords(uint256)", id);
        if (k == 5) return abi.encodeWithSignature("setPrimaryPage(uint256)", (r >> 40) % 4 == 0 ? 0 : id);
        if (k == 6) return abi.encodeWithSignature("approve(address,uint256)", x, id);
        if (k == 7) return abi.encodeWithSignature("setApprovalForAll(address,bool)", x, (r >> 40) % 2 == 0);
        if (k == 8) return abi.encodeWithSignature("transferFrom(address,address,uint256)", _ownerA(id), toA, id);
        if (k == 9) return abi.encodeWithSignature("safeTransferFrom(address,address,uint256)", _ownerA(id), toA, id);
        if (k == 10) {
            uint256 j = (r >> 40) % 4;
            address m = j == 0 ? address(0) : j == 1 ? RA : x;
            return abi.encodeWithSignature("setSubpageMinter(uint256,address)", p, m);
        }
        if (k == 11 || k == 12) return abi.encodeWithSignature("registerSubpageFor(string,uint256,address)", label, p, toA);
        if (k == 13) return abi.encodeWithSignature("registerSubpage(string,uint256)", label, p);
        if (k == 14) return abi.encodeWithSignature("withdraw(address)", (r >> 40) % 3 == 0 ? DEAD : x);
        if (k == 15) {
            return (r >> 40) % 2 == 0
                ? abi.encodeWithSignature("release(uint256)", p)
                : abi.encodeWithSignature("renew(uint256)", p);
        }
        if (k == 16) {
            uint256 j = (r >> 40) % 3;
            if (j == 0) return abi.encodeWithSignature("commit(bytes32)", keccak256(abi.encode(step, r)));
            if (j == 1) return abi.encodeWithSignature("reveal(string,address,uint256,bytes32)", tops[(r >> 44) % 4], DEAD, 0, bytes32(r));
            return abi.encodeWithSignature("reveal(string,address,uint256,bytes32)", tops[(r >> 44) % 4], x, 0, bytes32(r));
        }
        // tokenURI is left out: it prints the payee as text, which the address mapping cannot follow
        return (r >> 40) % 2 == 0
            ? abi.encodeWithSignature("getPageName(uint256)", id)
            : abi.encodeWithSignature("payee(uint256)", tids[(r >> 44) % 4]);
    }

    struct Bundle {
        uint256 n;
        bool nested;
        uint256 gs;
        uint256 ge;
        bytes[] dA;
        bytes[] dB;
    }

    function _packB(Bundle memory b) internal view returns (bytes[] memory out) {
        if (!b.nested) {
            out = new bytes[](b.n);
            for (uint256 i; i < b.n; ++i) out[i] = _mapBytes(b.dA[i]);
            return out;
        }
        out = new bytes[](b.n - (b.ge - b.gs) + 1);
        bytes[] memory inner = new bytes[](b.ge - b.gs);
        uint256 j;
        for (uint256 i; i < b.n; ++i) {
            if (i < b.gs || i >= b.ge) {
                out[j++] = _mapBytes(b.dA[i]);
            } else {
                inner[i - b.gs] = _mapBytes(b.dA[i]);
                if (i == b.ge - 1) out[j++] = abi.encodeWithSignature("multicall(bytes[])", inner);
            }
        }
    }

    function _bundleAs(address who, uint256 r) internal {
        Bundle memory b;
        b.n = r % 11 == 0 ? 0 : 1 + (r >> 4) % 6;
        b.dA = new bytes[](b.n);
        bool tame = (r >> 72) % 2 == 0;
        for (uint256 i; i < b.n; ++i) b.dA[i] = _entry(who, uint256(keccak256(abi.encode(r, i))), tame);
        b.nested = b.n >= 2 && (r >> 40) % 4 == 0;
        if (b.nested) {
            b.gs = (r >> 44) % b.n;
            b.ge = b.gs + 1 + (r >> 52) % (b.n - b.gs);
        }
        b.dB = _packB(b);
        bytes memory callB = abi.encodeWithSignature("multicall(bytes[])", b.dB);

        vm.recordLogs();
        vm.getRecordedLogs();
        if ((r >> 60) % 31 == 0) {
            vm.deal(who, who.balance + 1 ether);
            vm.prank(who);
            (bool okV, bytes memory retV) = NB.call{value: 1 + (r >> 64) % 1 ether}(callB);
            vm.getRecordedLogs();
            assertFalse(okV, "a bundle with value was accepted");
            assertEq(retV.length, 0, "a bundle with value failed with data");
            ++bundleValueRefused;
            return;
        }

        uint256 snap = vm.snapshotState();
        bytes[] memory rets = new bytes[](b.n);
        Vm.Log[] memory la;
        bool okA = true;
        bytes memory failA;
        for (uint256 i; i < b.n; ++i) {
            vm.prank(who);
            (bool ok, bytes memory ret) = NA.call(b.dA[i]);
            Vm.Log[] memory li = vm.getRecordedLogs();
            if (!ok) {
                okA = false;
                failA = ret;
                break;
            }
            rets[i] = ret;
            la = _concat(la, _expectB(li, _isSetPrimary(NA, b.dA[i]), true));
        }
        if (!okA) vm.revertToStateAndDelete(snap);
        else vm.deleteStateSnapshot(snap);

        vm.prank(who);
        (bool okB, bytes memory retB) = NB.call(callB);
        Vm.Log[] memory lb = vm.getRecordedLogs();
        if (!okA) {
            assertFalse(okB, "B's bundle worked where a call failed in A");
            assertEq(_mapBytes(failA), retB, "B's bundle failed with other data than A's first failing call");
            ++bundleFails;
            return;
        }
        assertTrue(okB, "B's bundle failed where every call worked in A");
        _cmpLogs(la, ProfileLogs.strip(lb));
        bytes[] memory res = abi.decode(retB, (bytes[]));
        uint256 j;
        for (uint256 i; i < b.n; ++i) {
            if (b.nested && i >= b.gs && i < b.ge) {
                if (i != b.ge - 1) continue;
                bytes[] memory inner = new bytes[](b.ge - b.gs);
                for (uint256 k = b.gs; k < b.ge; ++k) inner[k - b.gs] = _mapBytes(rets[k]);
                assertEq(res[j++], abi.encode(inner), "nested bundle result");
            } else {
                assertEq(res[j++], _mapBytes(rets[i]), "bundle result");
            }
        }
        assertEq(j, res.length, "bundle result count");
        _replay(la, true);
        _replay(lb, false);
        ++bundleOks;
        bundleEntries += b.n;
        if (b.nested) ++bundleNested;
    }

    function _concat(Vm.Log[] memory a, Vm.Log[] memory b) internal pure returns (Vm.Log[] memory c) {
        c = new Vm.Log[](a.length + b.length);
        for (uint256 i; i < a.length; ++i) c[i] = a[i];
        for (uint256 i; i < b.length; ++i) c[a.length + i] = b[i];
    }

    // a bundle from a holder of one of the names, else from any actor
    function _bundle(uint256 r) internal {
        address o = _owner(tids[r % 4]);
        _bundleAs(_isActor(o) && (r >> 8) % 4 != 0 ? o : _actor(r >> 12), r >> 16);
    }

    function _walk(uint256 seed, uint256 n) internal {
        for (uint256 i; i < n; ++i) {
            ++step;
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            uint256 w = r % 100;
            r >>= 8;
            if (w < 10) _register(r);
            else if (w < 16) _transferTop(r);
            else if (w < 30) _transferSub(r);
            else if (w < 38) _setMinter(r);
            else if (w < 60) _mint(r);
            else if (w < 64) _configure(r);
            else if (w < 74) _sell(r);
            else if (w < 80) _setupSale(r);
            else if (w < 90) _records(r);
            else if (w < 94) _warp(r);
            else if (w < 97) _renew(r);
            else _claim(r);
            // a bundle after one step in three
            if ((r >> 200) % 3 == 0) _bundle(r >> 100);
            _check(i % 20 == 19);
        }
        _check(true);
    }

    function _report() internal {
        emit log_named_uint("ok calls", okCalls);
        emit log_named_uint("display names hidden by the holder check", holderHidden);
        emit log_named_uint("failed calls", failCalls);
        emit log_named_uint("subpages sent to DEAD", deadSubsMade);
        emit log_named_uint("pages deleted by any call", deletions);
        emit log_named_uint("top-level names to DEAD", deadTops);
        emit log_named_uint("bundles that succeeded", bundleOks);
        emit log_named_uint("bundles that failed", bundleFails);
        emit log_named_uint("entries in successful bundles", bundleEntries);
        emit log_named_uint("nested bundles that succeeded", bundleNested);
        emit log_named_uint("bundles with value refused", bundleValueRefused);
        emit log_named_uint("deleted page view checks", deletedViewChecks);
        emit log_named_uint("deleted subpages created again", recreations);
    }

    // keeps each parent registered and held by an actor, so most steps reach a subpage
    function _focus(uint256 seed, uint256 n) internal {
        for (uint256 i; i < n; ++i) {
            ++step;
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            uint256 t = r % 4;
            uint256 p = tids[t];
            address o = _owner(p);
            bool gone = PageNFT(NB).epochOf(p) == 0 || _now() > PageNFT(NB).expiresAt(p) + 90 days;
            if (gone) {
                address to = (r >> 8) % 40 == 0 ? DEAD : _actor(r >> 16);
                bytes32 secret = keccak256(abi.encode(step, r));
                bytes32 c = PageNFT(NB).makeCommitment(tops[t], to, 0, secret);
                _both(_actor(r >> 24), 0, NA, abi.encodeWithSignature("commit(bytes32)", c), NB, abi.encodeWithSignature("commit(bytes32)", c), 0);
                vm.warp(_now() + 61);
                (,,, uint256 total) = PageNFT(NB).quote(tops[t]);
                bool ok = _both(
                    _actor(r >> 24), total,
                    NA, abi.encodeWithSignature("reveal(string,address,uint256,bytes32)", tops[t], to, 0, secret),
                    NB, abi.encodeWithSignature("reveal(string,address,uint256,bytes32)", tops[t], to, 0, secret),
                    p
                );
                if (ok && to == DEAD) ++deadTops;
                _check(false);
                continue;
            }
            if (_now() > PageNFT(NB).expiresAt(p)) {
                if ((r >> 8) % 3 == 0) _records(r >> 12);
                _renew((r & ~uint256(3)) | t);
                _check(false);
                continue;
            }
            if (!_isActor(o)) {
                if ((r >> 8) % 2 == 0) vm.warp(PageNFT(NB).expiresAt(p) + 90 days + 1);
                else _mintAs(p, subs[(r >> 16) % 6], _actor(r >> 32), _actor(r >> 40), false);
                _check(false);
                continue;
            }
            uint256 w = (r >> 8) % 25;
            address m = PageNFT(NB).subpageMinterOf(p);
            if (w >= 20) {
                _bundleAs((r >> 60) % 5 == 0 ? _actor(r >> 64) : o, r >> 16);
                _check(i % 25 == 24);
                continue;
            }
            string memory label = subs[(r >> 16) % 6];
            if (w < 2 || (m == address(0) && w < 4)) {
                address pick = (r >> 40) % 3 == 0 ? RA : _actor(r >> 40);
                _both(o, 0, NA, abi.encodeWithSignature("setSubpageMinter(uint256,address)", p, pick), NB, abi.encodeWithSignature("setSubpageMinter(uint256,address)", p, _mapA(pick)), p);
            } else if (w < 3) {
                _setupSale((r & ~uint256(3)) | t);
            } else if (w < 6) {
                if (_isActor(m) && m != o) _mintAs(p, label, m, (r >> 48) % 5 == 0 ? DEAD : _actor(r >> 52), (r >> 60) % 4 == 0);
                else _setupSale((r & ~uint256(3)) | t);
            } else if (w < 8) {
                _mintAs(p, label, o, (r >> 48) % 2 == 0 ? DEAD : _actor(r >> 52), false);
            } else if (w < 11) {
                // a subpage holder writes a profile, then deletes its subpage
                uint256 sid = _sid(p, subs[(r >> 44) % 6]);
                address h = _owner(sid);
                if (h != address(0) && h != DEAD && h != RB) {
                    _both(h, 0, NA, abi.encodeWithSignature("setText(uint256,string,string)", sid, "k", "v"), NB, abi.encodeWithSignature("setText(uint256,string,string)", sid, "k", "v"), sid);
                    _both(h, 0, NA, abi.encodeWithSignature("setAddr(uint256,address)", sid, _actor(r >> 50)), NB, abi.encodeWithSignature("setAddr(uint256,address)", sid, _actor(r >> 50)), sid);
                    bool ok = _both(h, 0, NA, abi.encodeWithSignature("transferFrom(address,address,uint256)", h, DEAD, sid), NB, abi.encodeWithSignature("transferFrom(address,address,uint256)", h, DEAD, sid), sid);
                    if (ok) ++deadSubsMade;
                } else {
                    _mintAs(p, subs[(r >> 44) % 6], o, _actor(r >> 52), false);
                }
            } else if (w < 14) {
                uint256 rr = (r & ~uint256(3)) | t;
                rr = (rr & ~(uint256(0xff) << 8)) | (uint256((r >> 16) % 6) << 8);
                _sell(rr);
            } else if (w < 16) {
                _records(r >> 20);
            } else if (w < 17) {
                _transferSub((r & ~uint256(3)) | t);
            } else if (w < 18) {
                vm.warp(_now() + 1 + (r >> 48) % 2 days);
            } else if ((r >> 48) % 4 == 0) {
                _transferTop((r & ~uint256(3)) | t);
            } else {
                _mintAs(p, label, _actor(r >> 52), _actor(r >> 56), false);
            }
            _check(i % 25 == 24);
        }
        _check(true);
    }

    function test_walk1() public {
        _walk(0x1001, 500);
        _report();
        assertGt(deletions, 5);
    }

    function test_walk2() public {
        _walk(0x2002, 500);
        _report();
        assertGt(deadTops, 0);
    }

    function test_focus1() public {
        _focus(0x5005, 800);
        _report();
        assertGt(deletions, 20);
        assertGt(recreations, 5);
        assertGt(bundleOks, 20);
        assertGt(bundleFails, 20);
    }

    function test_focus2() public {
        _focus(0x6006, 800);
        _report();
        assertGt(recreations, 5);
    }

    function test_focus3() public {
        _focus(0x7007, 800);
        _report();
        assertGt(deletedViewChecks, 100);
    }

    /// forge-config: default.fuzz.runs = 100

    /// forge-config: deep.fuzz.runs = 100
    function testFuzz_walk(uint256 seed) public {
        _walk(seed, 60);
    }

    /// forge-config: default.fuzz.runs = 200

    /// forge-config: deep.fuzz.runs = 200
    function testFuzz_focus(uint256 seed) public {
        _focus(seed, 60);
    }
}

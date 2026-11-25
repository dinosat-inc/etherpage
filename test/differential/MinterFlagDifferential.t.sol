// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Test, Vm} from "forge-std/Test.sol";
import {PageCard} from "../../src/PageCard.sol";
import {PageNFT} from "../../src/PageNFT.sol";
import {SubpageRegistrar, IPageNFT} from "../../src/SubpageRegistrar.sol";
import {PageNFTFlag} from "./harness/PageNFTFlag.sol";
import {SubpageRegistrarFlag, IPageNFTFlag} from "./harness/SubpageRegistrarFlag.sol";
import {Holder721} from "../utils/MinterMocks.sol";

// World A is PageNFTFlag, always called with the flag false. World B is src, where the minter only
// creates. Both get the same random calls, including picks, clears while away, mints by holders,
// minters and strangers over fresh, live and stale labels, transfers, sales, lapses and claims.
// Every call must succeed or fail alike with the same return data and the same logs, and every view
// must agree. The only differences that arise come from the flag: SubpageMinterSet carries it in A, so
// its first topic differs and its data is (epoch, false) in A and (epoch) in B, and subpageMinterOf
// returns (minter, false) in A and minter in B. reverseResolve is compared under B's holder check,
// which hides nothing here because no step sets a display name.
contract MinterFlagDifferentialTest is Test {
    PageCard card;
    address NA;
    address NB;
    address RA;
    address RB;
    Holder721 holder;
    address[6] actors;
    string[4] tops = ["club", "gold", "ab", "q"];
    string[10] subs = ["a", "b", "sub", "LIVE", "c", "d", "e", "f", "g", "h"];
    uint256[] tids;
    uint256[] ids;
    bytes32 constant T_SET = keccak256("SubpageMinterSet(uint256,address,address,uint64,bool)");
    bytes32 constant T_SET_B = keccak256("SubpageMinterSet(uint256,address,address,uint64)");
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    uint256 public okCalls;
    uint256 public failCalls;
    uint256 public minterMints;
    uint256 public minterStale;
    uint256 public minterRefusedLive;
    uint256 public sales;
    uint256 public awayClears;
    uint256 public revivals;
    uint256 public relapses;
    uint256 step;
    bool biased;

    function setUp() public {
        vm.warp(1_800_000_000);
        card = new PageCard();
        NA = address(new PageNFTFlag(card));
        NB = address(new PageNFT(card));
        RA = address(new SubpageRegistrarFlag(IPageNFTFlag(NA)));
        RB = address(new SubpageRegistrar(IPageNFT(NB)));
        holder = new Holder721();
        actors = [makeAddr("e0"), makeAddr("e1"), makeAddr("e2"), makeAddr("e3"), makeAddr("e4"), address(holder)];
        for (uint256 i; i < 6; ++i) vm.deal(actors[i], 1_000_000 ether);
        bytes32 root = PageNFT(NB).ROOT();
        for (uint256 t; t < 4; ++t) {
            uint256 top = uint256(keccak256(abi.encodePacked(root, keccak256(bytes(tops[t])))));
            tids.push(top);
            ids.push(top);
            for (uint256 s; s < 10; ++s) {
                string memory l = s == 3 ? "live" : subs[s];
                ids.push(uint256(keccak256(abi.encodePacked(bytes32(top), keccak256(bytes(l))))));
            }
        }
    }

    // address mapping

    function _mapA(address a) internal view returns (address) {
        if (a == NA) return NB;
        if (a == RA) return RB;
        return a;
    }

    // replaces every 20-byte occurrence of A's own addresses with B's, packed or padded
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

    // the paired call

    function _both(address who, uint256 value, address ta, bytes memory da, address tb, bytes memory db)
        internal
        returns (bool)
    {
        vm.recordLogs();
        vm.prank(who);
        (bool okA, bytes memory retA) = ta.call{value: value}(da);
        Vm.Log[] memory la = vm.getRecordedLogs();
        vm.prank(who);
        (bool okB, bytes memory retB) = tb.call{value: value}(db);
        Vm.Log[] memory lb = vm.getRecordedLogs();
        if (okA != okB) {
            emit log_named_uint("step", step);
            emit log_named_address("caller", who);
            emit log_named_uint("value", value);
            emit log_named_address("target B", tb);
            emit log_named_bytes("data B", db);
            emit log_named_bytes("ret A", retA);
            emit log_named_bytes("ret B", retB);
        }
        assertEq(okA, okB, "success differs");
        assertEq(_mapBytes(retA), retB, "return data differs");
        assertEq(la.length, lb.length, "log count differs");
        for (uint256 i; i < la.length; ++i) {
            assertEq(_mapA(la[i].emitter), lb[i].emitter, "emitter");
            assertEq(la[i].topics.length, lb[i].topics.length, "topic count");
            if (la[i].topics[0] == T_SET) {
                assertEq(lb[i].topics[0], T_SET_B, "event kind");
                for (uint256 k = 1; k < la[i].topics.length; ++k) {
                    assertEq(bytes32(_mapBytes(abi.encode(la[i].topics[k]))), lb[i].topics[k], "set topic");
                }
                (uint64 e, bool f) = abi.decode(la[i].data, (uint64, bool));
                assertFalse(f, "world A is always called with the flag false");
                assertEq(abi.encode(e), lb[i].data, "set epoch");
                continue;
            }
            for (uint256 k; k < la[i].topics.length; ++k) {
                assertEq(bytes32(_mapBytes(abi.encode(la[i].topics[k]))), lb[i].topics[k], "topic");
            }
            assertEq(_mapBytes(la[i].data), lb[i].data, "log data");
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

    function _sameR(bytes memory data) internal view {
        (bool okA, bytes memory ra) = RA.staticcall(data);
        (bool okB, bytes memory rb) = RB.staticcall(data);
        assertEq(okA, okB, "registrar view success differs");
        assertEq(_mapBytes(ra), rb, "registrar view differs");
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

    function _check(bool deep) internal view {
        assertEq(NA.balance, NB.balance, "PageNFT balance");
        assertEq(RA.balance, RB.balance, "registrar balance");
        for (uint256 k; k < ids.length; ++k) {
            uint256 id = ids[k];
            _sameN(abi.encodeWithSignature("ownerOf(uint256)", id));
            _sameN(abi.encodeWithSignature("records(uint256)", id));
            _sameN(abi.encodeWithSignature("recordVersion(uint256)", id));
            _sameN(abi.encodeWithSignature("payee(uint256)", id));
            _sameN(abi.encodeWithSignature("resolve(uint256)", id));
            _sameN(abi.encodeWithSignature("depositOf(uint256)", id));
            (address ma, bool fa) = PageNFTFlag(NA).subpageMinterOf(id);
            assertFalse(fa, "A never reports a flag");
            assertEq(_mapA(ma), PageNFT(NB).subpageMinterOf(id), "counted minter");
            // the raw slot-12 words agree once A's addresses are mapped
            bytes32 base = keccak256(abi.encode(id, uint256(12)));
            assertEq(
                _mapBytes(abi.encode(vm.load(NA, base), vm.load(NA, bytes32(uint256(base) + 1)))),
                abi.encode(vm.load(NB, base), vm.load(NB, bytes32(uint256(base) + 1))),
                "raw slot 12"
            );
            if (deep) {
                _sameN(abi.encodeWithSignature("addr(uint256,uint256)", id, 60));
                _sameN(abi.encodeWithSignature("getPageName(uint256)", id));
                _sameN(abi.encodeWithSignature("getApproved(uint256)", id));
                (bool okP, bytes memory pa) = NA.staticcall(abi.encodeWithSignature("payee(uint256)", id));
                if (okP && abi.decode(pa, (address)) != RA && abi.decode(pa, (address)) != NA) {
                    _sameN(abi.encodeWithSignature("tokenURI(uint256)", id));
                }
            }
        }
        for (uint256 t; t < 4; ++t) {
            _sameR(abi.encodeWithSignature("config(uint256)", tids[t]));
            for (uint256 s; s < 10; ++s) {
                _sameN(abi.encodeWithSignature("isAvailable(string,uint256)", subs[s], tids[t]));
            }
        }
        for (uint256 a; a < actors.length; ++a) {
            _sameN(abi.encodeWithSignature("owed(address)", actors[a]));
            _sameN(abi.encodeWithSignature("balanceOf(address)", actors[a]));
            _sameN(abi.encodeWithSignature("primaryPage(address)", actors[a]));
            _sameR(abi.encodeWithSignature("proceedsOf(address)", actors[a]));
            if (deep) {
                (string memory want,) = _rrWant(actors[a]);
                assertEq(PageNFT(NB).reverseResolve(actors[a]), want, "B reverseResolve under the holder check");
            }
        }
        assertEq(PageNFTFlag(NA).balanceOf(RA), PageNFT(NB).balanceOf(RB), "names stranded in the registrar");
        _sameN(abi.encodeWithSignature("owed(address)", DEAD));
    }

    // helpers

    function _now() internal view returns (uint256) {
        return vm.getBlockTimestamp();
    }

    function _owner(uint256 id) internal view returns (address) {
        (bool ok, bytes memory r) = NB.staticcall(abi.encodeWithSignature("ownerOf(uint256)", id));
        return ok ? abi.decode(r, (address)) : address(0);
    }

    function _setter(uint256 id) internal view returns (address) {
        bytes32 base = keccak256(abi.encode(id, uint256(12)));
        return address(uint160(uint256(vm.load(NB, bytes32(uint256(base) + 1)))));
    }

    function _actor(uint256 r) internal view returns (address) {
        return actors[r % 6];
    }

    // operations

    function _register(uint256 r) internal {
        uint256 t = r % 4;
        address payer = _actor(r >> 8);
        uint256 k = (r >> 16) % 8;
        // a commitment hashes the recipient, so a registrar recipient would differ between the worlds and is never picked
        address toA = k == 7 ? DEAD : _actor(r >> 24);
        address toB = _mapA(toA);
        bytes32 secret = keccak256(abi.encode(step, r));
        bytes32 cA = PageNFTFlag(NA).makeCommitment(tops[t], toA, 0, secret);
        bytes32 cB = PageNFT(NB).makeCommitment(tops[t], toB, 0, secret);
        _both(payer, 0, NA, abi.encodeWithSignature("commit(bytes32)", cA), NB, abi.encodeWithSignature("commit(bytes32)", cB));
        vm.warp(_now() + 61);
        (,,, uint256 total) = PageNFT(NB).quote(tops[t]);
        bool existed = PageNFT(NB).epochOf(tids[t]) > 0;
        bool ok = _both(
            payer, total,
            NA, abi.encodeWithSignature("reveal(string,address,uint256,bytes32)", tops[t], toA, 0, secret),
            NB, abi.encodeWithSignature("reveal(string,address,uint256,bytes32)", tops[t], toB, 0, secret)
        );
        if (ok && existed) ++relapses;
    }

    function _transfer(uint256 r) internal {
        uint256 p = tids[r % 4];
        address from = _owner(p);
        if (from == address(0)) return;
        uint256 k = (r >> 8) % 10;
        address toA;
        if (k < 5) toA = _actor(r >> 16);
        else if (k < 8) toA = _setter(p) == address(0) ? _actor(r >> 16) : _setter(p);
        else if (k == 8) toA = RA;
        else toA = DEAD;
        if (from == RB || from == DEAD) return;
        address toB = _mapA(toA);
        address by = (r >> 24) % 5 == 0 ? _actor(r >> 32) : from;
        address before = PageNFT(NB).subpageMinterOf(p);
        bool safe = (r >> 40) % 3 == 0;
        string memory sig = safe ? "safeTransferFrom(address,address,uint256)" : "transferFrom(address,address,uint256)";
        _both(by, 0, NA, abi.encodeWithSignature(sig, from, toA, p), NB, abi.encodeWithSignature(sig, from, toB, p));
        if (before == address(0) && PageNFT(NB).subpageMinterOf(p) != address(0)) ++revivals;
    }

    function _setMinter(uint256 r) internal {
        uint256 p = (r >> 48) % 13 == 0 ? ids[(r >> 52) % ids.length] : tids[r % 4];
        address o = _owner(p);
        uint256 k = (r >> 8) % 10;
        if (biased && k >= 5 && k < 8) k = 0;
        address caller;
        if (k < 5 && o != address(0) && o != RB && o != DEAD) caller = o;
        else if (k < 8 && _setter(p) != address(0)) caller = _setter(p);
        else caller = _actor(r >> 16);
        uint256 j = (r >> 24) % 8;
        if (biased && j < 4) j = 4 + j;
        address mA = j < 2 ? address(0) : j == 2 ? RA : j == 3 ? DEAD : _actor(r >> 32);
        bool ok = _both(
            caller, 0,
            NA, abi.encodeWithSignature("setSubpageMinter(uint256,address,bool)", p, mA, false),
            NB, abi.encodeWithSignature("setSubpageMinter(uint256,address)", p, _mapA(mA))
        );
        if (ok && caller != o) ++awayClears;
    }

    function _mint(uint256 r) internal {
        uint256 p = tids[r % 4];
        string memory label = subs[(r >> 8) % 10];
        address o = _owner(p);
        address m = PageNFT(NB).subpageMinterOf(p);
        uint256 k = (r >> 16) % 10;
        if (biased && k < 3) k = 3 + k;
        address caller;
        bool byMinter;
        if (k < 3 && o != address(0) && o != RB && o != DEAD) caller = o;
        else if (k < 8 && m != address(0) && m != RB && m != DEAD && m != NB) {
            caller = m;
            byMinter = caller != o;
        } else caller = _actor(r >> 24);
        address toA = (r >> 32) % 9 == 0 ? RA : _actor(r >> 40);
        _mintAs(p, label, caller, toA, byMinter);
    }

    function _mintAs(uint256 p, string memory label, address caller, address toA, bool byMinter) internal {
        uint256 sid = uint256(keccak256(abi.encodePacked(bytes32(p), keccak256(bytes(PageNFT(NB).normalize(label))))));
        bool existed = PageNFT(NB).epochOf(sid) > 0;
        (,,,, uint64 pe) = PageNFT(NB).records(sid);
        bool live = existed && pe == PageNFT(NB).epochOf(p);
        bool ok = _both(
            caller, 0,
            NA, abi.encodeWithSignature("registerSubpageFor(string,uint256,address)", label, p, toA),
            NB, abi.encodeWithSignature("registerSubpageFor(string,uint256,address)", label, p, _mapA(toA))
        );
        if (byMinter && ok) {
            ++minterMints;
            if (existed) ++minterStale;
        }
        if (byMinter && !ok && live) ++minterRefusedLive;
    }

    function _configure(uint256 r) internal {
        uint256 p = tids[r % 4];
        address o = _owner(p);
        address caller = (r >> 8) % 4 == 0 || o == address(0) || o == RB || o == DEAD ? _actor(r >> 16) : o;
        address pay = (r >> 24) % 3 == 0 ? address(0) : _actor(r >> 32);
        uint256 price = (r >> 40) % 3 == 0 ? 0 : 0.01 ether;
        bool enabled = (r >> 48) % 5 != 0;
        _both(
            caller, 0,
            RA, abi.encodeWithSignature("configure(uint256,address,address,uint256,bool,address,uint256,bool)", p, pay, address(0), price, enabled, address(0), 0, false),
            RB, abi.encodeWithSignature("configure(uint256,address,address,uint256,bool,address,uint256,bool)", p, pay, address(0), price, enabled, address(0), 0, false)
        );
    }

    function _sell(uint256 r) internal {
        uint256 p = tids[r % 4];
        string memory label = subs[(r >> 8) % 10];
        address buyer = _actor(r >> 16);
        address toA = (r >> 24) % 11 == 0 ? RA : _actor(r >> 32);
        uint256 value = (r >> 40) % 4 == 0 ? 0.02 ether : 0.01 ether;
        bool ok = _both(
            buyer, value,
            RA, abi.encodeWithSignature("registerSubpageFor(uint256,string,address,uint256,address)", p, label, toA, 1 ether, address(0)),
            RB, abi.encodeWithSignature("registerSubpageFor(uint256,string,address,uint256,address)", p, label, _mapA(toA), 1 ether, address(0))
        );
        if (ok) ++sales;
    }

    function _setupSale(uint256 r) internal {
        uint256 p = tids[r % 4];
        address o = _owner(p);
        if (o == address(0) || o == RB || o == DEAD) return;
        _both(
            o, 0,
            NA, abi.encodeWithSignature("setSubpageMinter(uint256,address,bool)", p, RA, false),
            NB, abi.encodeWithSignature("setSubpageMinter(uint256,address)", p, RB)
        );
        _configure((r & ~uint256(0xff << 8)) | (uint256(1) << 8));
    }

    function _warp(uint256 r) internal {
        uint256 k = r % 10;
        if (biased && k >= 6 && (r >> 60) % 4 != 0) k = 0;
        if (k < 6) vm.warp(_now() + 1 + (r >> 8) % 3 days);
        else if (k < 8) vm.warp(_now() + 200 days);
        else {
            uint256 p = tids[(r >> 8) % 4];
            uint256 e = PageNFT(NB).expiresAt(p);
            if (e != 0 && e + 90 days + 21 days + 1 > _now()) vm.warp(e + 90 days + 21 days + 1);
        }
    }

    function _renew(uint256 r) internal {
        uint256 p = tids[r % 4];
        _both(_actor(r >> 8), 0.05 ether, NA, abi.encodeWithSignature("renew(uint256)", p), NB, abi.encodeWithSignature("renew(uint256)", p));
    }

    function _claim(uint256 r) internal {
        address a = _actor(r);
        _both(a, 0, RA, abi.encodeWithSignature("claimProceeds(address)", address(0)), RB, abi.encodeWithSignature("claimProceeds(address)", address(0)));
    }

    function _disable(uint256 r) internal {
        uint256 p = tids[r % 4];
        address o = _owner(p);
        address caller = (r >> 8) % 3 == 0 || o == address(0) || o == RB || o == DEAD ? _actor(r >> 16) : o;
        _both(caller, 0, RA, abi.encodeWithSignature("disable(uint256)", p), RB, abi.encodeWithSignature("disable(uint256)", p));
    }

    function _approveAll(uint256 r) internal {
        address a = _actor(r);
        address op = _actor(r >> 8);
        bool on = (r >> 16) % 2 == 0;
        _both(a, 0, NA, abi.encodeWithSignature("setApprovalForAll(address,bool)", op, on), NB, abi.encodeWithSignature("setApprovalForAll(address,bool)", op, on));
    }

    function _walk(uint256 seed, uint256 n) internal {
        for (uint256 i; i < n; ++i) {
            ++step;
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            uint256 w = r % 100;
            r >>= 8;
            if (w < 12) _register(r);
            else if (w < 22) _transfer(r);
            else if (w < 38) _setMinter(r);
            else if (w < 62) _mint(r);
            else if (w < 68) _configure(r);
            else if (w < 78) _sell(r);
            else if (w < 84) _setupSale(r);
            else if (w < 90) _warp(r);
            else if (w < 93) _renew(r);
            else if (w < 95) _claim(r);
            else if (w < 97) _disable(r);
            else _approveAll(r);
            _check(i % 20 == 19);
        }
        _check(true);
    }

    function testFuzz_flagFalseEqualsCreateOnly(uint256 seed) public {
        _walk(seed, 60);
    }

    function _report() internal {
        emit log_named_uint("ok calls", okCalls);
        emit log_named_uint("failed calls", failCalls);
        emit log_named_uint("minter mints", minterMints);
        emit log_named_uint("of which stale re-mints", minterStale);
        emit log_named_uint("minter refused on live", minterRefusedLive);
        emit log_named_uint("sales", sales);
        emit log_named_uint("away clears", awayClears);
        emit log_named_uint("revivals by return", revivals);
        emit log_named_uint("re-registrations", relapses);
    }

    function _registerTop(uint256 t, address payer, address to) internal {
        bytes32 secret = keccak256(abi.encode(step, t, payer, to));
        bytes32 c = PageNFT(NB).makeCommitment(tops[t], to, 0, secret);
        _both(payer, 0, NA, abi.encodeWithSignature("commit(bytes32)", c), NB, abi.encodeWithSignature("commit(bytes32)", c));
        vm.warp(_now() + 61);
        (,,, uint256 total) = PageNFT(NB).quote(tops[t]);
        bool existed = PageNFT(NB).epochOf(tids[t]) > 0;
        bool ok = _both(
            payer, total,
            NA, abi.encodeWithSignature("reveal(string,address,uint256,bytes32)", tops[t], to, 0, secret),
            NB, abi.encodeWithSignature("reveal(string,address,uint256,bytes32)", tops[t], to, 0, secret)
        );
        if (ok && existed) ++relapses;
    }

    function _isActor(address a) internal view returns (bool) {
        for (uint256 i; i < 6; ++i) if (actors[i] == a) return true;
        return false;
    }

    // a walk that keeps each parent live and held by an actor, so most steps reach the minter paths
    function _focus(uint256 seed, uint256 n) internal {
        for (uint256 i; i < n; ++i) {
            ++step;
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            uint256 t = r % 4;
            uint256 p = tids[t];
            address o = _owner(p);
            bool dead = PageNFT(NB).epochOf(p) == 0 || _now() > PageNFT(NB).expiresAt(p) + 90 days;
            if (dead || !_isActor(o)) {
                if (PageNFT(NB).epochOf(p) == 0 || _now() > PageNFT(NB).expiresAt(p) + 90 days) {
                    _registerTop(t, _actor(r >> 8), _actor(r >> 16));
                } else if (_now() > PageNFT(NB).expiresAt(p)) {
                    _renew(r & ~uint256(3) | t);
                } else {
                    vm.warp(PageNFT(NB).expiresAt(p) + 90 days + 21 days + 1);
                }
                _check(false);
                continue;
            }
            if (_now() > PageNFT(NB).expiresAt(p)) {
                _renew((r & ~uint256(3)) | t);
                _check(false);
                continue;
            }
            uint256 w = (r >> 24) % 20;
            address m = PageNFT(NB).subpageMinterOf(p);
            string memory label = subs[(r >> 32) % 10];
            if (w < 3 || (m == address(0) && w < 13)) {
                address pick = _actor(r >> 40);
                _both(o, 0, NA, abi.encodeWithSignature("setSubpageMinter(uint256,address,bool)", p, pick, false), NB, abi.encodeWithSignature("setSubpageMinter(uint256,address)", p, pick));
            } else if (w < 13) {
                if (m == RB || !_isActor(m)) {
                    _both(o, 0, NA, abi.encodeWithSignature("setSubpageMinter(uint256,address,bool)", p, _actor(r >> 40), false), NB, abi.encodeWithSignature("setSubpageMinter(uint256,address)", p, _actor(r >> 40)));
                } else {
                    _mintAs(p, label, m, (r >> 48) % 9 == 0 ? RA : _actor(r >> 52), m != o);
                }
            } else if (w < 15) {
                _mintAs(p, label, (r >> 44) % 4 == 0 ? _actor(r >> 56) : o, _actor(r >> 52), false);
            } else if (w < 16) {
                _transfer((r & ~uint256(3)) | t);
            } else if (w < 17) {
                address setter = _setter(p);
                if (setter != address(0) && setter != o) {
                    _both(setter, 0, NA, abi.encodeWithSignature("setSubpageMinter(uint256,address,bool)", p, address(0), false), NB, abi.encodeWithSignature("setSubpageMinter(uint256,address)", p, address(0)));
                    ++awayClears;
                } else {
                    _transfer((r & ~uint256(3)) | t);
                }
            } else if (w < 18) {
                _setupSale((r & ~uint256(3)) | t);
                _sell((r & ~uint256(3)) | t);
            } else if (w < 19) {
                vm.warp(_now() + 1 + (r >> 48) % 2 days);
            } else {
                vm.warp(PageNFT(NB).expiresAt(p) + 90 days + 21 days + 1);
            }
            _check(i % 25 == 24);
        }
        _check(true);
    }

    function test_focusWalk1() public {
        _focus(0x101, 500);
        _report();
        assertGt(minterMints, 50);
        assertGt(minterRefusedLive, 10);
        assertGt(minterStale, 0);
    }

    function test_focusWalk2() public {
        _focus(0x202, 500);
        _report();
        assertGt(minterMints, 50);
    }

    function testFuzz_focus(uint256 seed) public {
        _focus(seed, 60);
    }

    function test_biasedWalk1() public {
        biased = true;
        _walk(0xe5, 500);
        _report();
        assertGt(minterMints, 0);
    }

    function test_biasedWalk2() public {
        biased = true;
        _walk(0xf6, 500);
        _report();
        assertGt(minterMints, 0);
    }

    function testFuzz_biased(uint256 seed) public {
        biased = true;
        _walk(seed, 60);
    }

    function test_longWalk1() public {
        _walk(0xa1, 600);
        _report();
        assertGt(minterMints, 0);
        assertGt(minterRefusedLive, 0);
    }

    function test_longWalk2() public {
        _walk(0xb2, 600);
        _report();
        assertGt(minterMints, 0);
    }

    function test_longWalk3() public {
        _walk(0xc3, 600);
        _report();
        assertGt(awayClears + revivals, 0);
    }

    function test_longWalk4() public {
        _walk(0xd4, 600);
        _report();
        assertGt(relapses + minterStale, 0);
    }
}

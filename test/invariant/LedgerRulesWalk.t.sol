// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {trialCommitmentRaw} from "../utils/TrialCommitment.sol";

import {Test, Vm} from "forge-std/Test.sol";
import {PageCard} from "../../src/PageCard.sol";
import {PageNFT} from "../../src/PageNFT.sol";
import {Holder721} from "../utils/MinterMocks.sol";

// A random walk over registrations, trials, renewals, auctions, releases, withdrawals, address saves,
// clears, transfers, subpage mints and code changes at a main address. After every step it checks that
// every deposit is a whole number of the smallest fee, that no EVM coin type answers twenty zero bytes,
// that the credits never exceed the balance, that the payee of a top level name stays what it was when the
// name was first seen inactive until the name is active again, and that the VersionChanged events of every
// id count its record version and the last one carries it. A failed call is undone and its logs are
// dropped, as an indexer never sees them.
contract LedgerRulesWalkTest is Test {
    PageNFT nft;
    Holder721 vault;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    bytes32 constant T_VERSION = keccak256("VersionChanged(bytes32,uint64)");
    uint256 constant GRACE = 90 days;
    uint256 constant DECAY = 21 days;

    address[5] actors;
    address kw = makeAddr("kw");
    string[6] tops = ["a", "bc", "def", "ghij", "klmno", "pqrstuvw"];
    string[2] subLabels = ["x", "y"];
    uint256[] ids;
    uint256[6] topIds;
    uint256 ghost;
    // fixed EVM coin types, and one more drawn from the seed in place of the last
    uint256[7] coins = [uint256(60), 0x80000000, 0x8000000a, 0x80000001, 0x80002105, 0xffffffff, 0x80000002];

    // what the logs of successful calls told so far
    mapping(uint256 => uint256) versionEvents;
    mapping(uint256 => uint64) lastVersion;

    struct Snap {
        bool set;
        uint64 epoch;
        address payee;
    }

    mapping(uint256 => Snap) snaps;

    // how often each action succeeded, and how often a check compared something
    uint256[12] okCount;
    uint256 payeeChecks;
    uint256 auctions;
    uint256 zeroSaves;
    uint256 nonce;

    function setUp() public {
        vm.warp(1_800_000_000);
        nft = new PageNFT(new PageCard());
        vault = new Holder721();
        actors = [makeAddr("alice"), makeAddr("bob"), makeAddr("carol"), kw, address(vault)];
        for (uint256 i; i < 5; ++i) vm.deal(actors[i], 10_000 ether);
        bytes32 root = nft.ROOT();
        for (uint256 i; i < 6; ++i) {
            topIds[i] = uint256(keccak256(abi.encodePacked(root, keccak256(bytes(tops[i])))));
            ids.push(topIds[i]);
        }
        for (uint256 p = 3; p < 6; ++p) {
            for (uint256 k; k < 2; ++k) {
                ids.push(uint256(keccak256(abi.encodePacked(bytes32(topIds[p]), keccak256(bytes(subLabels[k]))))));
            }
        }
        // alice, bob, carol and kw let carol move any name they hold, but the vault does not
        for (uint256 i; i < 4; ++i) {
            vm.prank(actors[i]);
            nft.setApprovalForAll(actors[2], true);
        }
    }

    function _now() internal view returns (uint256) {
        return vm.getBlockTimestamp();
    }

    // the holder, or zero when there is none or DEAD holds it, since nobody acts as DEAD
    function _ownerOf(uint256 id) internal view returns (address) {
        try nft.ownerOf(id) returns (address o) {
            return o == DEAD ? address(0) : o;
        } catch {
            return address(0);
        }
    }

    // reads the logs of the last call and counts its VersionChanged events if it succeeded
    function _logs(bool ok) internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        if (!ok) return;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(nft) || logs[i].topics.length < 2 || logs[i].topics[0] != T_VERSION) continue;
            uint256 id = uint256(logs[i].topics[1]);
            ++versionEvents[id];
            lastVersion[id] = abi.decode(logs[i].data, (uint64));
        }
    }

    function _call(address who, uint256 value, bytes memory data) internal returns (bool ok) {
        vm.deal(who, who.balance + value);
        vm.prank(who);
        (ok,) = address(nft).call{value: value}(data);
        _logs(ok);
    }

    // a referrer: none, another top level name, or an id with no record
    function _ref(uint256 r, uint256 self) internal view returns (uint256) {
        uint256 k = r % 4;
        if (k == 0) return 0;
        if (k == 1) return ghost;
        uint256 id = topIds[(r >> 4) % 6];
        return id == self ? 0 : id;
    }

    // actions

    function _register(uint256 r, bool trial) internal {
        uint256 t = r % 6;
        string memory label = tops[t];
        address payer = actors[(r >> 8) % 5];
        address to = actors[(r >> 16) % 5];
        uint256 ref = _ref(r >> 24, topIds[t]);
        bytes32 secret = keccak256(abi.encode(r, ++nonce));
        bytes32 c = trial ? trialCommitmentRaw(label, to, ref, secret) : nft.makeCommitment(label, to, ref, secret);
        _call(payer, 0, abi.encodeCall(PageNFT.commit, (c)));
        vm.warp(_now() + 61);
        (uint256 fee, uint256 carried,, uint256 total) = nft.quote(label);
        uint256 excess = (r >> 40) % 3 == 0 ? (r >> 48) % 1 ether : 0;
        bool ok = _call(
            payer,
            (trial ? fee / 10 : total) + excess,
            trial ? abi.encodeCall(PageNFT.revealTrial, (label, to, ref, secret)) : abi.encodeCall(PageNFT.reveal, (label, to, ref, secret))
        );
        if (ok) {
            ++okCount[trial ? 1 : 0];
            if (carried != 0) ++auctions;
        }
    }

    function _renew(uint256 r) internal {
        uint256 id = topIds[r % 6];
        uint256 fee = nft.getFee(bytes(tops[r % 6]).length);
        if (_call(actors[(r >> 8) % 5], fee, abi.encodeCall(PageNFT.renew, (id)))) ++okCount[2];
    }

    function _release(uint256 r) internal {
        if (_call(actors[(r >> 8) % 5], 0, abi.encodeCall(PageNFT.release, (topIds[r % 6])))) ++okCount[3];
    }

    function _withdraw(uint256 r) internal {
        address a = r % 6 == 5 ? DEAD : actors[r % 6];
        if (_call(actors[(r >> 8) % 5], 0, abi.encodeCall(PageNFT.withdraw, (a)))) ++okCount[4];
    }

    function _warp(uint256 r) internal {
        uint256 k = r % 8;
        uint256 target;
        if (k < 3) {
            target = _now() + 1 + (r >> 8) % 3 days;
        } else if (k < 5) {
            target = _now() + 30 days + (r >> 8) % 70 days;
        } else {
            uint256 e = nft.expiresAt(topIds[(r >> 8) % 6]);
            uint256 edge = k == 5 ? e : k == 6 ? e + GRACE : e + GRACE + DECAY;
            target = edge + (r >> 16) % 2;
        }
        if (target > _now()) {
            vm.warp(target);
            ++okCount[5];
        }
    }

    function _pickId(uint256 r) internal view returns (uint256) {
        return ids[r % ids.length];
    }

    function _setAddr(uint256 r) internal {
        uint256 id = _pickId(r);
        address o = _ownerOf(id);
        address caller = (r >> 8) % 4 == 0 ? actors[(r >> 10) % 5] : o;
        address a = (r >> 16) % 5 == 0 ? address(0) : actors[(r >> 20) % 5];
        if (caller != address(0) && _call(caller, 0, abi.encodeCall(PageNFT.setAddr, (id, a)))) ++okCount[6];
    }

    function _setAddrForCoin(uint256 r) internal {
        uint256 id = _pickId(r);
        address o = _ownerOf(id);
        uint256 k = (r >> 8) % 8;
        uint256 coin = k == 7 ? 0 : coins[k];
        uint256 v = (r >> 16) % 4;
        bytes memory value;
        if (v == 0) value = abi.encodePacked(actors[(r >> 20) % 5]);
        else if (v == 1) value = new bytes(20);
        else if (v == 2) value = "";
        else value = abi.encodePacked(bytes20(keccak256(abi.encode(r))));
        if (o != address(0) && _call(o, 0, abi.encodeCall(PageNFT.setAddrForCoin, (id, coin, value)))) {
            ++okCount[7];
            if (v != 0 && v != 3) ++zeroSaves;
        }
    }

    function _clear(uint256 r) internal {
        uint256 id = _pickId(r);
        address o = _ownerOf(id);
        if (o != address(0) && _call(o, 0, abi.encodeCall(PageNFT.clearRecords, (id)))) ++okCount[8];
    }

    function _transfer(uint256 r) internal {
        uint256 id = _pickId(r);
        address o = _ownerOf(id);
        if (o == address(0)) return;
        uint256 k = (r >> 8) % 6;
        address to = k == 5 ? DEAD : actors[k];
        address caller = (r >> 16) % 3 == 0 ? actors[2] : o;
        bytes memory data = (r >> 24) % 2 == 0
            ? abi.encodeWithSignature("transferFrom(address,address,uint256)", o, to, id)
            : abi.encodeWithSignature("safeTransferFrom(address,address,uint256)", o, to, id);
        if (_call(caller, 0, data)) ++okCount[9];
    }

    function _subMint(uint256 r) internal {
        uint256 p = 3 + r % 3;
        address o = _ownerOf(topIds[p]);
        if (o == address(0)) return;
        uint256 k = (r >> 8) % 6;
        address to = k == 5 ? DEAD : actors[k];
        bytes memory data = abi.encodeCall(PageNFT.registerSubpageFor, (subLabels[(r >> 16) % 2], topIds[p], to));
        if (_call(o, 0, data)) ++okCount[10];
    }

    // the main address kw gets no code, the 23 byte delegation or ordinary code
    function _etch(uint256 r) internal {
        uint256 k = r % 3;
        if (k == 0) vm.etch(kw, "");
        else if (k == 1) vm.etch(kw, abi.encodePacked(hex"ef0100", address(0x1234)));
        else vm.etch(kw, hex"600160005260206000f3");
        ++okCount[11];
    }

    function _step(uint256 r) internal {
        uint256 a = r % 100;
        r >>= 8;
        if (a < 16) _register(r, false);
        else if (a < 24) _register(r, true);
        else if (a < 32) _renew(r);
        else if (a < 37) _release(r);
        else if (a < 41) _withdraw(r);
        else if (a < 55) _warp(r);
        else if (a < 63) _setAddr(r);
        else if (a < 73) _setAddrForCoin(r);
        else if (a < 77) _clear(r);
        else if (a < 87) _transfer(r);
        else if (a < 96) _subMint(r);
        else _etch(r);
    }

    // checks

    function _depositIsFeeMultiple() internal view {
        uint256 unit = nft.getFee(63);
        for (uint256 len = 1; len < 6; ++len) assertEq(nft.getFee(len) % unit, 0, "every fee is a whole number of units");
        for (uint256 i; i < ids.length; ++i) assertEq(nft.depositOf(ids[i]) % unit, 0, "a deposit is a whole number of units");
        assertEq(nft.depositOf(ghost) % unit, 0, "the ghost id");
    }

    function _evmAnswerNeverZero() internal view {
        for (uint256 i; i < ids.length; ++i) {
            for (uint256 c; c < coins.length; ++c) {
                bytes memory b = nft.addr(ids[i], coins[c]);
                assertTrue(b.length == 0 || (b.length == 20 && bytes20(b) != bytes20(0)), "empty or a non zero address");
            }
        }
    }

    function _owedNeverExceedsBalance() internal view {
        uint256 sum = nft.owed(DEAD);
        for (uint256 i; i < 5; ++i) sum += nft.owed(actors[i]);
        assertLe(sum, address(nft).balance, "the credits never exceed the balance");
    }

    function _payeeFrozenWhileInactive() internal {
        for (uint256 i; i < 6; ++i) {
            uint256 id = topIds[i];
            uint256 e = nft.expiresAt(id);
            if (e == 0 || _now() <= e) {
                delete snaps[id];
                continue;
            }
            uint64 epoch = nft.epochOf(id);
            address p = nft.payee(id);
            Snap storage s = snaps[id];
            if (s.set && s.epoch == epoch) {
                assertEq(p, s.payee, "the payee of an inactive name is frozen");
                ++payeeChecks;
            } else {
                snaps[id] = Snap(true, epoch, p);
            }
        }
        assertEq(nft.payee(ghost), DEAD, "an id with no record pays DEAD");
    }

    function _versionEventsCountVersions() internal view {
        for (uint256 i; i < ids.length; ++i) {
            uint256 v = nft.recordVersion(ids[i]);
            assertEq(versionEvents[ids[i]], v, "one VersionChanged per version");
            if (v != 0) assertEq(lastVersion[ids[i]], v, "the last VersionChanged carries the version");
        }
    }

    function _checkAll() internal {
        _depositIsFeeMultiple();
        _evmAnswerNeverZero();
        _owedNeverExceedsBalance();
        _payeeFrozenWhileInactive();
        _versionEventsCountVersions();
    }

    function _walk(uint256 seed, uint256 steps) internal {
        ghost = uint256(keccak256(abi.encode("ghost", seed)));
        uint256 c = 0x80000001 + uint256(keccak256(abi.encode("coin", seed))) % 0x7fffffff;
        coins[6] = c == 0x8000000a ? 0x8000000b : c;
        vm.recordLogs();
        for (uint256 i; i < steps; ++i) {
            _step(uint256(keccak256(abi.encode(seed, i))));
            _checkAll();
        }
    }

    /// forge-config: default.fuzz.runs = 128
    /// forge-config: deep.fuzz.runs = 512
    function testFuzz_ledgerAndLogRulesHoldAtEveryStep(uint256 seed) public {
        _walk(seed, 40);
    }

    // long walks from fixed seeds reach every action and every comparison
    function test_walkReachesEveryActionAndCheck() public {
        for (uint256 s; s < 6; ++s) _walk(s, 120);
        for (uint256 k; k < okCount.length; ++k) assertGt(okCount[k], 0, "every action succeeded at least once");
        assertGt(payeeChecks, 0, "a payee was compared while inactive");
        assertGt(auctions, 0, "a deposit was bought out");
        assertGt(zeroSaves, 0, "zero and empty values were saved");
        uint256 events;
        for (uint256 i; i < ids.length; ++i) events += versionEvents[ids[i]];
        assertGt(events, 0, "VersionChanged was counted");
        emit log_named_uint("payee comparisons while inactive", payeeChecks);
        emit log_named_uint("auctions", auctions);
        emit log_named_uint("VersionChanged events", events);
        for (uint256 k; k < okCount.length; ++k) emit log_named_uint("successful calls of action", okCount[k]);
    }
}

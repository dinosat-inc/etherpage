// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Test, Vm} from "forge-std/Test.sol";
import {PageCard} from "../../src/PageCard.sol";
import {PageNFT} from "../../src/PageNFT.sol";
import {PageNFTNoDefault} from "./harness/PageNFTNoDefault.sol";

// a contract holder that runs a call for anyone, so both builds get the same caller
contract DiffHolder {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    function run(address to, bytes calldata data) external payable returns (bool ok, bytes memory ret) {
        (ok, ret) = to.call{value: msg.value}(data);
    }

    receive() external payable {}
}

// wallet code placed at an account to stand in for code adopted under EIP8298
contract DiffCode {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}

// The two builds side by side, and the models of how their answers differ. For an EVM chain other than the home
// chain, the earlier build answers the holder's own entry, else the main address when it is a key wallet. src answers
// the holder's own entry, else the default the holder saved, else nothing, whatever code any address has. An
// AddressChanged for such a chain carries the answer of its own build, and so does the AddrChanged that comes right
// after the one of coin type 60, so the two differ in the same way, and a transfer that keeps the main address
// announces coin type 60 only in a build whose answer it changes. addr with no coin type answers coin type 60 in both.
// Every other log, every result and revert data, and every other view is the same in both builds.
abstract contract DiffModel is Test {
    uint256 constant DEFAULT_EVM = 0x80000000;
    uint256 constant COIN_OP = 0x8000000a;
    bytes32 constant ADDRESS_CHANGED = keccak256("AddressChanged(bytes32,uint256,bytes)");
    bytes32 constant ADDR_CHANGED = keccak256("AddrChanged(bytes32,address)");

    PageNFT nft;
    PageNFTNoDefault old;
    DiffHolder holder;
    uint256[] ids;

    // the coin type 60 answer of each build for every id before the call in progress
    mapping(uint256 => bytes) pre60New;
    mapping(uint256 => bytes) pre60Old;

    // how often each predicted difference of the answer rule was seen, so the walks are not vacuous
    uint256 public answersDiffer;
    uint256 public announcementsDiffer;
    uint256 public announcedByOneBuild;

    function _call(address caller, address target, uint256 value, bytes memory data)
        internal
        returns (bool ok, bytes memory ret)
    {
        if (caller == address(holder)) {
            (ok, ret) = holder.run{value: value}(target, data);
        } else {
            vm.prank(caller);
            (ok, ret) = target.call{value: value}(data);
        }
    }

    // one call on each build by the same caller; results must match, and logs match but for the predicted
    // announcements of EVM chains other than the home chain
    function _both(address caller, uint256 value, bytes memory data) internal returns (bool ok) {
        for (uint256 k; k < ids.length; ++k) {
            pre60New[ids[k]] = nft.addr(ids[k], 60);
            pre60Old[ids[k]] = old.addr(ids[k], 60);
        }
        bytes memory r1;
        bytes memory r2;
        bool ok2;
        vm.recordLogs();
        (ok, r1) = _call(caller, address(nft), value, data);
        Vm.Log[] memory l1 = vm.getRecordedLogs();
        vm.recordLogs();
        (ok2, r2) = _call(caller, address(old), value, data);
        Vm.Log[] memory l2 = vm.getRecordedLogs();
        assertEq(ok, ok2, "success");
        assertEq(r1, r2, "return or revert data");
        _sameLogs(l1, l2);
    }

    function _sameLog(Vm.Log memory a, Vm.Log memory b) internal view {
        assertEq(a.topics.length, b.topics.length, "topics");
        for (uint256 k; k < a.topics.length; ++k) {
            bytes32 t1 = a.topics[k];
            // a Transfer of the token mentions no contract address, but a holder contract's call log could
            if (t1 == bytes32(uint256(uint160(address(nft))))) t1 = bytes32(uint256(uint160(address(old))));
            assertEq(t1, b.topics[k], "topic");
        }
        assertEq(a.data, b.data, "log data");
    }

    // every log of src against the earlier build's, in order. An announcement of an EVM chain other than the home
    // chain in both builds is checked against the answer rules, and one in a single build must be one they predict.
    // The AddrChanged right after an announcement of coin type 60 goes with it
    function _sameLogs(Vm.Log[] memory l1, Vm.Log[] memory l2) internal {
        uint256 i;
        uint256 j;
        while (i < l1.length || j < l2.length) {
            bool e1 = i < l1.length && _coinOf(l1[i]) != 0;
            bool e2 = j < l2.length && _coinOf(l2[j]) != 0;
            if (e1 && e2) {
                _sameAnnouncement(l1, i, l2, j);
                i = _afterAnnouncement(l1, i);
                j = _afterAnnouncement(l2, j);
            } else if (e1) {
                _announcedByOneBuild(l1, i, true);
                i = _afterAnnouncement(l1, i);
            } else if (e2) {
                _announcedByOneBuild(l2, j, false);
                j = _afterAnnouncement(l2, j);
            } else {
                assertTrue(i < l1.length && j < l2.length, "log count");
                assertFalse(_isAddrChanged(l1[i]) || _isAddrChanged(l2[j]), "AddrChanged comes only after coin type 60");
                _sameLog(l1[i], l2[j]);
                ++i;
                ++j;
            }
        }
        _lastAnnouncementsAreAnswers(l1, address(nft));
        _lastAnnouncementsAreAnswers(l2, address(old));
    }

    function _isAddrChanged(Vm.Log memory l) internal pure returns (bool) {
        return l.topics.length > 0 && l.topics[0] == ADDR_CHANGED;
    }

    // the index after the announcement at log i. An announcement of coin type 60 is followed by the AddrChanged of
    // the same name with the same address, which is skipped with it
    function _afterAnnouncement(Vm.Log[] memory l, uint256 i) internal pure returns (uint256) {
        if (_coinOf(l[i]) != 60) return i + 1;
        require(i + 1 < l.length, "coin type 60 without AddrChanged");
        Vm.Log memory n = l[i + 1];
        require(_isAddrChanged(n) && n.topics.length == 2 && n.topics[1] == l[i].topics[1], "AddrChanged of the same name");
        (, bytes memory a) = abi.decode(l[i].data, (uint256, bytes));
        require(abi.decode(n.data, (address)) == _addressOf(a), "AddrChanged carries the coin type 60 answer");
        return i + 2;
    }

    // an announced EVM address, empty for zero
    function _addressOf(bytes memory a) internal pure returns (address) {
        if (a.length == 0) return address(0);
        require(a.length == 20, "an EVM answer is empty or 20 bytes");
        return address(bytes20(a));
    }

    // the coin type of an AddressChanged log for an EVM chain other than the home chain, else 0
    function _coinOf(Vm.Log memory l) internal pure returns (uint256) {
        if (l.topics.length != 2 || l.topics[0] != ADDRESS_CHANGED) return 0;
        (uint256 coin,) = abi.decode(l.data, (uint256, bytes));
        bool evm = coin == 60 || (coin >= DEFAULT_EVM && coin <= 0xffffffff);
        return evm && coin != COIN_OP ? coin : 0;
    }

    // the main address announced right before log i, when log i - 1 is the AddressChanged of the home chain coin type
    // of the same name
    function _mainBefore(Vm.Log[] memory l, uint256 i) internal pure returns (bool announced, address main) {
        if (i == 0) return (false, address(0));
        Vm.Log memory p = l[i - 1];
        if (p.topics.length != 2 || p.topics[0] != ADDRESS_CHANGED || p.topics[1] != l[i].topics[1]) {
            return (false, address(0));
        }
        (uint256 coin, bytes memory a) = abi.decode(p.data, (uint256, bytes));
        if (coin != COIN_OP) return (false, address(0));
        return (true, _addressOf(a));
    }

    // The same announcement in both builds. No default is saved in a walk, so a non empty answer of src is the
    // holder's own entry, which the earlier build answers too; an empty one is where the earlier build answers the
    // main address when it is a key wallet. The main address is the one announced just before, or, for an
    // announcement of its own, the main address the call leaves.
    function _sameAnnouncement(Vm.Log[] memory l1, uint256 i, Vm.Log[] memory l2, uint256 j) internal {
        assertEq(l1[i].topics[1], l2[j].topics[1], "the same name");
        assertEq(_coinOf(l1[i]), _coinOf(l2[j]), "the same coin type");
        (bool after1, address m1) = _mainBefore(l1, i);
        (bool after2, address m2) = _mainBefore(l2, j);
        assertEq(after1, after2, "announced in the same place");
        assertEq(m1, m2, "after the same main address");
        address main = after1 ? m1 : nft.resolve(uint256(l1[i].topics[1]));
        (, bytes memory a1) = abi.decode(l1[i].data, (uint256, bytes));
        (, bytes memory a2) = abi.decode(l2[j].data, (uint256, bytes));
        assertEq(a2, a1.length != 0 ? a1 : _computed(main), "the earlier build announces its own answer");
        if (keccak256(a1) != keccak256(a2)) ++announcementsDiffer;
    }

    // An announcement in one build only: a transfer that keeps the main address announces coin type 60 when the
    // answer of the build changes, so it changed in that build and not in the other
    function _announcedByOneBuild(Vm.Log[] memory l, uint256 i, bool bySrc) internal {
        assertEq(_coinOf(l[i]), 60, "only coin type 60 is announced by a transfer");
        (bool announced,) = _mainBefore(l, i);
        assertFalse(announced, "an announcement after a new main address is in both builds");
        for (uint256 k; k < l.length; ++k) {
            if (k != i && _coinOf(l[k]) == 60 && l[k].topics[1] == l[i].topics[1]) {
                fail("an announcement by one build alone is the only coin type 60 one of its name in the call");
            }
        }
        uint256 id = uint256(l[i].topics[1]);
        bool newChanged = keccak256(pre60New[id]) != keccak256(nft.addr(id, 60));
        bool oldChanged = keccak256(pre60Old[id]) != keccak256(old.addr(id, 60));
        if (bySrc) {
            assertTrue(newChanged && !oldChanged, "announced by src alone, whose answer alone changed");
        } else {
            assertTrue(oldChanged && !newChanged, "announced by the earlier build alone, whose answer alone changed");
        }
        ++announcedByOneBuild;
    }

    // the last announcement of such a chain for a name in a call is what the build answers after it
    function _lastAnnouncementsAreAnswers(Vm.Log[] memory l, address build) internal view {
        for (uint256 i; i < l.length; ++i) {
            uint256 coin = _coinOf(l[i]);
            if (coin == 0) continue;
            bool last = true;
            for (uint256 k = i + 1; k < l.length; ++k) {
                if (_coinOf(l[k]) == coin && l[k].topics[1] == l[i].topics[1]) last = false;
            }
            if (!last) continue;
            (, bytes memory a) = abi.decode(l[i].data, (uint256, bytes));
            assertEq(a, PageNFT(build).addr(uint256(l[i].topics[1]), coin), "the last announcement is the answer");
        }
    }

    // the entry saved for coinType in the current record version of a build, read from its storage: the saver and a
    // value of 0 or 20 bytes, as setAddrForCoin stores an EVM entry. Both builds keep these entries in slot 9
    function _entry(address build, uint256 id, uint256 coinType) internal view returns (address saver, address value) {
        uint256 version = PageNFT(build).recordVersion(id);
        bytes32 base = keccak256(abi.encode(coinType, keccak256(abi.encode(version, keccak256(abi.encode(id, uint256(9)))))));
        saver = address(uint160(uint256(vm.load(build, base))));
        uint256 w = uint256(vm.load(build, bytes32(uint256(base) + 1)));
        if (w & 0xff == 40) value = address(uint160(w >> 96));
        else assertEq(w, 0, "an EVM entry is empty or 20 bytes");
    }

    function _isKey(address a) internal view returns (bool) {
        bytes memory c = a.code;
        return c.length == 0 || (c.length == 23 && c[0] == 0xef && c[1] == 0x01 && c[2] == 0x00);
    }

    function _enc(address a) internal pure returns (bytes memory) {
        return a == address(0) ? bytes("") : abi.encodePacked(a);
    }

    // what the earlier build answers for an EVM chain where the holder has no entry of its own
    function _computed(address main) internal view returns (bytes memory) {
        return main != address(0) && _isKey(main) ? abi.encodePacked(main) : bytes("");
    }

    // The answer of each build for an EVM coin type other than the home chain's, by its rule and the entries in its
    // storage, which are the same in both builds. A name that is not active answers nothing in either.
    function _evmAnswers(uint256 id, uint256 coin) internal {
        bytes memory n = nft.addr(id, coin);
        bytes memory o = old.addr(id, coin);
        if (coin == 60) {
            assertEq(_enc(nft.addr(bytes32(id))), n, "src: addr with no coin type answers coin type 60");
            assertEq(_enc(old.addr(bytes32(id))), o, "the earlier build: addr with no coin type answers coin type 60");
        }
        address main = nft.resolve(id);
        if (main == address(0)) {
            assertEq(n, "", "src: not active");
            assertEq(o, "", "the earlier build: not active");
            return;
        }
        address owner = nft.ownerOf(id);
        (address s1, address v1) = _entry(address(nft), id, coin);
        (address s2, address v2) = _entry(address(old), id, coin);
        assertEq(s1, s2, "the same saver in both builds");
        assertEq(v1, v2, "the same entry in both builds");
        address own = s1 == owner ? v1 : address(0);
        (address ds, address dv) = _entry(address(nft), id, DEFAULT_EVM);
        address def = ds == owner ? dv : address(0);
        assertEq(n, _enc(own != address(0) ? own : def), "src: own entry, else the default, else nothing");
        assertEq(o, own != address(0) ? _enc(own) : _computed(main), "the earlier build: own entry, else the key wallet");
        if (keccak256(n) != keccak256(o)) ++answersDiffer;
    }
}

// The build with a settable default and no computed answer against the build before it. For any walk that never
// saves coin type 0x80000000, both builds give the same result and revert data for every call, and the same logs and
// the same answer for every view but for addr, AddressChanged and AddrChanged on an EVM chain other than the home
// chain, through registrations, saves, moves, clears, subpages, time and code changes. Those answers and
// announcements differ only as DiffModel predicts.
contract DefaultDifferentialTest is DiffModel {
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address seven = makeAddr("seven");
    address relayer = makeAddr("relayer");
    address[5] actors;
    string[4] labels = ["alpha", "beta", "gamma", "delta"];

    uint256[7] coins = [uint256(60), 0x8000000a, 0x80000000, 0x80002105, 0x8000a4b1, 0x80000000 | 999_999, 0];

    function setUp() public {
        vm.warp(1_800_000_000);
        PageCard card = new PageCard();
        nft = new PageNFT(card);
        old = new PageNFTNoDefault(card);
        holder = new DiffHolder();
        vm.etch(seven, abi.encodePacked(hex"ef0100", address(new DiffCode())));
        actors = [alice, bob, seven, address(holder), relayer];
        for (uint256 i; i < 5; ++i) vm.deal(actors[i], 1000 ether);
    }

    function _views() internal {
        for (uint256 i; i < ids.length; ++i) {
            uint256 id = ids[i];
            for (uint256 c; c < coins.length; ++c) {
                if (coins[c] == COIN_OP || coins[c] == 0) assertEq(nft.addr(id, coins[c]), old.addr(id, coins[c]), "addr");
                else _evmAnswers(id, coins[c]);
            }
            assertEq(nft.resolve(id), old.resolve(id), "resolve");
            assertEq(nft.payee(id), old.payee(id), "payee");
            assertEq(nft.text(id, "url"), old.text(id, "url"), "text");
            assertEq(nft.contenthash(id), old.contenthash(id), "contenthash");
            assertEq(nft.recordVersion(id), old.recordVersion(id), "record version");
            assertEq(nft.profileWriter(id), old.profileWriter(id), "profile writer");
            (bool a, bytes memory oa) = address(nft).staticcall(abi.encodeWithSignature("ownerOf(uint256)", id));
            (bool b, bytes memory ob) = address(old).staticcall(abi.encodeWithSignature("ownerOf(uint256)", id));
            assertEq(a, b, "ownerOf success");
            assertEq(oa, ob, "ownerOf");
        }
        for (uint256 k; k < 5; ++k) {
            assertEq(nft.reverseResolve(actors[k]), old.reverseResolve(actors[k]), "display name");
            assertEq(nft.owed(actors[k]), old.owed(actors[k]), "owed");
        }
    }

    function _register(uint256 r) internal {
        string memory label = labels[r % 4];
        address to = actors[(r >> 8) % 5];
        bytes32 secret = keccak256(abi.encode(r));
        bytes32 c = nft.makeCommitment(label, to, 0, secret);
        _both(relayer, 0, abi.encodeCall(PageNFT.commit, (c)));
        vm.warp(vm.getBlockTimestamp() + 61);
        (,,, uint256 total) = nft.quote(label);
        if (_both(relayer, total, abi.encodeCall(PageNFT.reveal, (label, to, 0, secret)))) {
            ids.push(nft.computeId(label));
        }
    }

    function testFuzz_withoutADefaultOnlyTheComputedAnswerDiffers(uint256 seed) public {
        _register(seed);
        _register(seed >> 16);
        for (uint256 i; i < 24; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            uint256 step = r % 12;
            address caller = actors[(r >> 8) % 5];
            uint256 id = ids.length == 0 ? 0 : ids[(r >> 16) % ids.length];
            address v = actors[(r >> 24) % 5];
            if (step == 0) _register(r >> 32);
            else if (step == 1) _both(caller, 0, abi.encodeCall(PageNFT.setAddr, (id, (r >> 40) % 3 == 0 ? address(0) : v)));
            else if (step == 2) {
                uint256 coin = coins[(r >> 40) % 7];
                if (coin == 0x80000000) coin = 0x80002105;
                bytes memory val = (r >> 48) % 3 == 0 ? bytes("") : abi.encodePacked(v);
                _both(caller, 0, abi.encodeCall(PageNFT.setAddrForCoin, (id, coin, val)));
            } else if (step == 3) _both(caller, 0, abi.encodeCall(PageNFT.setText, (id, "url", vm.toString(r % 97))));
            else if (step == 4) {
                (bool exists, bytes memory o) = address(nft).staticcall(abi.encodeWithSignature("ownerOf(uint256)", id));
                address from = exists ? abi.decode(o, (address)) : alice;
                _both((r >> 40) % 4 == 0 ? caller : from, 0, abi.encodeCall(PageNFT.transferFrom, (from, v, id)));
            } else if (step == 5) _both(caller, 0, abi.encodeCall(PageNFT.clearRecords, (id)));
            else if (step == 6) _both(caller, 0, abi.encodeCall(PageNFT.keepProfile, (id)));
            else if (step == 7) {
                if (_both(caller, 0, abi.encodeCall(PageNFT.registerSubpageFor, ("sub", id, v)))) {
                    ids.push(uint256(keccak256(abi.encodePacked(bytes32(id), keccak256("sub")))));
                }
            } else if (step == 8) vm.warp(vm.getBlockTimestamp() + ((r >> 40) % 5 == 0 ? 400 days : 1 days));
            else if (step == 9) {
                // code appears at or leaves an account, the same for both builds; it can change what the earlier
                // build answers, never what src answers
                address a = (r >> 40) % 2 == 0 ? alice : bob;
                if (a.code.length == 0) vm.etch(a, type(DiffCode).runtimeCode);
                else vm.etch(a, "");
            } else if (step == 10) _both(caller, 0, abi.encodeCall(PageNFT.setPrimaryPage, (id)));
            else _both(caller, nft.getFee(5), abi.encodeCall(PageNFT.renew, (id)));
            _views();
        }
    }
}

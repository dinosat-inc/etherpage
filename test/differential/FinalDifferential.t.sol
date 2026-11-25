// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Vm} from "forge-std/Test.sol";
import {Base64} from "solady/utils/Base64.sol";
import {LibString} from "solady/utils/LibString.sol";
import {PageCard} from "../../src/PageCard.sol";
import {PageNFT} from "../../src/PageNFT.sol";
import {PageNFTNoDefault} from "./harness/PageNFTNoDefault.sol";
import {DiffHolder, DiffCode, DiffModel} from "./DefaultDifferential.t.sol";

// The build of src against the build before its three changes. PageNFTNoDefault is the source of commit 4a00e46 with
// its import path changed and the seven later changes of src ported to it: holderSince, addressesUpdatedAt, the
// deletion of every page the dead address holds, the subpage sentence of the metadata, data records, addr with no
// coin type answering coin type 60 with AddrChanged after AddressChanged, and render called without the payee, with
// tokenURI giving only a top level page a Length. It also has the shorter _formatEther of src, so the tokenURI
// comparison below does not test that code: test/unit/cards/FormatEtherSame.t.sol proves it gives the same text as
// the earlier code. So it is the build before the settable default, the refusal of the zero caller and the end of
// the computed answer. Every step runs on both builds with the same caller, and every difference is predicted:
// - a call from the zero address to transferFrom, safeTransferFrom, approve, registerSubpage or registerSubpageFor
//   never succeeds in src; it fails with the earlier build's revert data or with the guard's error,
// - setAddrForCoin with coin type 0x80000000 fails in the earlier build with CoinTypeNotSettable where src saves it,
//   and then every EVM chain but the home chain answers the holder's own entry, else that default, else nothing,
// - with no default saved, an EVM chain other than the home chain answers the holder's own entry, else nothing in
//   src, else the main address when it is a key wallet in the earlier build, and the AddressChanged of those chains,
//   the AddrChanged after coin type 60 and addr with no coin type differ in the same way, as DiffModel predicts.
// Every other call gives the same result, revert data and logs, and every view the same answer: name, symbol and
// tokenURI included, byte for byte. The zero caller and default steps run on a snapshot that is then reverted, so
// the two builds stay in the same state for the next step.
contract FinalDifferentialTest is DiffModel {
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address seven = makeAddr("seven");
    address relayer = makeAddr("relayer");
    address[5] actors;
    string[4] labels = ["alpha", "beta", "gamma", "delta"];

    uint256[7] coins = [uint256(60), COIN_OP, DEFAULT_EVM, 0x80002105, 0x8000a4b1, 0x80000000 | 999_999, 0];

    bytes4 constant NOT_OWNER_NOR_APPROVED = 0x4b6e7f18;
    bytes4 constant COIN_TYPE_NOT_SETTABLE = 0xb4c68276;

    // how often each predicted difference was seen, so the walk is not vacuous
    uint256 public zeroRefusedWhereOldAllowed;
    uint256 public zeroProbes;
    uint256 public defaultSaves;
    uint256 public defaultAnswersChanged;
    uint256 public uriChecks;

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

    // a guarded call from the zero address on a snapshot: src never lets it through, and where the earlier build
    // refuses it too, src refuses with the same data or with the guard's error
    function _zeroProbe(bytes memory data, bytes4 guardError) internal {
        uint256 snap = vm.snapshotState();
        vm.prank(address(0));
        (bool okNew, bytes memory rNew) = address(nft).call(data);
        vm.prank(address(0));
        (bool okOld, bytes memory rOld) = address(old).call(data);
        assertFalse(okNew, "the zero caller never gets through");
        if (okOld) {
            assertEq(rNew, abi.encodePacked(guardError), "refused by the guard");
        } else if (keccak256(rNew) != keccak256(rOld)) {
            assertEq(rNew, abi.encodePacked(guardError), "a different refusal is the guard's");
        }
        // the counters are written after the revert, which would undo them
        vm.revertToState(snap);
        ++zeroProbes;
        if (okOld) ++zeroRefusedWhereOldAllowed;
    }

    // the holder saves a default on a snapshot. The earlier build refuses it with CoinTypeNotSettable where src checks
    // the length and saves it, and src then answers by the rule for every coin type
    function _defaultProbe(address caller, uint256 id, bytes memory val) internal {
        uint256 snap = vm.snapshotState();
        (bool saved, uint256 changed) = _defaultSave(caller, id, val);
        // the counters are written after the revert, which would undo them
        vm.revertToState(snap);
        if (saved) ++defaultSaves;
        defaultAnswersChanged += changed;
    }

    // the save on both builds and the checks of the earlier build's refusal; on a save, the answers of src, and how
    // many of them the default changed
    function _defaultSave(address caller, uint256 id, bytes memory val) internal returns (bool saved, uint256 changed) {
        bytes memory data = abi.encodeCall(PageNFT.setAddrForCoin, (id, DEFAULT_EVM, val));
        bytes[] memory before = new bytes[](coins.length);
        for (uint256 i; i < coins.length; ++i) before[i] = nft.addr(id, coins[i]);
        vm.recordLogs();
        (bool okNew, bytes memory rNew) = _call(caller, address(nft), 0, data);
        Vm.Log[] memory lNew = vm.getRecordedLogs();
        (bool okOld, bytes memory rOld) = _call(caller, address(old), 0, data);
        assertFalse(okOld, "the earlier build never saves the default");
        if (keccak256(rOld) != keccak256(abi.encodePacked(COIN_TYPE_NOT_SETTABLE))) {
            // refused before the coin type was read: src refuses it the same way
            assertFalse(okNew);
            assertEq(rNew, rOld, "same refusal before the coin type");
            return (false, 0);
        }
        if (val.length != 0 && val.length != 20) {
            assertFalse(okNew);
            assertEq(rNew, abi.encodeWithSelector(PageNFT.InvalidLength.selector), "a wrong length");
            return (false, 0);
        }
        assertTrue(okNew, "src saves the default");
        address v = val.length == 0 ? address(0) : address(bytes20(val));
        address main = nft.resolve(id);
        assertEq(main, old.resolve(id), "the main address does not move");
        assertEq(nft.payee(id), old.payee(id), "the payee does not move");
        assertEq(lNew.length, 3, "two announcements, and AddrChanged after the one of coin type 60");
        assertEq(lNew[0].data, abi.encode(DEFAULT_EVM, _enc(v)));
        assertEq(lNew[2].topics[0], ADDR_CHANGED, "AddrChanged right after coin type 60");
        assertEq(lNew[2].topics[1], bytes32(id), "AddrChanged of the same name");
        for (uint256 i; i < coins.length; ++i) {
            bytes memory got = nft.addr(id, coins[i]);
            if (_answerChanged(id, coins[i], v, main, got, before[i])) ++changed;
            if (coins[i] == 60) {
                assertEq(lNew[1].data, abi.encode(uint256(60), got), "the coin type 60 announcement");
                assertEq(lNew[2].data, abi.encode(_addressOf(got)), "AddrChanged carries the coin type 60 answer");
            }
        }
        return (true, changed);
    }

    // after a save of the default v, the answer of src for one coin type by its rule, the unchanged answer of the
    // earlier build by its own rule, and whether the default changed the answer src gave before the save
    function _answerChanged(uint256 id, uint256 coin, address v, address main, bytes memory got, bytes memory before)
        internal
        view
        returns (bool)
    {
        bytes memory was = old.addr(id, coin);
        if (coin == COIN_OP || coin == 0) {
            assertEq(got, was, "the home chain and coins outside the EVM keep their answer");
            assertEq(got, before, "and src keeps it too");
            return false;
        }
        bool ownCounts;
        address own;
        if (coin != DEFAULT_EVM) {
            address s;
            (s, own) = _entry(address(nft), id, coin);
            ownCounts = s == nft.ownerOf(id) && own != address(0);
        }
        bytes memory want = ownCounts ? abi.encodePacked(own) : _enc(v);
        assertEq(got, want, "the answer rule");
        assertEq(was, ownCounts ? abi.encodePacked(own) : _computed(main), "the earlier build's answer rule");
        if (ownCounts || v == address(0)) assertEq(got, before, "unchanged where the default does not apply");
        return keccak256(got) != keccak256(before);
    }

    function _json(string memory uri) internal pure returns (string memory) {
        return string(Base64.decode(LibString.slice(uri, 29)));
    }

    // the token JSON of src is the earlier one, byte for byte. It is called as an external function of this test so
    // that its string work has a stack of its own
    function sameMetadata(uint256 id) external view {
        string memory jn = _json(nft.tokenURI(id));
        string memory jo = _json(old.tokenURI(id));
        assertEq(jn, jo, "tokenURI");
    }

    function _views(bool uris) internal {
        assertEq(nft.name(), "Etherpage");
        assertEq(old.name(), "Etherpage");
        assertEq(nft.symbol(), "ETHERPAGE");
        assertEq(old.symbol(), "ETHERPAGE");
        assertEq(nft.ROOT(), old.ROOT(), "the root stays");
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
            (bool ga, bytes memory gna) = address(nft).staticcall(abi.encodeWithSignature("getApproved(uint256)", id));
            (bool gb, bytes memory gnb) = address(old).staticcall(abi.encodeWithSignature("getApproved(uint256)", id));
            assertEq(ga, gb, "getApproved success");
            assertEq(gna, gnb, "getApproved");
            if (uris) {
                this.sameMetadata(id);
                ++uriChecks;
            }
        }
        for (uint256 k; k < 5; ++k) {
            assertEq(nft.reverseResolve(actors[k]), old.reverseResolve(actors[k]), "display name");
            assertEq(nft.owed(actors[k]), old.owed(actors[k]), "owed");
            assertEq(nft.balanceOf(actors[k]), old.balanceOf(actors[k]), "balance");
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

    function testFuzz_onlyThePlannedDifferences(uint256 seed) public {
        _register(seed);
        _register(seed >> 16);
        for (uint256 i; i < 24; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            uint256 step = r % 15;
            address caller = actors[(r >> 8) % 5];
            uint256 id = ids.length == 0 ? 0 : ids[(r >> 16) % ids.length];
            address v = actors[(r >> 24) % 5];
            (bool exists, bytes memory o) = address(nft).staticcall(abi.encodeWithSignature("ownerOf(uint256)", id));
            address from = exists ? abi.decode(o, (address)) : alice;
            if (step == 0) _register(r >> 32);
            else if (step == 1) _both(caller, 0, abi.encodeCall(PageNFT.setAddr, (id, (r >> 40) % 3 == 0 ? address(0) : v)));
            else if (step == 2) {
                uint256 coin = coins[(r >> 40) % 7];
                if (coin == DEFAULT_EVM) coin = 0x80002105;
                bytes memory val = (r >> 48) % 3 == 0 ? bytes("") : abi.encodePacked(v);
                _both(caller, 0, abi.encodeCall(PageNFT.setAddrForCoin, (id, coin, val)));
            } else if (step == 3) _both(caller, 0, abi.encodeCall(PageNFT.setText, (id, "url", vm.toString(r % 97))));
            else if (step == 4) {
                _both((r >> 40) % 4 == 0 ? caller : from, 0, abi.encodeCall(PageNFT.transferFrom, (from, v, id)));
            } else if (step == 5) _both(caller, 0, abi.encodeCall(PageNFT.clearRecords, (id)));
            else if (step == 6) _both(caller, 0, abi.encodeCall(PageNFT.keepProfile, (id)));
            else if (step == 7) {
                if (_both((r >> 40) % 2 == 0 ? caller : from, 0, abi.encodeCall(PageNFT.registerSubpageFor, ("sub", id, v)))) {
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
            else if (step == 11) _both(caller, nft.getFee(5), abi.encodeCall(PageNFT.renew, (id)));
            else if (step == 12) {
                // an approval or an operator, the same for both builds
                if ((r >> 40) % 2 == 0) _both(from, 0, abi.encodeCall(PageNFT.approve, ((r >> 48) % 3 == 0 ? address(0) : v, id)));
                else _both(caller, 0, abi.encodeWithSignature("setApprovalForAll(address,bool)", v, (r >> 48) % 2 == 0));
            } else if (step == 13) {
                uint256 k = (r >> 40) % 5;
                if (k == 0) _zeroProbe(abi.encodeCall(PageNFT.transferFrom, (from, v, id)), NOT_OWNER_NOR_APPROVED);
                else if (k == 1) _zeroProbe(abi.encodeWithSignature("safeTransferFrom(address,address,uint256)", from, v, id), NOT_OWNER_NOR_APPROVED);
                else if (k == 2) _zeroProbe(abi.encodeCall(PageNFT.approve, (v, id)), NOT_OWNER_NOR_APPROVED);
                else if (k == 3) _zeroProbe(abi.encodeCall(PageNFT.registerSubpageFor, ("zed", id, v)), PageNFT.NotParentOwner.selector);
                else _zeroProbe(abi.encodeCall(PageNFT.registerSubpage, ("zed", id)), PageNFT.NotParentOwner.selector);
            } else {
                uint256 len = (r >> 40) % 4;
                bytes memory val = len == 0 ? bytes("") : len == 3 ? abi.encodePacked(v, bytes1(0x01)) : abi.encodePacked(len == 1 ? v : address(0));
                _defaultProbe((r >> 48) % 4 == 0 ? caller : from, id, val);
            }
            _views(i % 6 == 5);
        }
        _views(true);
    }

    // A transfer that keeps the main address, where the holder's own entry for coin type 60 is that main address, a
    // key wallet. src announces that coin type 60 now answers nothing, since the entry is not the new holder's. The
    // earlier build answers the key wallet before and after, so it announces nothing
    function test_aTransferThatKeepsTheMainAddressAnnouncesOnlyAChangedAnswer() public {
        _register(0);
        uint256 id = ids[0];
        assertEq(nft.ownerOf(id), alice);
        _both(alice, 0, abi.encodeCall(PageNFT.setAddrForCoin, (id, 60, abi.encodePacked(bob))));
        _both(alice, 0, abi.encodeCall(PageNFT.setAddr, (id, bob)));
        _views(false);
        assertEq(nft.addr(id, 60), abi.encodePacked(bob), "src: the own entry");
        assertEq(old.addr(id, 60), abi.encodePacked(bob), "the earlier build: the own entry");
        _both(alice, 0, abi.encodeCall(PageNFT.transferFrom, (alice, bob, id)));
        assertEq(announcedByOneBuild, 1, "src alone announced coin type 60");
        assertEq(nft.resolve(id), bob, "the main address stays");
        assertEq(nft.addr(id, 60), "", "src: no entry of the new holder and no default");
        assertEq(old.addr(id, 60), abi.encodePacked(bob), "the earlier build: the main address is a key wallet");
        _views(true);
    }

    // one long walk with fixed seeds, which reports how often each planned difference showed
    function test_walksSeeEveryDifference() public {
        for (uint256 s = 1; s <= 12; ++s) {
            uint256 snap = vm.snapshotState();
            testFuzz_onlyThePlannedDifferences(uint256(keccak256(abi.encode("final", s))));
            uint256 a = zeroRefusedWhereOldAllowed;
            uint256 b = zeroProbes;
            uint256 c = defaultSaves;
            uint256 d = defaultAnswersChanged;
            uint256 e = uriChecks;
            uint256 f = answersDiffer;
            uint256 g = announcementsDiffer;
            uint256 h = announcedByOneBuild;
            vm.revertToState(snap);
            zeroRefusedWhereOldAllowed = a;
            zeroProbes = b;
            defaultSaves = c;
            defaultAnswersChanged = d;
            uriChecks = e;
            answersDiffer = f;
            announcementsDiffer = g;
            announcedByOneBuild = h;
            delete ids;
        }
        emit log_named_uint("zero caller probes", zeroProbes);
        emit log_named_uint("zero caller refused where the earlier build let it through", zeroRefusedWhereOldAllowed);
        emit log_named_uint("default saves", defaultSaves);
        emit log_named_uint("answers the default changed", defaultAnswersChanged);
        emit log_named_uint("tokenURI comparisons", uriChecks);
        emit log_named_uint("answers that differ by the answer rule", answersDiffer);
        emit log_named_uint("announcements of other EVM chains that differ", announcementsDiffer);
        emit log_named_uint("coin type 60 announcements in one build only", announcedByOneBuild);
        assertGt(zeroRefusedWhereOldAllowed, 0, "the guard refused something the earlier build allowed");
        assertGt(defaultSaves, 0, "a default was saved");
        assertGt(defaultAnswersChanged, 0, "a saved default changed an answer");
        assertGt(uriChecks, 0, "tokenURI was compared");
        assertGt(answersDiffer, 0, "an answer differed by the answer rule");
        assertGt(announcementsDiffer, 0, "an announcement differed by the answer rule");
    }
}

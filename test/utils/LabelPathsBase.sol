// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {trialCommitmentRaw} from "./TrialCommitment.sol";

import {Test} from "forge-std/Test.sol";
import {PageCard} from "../../src/PageCard.sol";
import {PageNFT} from "../../src/PageNFT.sol";
import {SubpageRegistrar, IPageNFT} from "../../src/SubpageRegistrar.sol";

// Every path a label can take. The view paths are normalize, quote, isAvailable as a top level name and
// under a live parent, makeCommitment and the registrar's makeSubpageCommitment. The write paths are
// reveal, revealTrial, PageNFT.registerSubpage and registerSubpageFor by the parent's holder, and the
// registrar's registerSubpage and registerSubpageFor under a parent with an open ETH sale, and its
// revealSubpage and revealSubpageFor under a parent whose sale needs commit and reveal. Every write starts
// from the same snapshot, in which the commitments of the label are already 61 seconds old.
abstract contract LabelPathsBase is Test {
    uint8 constant OK = 0;
    uint8 constant BAD_LENGTH = 1;
    uint8 constant BAD_NAME = 2;

    bytes32 constant ROOT = 0x62460c06d95b73747abf6ea4f28aefd78b4ad2abee112e7cf15fe6a924cca3c6;
    bytes32 constant SECRET = keccak256("label paths");
    string constant CLUB = "parentclub";
    string constant SHOP = "parentshop";

    PageNFT nft;
    SubpageRegistrar reg;
    address holder = makeAddr("holder");
    address buyer = makeAddr("buyer");
    address owner = makeAddr("owner");
    uint256 club;
    uint256 shop;
    uint256 snap;

    function setUp() public virtual {
        vm.warp(1_800_000_000);
        nft = new PageNFT(new PageCard());
        reg = new SubpageRegistrar(IPageNFT(address(nft)));
        vm.deal(holder, 1000 ether);
        vm.deal(buyer, 1000 ether);
        club = _registerParent(CLUB);
        shop = _registerParent(SHOP);
        vm.startPrank(holder);
        nft.setSubpageMinter(club, address(reg));
        reg.configure(club, holder, address(0), 0, true, address(0), 0, false);
        nft.setSubpageMinter(shop, address(reg));
        reg.configure(shop, holder, address(0), 0, true, address(0), 0, true);
        vm.stopPrank();
    }

    function _registerParent(string memory label) internal returns (uint256 id) {
        bytes32 c = nft.makeCommitment(label, holder, 0, SECRET);
        vm.prank(holder);
        nft.commit(c);
        vm.warp(vm.getBlockTimestamp() + 61);
        (,,, uint256 total) = nft.quote(label);
        vm.prank(holder);
        id = nft.reveal{value: total}(label, holder, 0, SECRET);
    }

    // the rule of the label as an independent model that shares no code with the contract
    function _model(bytes memory raw) internal pure returns (uint8 verdict, bytes memory low) {
        uint256 n = raw.length;
        if (n == 0 || n > 63) return (BAD_LENGTH, "");
        low = new bytes(n);
        for (uint256 i; i < n; ++i) {
            bytes1 c = raw[i];
            if (c >= "A" && c <= "Z") c = bytes1(uint8(c) + 32);
            if (!((c >= "a" && c <= "z") || (c >= "0" && c <= "9") || c == "-")) return (BAD_NAME, "");
            low[i] = c;
        }
        if (low[0] == "-" || low[n - 1] == "-") return (BAD_NAME, "");
        if (n >= 4 && low[2] == "-" && low[3] == "-") return (BAD_NAME, "");
        if (n == 42 && low[0] == "0" && low[1] == "x") {
            uint256 j = 2;
            while (j < 42 && ((low[j] >= "0" && low[j] <= "9") || (low[j] >= "a" && low[j] <= "f"))) ++j;
            if (j == 42) return (BAD_NAME, "");
        }
        verdict = OK;
    }

    // A to Z lowered, every other byte kept
    function _lower(bytes memory raw) internal pure returns (bytes memory out) {
        out = new bytes(raw.length);
        for (uint256 i; i < raw.length; ++i) {
            bytes1 c = raw[i];
            out[i] = (c >= "A" && c <= "Z") ? bytes1(uint8(c) + 32) : c;
        }
    }

    // a to z raised, every other byte kept
    function _upper(bytes memory raw) internal pure returns (bytes memory out) {
        out = new bytes(raw.length);
        for (uint256 i; i < raw.length; ++i) {
            bytes1 c = raw[i];
            out[i] = (c >= "a" && c <= "z") ? bytes1(uint8(c) - 32) : c;
        }
    }

    function _rep(bytes1 c, uint256 n) internal pure returns (bytes memory b) {
        b = new bytes(n);
        for (uint256 i; i < n; ++i) b[i] = c;
    }

    function _topId(bytes memory low) internal pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(ROOT, keccak256(low))));
    }

    function _subId(uint256 parent, bytes memory low) internal pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(bytes32(parent), keccak256(low))));
    }

    function _paidCommitment(bytes memory raw) internal view returns (bytes32) {
        return keccak256(abi.encode(_lower(raw), owner, uint256(0), SECRET));
    }

    function _trialCommitment(bytes memory raw) internal view returns (bytes32) {
        return trialCommitmentRaw(string(raw), owner, 0, SECRET);
    }

    function _subCommitment(bytes memory raw, address to) internal view returns (bytes32) {
        return keccak256(abi.encode(shop, string(_lower(raw)), to, SECRET));
    }

    function _err(uint8 verdict) internal pure returns (bytes4) {
        return verdict == BAD_LENGTH ? PageNFT.InvalidLength.selector : PageNFT.InvalidLabel.selector;
    }

    function _assertReverted(bool ok, bytes memory ret, bytes4 want, string memory path) internal pure {
        assertFalse(ok, path);
        assertEq(ret.length, 4, path);
        assertEq(bytes4(ret), want, path);
    }

    // commits every form of each label, built by hand over the lowered bytes so that refused labels
    // have commitments too, waits 61 seconds and takes the snapshot every write starts from
    function _prepare(bytes[] memory raws) internal {
        vm.startPrank(buyer);
        for (uint256 i; i < raws.length; ++i) {
            bytes32[4] memory cs = [
                _paidCommitment(raws[i]),
                _trialCommitment(raws[i]),
                _subCommitment(raws[i], owner),
                _subCommitment(raws[i], buyer)
            ];
            if (nft.commitments(cs[0]) == 0) nft.commit(cs[0]);
            if (nft.commitments(cs[1]) == 0) nft.commit(cs[1]);
            if (reg.subCommitments(cs[2]) == 0) reg.commitSubpage(cs[2]);
            if (reg.subCommitments(cs[3]) == 0) reg.commitSubpage(cs[3]);
        }
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + 61);
        snap = vm.snapshotState();
    }

    // the six view paths of one label against the expected verdict, from a state where the label is free
    function _viewPaths(bytes memory raw, uint8 want) internal view {
        string memory s = string(raw);
        bytes memory low = _lower(raw);
        (bool ok, bytes memory ret) = address(nft).staticcall(abi.encodeCall(PageNFT.normalize, (s)));
        if (want == OK) {
            assertTrue(ok, "normalize accepts");
            assertEq(bytes(abi.decode(ret, (string))), low, "normalize lowers A to Z only");
        } else {
            _assertReverted(ok, ret, _err(want), "normalize");
        }
        (uint256 fee, uint256 carried, uint256 premium, uint256 total) = nft.quote(s);
        if (want == OK) {
            assertEq(fee, nft.getFee(raw.length), "quote prices the length");
            assertEq(total, fee, "a free name costs its fee");
        } else {
            assertEq(fee + carried + premium + total, 0, "quote is four zeros");
        }
        assertEq(nft.isAvailable(s, 0), want == OK, "isAvailable as a top level name");
        assertEq(nft.isAvailable(s, club), want == OK, "isAvailable under a live parent");
        (ok, ret) = address(nft).staticcall(abi.encodeCall(PageNFT.makeCommitment, (s, owner, 0, SECRET)));
        if (want == OK) {
            assertTrue(ok, "makeCommitment accepts");
            assertEq(abi.decode(ret, (bytes32)), _paidCommitment(raw), "makeCommitment hashes the lowered bytes");
        } else {
            _assertReverted(ok, ret, _err(want), "makeCommitment");
        }
        (ok, ret) = address(reg).staticcall(
            abi.encodeCall(SubpageRegistrar.makeSubpageCommitment, (shop, s, owner, SECRET))
        );
        if (want == OK) {
            assertTrue(ok, "makeSubpageCommitment accepts");
            assertEq(abi.decode(ret, (bytes32)), _subCommitment(raw, owner), "makeSubpageCommitment hashes the lowered bytes");
        } else {
            _assertReverted(ok, ret, _err(want), "makeSubpageCommitment");
        }
    }

    // the eight write paths of one label, each from the snapshot
    function _writePaths(bytes memory raw, uint8 want) internal {
        for (uint256 p; p < 8; ++p) {
            vm.revertToState(snap);
            _writePath(raw, want, p);
        }
        vm.revertToState(snap);
    }

    function _writePath(bytes memory raw, uint8 want, uint256 p) internal {
        string memory s = string(raw);
        uint256 fee = want == OK ? nft.getFee(raw.length) : 1 ether;
        address to = owner;
        bool ok;
        bytes memory ret;
        if (p == 0) {
            vm.prank(buyer);
            (ok, ret) = address(nft).call{value: fee}(abi.encodeCall(PageNFT.reveal, (s, owner, 0, SECRET)));
        } else if (p == 1) {
            vm.prank(buyer);
            (ok, ret) = address(nft).call{value: fee / 10}(abi.encodeCall(PageNFT.revealTrial, (s, owner, 0, SECRET)));
        } else if (p == 2) {
            to = holder;
            vm.prank(holder);
            (ok, ret) = address(nft).call(abi.encodeCall(PageNFT.registerSubpage, (s, club)));
        } else if (p == 3) {
            vm.prank(holder);
            (ok, ret) = address(nft).call(abi.encodeCall(PageNFT.registerSubpageFor, (s, club, owner)));
        } else if (p == 4) {
            to = buyer;
            vm.prank(buyer);
            (ok, ret) = address(reg).call(abi.encodeCall(SubpageRegistrar.registerSubpage, (club, s, 0, address(0))));
        } else if (p == 5) {
            vm.prank(buyer);
            (ok, ret) = address(reg).call(
                abi.encodeCall(SubpageRegistrar.registerSubpageFor, (club, s, owner, 0, address(0)))
            );
        } else if (p == 6) {
            to = buyer;
            vm.prank(buyer);
            (ok, ret) = address(reg).call(
                abi.encodeCall(SubpageRegistrar.revealSubpage, (shop, s, SECRET, 0, address(0)))
            );
        } else {
            vm.prank(buyer);
            (ok, ret) = address(reg).call(
                abi.encodeCall(SubpageRegistrar.revealSubpageFor, (shop, s, owner, SECRET, 0, address(0)))
            );
        }
        if (want != OK) {
            // the registrar's direct path first checks the label with isAvailable, which answers false for a
            // refused label, so it reverts with NotAvailable; every other path normalizes first
            bytes4 e = (p == 4 || p == 5) ? SubpageRegistrar.NotAvailable.selector : _err(want);
            _assertReverted(ok, ret, e, "a refused label is refused on every write path");
            return;
        }
        assertTrue(ok, "an accepted label is written on every write path");
        bytes memory low = _lower(raw);
        uint256 parent = p < 2 ? 0 : p < 6 ? club : shop;
        uint256 id = parent == 0 ? _topId(low) : _subId(parent, low);
        assertEq(abi.decode(ret, (uint256)), id, "the id of the lowered bytes");
        (string memory stored,,,,) = nft.records(id);
        assertEq(bytes(stored), low, "stored in lower case");
        assertEq(nft.ownerOf(id), to, "minted to the named account");
        string memory full = parent == 0 ? string(low) : string.concat(string(low), ".", parent == club ? CLUB : SHOP);
        assertEq(nft.getPageName(id), full, "getPageName gives the lowered bytes");
        assertEq(nft.computeId(full), id, "computeId of the full name");
        assertFalse(nft.isAvailable(s, parent), "taken in the spelling used");
        assertFalse(nft.isAvailable(string(low), parent), "taken in lower case");
        assertFalse(nft.isAvailable(string(_upper(raw)), parent), "taken in upper case");
    }

    // a label on all fourteen paths
    function _everyPath(bytes memory raw, uint8 want) internal {
        vm.revertToState(snap);
        _viewPaths(raw, want);
        _writePaths(raw, want);
    }
}

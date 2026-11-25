// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {Base64} from "solady/utils/Base64.sol";
import {LibString} from "solady/utils/LibString.sol";
import {PageCard} from "../src/PageCard.sol";
import {PageNFT} from "../src/PageNFT.sol";
import {DepositHarness} from "./DepositProofs.t.sol";

/// @notice Symbolic proofs that status equals the Status the metadata shows, and the self referral
/// rule for every label of three bytes.
/// Halmos: FOUNDRY_PROFILE=proofs halmos --contract StatusProofsTest --function check_ --forge-build-out out-proofs --loop 4 --storage-layout generic
contract StatusProofsTest is Test {
    DepositHarness n;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address constant HOLDER = address(0xB0B);
    address constant OTHER = address(0xC0FFEE);
    bytes32 constant ROOT = 0x62460c06d95b73747abf6ea4f28aefd78b4ad2abee112e7cf15fe6a924cca3c6;
    uint64 constant EXP = 1_800_000_000;
    uint256 id;
    uint256 sub;

    function setUp() public {
        n = new DepositHarness(new PageCard());
        id = uint256(keccak256(abi.encodePacked(ROOT, keccak256(bytes("alpha")))));
        sub = uint256(keccak256(abi.encodePacked(bytes32(id), keccak256(bytes("x")))));
    }

    // the metadata JSON inside tokenURI
    function _json(uint256 tokenId) internal view returns (string memory) {
        bytes memory u = bytes(n.tokenURI(tokenId));
        uint256 skip = bytes("data:application/json;base64,").length;
        bytes memory b64 = new bytes(u.length - skip);
        for (uint256 i; i < b64.length; ++i) b64[i] = u[skip + i];
        return string(Base64.decode(string(b64)));
    }

    // the Status value inside the metadata JSON
    function _metaStatus(string memory json) internal pure returns (string memory) {
        string memory marker = '"trait_type":"Status","value":"';
        uint256 at = LibString.indexOf(json, marker);
        assert(at != LibString.NOT_FOUND);
        uint256 start = at + bytes(marker).length;
        uint256 end = LibString.indexOf(json, '"', start);
        return LibString.slice(json, start, end);
    }

    function _name(PageCard.Status s) internal pure returns (string memory) {
        if (s == PageCard.Status.Active) return "Active";
        if (s == PageCard.Status.Grace) return "Grace";
        if (s == PageCard.Status.Expired) return "Expired";
        if (s == PageCard.Status.Invalid) return "Invalid";
        return "Trial";
    }

    function _eq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    // a time long before the expiry, the seconds around the expiry and around the end of the 90 day
    // grace period, or one far after: the metadata is built from concrete values on each path, since
    // a symbolic index into the status names is not followed
    function _time(uint8 k) internal pure returns (uint256) {
        uint8 m = k % 7;
        if (m == 0) return 1000;
        if (m == 1) return uint256(EXP) - 1;
        if (m == 2) return EXP;
        if (m == 3) return uint256(EXP) + 1;
        if (m == 4) return uint256(EXP) + 90 days;
        if (m == 5) return uint256(EXP) + 90 days + 1;
        return uint256(EXP) + 5000 days;
    }

    /// @notice FS1: for a top level name with no deposit, a small or a large deposit, and any held
    /// trial money, at every instant where the status changes, status equals the Status in the
    /// metadata, and it follows the rule: Trial while live with no deposit, Active while live with one,
    /// Grace up to the grace end, Expired after it.
    function check_FS1_topLevelStatusIsMetadata(uint8 depKind, uint96 held, uint8 tPick) public {
        _fs1(depKind % 3, held, tPick);
    }

    /// @notice FS1 split by the deposit so each part finishes: a no deposit, b a small one, c a large one.
    function check_FS1a(uint96 held, uint8 tPick) public {
        _fs1(0, held, tPick);
    }

    function check_FS1b(uint8 tPick) public {
        _fs1(1, 0, tPick);
    }

    function check_FS1c(uint8 tPick) public {
        _fs1(2, 0, tPick);
    }

    function _fs1(uint8 k, uint96 held, uint8 tPick) internal {
        uint256 t = _time(tPick);
        uint256 dep = k == 0 ? 0 : k == 1 ? 0.0001 ether : 1.2345 ether;
        vm.assume(dep == 0 || held == 0);
        n.h_setRecord(id, "alpha", 0, EXP, 3, 0);
        n.h_mint(HOLDER, id);
        n.h_setDeposit(id, dep);
        n.h_setHeld(id, OTHER, held);
        vm.warp(t);
        PageCard.Status s = n.status(id);
        assert(_eq(_metaStatus(_json(id)), _name(s)));
        uint256 graceEnd = dep == 0 ? uint256(EXP) : uint256(EXP) + 90 days;
        if (t <= EXP) assert(s == (dep == 0 ? PageCard.Status.Trial : PageCard.Status.Active));
        else if (t <= graceEnd) assert(s == PageCard.Status.Grace);
        else assert(s == PageCard.Status.Expired);
    }

    /// @notice FS1d: a top level name DEAD holds, with no deposit, a small or a large deposit and any held
    /// trial money, shows Invalid in status and in the metadata at any time. The metadata does not read
    /// the time once the name is Invalid, so the time stays symbolic here.
    function check_FS1d_deadHeldTopLevelIsInvalid(uint8 depKind, uint96 held, uint64 t) public {
        uint8 k = depKind % 3;
        uint256 dep = k == 0 ? 0 : k == 1 ? 0.0001 ether : 1.2345 ether;
        vm.assume(dep == 0 || held == 0);
        n.h_setRecord(id, "alpha", 0, EXP, 3, 0);
        n.h_mint(DEAD, id);
        n.h_setDeposit(id, dep);
        n.h_setHeld(id, OTHER, held);
        vm.warp(t);
        PageCard.Status s = n.status(id);
        assert(s == PageCard.Status.Invalid);
        assert(_eq(_metaStatus(_json(id)), "Invalid"));
    }

    /// @notice FS2: for a subpage that is live, stale (its parent registered again) or deleted (held by
    /// DEAD), under a paid parent or one with no deposit, at every instant where the status changes,
    /// status equals the Status in the metadata, a subpage is never Trial, and the metadata name is
    /// the full name in every state.
    function check_FS2_subpageStatusIsMetadata(bool stale, bool deleted, bool parentPaid, uint8 tPick) public {
        _fs2(stale, deleted, parentPaid, tPick);
    }

    /// @notice FS2 split by the state so each part finishes: a live under a paid parent, b stale and
    /// not deleted, c deleted and not stale, d live under a parent with no deposit. A subpage both
    /// stale and deleted is in no part, only in FS2 itself.
    function check_FS2a(uint8 tPick) public {
        _fs2(false, false, true, tPick);
    }

    function check_FS2b(bool parentPaid, uint8 tPick) public {
        _fs2(true, false, parentPaid, tPick);
    }

    function check_FS2c(bool parentPaid, uint8 tPick) public {
        _fs2(false, true, parentPaid, tPick);
    }

    function check_FS2d(uint8 tPick) public {
        _fs2(false, false, false, tPick);
    }

    function _fs2(bool stale, bool deleted, bool parentPaid, uint8 tPick) internal {
        uint256 t = _time(tPick);
        n.h_setRecord(id, "alpha", 0, EXP, 3, 0);
        n.h_mint(HOLDER, id);
        n.h_setDeposit(id, parentPaid ? 0.0001 ether : 0);
        n.h_setRecord(sub, "x", id, 0, 1, stale ? 2 : 3);
        n.h_mint(deleted ? DEAD : OTHER, sub);
        vm.warp(t);
        PageCard.Status s = n.status(sub);
        string memory json = _json(sub);
        assert(_eq(_metaStatus(json), _name(s)));
        assert(LibString.indexOf(json, '{"name":"x.alpha"') == 0);
        assert(s != PageCard.Status.Trial);
        if (stale || deleted) assert(s == PageCard.Status.Invalid);
        else if (t <= EXP) assert(s == PageCard.Status.Active);
        else if (t <= uint256(EXP) + 90 days) assert(s == PageCard.Status.Grace);
        else assert(s == PageCard.Status.Expired);
    }

    /// @notice FS3: for any id with no record, at any time, status and tokenURI both revert with
    /// TokenDoesNotExist, with a name and a subpage in place.
    function check_FS3_statusRevertsExactlyWithMetadata(uint256 other, uint256 t) public {
        vm.assume(t < 2 ** 40);
        vm.assume(other != id && other != sub);
        n.h_setRecord(id, "alpha", 0, EXP, 3, 0);
        n.h_mint(HOLDER, id);
        n.h_setRecord(sub, "x", id, 0, 1, 3);
        n.h_mint(OTHER, sub);
        vm.warp(t);
        (bool okS, bytes memory rs) = address(n).call(abi.encodeCall(PageNFT.status, (other)));
        (bool okU, bytes memory ru) = address(n).call(abi.encodeWithSignature("tokenURI(uint256)", other));
        assert(!okS && !okU);
        assert(bytes4(rs) == bytes4(keccak256("TokenDoesNotExist()")));
        assert(keccak256(rs) == keccak256(ru));
    }

    // a dot would make computeId read two labels; label checks refuse a dot anyway
    function _noDot(bytes3 raw) internal pure {
        vm.assume(raw[0] != 0x2e && raw[1] != 0x2e && raw[2] != 0x2e);
    }

    /// @notice RF1: makeCommitment refuses a name as its own referrer for every label of three bytes,
    /// every owner and every secret: it reverts SelfReferral for a valid label, in any letter case, and
    /// InvalidLabel otherwise.
    function check_RF1_makeCommitmentRefusesSelf(bytes3 raw, address owner, bytes32 secret) public view {
        _noDot(raw);
        string memory label = string(abi.encodePacked(raw));
        uint256 self = n.computeId(label);
        (bool okN,) = address(n).staticcall(abi.encodeCall(PageNFT.normalize, (label)));
        (bool ok, bytes memory ret) =
            address(n).staticcall(abi.encodeCall(PageNFT.makeCommitment, (label, owner, self, secret)));
        assert(!ok);
        if (okN) assert(bytes4(ret) == PageNFT.SelfReferral.selector);
        else assert(bytes4(ret) == PageNFT.InvalidLabel.selector);
    }

    /// @notice RF2s: reveal and revealTrial revert SelfReferral when a name is its own referrer, for
    /// every valid label of three bytes, every owner, any value up to 100 ether and any time, with a
    /// commitment built by hand in either form.
    function check_RF2s_revealRefusesSelf(bytes3 raw, address owner, uint256 value, uint256 t, bool trial) public {
        vm.assume(t < 2 ** 40 && t > 100 && value <= 100 ether);
        _noDot(raw);
        string memory label = string(abi.encodePacked(raw));
        uint256 self = n.computeId(label);
        (bool okN, bytes memory nret) = address(n).staticcall(abi.encodeCall(PageNFT.normalize, (label)));
        vm.assume(okN);
        bytes memory normalized = bytes(abi.decode(nret, (string)));
        bytes32 c = keccak256(abi.encode(normalized, owner, self, bytes32("s")));
        n.h_setCommitment(trial ? keccak256(abi.encode(normalized, owner, self, bytes32("s"), true)) : c, t - 61);
        vm.deal(OTHER, value);
        vm.warp(t);
        vm.prank(OTHER);
        (bool ok, bytes memory ret) = trial
            ? address(n).call{value: value}(abi.encodeCall(PageNFT.revealTrial, (label, owner, self, bytes32("s"))))
            : address(n).call{value: value}(abi.encodeCall(PageNFT.reveal, (label, owner, self, bytes32("s"))));
        assert(!ok);
        assert(bytes4(ret) == PageNFT.SelfReferral.selector);
    }
}

// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {PageCard} from "../src/PageCard.sol";
import {PageNFT} from "../src/PageNFT.sol";
import {ClearHarnessA, ClearHarnessB} from "./ClearPrimaryHarness.sol";

/// @notice Symbolic proofs that a transfer clears the sender's display name pointer when that
/// pointer names the moved id. World a is the PageNFTMulticall reference build, world b is src.
/// Both get the same symbolic start state through the harness, except that only the top level name
/// in b starts with a deposit of 1, which a never reads in CP1 to CP3; CP3r and CP3t then give both
/// the same deposit, and in CP3t only b holds trial money for a payer. Each proof states exactly
/// where b may differ from a: the sender's pointer of a transfer between two different accounts,
/// only when it names the moved id, where b stores zero, and in CP3t the held trial money, which b
/// credits to its payer when the registration succeeds.
/// Halmos: FOUNDRY_PROFILE=proofs halmos --contract ClearPrimaryProofsTest --function test_check_CP --forge-build-out out-proofs --loop 4 --storage-layout generic
contract ClearPrimaryProofsTest is Test {
    PageCard card;
    ClearHarnessA a;
    ClearHarnessB b;

    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address constant OWNER = address(0xA11CE);
    address constant HOLDER = address(0xB0B);
    address constant OTHER = address(0xC0FFEE);
    address constant NEAR = address(0xdEaE);
    address constant OPR = address(0x0FE2);
    address constant MINTER = address(0x3117);
    uint256 constant COIN_OP = 0x8000000a;
    bytes32 constant ROOT = 0x62460c06d95b73747abf6ea4f28aefd78b4ad2abee112e7cf15fe6a924cca3c6;

    uint256 pid;
    uint256 sub;

    function setUp() public {
        card = new PageCard();
        a = new ClearHarnessA(card);
        b = new ClearHarnessB(card);
        pid = uint256(keccak256(abi.encodePacked(ROOT, keccak256(bytes("club")))));
        sub = uint256(keccak256(abi.encodePacked(bytes32(pid), keccak256(bytes("fresh")))));
    }

    function _pick(uint8 p) internal pure returns (address) {
        uint8 k = p % 5;
        if (k == 0) return DEAD;
        if (k == 1) return HOLDER;
        if (k == 2) return OWNER;
        if (k == 3) return NEAR;
        return OTHER;
    }

    function _world(uint64 exp, uint64 epoch, uint64 pe, address pHolder, address holder) internal {
        a.h_setRecord(pid, "club", 0, exp, epoch, 0);
        b.h_setRecord(pid, "club", 0, exp, epoch, 0);
        a.h_mint(pHolder, pid);
        b.h_mint(pHolder, pid);
        a.h_setRecord(sub, "fresh", pid, 0, 1, pe);
        b.h_setRecord(sub, "fresh", pid, 0, 1, pe);
        a.h_mint(holder, sub);
        b.h_mint(holder, sub);
        a.h_setProfile(sub);
        b.h_setProfile(sub);
    }

    function _ptr(address x, uint256 v) internal {
        a.h_setPrimary(x, v);
        b.h_setPrimary(x, v);
    }

    function _eqS(string memory x, string memory y) internal pure returns (bool) {
        return keccak256(bytes(x)) == keccak256(bytes(y));
    }

    function _xfer(uint8 kind, address from, address to, uint256 id) internal pure returns (bytes memory) {
        uint8 k = kind % 3;
        if (k == 0) return abi.encodeWithSignature("transferFrom(address,address,uint256)", from, to, id);
        if (k == 1) return abi.encodeWithSignature("safeTransferFrom(address,address,uint256)", from, to, id);
        return abi.encodeWithSignature("safeTransferFrom(address,address,uint256,bytes)", from, to, id, hex"01");
    }

    /// @notice CP1: every transfer (the three functions, by the holder, an approved account, an
    /// operator or anyone, to DEAD, another account or the holder itself) succeeds in src exactly when
    /// it succeeds in the reference build, with the same return or revert data and the same holder,
    /// main address and payee. The sender's pointer becomes zero in src exactly when the transfer
    /// succeeds, the recipient differs from the sender and the pointer named the moved id; it is
    /// otherwise the same in both worlds. The recipient's pointer and the pointer of every other
    /// account (any address, any stored value) are the same in both worlds and unchanged.
    /// reverseResolve of the sender is empty in src when cleared and equal otherwise.
    /// @dev Technique: symbolic differential of the write path. Classification: DIRECT.
    function test_check_CP1_transfers(
        uint64 exp, uint64 epoch, uint64 pe, uint64 ts, uint8 hPick, uint8 cPick, uint8 tPick, uint8 kind,
        bool top, bool approved, bool operator, uint8 pk, uint256 pHv, uint256 pTv, address y, uint256 pYv
    ) public {
        _cp1(exp, epoch, pe, ts, hPick, cPick, tPick, kind, top, approved, operator, pk, pHv, pTv, y, pYv);
    }

    /// @notice CP1x: CP1 with the transfer function and the kind of name fixed per proof, so each
    /// finishes. x0 transferFrom, x1 safeTransferFrom, x2 safeTransferFrom with data; t a top level
    /// name, s a subpage.
    function test_check_CP1x0t(uint64 exp, uint64 epoch, uint64 pe, uint64 ts, uint8 hPick, uint8 cPick, uint8 tPick,
        bool approved, bool operator, uint8 pk, uint256 pHv, uint256 pTv, address y, uint256 pYv) public {
        _cp1(exp, epoch, pe, ts, hPick, cPick, tPick, 0, true, approved, operator, pk, pHv, pTv, y, pYv);
    }

    function test_check_CP1x0s(uint64 exp, uint64 epoch, uint64 pe, uint64 ts, uint8 hPick, uint8 cPick, uint8 tPick,
        bool approved, bool operator, uint8 pk, uint256 pHv, uint256 pTv, address y, uint256 pYv) public {
        _cp1(exp, epoch, pe, ts, hPick, cPick, tPick, 0, false, approved, operator, pk, pHv, pTv, y, pYv);
    }

    function test_check_CP1x1t(uint64 exp, uint64 epoch, uint64 pe, uint64 ts, uint8 hPick, uint8 cPick, uint8 tPick,
        bool approved, bool operator, uint8 pk, uint256 pHv, uint256 pTv, address y, uint256 pYv) public {
        _cp1(exp, epoch, pe, ts, hPick, cPick, tPick, 1, true, approved, operator, pk, pHv, pTv, y, pYv);
    }

    function test_check_CP1x1s(uint64 exp, uint64 epoch, uint64 pe, uint64 ts, uint8 hPick, uint8 cPick, uint8 tPick,
        bool approved, bool operator, uint8 pk, uint256 pHv, uint256 pTv, address y, uint256 pYv) public {
        _cp1(exp, epoch, pe, ts, hPick, cPick, tPick, 1, false, approved, operator, pk, pHv, pTv, y, pYv);
    }

    function test_check_CP1x2t(uint64 exp, uint64 epoch, uint64 pe, uint64 ts, uint8 hPick, uint8 cPick, uint8 tPick,
        bool approved, bool operator, uint8 pk, uint256 pHv, uint256 pTv, address y, uint256 pYv) public {
        _cp1(exp, epoch, pe, ts, hPick, cPick, tPick, 2, true, approved, operator, pk, pHv, pTv, y, pYv);
    }

    function test_check_CP1x2s(uint64 exp, uint64 epoch, uint64 pe, uint64 ts, uint8 hPick, uint8 cPick, uint8 tPick,
        bool approved, bool operator, uint8 pk, uint256 pHv, uint256 pTv, address y, uint256 pYv) public {
        _cp1(exp, epoch, pe, ts, hPick, cPick, tPick, 2, false, approved, operator, pk, pHv, pTv, y, pYv);
    }

    function _cp1(
        uint64 exp, uint64 epoch, uint64 pe, uint64 ts, uint8 hPick, uint8 cPick, uint8 tPick, uint8 kind,
        bool top, bool approved, bool operator, uint8 pk, uint256 pHv, uint256 pTv, address y, uint256 pYv
    ) internal {
        address holder = _pick(hPick);
        uint256 id = top ? pid : sub;
        _world(exp, epoch, pe, top ? holder : OWNER, top ? OWNER : holder);
        uint8 ck = cPick % 3;
        address caller = ck == 0 ? holder : ck == 1 ? OPR : DEAD;
        uint8 tk = tPick % 4;
        address to = tk == 0 ? DEAD : tk == 1 ? OTHER : tk == 2 ? NEAR : holder;
        if (approved) {
            a.h_approve(OPR, id);
            b.h_approve(OPR, id);
        }
        if (operator) {
            a.h_setApprovalForAll(holder, OPR, true);
            b.h_setApprovalForAll(holder, OPR, true);
        }
        _ptr(y, pYv);
        _ptr(to, pTv);
        uint8 p = pk % 3;
        _ptr(holder, p == 0 ? id : p == 1 ? (top ? sub : pid) : pHv);
        uint256 preH = a.primaryPage(holder);
        uint256 preT = a.primaryPage(to);
        uint256 preY = a.primaryPage(y);
        vm.warp(ts);

        bytes memory data = _xfer(kind, holder, to, id);
        vm.prank(caller);
        (bool okA, bytes memory rA) = address(a).call(data);
        vm.prank(caller);
        (bool okB, bytes memory rB) = address(b).call(data);
        assert(okA == okB);
        assert(keccak256(rA) == keccak256(rB));
        assert(b.h_ownerOf(id) == a.h_ownerOf(id));
        assert(b.resolve(id) == a.resolve(id));
        assert(b.payee(id) == a.payee(id));

        bool cleared = okB && to != holder && preH == id;
        assert(a.primaryPage(holder) == preH);
        assert(b.primaryPage(holder) == (cleared ? 0 : preH));
        if (to != holder) assert(a.primaryPage(to) == preT && b.primaryPage(to) == preT);
        if (y != holder) assert(a.primaryPage(y) == preY && b.primaryPage(y) == preY);
        if (cleared) assert(bytes(b.reverseResolve(holder)).length == 0);
        else assert(_eqS(b.reverseResolve(holder), a.reverseResolve(holder)));
    }

    /// @notice CP2: after the holder sells a name it showed as its display name, no single call by
    /// any other account, of ten kinds (pointing the name back at the seller, with or without a
    /// bundle, saving any main address, clearing records, choosing any display name, sending the name
    /// back to the seller, minting the subpage again to the seller, approvals), gives the seller its
    /// pointer or its reverse name back in src. The reference build keeps the pointer, so the proof
    /// is not vacuous.
    /// @dev Technique: symbolic dispatcher after a symbolic sale. Classification: DIRECT.
    function test_check_CP2_onlySellerRestores(
        uint64 exp, uint64 epoch, uint64 pe, uint64 ts, bool top, uint8 kind, bool pointBack, uint8 which,
        address caller, address y, uint256 x
    ) public {
        uint256 id = top ? pid : sub;
        _world(exp, epoch, pe, top ? HOLDER : OWNER, top ? OWNER : HOLDER);
        _ptr(HOLDER, id);
        vm.warp(ts);
        bytes memory sale = _xfer(kind, HOLDER, OTHER, id);
        vm.prank(HOLDER);
        (bool okA,) = address(a).call(sale);
        vm.prank(HOLDER);
        (bool okB,) = address(b).call(sale);
        assert(okA == okB);
        if (!okB) {
            assert(b.primaryPage(HOLDER) == id);
            return;
        }
        assert(a.primaryPage(HOLDER) == id);
        assert(b.primaryPage(HOLDER) == 0);
        if (pointBack) {
            vm.prank(OTHER);
            (bool okP,) = address(b).call(abi.encodeWithSignature("setAddr(uint256,address)", id, HOLDER));
            okP;
        }
        // Justification: no transaction or call has msg.sender == address(0), and only the seller
        // itself may choose its display name
        vm.assume(caller != HOLDER && caller != address(0));
        uint8 w = which % 10;
        bytes memory d;
        if (w == 0) d = abi.encodeWithSignature("setAddr(uint256,address)", id, y);
        else if (w == 1) d = abi.encodeCall(PageNFT.setAddrForCoin, (id, COIN_OP, abi.encodePacked(y)));
        else if (w == 2) d = abi.encodeCall(PageNFT.setPrimaryPage, (x));
        else if (w == 3) d = abi.encodeCall(PageNFT.clearRecords, (id));
        else if (w == 4) d = abi.encodeWithSignature("transferFrom(address,address,uint256)", OTHER, HOLDER, id);
        else if (w == 5) d = abi.encodeWithSignature("safeTransferFrom(address,address,uint256)", OTHER, HOLDER, id);
        else if (w == 6) d = abi.encodeCall(PageNFT.registerSubpageFor, ("fresh", pid, HOLDER));
        else if (w == 7) {
            bytes[] memory inner = new bytes[](1);
            inner[0] = abi.encodeWithSignature("setAddr(uint256,address)", id, HOLDER);
            d = abi.encodeCall(PageNFT.multicall, (inner));
        } else if (w == 8) d = abi.encodeWithSignature("approve(address,uint256)", y, id);
        else d = abi.encodeWithSignature("setApprovalForAll(address,bool)", y, true);
        vm.prank(caller);
        (bool ok,) = address(b).call(d);
        ok;
        assert(b.primaryPage(HOLDER) == 0);
        assert(bytes(b.reverseResolve(HOLDER)).length == 0);
    }

    /// @notice CP3: a subpage mint by the parent's holder, its counted minter or anyone else, over a
    /// subpage any account holds (DEAD included), succeeds in src exactly when it does in the
    /// reference build, with the same revert data, and leaves the same holder, version, epoch and
    /// pointers: the old holder's, the recipient's, DEAD's and any other account's.
    /// @dev Technique: symbolic differential of the write path. Classification: DIRECT.
    function test_check_CP3_mintsSame(
        uint64 exp, uint64 epoch, uint64 pe, uint64 ts, uint8 hPick, uint8 cPick, uint8 tPick, bool counted,
        bool pointer, uint256 pTv, address y, uint256 pYv
    ) public {
        address holder = _pick(hPick);
        address to = _pick(tPick);
        uint8 k = cPick % 3;
        address caller = k == 0 ? OWNER : k == 1 ? MINTER : OTHER;
        _world(exp, epoch, pe, OWNER, holder);
        a.h_setMinter(pid, MINTER, counted ? epoch : epoch ^ 1, OWNER);
        b.h_setMinter(pid, MINTER, counted ? epoch : epoch ^ 1, OWNER);
        _ptr(y, pYv);
        _ptr(to, pTv);
        if (pointer) _ptr(holder, sub);
        vm.warp(ts);
        bytes memory d = abi.encodeCall(PageNFT.registerSubpageFor, ("fresh", pid, to));
        vm.prank(caller);
        (bool okA, bytes memory rA) = address(a).call(d);
        vm.prank(caller);
        (bool okB, bytes memory rB) = address(b).call(d);
        assert(okA == okB);
        assert(keccak256(rA) == keccak256(rB));
        assert(b.h_ownerOf(sub) == a.h_ownerOf(sub));
        assert(b.recordVersion(sub) == a.recordVersion(sub));
        assert(b.epochOf(sub) == a.epochOf(sub));
        assert(b.primaryPage(holder) == a.primaryPage(holder));
        assert(b.primaryPage(to) == a.primaryPage(to));
        assert(b.primaryPage(DEAD) == a.primaryPage(DEAD));
        assert(b.primaryPage(y) == a.primaryPage(y));
    }

    /// @notice CP3r: a registration over an existing top level name (any holder, DEAD included, any
    /// nonzero deposit and any epoch) succeeds in src exactly when it does in the reference
    /// build, with the same revert data, and leaves the same holder and pointers: the old holder's,
    /// the new holder's and any other account's. Time is one of three windows around the symbolic
    /// expiry (last second of grace, first second of the premium, first second release allows) and
    /// the commitment is ripe, too new or missing.
    /// @dev Technique: symbolic differential of the write path with time in fixed windows. Classification: DIRECT.
    function test_check_CP3r_reRegistrationSame(
        uint64 exp, uint64 epoch, uint8 when, uint8 cwhen, uint8 hPick, bool pointer, uint96 dep, address y,
        uint256 pYv, bytes32 secret
    ) public {
        address holder = _pick(hPick);
        // Justification: an expiry far from both ends of uint64, so every window below exists
        vm.assume(exp > 1000 && exp < type(uint64).max / 2);
        _world(exp, epoch, epoch, holder, OWNER);
        // Justification: a top level name with no deposit, a trial or a released name, has no grace and no
        // premium in src, while the reference build, which has no trials, counts both from the expiry
        // whatever the deposit; TrialProofs T1 to T8 cover it
        vm.assume(dep != 0);
        a.h_setDeposit(pid, dep);
        b.h_setDeposit(pid, dep);
        _ptr(y, pYv);
        if (pointer) _ptr(holder, pid);
        uint8 w = when % 3;
        uint256 ts = w == 0 ? uint256(exp) + 90 days : w == 1 ? uint256(exp) + 90 days + 1 : uint256(exp) + 111 days + 1;
        uint8 cw = cwhen % 3;
        uint256 ct = cw == 0 ? ts - 61 : cw == 1 ? ts - 19 : 0;
        bytes32 c = b.makeCommitment("club", OTHER, 0, secret);
        a.h_setCommit(c, ct);
        b.h_setCommit(c, ct);
        vm.warp(ts);
        // reveal charges the carried deposit even inside grace, where quote leaves it out, so pay what
        // reveal charges and let the last second of grace reach its own check; after the auction the deposit
        // goes back first and is not charged
        (uint256 fee,, uint256 premium,) = b.quote("club");
        uint256 total = fee + (ts > uint256(exp) + 111 days ? 0 : dep) + premium;
        vm.deal(OTHER, total * 2);
        bytes memory d = abi.encodeCall(PageNFT.reveal, ("club", OTHER, 0, secret));
        vm.prank(OTHER);
        (bool okA, bytes memory rA) = address(a).call{value: total}(d);
        vm.prank(OTHER);
        (bool okB, bytes memory rB) = address(b).call{value: total}(d);
        assert(okA == okB);
        assert(keccak256(rA) == keccak256(rB));
        assert(b.h_ownerOf(pid) == a.h_ownerOf(pid));
        assert(b.primaryPage(holder) == a.primaryPage(holder));
        assert(b.primaryPage(OTHER) == a.primaryPage(OTHER));
        assert(b.primaryPage(y) == a.primaryPage(y));
    }

    /// @notice CP3t: the twin of CP3r for the trial state. In b the record's last registration was a
    /// trial that ended unpaid and still holds its price for a payer; a has no trials and the same record
    /// with no deposit. At times after the auction window, where both worlds take a paid registration
    /// at the plain fee, it succeeds or fails alike with the same return or revert data, the holder and
    /// every display name pointer end the same, and b credits exactly the held price to its payer when
    /// it succeeds and keeps it held when it fails. Differential only on the effects that are not about
    /// trial money.
    /// @dev Technique: symbolic differential of the write path with time in fixed windows. Classification: DIRECT.
    function test_check_CP3t_reRegistrationOverTrialSame(
        uint64 exp, uint64 epoch, uint8 when, uint8 cwhen, uint8 hPick, bool pointer, uint96 held, address y,
        uint256 pYv, bytes32 secret
    ) public {
        address holder = _pick(hPick);
        address payer = address(0xFA7E5);
        // Justification: an expiry far from both ends of uint64, so every window below exists
        vm.assume(exp > 1000 && exp < type(uint64).max / 2);
        vm.assume(held != 0 && held <= 1 ether);
        _world(exp, epoch, epoch, holder, OWNER);
        a.h_setDeposit(pid, 0);
        b.h_setDeposit(pid, 0);
        b.h_setHeld(pid, payer, held);
        vm.deal(address(b), held);
        _ptr(y, pYv);
        if (pointer) _ptr(holder, pid);
        uint256 ts = when % 2 == 0 ? uint256(exp) + 111 days + 1 : uint256(exp) + 400 days;
        uint8 cw = cwhen % 3;
        uint256 ct = cw == 0 ? ts - 61 : cw == 1 ? ts - 19 : 0;
        bytes32 c = b.makeCommitment("club", OTHER, 0, secret);
        a.h_setCommit(c, ct);
        b.h_setCommit(c, ct);
        vm.warp(ts);
        (,,, uint256 total) = b.quote("club");
        vm.deal(OTHER, total * 2);
        uint256 owedPayer = b.owed(payer);
        bytes memory d = abi.encodeCall(PageNFT.reveal, ("club", OTHER, 0, secret));
        vm.prank(OTHER);
        (bool okA, bytes memory rA) = address(a).call{value: total}(d);
        vm.prank(OTHER);
        (bool okB, bytes memory rB) = address(b).call{value: total}(d);
        assert(okA == okB);
        assert(keccak256(rA) == keccak256(rB));
        assert(b.h_ownerOf(pid) == a.h_ownerOf(pid));
        assert(b.primaryPage(holder) == a.primaryPage(holder));
        assert(b.primaryPage(OTHER) == a.primaryPage(OTHER));
        assert(b.primaryPage(y) == a.primaryPage(y));
        (, uint96 left) = b.trialPaymentOf(pid);
        if (okB) {
            assert(b.owed(payer) == owedPayer + held);
            assert(left == 0);
        } else {
            assert(b.owed(payer) == owedPayer);
            assert(left == held);
        }
    }
}

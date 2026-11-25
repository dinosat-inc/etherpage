// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {PageCard} from "../src/PageCard.sol";
import {PageNFT} from "../src/PageNFT.sol";
import {MulticallHarness} from "./MulticallHarness.sol";

/// @notice Symbolic proofs for multicall. Worlds a and b are two copies of src with the same
/// symbolic start state. In MC1 to MC4, a gets a call directly and b gets the same call inside a
/// bundle of one call, and each proof asserts the same success, the same return or revert data and
/// the same state afterwards. In MC7, a gets three calls one by one and b gets them as one bundle,
/// which succeeds exactly when all three calls do and then ends in the same state, and otherwise
/// fails with the revert data of the first failing call and changes nothing. MC5, MC5a to MC5c and
/// MC6 call only b and assert that the bundle fails and changes nothing.
/// Halmos: FOUNDRY_PROFILE=proofs halmos --contract MulticallProofsTest --function test_check_MC --forge-build-out out-proofs --loop 4 --storage-layout generic
contract MulticallProofsTest is Test {
    PageCard card;
    MulticallHarness a;
    MulticallHarness b;

    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address constant OWNER = address(0xA11CE);
    address constant HOLDER = address(0xB0B);
    address constant OTHER = address(0xC0FFEE);
    address constant MINTER = address(0x3117);
    uint256 constant COIN_OP = 0x8000000a;
    bytes32 constant ROOT = 0x62460c06d95b73747abf6ea4f28aefd78b4ad2abee112e7cf15fe6a924cca3c6;

    uint256 pid;
    uint256 sub;
    // the price a top level record with no deposit holds, as a trial does: a tenth of the yearly fee of club
    uint96 constant HELD = 0.0001 ether;

    function setUp() public {
        card = new PageCard();
        a = new MulticallHarness(card);
        b = new MulticallHarness(card);
        pid = uint256(keccak256(abi.encodePacked(ROOT, keccak256(bytes("club")))));
        sub = uint256(keccak256(abi.encodePacked(bytes32(pid), keccak256(bytes("fresh")))));
    }

    function _pick(uint8 p) internal pure returns (address) {
        uint8 k = p % 5;
        if (k == 0) return DEAD;
        if (k == 1) return HOLDER;
        if (k == 2) return OWNER;
        if (k == 3) return MINTER;
        return OTHER;
    }

    function _pick3(uint8 p) internal pure returns (address) {
        uint8 k = p % 3;
        if (k == 0) return HOLDER;
        if (k == 1) return OWNER;
        return OTHER;
    }

    // a parent and one subpage, the same in both worlds
    function _world(uint64 exp, uint64 epoch, uint64 pe, address pHolder, address holder) internal {
        MulticallHarness[2] memory w = [a, b];
        for (uint256 i; i < 2; ++i) {
            MulticallHarness n = w[i];
            n.h_setRecord(pid, "club", 0, exp, epoch, 0);
            n.h_mint(pHolder, pid);
            n.h_setRecord(sub, "fresh", pid, 0, 1, pe);
            n.h_mint(holder, sub);
            n.h_setProfile(sub);
        }
    }

    function _one(bytes memory d) internal pure returns (bytes[] memory x) {
        x = new bytes[](1);
        x[0] = d;
    }

    // the call alone in a, inside a bundle of one call in b, both from caller
    function _pair(address caller, bytes memory data) internal returns (bool okA, bool okB) {
        vm.prank(caller);
        bytes memory rA;
        (okA, rA) = address(a).call(data);
        vm.prank(caller);
        bytes memory rB;
        (okB, rB) = address(b).call(abi.encodeCall(PageNFT.multicall, (_one(data))));
        assert(okA == okB);
        if (okB) {
            bytes[] memory res = abi.decode(rB, (bytes[]));
            assert(res.length == 1);
            assert(keccak256(res[0]) == keccak256(rA));
        } else {
            assert(keccak256(rB) == keccak256(rA));
        }
    }

    function _sameState(address x) internal view {
        assert(b.h_ownerOf(pid) == a.h_ownerOf(pid));
        assert(b.h_ownerOf(sub) == a.h_ownerOf(sub));
        assert(b.recordVersion(pid) == a.recordVersion(pid));
        assert(b.recordVersion(sub) == a.recordVersion(sub));
        assert(b.epochOf(sub) == a.epochOf(sub));
        assert(b.primaryPage(x) == a.primaryPage(x));
        assert(b.primaryPage(HOLDER) == a.primaryPage(HOLDER));
        assert(b.resolve(pid) == a.resolve(pid));
        assert(b.resolve(sub) == a.resolve(sub));
        assert(b.subpageMinterOf(pid) == a.subpageMinterOf(pid));
        assert(b.isApprovedForAll(OWNER, x) == a.isApprovedForAll(OWNER, x));
        assert(keccak256(bytes(b.text(sub, "k"))) == keccak256(bytes(a.text(sub, "k"))));
        assert(keccak256(b.contenthash(sub)) == keccak256(a.contenthash(sub)));
        assert(keccak256(bytes(b.text(pid, "k"))) == keccak256(bytes(a.text(pid, "k"))));
        assert(keccak256(b.data(bytes32(sub), "k")) == keccak256(a.data(bytes32(sub), "k")));
        assert(keccak256(b.data(bytes32(pid), "k")) == keccak256(a.data(bytes32(pid), "k")));
        assert(b.profileWriter(sub) == a.profileWriter(sub));
        assert(b.profileWriter(pid) == a.profileWriter(pid));
        assert(keccak256(b.addr(sub, 60)) == keccak256(a.addr(sub, 60)));
        assert(b.owed(x) == a.owed(x));
        assert(b.owed(HOLDER) == a.owed(HOLDER));
        assert(b.depositOf(pid) == a.depositOf(pid));
        assert(address(b).balance == address(a).balance);
    }

    /// @notice MC1: each resolver writer (setAddr, setAddrForCoin for Ethereum and OP, setText,
    /// setContenthash, clearRecords, setData) and setPrimaryPage in a bundle of one call equals the call
    /// alone, on the parent or the subpage, for a caller and a subpage holder each among DEAD,
    /// HOLDER, OWNER, MINTER and OTHER, the parent held by OWNER with any expiry and epoch, the
    /// subpage made in any epoch of the parent, and any time: same success, same return or revert
    /// data, same state.
    /// @dev Technique: symbolic differential of the write path. Classification: DIRECT.
    function test_check_MC1_writers(
        uint64 exp, uint64 epoch, uint64 pe, uint64 ts, uint8 hPick, uint8 cPick, uint8 xPick, uint8 k, bool onSub
    ) public {
        address holder = _pick(hPick);
        address caller = _pick(cPick);
        address x = _pick(xPick);
        _world(exp, epoch, pe, OWNER, holder);
        vm.warp(ts);
        uint256 id = onSub ? sub : pid;
        uint8 kk = k % 8;
        bytes memory data;
        if (kk == 0) data = abi.encodeCall(PageNFT.setAddr, (id, x));
        else if (kk == 1) data = abi.encodeCall(PageNFT.setAddrForCoin, (id, 60, abi.encodePacked(x)));
        else if (kk == 2) data = abi.encodeCall(PageNFT.setAddrForCoin, (id, COIN_OP, abi.encodePacked(x)));
        else if (kk == 3) data = abi.encodeCall(PageNFT.setText, (id, "k", "w"));
        else if (kk == 4) data = abi.encodeCall(PageNFT.setContenthash, (id, hex"e301"));
        else if (kk == 5) data = abi.encodeCall(PageNFT.clearRecords, (id));
        else if (kk == 6) data = abi.encodeCall(PageNFT.setPrimaryPage, (x == DEAD ? 0 : id));
        else data = abi.encodeCall(PageNFT.setData, (id, "k", hex"e301"));
        _pair(caller, data);
        _sameState(caller);
    }

    /// @notice MC1k: keepProfile in a bundle of one call equals the call alone, on the subpage whose
    /// profile its holder wrote or on the parent, which has no profile writer, for a caller and a
    /// subpage holder each among DEAD, HOLDER, OWNER, MINTER and OTHER, the parent held by OWNER
    /// with any expiry and epoch, the subpage made in any epoch of the parent, and any time: same
    /// success, same return or revert data, same state.
    /// @dev Technique: symbolic differential of the write path. Classification: DIRECT.
    function test_check_MC1k_keepProfile(
        uint64 exp, uint64 epoch, uint64 pe, uint64 ts, uint8 hPick, uint8 cPick, bool onSub
    ) public {
        address holder = _pick(hPick);
        address caller = _pick(cPick);
        _world(exp, epoch, pe, OWNER, holder);
        vm.warp(ts);
        _pair(caller, abi.encodeCall(PageNFT.keepProfile, (onSub ? sub : pid)));
        _sameState(caller);
    }

    /// @notice MC2: transferFrom, both safeTransferFrom overloads, approve, setApprovalForAll and
    /// setSubpageMinter in a bundle of one call equal the call alone, with or without an approval or
    /// an operator, for a holder of both names, a caller and a recipient each among DEAD, HOLDER,
    /// OWNER, MINTER and OTHER, and any time.
    /// @dev Technique: symbolic differential of the write path. Classification: DIRECT. Too wide to
    /// finish in a practical time, as are MC2t and MC2a. MC2x0 to MC2x5 prove it one function at a
    /// time over smaller address sets.
    function test_check_MC2_transfersAndApprovals(
        uint64 exp, uint64 epoch, uint64 pe, uint64 ts, uint8 hPick, uint8 cPick, uint8 tPick,
        uint8 k, bool onSub, bool approved, bool operator
    ) public {
        _mc2(exp, epoch, pe, ts, hPick, cPick, tPick, k, onSub, approved, operator, 0);
    }

    /// @notice MC2t: MC2 for the three transfer functions only.
    function test_check_MC2t_transfers(
        uint64 exp, uint64 epoch, uint64 pe, uint64 ts, uint8 hPick, uint8 cPick, uint8 tPick,
        uint8 k, bool onSub, bool approved, bool operator
    ) public {
        _mc2(exp, epoch, pe, ts, hPick, cPick, tPick, k, onSub, approved, operator, 1);
    }

    /// @notice MC2a: MC2 for approve, setApprovalForAll and setSubpageMinter only.
    function test_check_MC2a_approvals(
        uint64 exp, uint64 epoch, uint64 pe, uint64 ts, uint8 hPick, uint8 cPick, uint8 tPick,
        uint8 k, bool onSub, bool approved, bool operator
    ) public {
        _mc2(exp, epoch, pe, ts, hPick, cPick, tPick, k, onSub, approved, operator, 2);
    }

    function _mc2(
        uint64 exp, uint64 epoch, uint64 pe, uint64 ts, uint8 hPick, uint8 cPick, uint8 tPick,
        uint8 k, bool onSub, bool approved, bool operator, uint8 kSplit
    ) internal {
        address holder = _pick(hPick);
        address caller = _pick(cPick);
        address to = _pick(tPick);
        _world(exp, epoch, pe, holder, holder);
        uint256 id = onSub ? sub : pid;
        if (approved) {
            a.h_approve(caller, id);
            b.h_approve(caller, id);
        }
        if (operator) {
            a.h_setApprovalForAll(holder, caller, true);
            b.h_setApprovalForAll(holder, caller, true);
        }
        vm.warp(ts);
        uint8 kk = k % 6;
        // kSplit 1 keeps MC2t to the three transfers and kSplit 2 keeps MC2a to the other three kinds
        if (kSplit == 1) kk = kk % 3;
        if (kSplit == 2) kk = 3 + kk % 3;
        bytes memory data;
        if (kk == 0) data = abi.encodeWithSignature("transferFrom(address,address,uint256)", holder, to, id);
        else if (kk == 1) data = abi.encodeWithSignature("safeTransferFrom(address,address,uint256)", holder, to, id);
        else if (kk == 2) data = abi.encodeWithSignature("safeTransferFrom(address,address,uint256,bytes)", holder, to, id, hex"01");
        else if (kk == 3) data = abi.encodeCall(PageNFT.approve, (to, id));
        else if (kk == 4) data = abi.encodeWithSignature("setApprovalForAll(address,bool)", to, approved);
        else data = abi.encodeCall(PageNFT.setSubpageMinter, (pid, to));
        _pair(caller, data);
        _sameState(to);
        if (b.h_ownerOf(id) != address(0)) assert(b.getApproved(id) == a.getApproved(id));
    }

    /// @notice MC2x: MC2 with one function per proof and smaller address sets, so each finishes.
    /// holder is HOLDER or DEAD, caller is the holder or OTHER, the recipient is OTHER, DEAD or
    /// the holder; approvals and the operator flag stay symbolic.
    function _mc2x(uint64 exp, uint64 epoch, uint64 pe, uint64 ts, bool hDead, bool cOther, uint8 tPick, bool onSub,
        bool approved, bool operator, uint8 kind) internal {
        address holder = hDead ? DEAD : HOLDER;
        address caller = cOther ? OTHER : holder;
        uint8 t = tPick % 3;
        address to = t == 0 ? OTHER : t == 1 ? DEAD : holder;
        _world(exp, epoch, pe, holder, holder);
        uint256 id = onSub ? sub : pid;
        if (approved) {
            a.h_approve(caller, id);
            b.h_approve(caller, id);
        }
        if (operator) {
            a.h_setApprovalForAll(holder, caller, true);
            b.h_setApprovalForAll(holder, caller, true);
        }
        vm.warp(ts);
        bytes memory data;
        if (kind == 0) data = abi.encodeWithSignature("transferFrom(address,address,uint256)", holder, to, id);
        else if (kind == 1) data = abi.encodeWithSignature("safeTransferFrom(address,address,uint256)", holder, to, id);
        else if (kind == 2) data = abi.encodeWithSignature("safeTransferFrom(address,address,uint256,bytes)", holder, to, id, hex"01");
        else if (kind == 3) data = abi.encodeCall(PageNFT.approve, (to, id));
        else if (kind == 4) data = abi.encodeWithSignature("setApprovalForAll(address,bool)", to, approved);
        else data = abi.encodeCall(PageNFT.setSubpageMinter, (pid, to));
        _pair(caller, data);
        _sameState(to);
        assert(b.isApprovedForAll(caller, to) == a.isApprovedForAll(caller, to));
        if (b.h_ownerOf(id) != address(0)) assert(b.getApproved(id) == a.getApproved(id));
    }

    function test_check_MC2x0_transferFrom(uint64 exp, uint64 epoch, uint64 pe, uint64 ts, bool hDead, bool cOther,
        uint8 tPick, bool onSub, bool approved, bool operator) public {
        _mc2x(exp, epoch, pe, ts, hDead, cOther, tPick, onSub, approved, operator, 0);
    }

    function test_check_MC2x1_safeTransferFrom(uint64 exp, uint64 epoch, uint64 pe, uint64 ts, bool hDead, bool cOther,
        uint8 tPick, bool onSub, bool approved, bool operator) public {
        _mc2x(exp, epoch, pe, ts, hDead, cOther, tPick, onSub, approved, operator, 1);
    }

    function test_check_MC2x2_safeTransferFromData(uint64 exp, uint64 epoch, uint64 pe, uint64 ts, bool hDead,
        bool cOther, uint8 tPick, bool onSub, bool approved, bool operator) public {
        _mc2x(exp, epoch, pe, ts, hDead, cOther, tPick, onSub, approved, operator, 2);
    }

    function test_check_MC2x3_approve(uint64 exp, uint64 epoch, uint64 pe, uint64 ts, bool hDead, bool cOther,
        uint8 tPick, bool onSub, bool approved, bool operator) public {
        _mc2x(exp, epoch, pe, ts, hDead, cOther, tPick, onSub, approved, operator, 3);
    }

    function test_check_MC2x4_setApprovalForAll(uint64 exp, uint64 epoch, uint64 pe, uint64 ts, bool hDead,
        bool cOther, uint8 tPick, bool onSub, bool approved, bool operator) public {
        _mc2x(exp, epoch, pe, ts, hDead, cOther, tPick, onSub, approved, operator, 4);
    }

    function test_check_MC2x5_setSubpageMinter(uint64 exp, uint64 epoch, uint64 pe, uint64 ts, bool hDead,
        bool cOther, uint8 tPick, bool onSub, bool approved, bool operator) public {
        _mc2x(exp, epoch, pe, ts, hDead, cOther, tPick, onSub, approved, operator, 5);
    }

    /// @notice MC3: registerSubpage and registerSubpageFor in a bundle of one call equal the call
    /// alone, by the parent's holder OWNER, by MINTER as a counted or stale minter, or by DEAD,
    /// HOLDER or OTHER, over the subpage held by any of these five accounts, DEAD included, with
    /// registerSubpageFor minting to HOLDER, OWNER or OTHER.
    /// @dev Technique: symbolic differential of the write path. Classification: DIRECT.
    function test_check_MC3_mints(
        uint64 exp, uint64 epoch, uint64 pe, uint64 ts, uint8 hPick, uint8 cPick, uint8 tPick,
        bool counted, bool forOther
    ) public {
        address holder = _pick(hPick);
        address to = _pick3(tPick);
        address caller = _pick(cPick);
        _world(exp, epoch, pe, OWNER, holder);
        a.h_setMinter(pid, MINTER, counted ? epoch : epoch ^ 1, OWNER);
        b.h_setMinter(pid, MINTER, counted ? epoch : epoch ^ 1, OWNER);
        a.h_setPrimary(holder, sub);
        b.h_setPrimary(holder, sub);
        vm.warp(ts);
        bytes memory data = forOther
            ? abi.encodeCall(PageNFT.registerSubpageFor, ("fresh", pid, to))
            : abi.encodeCall(PageNFT.registerSubpage, ("fresh", pid));
        _pair(caller, data);
        _sameState(caller);
        (,,,, uint64 peA) = a.records(sub);
        (,,,, uint64 peB) = b.records(sub);
        assert(peA == peB);
    }

    /// @notice MC4: withdraw and release in a bundle of one call equal the call alone, with the same
    /// payment to x, the parent's holder, and the same credits to x and HOLDER. A direct withdraw
    /// for x afterwards succeeds in b exactly when it does in a; when x still has a credit, which
    /// only the release case can leave, this shows the bundle left the reentrancy guard free. After
    /// a withdraw, x has no credit, so that call fails in both worlds and does not test the guard.
    /// @dev Technique: symbolic differential of the money path. Classification: DIRECT.
    function test_check_MC4_money(
        uint64 exp, uint64 ts, uint8 cPick, uint8 xPick, uint96 owedX, uint96 dep, uint96 extra, bool rel
    ) public {
        address caller = _pick(cPick);
        address x = _pick3(xPick);
        _world(exp, 1, 1, x, HOLDER);
        uint256 held = dep == 0 ? HELD : 0;
        uint256 bal = uint256(owedX) + dep + held + extra;
        MulticallHarness[2] memory w = [a, b];
        for (uint256 i; i < 2; ++i) {
            w[i].h_setOwed(x, owedX);
            w[i].h_setDeposit(pid, dep);
            w[i].h_setHeld(pid, OWNER, uint96(held));
            vm.deal(address(w[i]), bal);
        }
        vm.warp(ts);
        uint256 xBefore = x.balance;
        bytes memory data = rel ? abi.encodeCall(PageNFT.release, (pid)) : abi.encodeCall(PageNFT.withdraw, (x));
        (bool okA,) = _pair(caller, data);
        _sameState(x);
        // both worlds paid, so x received twice what one world paid
        if (okA && !rel) assert(x.balance == xBefore + 2 * uint256(owedX));
        // a direct withdraw afterwards: when x still has a credit, which only the release case can
        // leave, it succeeds in a, so the check below holds only if the guard is free in b too
        vm.prank(caller);
        (bool okA2,) = address(a).call(abi.encodeCall(PageNFT.withdraw, (x)));
        vm.prank(caller);
        (bool okB2,) = address(b).call(abi.encodeCall(PageNFT.withdraw, (x)));
        assert(okA2 == okB2);
    }

    /// @notice MC5: a paid call (renew, reveal, revealTrial) can never succeed inside a bundle, on
    /// the top level name held by OWNER with any expiry, epoch and deposit, at any time, with
    /// commitments of both forms, ripe or not, for a caller among DEAD, HOLDER, OWNER, MINTER and
    /// OTHER; nothing is paid, credited or registered.
    /// @dev Technique: symbolic reachability of success. Classification: DIRECT. Does not finish:
    /// the premium division inside the window defeats the solver. MC5a, MC5b and MC5c prove it
    /// outside that window; MC5v, MC5p and MC5f in PaidCallProofs prove it in three parts that need
    /// no premium curve.
    function test_check_MC5_paidCallsFail(
        uint64 exp, uint64 epoch, uint64 ts, uint64 committedAt, uint8 cPick, uint8 k, uint96 dep, bytes32 secret
    ) public {
        address caller = _pick(cPick);
        _world(exp, epoch, 1, OWNER, HOLDER);
        b.h_setDeposit(pid, dep);
        b.h_setHeld(pid, OWNER, dep == 0 ? HELD : 0);
        vm.deal(address(b), uint256(dep) + (dep == 0 ? HELD : 0));
        bytes32 c = keccak256(abi.encode(bytes("club"), caller, uint256(0), secret));
        bytes32 tc = keccak256(abi.encode(bytes("club"), caller, uint256(0), secret, true));
        b.h_setCommit(c, committedAt);
        b.h_setCommit(tc, committedAt);
        vm.warp(ts);
        uint8 kk = k % 3;
        bytes memory data;
        if (kk == 0) data = abi.encodeCall(PageNFT.renew, (pid));
        else if (kk == 1) data = abi.encodeCall(PageNFT.revealTrial, ("club", caller, 0, secret));
        else data = abi.encodeCall(PageNFT.reveal, ("club", caller, 0, secret));
        uint64 expBefore = uint64(b.expiresAt(pid));
        vm.prank(caller);
        (bool ok,) = address(b).call(abi.encodeCall(PageNFT.multicall, (_one(data))));
        assert(!ok);
        assert(address(b).balance == uint256(dep) + (dep == 0 ? HELD : 0));
        assert(b.depositOf(pid) == dep);
        assert(b.expiresAt(pid) == expBefore);
        assert(b.commitments(c) == committedAt);
        assert(b.commitments(tc) == committedAt);
        assert(b.h_ownerOf(pid) == OWNER);
    }

    /// @notice MC5a: renew inside a bundle never succeeds, on the top level name held by OWNER or on
    /// its subpage, for any expiry, epoch, deposit and time, and for a caller among DEAD, HOLDER,
    /// OWNER, MINTER and OTHER; the expiry, the deposit and the balance are unchanged.
    /// @dev Technique: symbolic reachability of success. Classification: DIRECT.
    function test_check_MC5a_renewFails(uint64 exp, uint64 epoch, uint64 ts, uint8 cPick, uint96 dep, bool onSub) public {
        address caller = _pick(cPick);
        _world(exp, epoch, 1, OWNER, HOLDER);
        b.h_setDeposit(pid, dep);
        b.h_setHeld(pid, OWNER, dep == 0 ? HELD : 0);
        vm.deal(address(b), uint256(dep) + (dep == 0 ? HELD : 0));
        vm.warp(ts);
        uint256 id = onSub ? sub : pid;
        vm.prank(caller);
        (bool ok,) = address(b).call(abi.encodeCall(PageNFT.multicall, (_one(abi.encodeCall(PageNFT.renew, (id))))));
        assert(!ok);
        assert(address(b).balance == uint256(dep) + (dep == 0 ? HELD : 0));
        assert(b.depositOf(pid) == dep);
        assert(b.expiresAt(pid) == exp);
    }

    /// @notice MC5b: reveal and revealTrial inside a bundle never succeed for a label with no record
    /// and commitments of both forms, ripe or not, at any time and for a caller among DEAD, HOLDER,
    /// OWNER, MINTER and OTHER; the commitments stay and no token is minted.
    /// @dev Technique: symbolic reachability of success. Classification: DIRECT.
    function test_check_MC5b_revealFreshFails(uint64 ts, uint64 committedAt, uint8 cPick, bool paid, bytes32 secret)
        public
    {
        address caller = _pick(cPick);
        uint256 id = uint256(keccak256(abi.encodePacked(ROOT, keccak256(bytes("newname")))));
        bytes32 c = keccak256(abi.encode(bytes("newname"), caller, uint256(0), secret));
        bytes32 tc = keccak256(abi.encode(bytes("newname"), caller, uint256(0), secret, true));
        b.h_setCommit(c, committedAt);
        b.h_setCommit(tc, committedAt);
        vm.warp(ts);
        bytes memory data = paid
            ? abi.encodeCall(PageNFT.reveal, ("newname", caller, 0, secret))
            : abi.encodeCall(PageNFT.revealTrial, ("newname", caller, 0, secret));
        vm.prank(caller);
        (bool ok,) = address(b).call(abi.encodeCall(PageNFT.multicall, (_one(data))));
        assert(!ok);
        assert(b.commitments(c) == committedAt);
        assert(b.commitments(tc) == committedAt);
        assert(b.h_ownerOf(id) == address(0));
        assert(address(b).balance == 0);
    }

    /// @notice MC5c: reveal and revealTrial inside a bundle never succeed for a label that has a
    /// record, with a deposit and a ripe commitment, at any time outside the premium
    /// window (the window's division is what times out MC5; there the premium only adds to a
    /// total that the fee already keeps above zero).
    /// @dev Technique: symbolic reachability of success. Classification: DIRECT, window excluded.
    function test_check_MC5c_revealTakenFails(
        uint64 exp, uint64 epoch, uint64 ts, uint64 committedAt, uint8 cPick, bool paid, uint96 dep, bytes32 secret
    ) public {
        vm.assume(uint256(ts) <= uint256(exp) + 90 days || uint256(ts) >= uint256(exp) + 111 days);
        address caller = _pick(cPick);
        _world(exp, epoch, 1, OWNER, HOLDER);
        b.h_setDeposit(pid, dep);
        b.h_setHeld(pid, OWNER, dep == 0 ? HELD : 0);
        vm.deal(address(b), uint256(dep) + (dep == 0 ? HELD : 0));
        bytes32 c = keccak256(abi.encode(bytes("club"), caller, uint256(0), secret));
        bytes32 tc = keccak256(abi.encode(bytes("club"), caller, uint256(0), secret, true));
        b.h_setCommit(c, committedAt);
        b.h_setCommit(tc, committedAt);
        vm.warp(ts);
        bytes memory data = paid
            ? abi.encodeCall(PageNFT.reveal, ("club", caller, 0, secret))
            : abi.encodeCall(PageNFT.revealTrial, ("club", caller, 0, secret));
        vm.prank(caller);
        (bool ok,) = address(b).call(abi.encodeCall(PageNFT.multicall, (_one(data))));
        assert(!ok);
        assert(b.commitments(c) == committedAt);
        assert(b.commitments(tc) == committedAt);
        assert(b.h_ownerOf(pid) == OWNER);
        assert(address(b).balance == uint256(dep) + (dep == 0 ? HELD : 0));
        assert(b.depositOf(pid) == dep);
    }

    /// @notice MC6: a bundle sent with any nonzero value below 10^30 wei, by a caller among DEAD,
    /// HOLDER, OWNER, MINTER and OTHER that holds both names, is refused with empty revert data
    /// and changes nothing, whether it is empty or holds a renew, a setText, a transferFrom or an
    /// empty multicall.
    /// @dev Technique: symbolic reachability of success. Classification: DIRECT.
    function test_check_MC6_valueRefused(uint256 v, uint8 cPick, uint8 k, uint64 exp, uint64 ts) public {
        vm.assume(v != 0 && v < 1e30);
        address caller = _pick(cPick);
        _world(exp, 1, 1, caller, caller);
        vm.warp(ts);
        uint8 kk = k % 5;
        bytes[] memory d;
        if (kk == 0) d = new bytes[](0);
        else if (kk == 1) d = _one(abi.encodeCall(PageNFT.renew, (pid)));
        else if (kk == 2) d = _one(abi.encodeCall(PageNFT.setText, (sub, "k", "w")));
        else if (kk == 3) d = _one(abi.encodeWithSignature("transferFrom(address,address,uint256)", caller, OTHER, pid));
        else d = _one(abi.encodeCall(PageNFT.multicall, (new bytes[](0))));
        vm.deal(caller, v);
        vm.prank(caller);
        (bool ok, bytes memory ret) = address(b).call{value: v}(abi.encodeCall(PageNFT.multicall, (d)));
        assert(!ok);
        assert(ret.length == 0);
        assert(address(b).balance == 0);
        assert(caller.balance == v);
        assert(b.h_ownerOf(pid) == caller);
        assert(keccak256(bytes(b.text(sub, "k"))) == keccak256(bytes(a.text(sub, "k"))));
    }

    /// @notice MC7: the Delete bundle (setPrimaryPage(0), clearRecords, transferFrom to DEAD)
    /// succeeds exactly when the three calls one by one all do, for a caller and a subpage holder
    /// each among DEAD, HOLDER, OWNER, MINTER and OTHER, the parent held by OWNER with any expiry
    /// and epoch, the subpage made in any epoch of the parent, and any time. On success both worlds
    /// end in the same state; on failure the bundle reverts with the revert data of the first
    /// failing call and changes nothing. MC7t is the same for the top level name, held by any of
    /// the five accounts, with the subpage held by OWNER.
    /// @dev Technique: symbolic differential of a sequence of three calls. Classification: DIRECT.
    function test_check_MC7_deleteFlow(uint64 exp, uint64 epoch, uint64 pe, uint64 ts, uint8 hPick, uint8 cPick, bool primary)
        public
    {
        _mc7(false, exp, epoch, pe, ts, hPick, cPick, primary);
    }

    function test_check_MC7t_deleteFlowTop(uint64 exp, uint64 epoch, uint64 pe, uint64 ts, uint8 hPick, uint8 cPick, bool primary)
        public
    {
        _mc7(true, exp, epoch, pe, ts, hPick, cPick, primary);
    }

    function _mc7(bool top, uint64 exp, uint64 epoch, uint64 pe, uint64 ts, uint8 hPick, uint8 cPick, bool primary)
        internal
    {
        address holder = _pick(hPick);
        address caller = _pick(cPick);
        uint256 id = top ? pid : sub;
        _world(exp, epoch, pe, top ? holder : OWNER, top ? OWNER : holder);
        if (primary) {
            a.h_setPrimary(caller, id);
            b.h_setPrimary(caller, id);
        }
        vm.warp(ts);
        bytes[] memory d = new bytes[](3);
        d[0] = abi.encodeCall(PageNFT.setPrimaryPage, (0));
        d[1] = abi.encodeCall(PageNFT.clearRecords, (id));
        d[2] = abi.encodeWithSignature("transferFrom(address,address,uint256)", caller, DEAD, id);
        bytes32 before = _viewHash(b, caller, id);
        bool okA = true;
        bytes memory failA;
        for (uint256 i; i < 3; ++i) {
            vm.prank(caller);
            (bool ok, bytes memory r) = address(a).call(d[i]);
            if (!ok) {
                okA = false;
                failA = r;
                break;
            }
        }
        vm.prank(caller);
        (bool okB, bytes memory rB) = address(b).call(abi.encodeCall(PageNFT.multicall, (d)));
        assert(okA == okB);
        if (okB) {
            _sameState(caller);
        } else {
            // a stops where it failed; b must fail with that data and change nothing
            assert(keccak256(rB) == keccak256(failA));
            assert(_viewHash(b, caller, id) == before);
        }
    }

    function _viewHash(MulticallHarness n, address x, uint256 id) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                n.h_ownerOf(id), n.recordVersion(id), n.primaryPage(x), n.resolve(id),
                keccak256(bytes(n.text(id, "k"))), n.h_ownerOf(id == pid ? sub : pid)
            )
        );
    }
}

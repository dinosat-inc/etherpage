// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Test, Vm} from "forge-std/Test.sol";
import {PageNFT} from "../../src/PageNFT.sol";
import {PageCard} from "../../src/PageCard.sol";
import {PageNFTManualRelease} from "./harness/PageNFTManualRelease.sol";
import {ReleaseFirstBase} from "./ReleaseFirstBase.sol";

// The same random walk on src (nft) and on the manual release build (manual). Before a registration that comes
// after the auction of a name still holding a deposit, manual gets an explicit release, so the two must agree on
// every outcome, revert and credit, and on the views that _compareAll reads, after every step. Registrations land near the ends of the grace period,
// the auction and the trial pause most of the time.
contract LockstepHandler is ReleaseFirstBase {
    string[3] internal labels;
    address[4] public actors;
    address[2] public savedAddrs;

    mapping(uint256 => uint256) public added;
    mapping(uint256 => uint256) public releasedOut;
    mapping(address => uint256) public credited;
    mapping(address => uint256) public withdrawnBy;

    uint256 public releasedByAPaidRegistration;
    uint256 public releasedByATrial;
    uint256 public auctionBuys;
    uint256 public atTheAuctionEnd;
    uint256 public oneSecondAfter;
    uint256 public failedRegistrations;
    uint256 nonce;

    constructor(PageNFT n, PageNFT m) {
        nft = n;
        manual = m;
        labels[0] = "x";
        labels[1] = "abc";
        labels[2] = "alice";
        actors = [makeAddr("a0"), makeAddr("a1"), makeAddr("a2"), makeAddr("a3")];
        savedAddrs = [makeAddr("s0"), makeAddr("s1")];
        for (uint256 i; i < 4; ++i) vm.deal(actors[i], 1e9 ether);
    }

    function setUp() public override {}

    function label(uint256 i) external view returns (string memory) {
        return labels[i];
    }

    function everyone() public view returns (address[] memory w) {
        w = new address[](7);
        for (uint256 i; i < 4; ++i) w[i] = actors[i];
        w[4] = savedAddrs[0];
        w[5] = savedAddrs[1];
        w[6] = DEAD;
    }

    // adds up the deposits and credits that the logs of src announce
    function _consume() internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory g = logs[i];
            if (g.emitter != address(nft) || g.topics.length == 0) continue;
            bytes32 t = g.topics[0];
            if (t == T_ADDED) {
                (uint256 amount,) = abi.decode(g.data, (uint256, uint256));
                added[uint256(g.topics[1])] += amount;
            } else if (t == T_RELEASED) {
                uint256 amount = abi.decode(g.data, (uint256));
                releasedOut[uint256(g.topics[1])] += amount;
                credited[address(uint160(uint256(g.topics[2])))] += amount;
            } else if (t == T_BOUGHT || t == T_OWNER || t == T_REFUND) {
                credited[address(uint160(uint256(g.topics[2])))] += abi.decode(g.data, (uint256));
            } else if (t == T_REF) {
                credited[address(uint160(uint256(g.topics[3])))] += abi.decode(g.data, (uint256));
            } else if (t == T_WITHDRAWN) {
                withdrawnBy[address(uint160(uint256(g.topics[1])))] += abi.decode(g.data, (uint256));
            }
        }
    }

    function _compareAll() internal view {
        for (uint256 i; i < 3; ++i) _sameName(nft.computeId(labels[i]), labels[i]);
        _sameOwed(everyone());
        for (uint256 i; i < 3; ++i) {
            (uint256 f1, uint256 c1, uint256 p1, uint256 t1) = nft.quote(labels[i]);
            (uint256 f2, uint256 c2, uint256 p2, uint256 t2) = manual.quote(labels[i]);
            assertEq(f1, f2);
            assertEq(p1, p2);
            // after the auction manual still quotes a deposit that its release takes out
            uint256 e = nft.expiresAt(nft.computeId(labels[i]));
            if (e != 0 && _now() > e + G + D) {
                assertEq(c1, 0, "nothing carried after the auction");
                assertEq(t1, f1 + p1);
            } else {
                assertEq(c1, c2);
                assertEq(t1, t2);
            }
        }
    }

    function _same(bool okN, bytes memory retN, bool okM, bytes memory retM) internal pure {
        assertEq(okN, okM, "same outcome");
        assertEq(retN, retM, "same revert");
    }

    function _register(uint256 li, uint256 oi, uint256 pi, uint256 ri, uint256 extra, bool trial) internal {
        vm.recordLogs();
        string memory l = labels[li % 3];
        uint256 id = nft.computeId(l);
        address owner = actors[oi % 4];
        address payer = actors[pi % 4];
        uint256 ref = ri % 4 == 0 ? 0 : nft.computeId(labels[ri % 4 - 1]);
        if (ref == id) ref = 0;
        extra = bound(extra, 0, 1 ether);
        bytes32 s = keccak256(abi.encode(++nonce));
        bytes32 c = trial ? keccak256(abi.encode(bytes(l), owner, ref, s, true)) : nft.makeCommitment(l, owner, ref, s);
        vm.prank(payer);
        nft.commit(c);
        vm.prank(payer);
        manual.commit(c);
        vm.warp(_now() + 61);

        uint256 e = nft.expiresAt(id);
        uint256 dep = nft.depositOf(id);
        bool afterAuction = e != 0 && _now() > e + G + D;
        if (e != 0 && _now() == e + G + D) ++atTheAuctionEnd;
        if (e != 0 && _now() == e + G + D + 1) ++oneSecondAfter;
        bool releasedFirst = afterAuction && manual.depositOf(id) != 0;
        assertEq(releasedFirst, afterAuction && dep != 0);
        if (releasedFirst) {
            vm.prank(actors[3]);
            manual.release(id);
        }
        uint256 vN = trial ? nft.getFee(bytes(l).length) / 10 : _total(nft, l);
        uint256 vM = trial ? manual.getFee(bytes(l).length) / 10 : _total(manual, l);
        assertEq(vN, vM, "the price is what release then registration costs");
        address oldPayee = nft.payee(id);
        uint256 owedBefore = nft.owed(oldPayee);
        bytes memory data = trial
            ? abi.encodeCall(PageNFT.revealTrial, (l, owner, ref, s))
            : abi.encodeCall(PageNFT.reveal, (l, owner, ref, s));
        vm.prank(payer);
        (bool okN, bytes memory retN) = address(nft).call{value: vN + extra}(data);
        vm.prank(payer);
        (bool okM, bytes memory retM) = address(manual).call{value: vM + extra}(data);
        _same(okN, retN, okM, retM);
        if (!okN) {
            ++failedRegistrations;
            // a failed registration released nothing, so src gets the explicit release too
            if (releasedFirst) {
                assertEq(nft.depositOf(id), dep, "a failed registration released nothing");
                vm.prank(actors[3]);
                nft.release(id);
            }
        } else if (releasedFirst) {
            if (trial) ++releasedByATrial;
            else ++releasedByAPaidRegistration;
            assertEq(nft.depositOf(id), trial ? 0 : vN, "the deposit after the auction is the new fee alone");
            assertEq(nft.owed(oldPayee), owedBefore + dep, "the old payee gets exactly the deposit");
        } else if (e != 0 && dep != 0 && !trial) {
            ++auctionBuys;
        }
        _consume();
        _compareAll();
    }

    function buy(uint256 li, uint256 oi, uint256 pi, uint256 ri, uint256 extra) external {
        _register(li, oi, pi, ri, extra, false);
    }

    function trial(uint256 li, uint256 oi, uint256 pi, uint256 ri, uint256 extra) external {
        _register(li, oi, pi, ri, extra, true);
    }

    // lands the registration within two seconds of the end of the auction
    function atAuctionEnd(uint256 li, uint256 oi, uint256 pi, uint256 k, bool isTrial) external {
        uint256 e = nft.expiresAt(nft.computeId(labels[li % 3]));
        if (e != 0) {
            uint256 target = e + G + D - 61 + (k % 5) - 2;
            if (target > _now()) vm.warp(target);
        }
        _register(li, oi, pi, k, 0, isTrial);
    }

    // lands the registration within two seconds of the end of the grace period
    function atGraceEnd(uint256 li, uint256 oi, uint256 pi, uint256 k, bool isTrial) external {
        uint256 e = nft.expiresAt(nft.computeId(labels[li % 3]));
        if (e != 0) {
            uint256 target = e + G - 61 + (k % 5) - 2;
            if (target > _now()) vm.warp(target);
        }
        _register(li, oi, pi, k, 0, isTrial);
    }

    // lands the registration within two seconds of the end of the trial pause
    function atPauseEnd(uint256 li, uint256 oi, uint256 pi, uint256 k, bool isTrial) external {
        uint256 e = nft.expiresAt(nft.computeId(labels[li % 3]));
        if (e != 0) {
            uint256 target = e + PAUSE - 61 + (k % 5) - 2;
            if (target > _now()) vm.warp(target);
        }
        _register(li, oi, pi, k, 0, isTrial);
    }

    function renew(uint256 li, uint256 pi) external {
        vm.recordLogs();
        string memory l = labels[li % 3];
        uint256 id = nft.computeId(l);
        uint256 fee = nft.getFee(bytes(l).length);
        vm.prank(actors[pi % 4]);
        (bool okN, bytes memory retN) = address(nft).call{value: fee}(abi.encodeCall(PageNFT.renew, (id)));
        vm.prank(actors[pi % 4]);
        (bool okM, bytes memory retM) = address(manual).call{value: fee}(abi.encodeCall(PageNFT.renew, (id)));
        _same(okN, retN, okM, retM);
        _consume();
        _compareAll();
    }

    function release(uint256 li, uint256 ci) external {
        vm.recordLogs();
        uint256 id = nft.computeId(labels[li % 3]);
        vm.prank(actors[ci % 4]);
        (bool okN, bytes memory retN) = address(nft).call(abi.encodeCall(PageNFT.release, (id)));
        vm.prank(actors[ci % 4]);
        (bool okM, bytes memory retM) = address(manual).call(abi.encodeCall(PageNFT.release, (id)));
        _same(okN, retN, okM, retM);
        _consume();
        _compareAll();
    }

    function withdraw(uint256 ai) external {
        vm.recordLogs();
        address[] memory w = everyone();
        address a = w[ai % w.length];
        (bool okN, bytes memory retN) = address(nft).call(abi.encodeCall(PageNFT.withdraw, (a)));
        (bool okM, bytes memory retM) = address(manual).call(abi.encodeCall(PageNFT.withdraw, (a)));
        _same(okN, retN, okM, retM);
        _consume();
        _compareAll();
    }

    function setAddr(uint256 li, uint256 si) external {
        uint256 id = nft.computeId(labels[li % 3]);
        address o = _ownerOr0(nft, id);
        if (o == address(0)) return;
        address a = si % 3 == 2 ? address(0) : savedAddrs[si % 3];
        vm.prank(o);
        (bool okN, bytes memory retN) = address(nft).call(abi.encodeCall(PageNFT.setAddr, (id, a)));
        vm.prank(o);
        (bool okM, bytes memory retM) = address(manual).call(abi.encodeCall(PageNFT.setAddr, (id, a)));
        _same(okN, retN, okM, retM);
        _compareAll();
    }

    function transfer(uint256 li, uint256 ti) external {
        uint256 id = nft.computeId(labels[li % 3]);
        address o = _ownerOr0(nft, id);
        if (o == address(0)) return;
        address to = ti % 5 == 4 ? DEAD : actors[ti % 5];
        vm.prank(o);
        (bool okN, bytes memory retN) = address(nft).call(abi.encodeCall(PageNFT.transferFrom, (o, to, id)));
        vm.prank(o);
        (bool okM, bytes memory retM) = address(manual).call(abi.encodeCall(PageNFT.transferFrom, (o, to, id)));
        _same(okN, retN, okM, retM);
        _compareAll();
    }

    function warp(uint256 secs) external {
        vm.warp(_now() + bound(secs, 1, 400 days));
        _compareAll();
    }
}

contract ReleaseFirstLockstepTest is Test {
    LockstepHandler h;
    PageNFT nft;
    PageNFT manual;

    function setUp() public {
        vm.warp(1_800_000_000);
        PageCard card = new PageCard();
        nft = new PageNFT(card);
        manual = PageNFT(address(new PageNFTManualRelease(card)));
        h = new LockstepHandler(nft, manual);
        bytes4[] memory sels = new bytes4[](11);
        sels[0] = h.buy.selector;
        sels[1] = h.trial.selector;
        sels[2] = h.atAuctionEnd.selector;
        sels[3] = h.atGraceEnd.selector;
        sels[4] = h.atPauseEnd.selector;
        sels[5] = h.renew.selector;
        sels[6] = h.release.selector;
        sels[7] = h.withdraw.selector;
        sels[8] = h.setAddr.selector;
        sels[9] = h.transfer.selector;
        sels[10] = h.warp.selector;
        targetSelector(FuzzSelector({addr: address(h), selectors: sels}));
        targetContract(address(h));
    }

    function _sum(PageNFT n) internal view returns (uint256 sum) {
        for (uint256 i; i < 3; ++i) {
            uint256 id = n.computeId(h.label(i));
            (, uint96 a) = n.trialPaymentOf(id);
            sum += n.depositOf(id) + a;
        }
        address[] memory w = h.everyone();
        for (uint256 i; i < w.length; ++i) sum += n.owed(w[i]);
    }

    // every wei held is a deposit, held trial money or a credit, on both builds
    function invariant_balanceIsTheLedger() public view {
        assertEq(address(nft).balance, _sum(nft));
        assertEq(address(manual).balance, _sum(manual));
    }

    // each deposit is the fees its logs added less the deposits its logs released, and never sits beside trial money
    function invariant_depositsMatchTheLogs() public view {
        for (uint256 i; i < 3; ++i) {
            uint256 id = nft.computeId(h.label(i));
            assertEq(nft.depositOf(id), h.added(id) - h.releasedOut(id), "deposit ledger");
            (, uint96 a) = nft.trialPaymentOf(id);
            assertTrue(a == 0 || nft.depositOf(id) == 0, "a deposit and trial money together");
        }
    }

    // each credit is what the logs credited less what they withdrew
    function invariant_owedMatchesTheLogs() public view {
        address[] memory w = h.everyone();
        for (uint256 i; i < w.length; ++i) {
            assertEq(nft.owed(w[i]), h.credited(w[i]) - h.withdrawnBy(w[i]), "owed ledger");
        }
    }

    // a fixed walk that registers at the last second of the auction and one second after it, paid and as a trial,
    // reaches each path the counters follow
    function test_walkReachesTheReleaseFirstPaths() public {
        h.buy(0, 0, 0, 0, 0);
        h.atAuctionEnd(0, 1, 1, 2, false);
        h.atAuctionEnd(0, 2, 2, 3, false);
        h.atAuctionEnd(0, 3, 3, 3, true);
        assertGt(h.atTheAuctionEnd(), 0, "a registration at the last second of the auction");
        assertGt(h.auctionBuys(), 0, "a deposit bought out in the auction");
        assertGt(h.oneSecondAfter(), 0, "a registration one second after it");
        assertGt(h.releasedByAPaidRegistration(), 0, "a paid registration released a deposit first");
        assertGt(h.releasedByATrial(), 0, "a trial released a deposit first");
        assertEq(h.failedRegistrations(), 0);
    }

    function afterInvariant() public {
        string memory line = string.concat(
            vm.toString(h.releasedByAPaidRegistration()), " releases by a paid registration, ",
            vm.toString(h.releasedByATrial()), " releases by a trial, ", vm.toString(h.auctionBuys()),
            " auction buys, ", vm.toString(h.atTheAuctionEnd()), " registrations at the last second of the auction, ",
            vm.toString(h.oneSecondAfter()), " one second after it, ", vm.toString(h.failedRegistrations()),
            " failed registrations"
        );
        vm.createDir("logs", true);
        vm.writeLine("logs/release-first-lockstep-stats.txt", line);
    }
}

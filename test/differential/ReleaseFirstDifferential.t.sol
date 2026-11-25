// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Vm} from "forge-std/Test.sol";
import {PageNFT} from "../../src/PageNFT.sol";
import {PageCard} from "../../src/PageCard.sol";
import {ReleaseFirstBase} from "./ReleaseFirstBase.sol";

// takes names and tries the guarded calls from inside the mint hook, keeping the first four bytes of each revert
contract HookReceiver {
    PageNFT public n;
    address public oldPayee;
    bytes4[] public errs;

    constructor(PageNFT nft, address payee_) {
        n = nft;
        oldPayee = payee_;
    }

    function errCount() external view returns (uint256) {
        return errs.length;
    }

    function _try(bytes memory data) internal {
        (bool ok, bytes memory ret) = address(n).call(data);
        errs.push(ok ? bytes4(0) : bytes4(ret));
    }

    function onERC721Received(address, address, uint256 id, bytes calldata) external returns (bytes4) {
        _try(abi.encodeCall(PageNFT.release, (id)));
        _try(abi.encodeCall(PageNFT.withdraw, (address(this))));
        _try(abi.encodeCall(PageNFT.withdraw, (oldPayee)));
        _try(abi.encodeCall(PageNFT.renew, (id)));
        return this.onERC721Received.selector;
    }

    receive() external payable {}
}

// A registration or trial after the auction first releases the old deposit to its payee. On the manual release
// build the same registration is made right after an explicit release, and both builds must then agree on the
// outcome, the revert data, every credit and the views that _sameName compares. Up to the end of the auction both
// builds must agree log for log.
contract ReleaseFirstDifferentialTest is ReleaseFirstBase {
    string constant L = "alice";
    string constant R = "daveref";
    bytes4 constant REENTRANCY = 0xab143c06;
    uint256 id;
    uint256 refId;
    uint256 E;
    uint256 dep;
    address[] who;

    // alice holds alice on both builds, with daveref of dave as referrer, renewed twice and shown as her display name
    function setUp() public override {
        super.setUp();
        refId = nft.computeId(R);
        id = nft.computeId(L);
        _commit(nft, dave, R, dave, 0, false);
        _commit(manual, dave, R, dave, 0, false);
        _commit(nft, alice, L, alice, refId, false);
        _commit(manual, alice, L, alice, refId, false);
        vm.warp(_now() + 61);
        _mustCall(nft, dave, R, dave, 0, false, FEE5);
        _mustCall(manual, dave, R, dave, 0, false, FEE5);
        _mustCall(nft, alice, L, alice, refId, false, FEE5);
        _mustCall(manual, alice, L, alice, refId, false, FEE5);
        vm.startPrank(alice);
        nft.renew{value: FEE5}(id);
        manual.renew{value: FEE5}(id);
        nft.renew{value: FEE5}(id);
        manual.renew{value: FEE5}(id);
        nft.setPrimaryPage(id);
        manual.setPrimaryPage(id);
        vm.stopPrank();
        E = nft.expiresAt(id);
        dep = nft.depositOf(id);
        assertEq(dep, 3 * FEE5);
        assertEq(manual.expiresAt(id), E);
        who.push(alice);
        who.push(bob);
        who.push(carol);
        who.push(dave);
        who.push(saved);
        who.push(DEAD);
    }

    struct Run {
        bool okN;
        bytes retN;
        bool okM;
        bytes retM;
        Vm.Log[] logsN;
        Vm.Log[] releaseLogsM;
        Vm.Log[] logsM;
    }

    // commits on both builds at t minus 61 and registers on both at t, on the manual release build right after a
    // release when the name still holds a deposit after its auction, and keeps the logs of each call
    function _lockstep(string memory l, address payer, address owner, uint256 ref, bool trial, uint256 t)
        internal
        returns (Run memory r)
    {
        uint256 tid = nft.computeId(l);
        vm.warp(t - 61);
        _commit(nft, payer, l, owner, ref, trial);
        _commit(manual, payer, l, owner, ref, trial);
        vm.warp(t);
        uint256 e = nft.expiresAt(tid);
        vm.recordLogs();
        if (e != 0 && t > e + G + D && manual.depositOf(tid) != 0) {
            vm.prank(dave);
            manual.release(tid);
        }
        r.releaseLogsM = vm.getRecordedLogs();
        uint256 vN = trial ? _price(nft, l, true) : _total(nft, l);
        uint256 vM = trial ? _price(manual, l, true) : _total(manual, l);
        assertEq(vN, vM, "the price is what release then registration costs");
        vm.recordLogs();
        (r.okN, r.retN) = _call(nft, payer, l, owner, ref, trial, vN + 7);
        r.logsN = vm.getRecordedLogs();
        vm.recordLogs();
        (r.okM, r.retM) = _call(manual, payer, l, owner, ref, trial, vM + 7);
        r.logsM = vm.getRecordedLogs();
    }

    function _sameLog(Vm.Log memory a, Vm.Log memory b) internal pure {
        assertEq(a.topics.length, b.topics.length, "topic count");
        for (uint256 j; j < a.topics.length; ++j) assertEq(a.topics[j], b.topics[j], "topic");
        assertEq(a.data, b.data, "data");
    }

    function _sameLogs(Vm.Log[] memory a, Vm.Log[] memory b) internal pure {
        assertEq(a.length, b.length, "log count");
        for (uint256 i; i < a.length; ++i) _sameLog(a[i], b[i]);
    }

    // after the auction the registration in src logs what release and then the same registration log on the manual
    // release build, less the MetadataUpdate of release, topic for topic and data for data
    function _sameLogsAsReleaseThenRegistration(Run memory r) internal pure {
        assertEq(r.releaseLogsM.length, 2, "release logs DepositReleased and MetadataUpdate");
        assertEq(r.releaseLogsM[0].topics[0], T_RELEASED);
        assertEq(r.logsN.length, r.logsM.length + 1, "the registration also logs the release");
        _sameLog(r.logsN[0], r.releaseLogsM[0]);
        for (uint256 i; i < r.logsM.length; ++i) _sameLog(r.logsN[i + 1], r.logsM[i]);
    }

    function _expectAt(uint256 offset, bool trial) internal {
        uint256 snap = vm.snapshotState();
        Run memory r = _lockstep(L, bob, bob, 0, trial, E + offset);
        (bool okN, bytes memory retN, Vm.Log[] memory logsN) = (r.okN, r.retN, r.logsN);
        assertEq(okN, r.okM, "same outcome as release then registration");
        assertEq(retN, r.retM, "same revert");
        _sameName(id, L);
        _sameName(refId, R);
        _sameOwed(who);

        if (offset <= G) {
            assertFalse(okN);
            // in grace the quote leaves out the deposit, so the fee check fails first
            assertEq(_sel(retN), trial ? PageNFT.TrialNotAllowed.selector : PageNFT.InsufficientFee.selector);
        } else if (offset <= G + D) {
            if (trial) {
                assertFalse(okN);
                assertEq(_sel(retN), PageNFT.TrialNotAllowed.selector);
            } else {
                assertTrue(okN);
                assertEq(_count(logsN, address(nft), T_BOUGHT), 1, "bought out in the auction");
                assertEq(_count(logsN, address(nft), T_RELEASED), 0, "no release in the auction");
                assertEq(nft.depositOf(id), dep + FEE5, "the deposit stays and grows");
            }
        } else {
            assertTrue(okN, "registrable after the auction");
            assertEq(_count(logsN, address(nft), T_RELEASED), 1, "released once");
            assertEq(_count(logsN, address(nft), T_BOUGHT), 0, "nothing bought out");
            assertEq(_count(logsN, address(nft), T_REF), 0);
            assertEq(_count(logsN, address(nft), T_OWNER), 0);
            assertEq(nft.depositOf(id), trial ? 0 : FEE5);
            assertEq(_held(nft, id), trial ? FEE5 / 10 : 0);
            _sameLogsAsReleaseThenRegistration(r);
        }
        if (offset <= G + D && okN) _sameLogs(logsN, r.logsM);
        vm.revertToState(snap);
    }

    function test_everyOffsetMatchesReleaseThenRegistration() public {
        uint256[17] memory offs = [
            uint256(1),
            G - 1,
            G,
            G + 1,
            G + 2,
            G + D / 2,
            G + D - 2,
            G + D - 1,
            G + D,
            G + D + 1,
            G + D + 2,
            G + D + 61,
            G + D + 1 days,
            G + D + 30 days,
            G + D + 365 days,
            G + D + 3 * 365 days,
            G + D + 9 * 365 days
        ];
        for (uint256 i; i < offs.length; ++i) {
            _expectAt(offs[i], false);
            _expectAt(offs[i], true);
        }
    }

    // the last second of the auction: no premium, the deposit is still bought out, release and trial are refused
    function test_lastSecondOfTheAuction() public {
        vm.warp(E + G + D - 61);
        _commit(nft, bob, L, bob, 0, false);
        _commit(nft, carol, L, carol, 0, true);
        vm.warp(E + G + D);
        (uint256 fee, uint256 carried, uint256 premium, uint256 total) = nft.quote(L);
        assertEq(fee, FEE5);
        assertEq(carried, dep);
        assertEq(premium, 0);
        assertEq(total, FEE5 + dep);
        assertFalse(nft.isReleasable(id));
        vm.expectRevert(PageNFT.NotReleasable.selector);
        nft.release(id);
        (bool ok, bytes memory ret) = _call(nft, carol, L, carol, 0, true, 1 ether);
        assertFalse(ok);
        assertEq(_sel(ret), PageNFT.TrialNotAllowed.selector);
        (ok, ret) = _call(nft, bob, L, bob, 0, false, total - 1);
        assertFalse(ok);
        assertEq(_sel(ret), PageNFT.InsufficientFee.selector);
        vm.recordLogs();
        (ok,) = _call(nft, bob, L, bob, 0, false, total);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertTrue(ok);
        assertEq(_count(logs, address(nft), T_BOUGHT), 1);
        assertEq(_count(logs, address(nft), T_RELEASED), 0);
        assertEq(nft.depositOf(id), dep + FEE5);
        assertEq(nft.owed(alice), dep);
    }

    // a registration one second after the auction pays the fee alone, the deposit goes to the old payee once, and the
    // release is logged first; the same holds long after it
    function test_paidRegistrationOneSecondAfterTheAuction() public {
        _afterAuctionCase(E + G + D + 1, false);
    }

    function test_trialOneSecondAfterTheAuction() public {
        _afterAuctionCase(E + G + D + 1, true);
    }

    function test_paidRegistrationLongAfterTheAuction() public {
        _afterAuctionCase(E + G + D + 800 days, false);
    }

    function test_trialLongAfterTheAuction() public {
        _afterAuctionCase(E + G + D + 800 days, true);
    }

    function _afterAuctionCase(uint256 t, bool trial) internal {
        vm.warp(t - 61);
        _commit(nft, bob, L, bob, 0, trial);
        vm.warp(t);
        assertTrue(nft.isReleasable(id));
        assertTrue(nft.isAvailable(L, 0));
        (uint256 fee, uint256 carried, uint256 premium, uint256 total) = nft.quote(L);
        assertEq(carried, 0);
        assertEq(premium, 0);
        assertEq(total, fee);
        uint256 price = trial ? fee / 10 : fee;
        assertEq(nft.payee(id), alice);
        (bool ok, bytes memory ret) = _call(nft, bob, L, bob, 0, trial, price - 1);
        assertFalse(ok);
        assertEq(_sel(ret), PageNFT.InsufficientFee.selector);
        assertEq(nft.depositOf(id), dep, "a failed registration releases nothing");
        assertEq(nft.owed(alice), 0);

        uint256 bobBefore = bob.balance;
        uint256 balBefore = address(nft).balance;
        vm.recordLogs();
        (ok,) = _call(nft, bob, L, bob, 0, trial, price + 1 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertTrue(ok);
        assertEq(bob.balance, bobBefore - price, "only the price is kept");
        assertEq(address(nft).balance, balBefore + price);
        assertEq(nft.owed(alice), dep, "the old payee is credited the deposit");
        assertEq(nft.owed(bob), 0);
        assertEq(nft.owed(dave), 0, "no referrer share after the auction");
        assertEq(nft.owed(DEAD), 0);
        assertEq(_count(logs, address(nft), T_RELEASED), 1);
        uint256 r = _index(logs, address(nft), T_RELEASED);
        assertEq(r, 0, "the release is the first log");
        assertEq(uint256(logs[r].topics[1]), id);
        assertEq(address(uint160(uint256(logs[r].topics[2]))), alice);
        assertEq(abi.decode(logs[r].data, (uint256)), dep);
        assertLt(r, _index(logs, address(nft), T_TRANSFER), "the release is logged before the burn");
        assertLt(r, _index(logs, address(nft), T_REGISTERED));
        assertEq(_count(logs, address(nft), T_BOUGHT), 0);
        assertEq(_count(logs, address(nft), T_REFUND), 0);
        if (trial) {
            assertEq(nft.depositOf(id), 0);
            assertEq(_held(nft, id), price);
            assertEq(uint256(nft.status(id)), uint256(PageCard.Status.Trial));
            assertEq(_count(logs, address(nft), T_STARTED), 1);
            assertEq(_count(logs, address(nft), T_ADDED), 0);
        } else {
            assertEq(nft.depositOf(id), fee);
            assertEq(_held(nft, id), 0);
            assertEq(uint256(nft.status(id)), uint256(PageCard.Status.Active));
            assertEq(_count(logs, address(nft), T_ADDED), 1);
        }
        assertEq(nft.ownerOf(id), bob);
        assertEq(nft.referrerOf(id), 0);
        assertFalse(nft.isReleasable(id));
        vm.expectRevert(PageNFT.NotReleasable.selector);
        nft.release(id);

        // the old deposit is never paid again later in the life of the name
        if (trial) {
            vm.warp(nft.expiresAt(id) + 1);
            nft.release(id);
            assertEq(nft.owed(bob), price, "the trial money goes back to its payer");
            assertEq(nft.owed(alice), dep);
            vm.expectRevert(PageNFT.NotReleasable.selector);
            nft.release(id);
            vm.warp(nft.expiresAt(id) + G + D + 1);
            vm.expectRevert(PageNFT.NothingToRelease.selector);
            nft.release(id);
        } else {
            vm.warp(nft.expiresAt(id) + G + D + 1);
            nft.release(id);
            assertEq(nft.owed(bob), fee, "the new holder gets only its own deposit");
            assertEq(nft.owed(alice), dep, "alice is paid once");
            vm.expectRevert(PageNFT.NothingToRelease.selector);
            nft.release(id);
        }
        assertEq(address(nft).balance, nft.owed(alice) + nft.owed(bob) + nft.depositOf(refId));
    }

    // a release by anyone before the registration leaves nothing for the registration to release
    function test_releaseThenRegistrationNoSecondCredit() public {
        vm.warp(E + G + D + 1);
        vm.prank(dave);
        nft.release(id);
        assertEq(nft.owed(alice), dep);
        vm.warp(E + G + D + 10 days);
        _commit(nft, bob, L, bob, 0, true);
        vm.warp(E + G + D + 10 days + 61);
        vm.recordLogs();
        (bool ok,) = _call(nft, bob, L, bob, 0, true, FEE5 / 10);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertTrue(ok);
        assertEq(_count(logs, address(nft), T_RELEASED), 0);
        assertEq(nft.owed(alice), dep);
    }

    // a first registration finds no deposit and logs no release
    function test_firstRegistrationLogsNoRelease() public {
        _commit(nft, bob, "fresh", bob, 0, false);
        vm.warp(_now() + 61);
        vm.recordLogs();
        (bool ok,) = _call(nft, bob, "fresh", bob, 0, false, FEE5);
        assertTrue(ok);
        assertEq(_count(vm.getRecordedLogs(), address(nft), T_RELEASED), 0);
    }

    // the deposit follows the payee rule: a saved address is paid, and the display name of alice is cleared
    function test_savedAddressIsPaid() public {
        vm.startPrank(alice);
        nft.setAddr(id, saved);
        nft.setPrimaryPage(id);
        vm.stopPrank();
        assertEq(nft.payee(id), saved);
        vm.warp(E + G + D + 5);
        _commit(nft, bob, L, bob, 0, false);
        vm.warp(E + G + D + 66);
        (bool ok,) = _call(nft, bob, L, bob, 0, false, FEE5);
        assertTrue(ok);
        assertEq(nft.owed(saved), dep);
        assertEq(nft.owed(alice), 0);
        assertEq(nft.primaryPage(alice), 0);
    }

    // a paid name alice sent to the dead address: its deposit goes to the dead address, as release would do
    function test_deadHolderDepositGoesToTheDeadAddress() public {
        vm.prank(alice);
        nft.transferFrom(alice, DEAD, id);
        vm.warp(E + G + D + 5);
        _commit(nft, bob, L, bob, 0, true);
        vm.warp(E + G + D + 66);
        (bool ok,) = _call(nft, bob, L, bob, 0, true, FEE5 / 10);
        assertTrue(ok);
        assertEq(nft.owed(DEAD), dep);
    }

    // alice takes her own lapsed name back after the auction: she pays the fee and gets her deposit back
    function test_lastHolderRegistersAgain() public {
        vm.warp(E + G + D + 5);
        _commit(nft, alice, L, alice, 0, false);
        vm.warp(E + G + D + 66);
        uint256 before = alice.balance;
        (bool ok,) = _call(nft, alice, L, alice, 0, false, FEE5);
        assertTrue(ok);
        assertEq(alice.balance, before - FEE5);
        assertEq(nft.owed(alice), dep);
        assertEq(nft.depositOf(id), FEE5);
    }

    // the mint hook of a contract owner reaches no guarded call while the registration runs: release, renew, its own
    // withdraw and the withdraw of the old payee, credited earlier in the same call, all revert with the reentrancy
    // error
    function test_hookCannotReenter() public {
        HookReceiver h = new HookReceiver(nft, alice);
        vm.warp(E + G + D + 5);
        _commit(nft, bob, L, address(h), 0, false);
        vm.warp(E + G + D + 66);
        (bool ok,) = _call(nft, bob, L, address(h), 0, false, FEE5);
        assertTrue(ok);
        assertEq(h.errCount(), 4);
        for (uint256 i; i < 4; ++i) assertEq(h.errs(i), REENTRANCY, "the guard refused it");
        assertEq(nft.owed(alice), dep);
        assertEq(nft.depositOf(id), FEE5);
    }

    // a trial name never holds a deposit, so both builds agree at every offset, before and after its money goes back
    function test_trialNamesAgree() public {
        string memory tl = "trialx";
        uint256 tid = nft.computeId(tl);
        _commit(nft, carol, tl, carol, refId, true);
        _commit(manual, carol, tl, carol, refId, true);
        vm.warp(_now() + 61);
        _mustCall(nft, carol, tl, carol, refId, true, FEE5 / 10);
        _mustCall(manual, carol, tl, carol, refId, true, FEE5 / 10);
        uint256 et = nft.expiresAt(tid);
        uint256[9] memory offs = [uint256(0), 1, PAUSE - 1, PAUSE, PAUSE + 1, G + D, G + D + 1, G + D + 2, 400 days];
        for (uint256 k; k < 2; ++k) {
            for (uint256 i; i < offs.length; ++i) {
                for (uint256 tr; tr < 2; ++tr) {
                    if (et + offs[i] < _now() + 61) continue;
                    uint256 snap = vm.snapshotState();
                    Run memory r = _lockstep(tl, bob, bob, 0, tr == 1, et + offs[i]);
                    assertEq(r.okN, r.okM);
                    assertEq(r.retN, r.retM);
                    if (r.okN) _sameLogs(r.logsN, r.logsM);
                    _sameName(tid, tl);
                    _sameOwed(who);
                    vm.revertToState(snap);
                }
            }
            if (k == 0) {
                vm.warp(et + 1);
                nft.release(tid);
                manual.release(tid);
                assertEq(nft.owed(carol), FEE5 / 10);
            }
        }
    }

    // after a release by anyone both builds agree at every offset
    function test_afterAReleaseBothAgree() public {
        vm.warp(E + G + D + 1);
        nft.release(id);
        manual.release(id);
        uint256[5] memory offs = [uint256(G + D + 100), G + D + 200, G + D + 2 days, G + D + 400 days, G + D + 9000 days];
        for (uint256 i; i < offs.length; ++i) {
            for (uint256 tr; tr < 2; ++tr) {
                uint256 snap = vm.snapshotState();
                Run memory r = _lockstep(L, bob, bob, refId, tr == 1, E + offs[i]);
                assertTrue(r.okN);
                assertEq(r.okN, r.okM);
                assertEq(r.retN, r.retM);
                assertEq(_count(r.logsN, address(nft), T_RELEASED), 0);
                _sameLogs(r.logsN, r.logsM);
                _sameName(id, L);
                _sameOwed(who);
                vm.revertToState(snap);
            }
        }
    }

    // quote is exactly what reveal requires at every second around the grace and auction ends
    function testFuzz_quoteIsTheRequiredValue(uint256 offset, bool trial) public {
        offset = bound(offset, 1, G + D + 5 days);
        uint256 t = E + offset;
        vm.warp(t - 61);
        _commit(nft, bob, L, bob, 0, trial);
        vm.warp(t);
        (uint256 fee, uint256 carried, uint256 premium, uint256 total) = nft.quote(L);
        (, uint256 carriedM, uint256 premiumM,) = manual.quote(L);
        assertEq(premium, premiumM);
        assertEq(premium, nft.getPremium(id));
        if (offset <= G + D) assertEq(carried, carriedM, "the same up to the end of the auction");
        else assertEq(carried, 0, "nothing carried after it");
        uint256 price = trial ? fee / 10 : total;
        if (!nft.isAvailable(L, 0)) {
            (bool okU, bytes memory retU) = _call(nft, bob, L, bob, 0, trial, 1 ether);
            assertFalse(okU);
            assertEq(_sel(retU), trial ? PageNFT.TrialNotAllowed.selector : PageNFT.AlreadyRegistered.selector);
            return;
        }
        (bool ok, bytes memory ret) = _call(nft, bob, L, bob, 0, trial, price - 1);
        assertFalse(ok);
        if (trial && offset <= G + D) {
            assertEq(_sel(ret), PageNFT.TrialNotAllowed.selector);
            return;
        }
        assertEq(_sel(ret), PageNFT.InsufficientFee.selector);
        (ok,) = _call(nft, bob, L, bob, 0, trial, price);
        assertTrue(ok);
    }

    // any moment after the auction, with a fuzzed referrer, payee and payer, the payer being a stranger, the old holder
    // or the holder of the referrer, equals release then registration
    function testFuzz_afterTheAuctionEqualsReleaseThenRegistration(
        uint256 offset, bool trial, bool useRef, bool useSaved, uint8 payerPick
    ) public {
        offset = bound(offset, G + D + 1, G + D + 4000 days);
        if (useSaved) {
            // the saved address shows the name as its display name too
            vm.prank(alice);
            nft.setAddr(id, saved);
            vm.prank(alice);
            manual.setAddr(id, saved);
            vm.prank(saved);
            nft.setPrimaryPage(id);
            vm.prank(saved);
            manual.setPrimaryPage(id);
        }
        address payer = payerPick % 3 == 0 ? carol : payerPick % 3 == 1 ? alice : dave;
        Run memory r = _lockstep(L, payer, bob, useRef ? refId : 0, trial, E + offset);
        assertTrue(r.okN);
        assertEq(r.okN, r.okM);
        assertEq(r.retN, r.retM);
        _sameLogsAsReleaseThenRegistration(r);
        _sameName(id, L);
        _sameName(refId, R);
        _sameOwed(who);
        assertEq(nft.owed(useSaved ? saved : alice), dep);
    }

    // up to the end of the auction both builds agree log for log
    function testFuzz_upToTheAuctionEndBothAgree(uint256 offset, bool trial, bool useRef) public {
        offset = bound(offset, 1, G + D);
        uint256 t = E + offset;
        vm.warp(t - 61);
        _commit(nft, carol, L, bob, useRef ? refId : 0, trial);
        _commit(manual, carol, L, bob, useRef ? refId : 0, trial);
        vm.warp(t);
        uint256 v = trial ? FEE5 / 10 : _total(manual, L);
        assertEq(_total(nft, L), _total(manual, L));
        vm.recordLogs();
        (bool okN, bytes memory retN) = _call(nft, carol, L, bob, useRef ? refId : 0, trial, v);
        Vm.Log[] memory a = vm.getRecordedLogs();
        (bool okM, bytes memory retM) = _call(manual, carol, L, bob, useRef ? refId : 0, trial, v);
        Vm.Log[] memory b = vm.getRecordedLogs();
        assertEq(okN, okM);
        assertEq(retN, retM);
        assertEq(a.length, b.length, "the same number of logs");
        for (uint256 i; i < a.length; ++i) {
            assertEq(a[i].data, b[i].data);
            assertEq(a[i].topics.length, b[i].topics.length);
            for (uint256 j; j < a[i].topics.length; ++j) assertEq(a[i].topics[j], b[i].topics[j]);
        }
        _sameName(id, L);
        _sameName(refId, R);
        _sameOwed(who);
    }

    // a trial started straight after the auction cannot revive the display name of the old pointee
    function test_trialAfterTheAuctionCannotReviveTheDisplayName() public {
        address hot = makeAddr("hot");
        address bot = makeAddr("bot");
        vm.prank(alice);
        nft.setAddr(id, hot);
        vm.prank(hot);
        nft.setPrimaryPage(id);
        vm.prank(alice);
        nft.setPrimaryPage(id);
        assertEq(nft.reverseResolve(hot), "alice");
        vm.warp(E + G + D + 1);
        _commit(nft, carol, L, bot, 0, true);
        vm.warp(E + G + D + 62);
        (bool ok,) = _call(nft, carol, L, bot, 0, true, FEE5 / 10);
        assertTrue(ok);
        assertEq(nft.owed(hot), dep, "the saved address was the payee");
        assertEq(nft.primaryPage(alice), 0, "the display name of the old holder is cleared");
        assertEq(nft.text(id, "url"), "");
        vm.startPrank(bot);
        nft.setAddr(id, hot);
        nft.setText(id, "url", "https://scam.example");
        nft.setContenthash(id, hex"e301");
        vm.stopPrank();
        assertEq(nft.resolve(id), hot);
        assertEq(nft.reverseResolve(hot), "", "still hidden");
    }

    // a bundle can release a deposit left after the auction but cannot register, since it carries no ETH
    function test_multicallReleasesButCannotRegister() public {
        vm.warp(E + G + D + 1 - 61);
        _commit(nft, bob, L, bob, 0, false);
        vm.warp(E + G + D + 1);
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(PageNFT.release, (id));
        calls[1] = abi.encodeCall(PageNFT.reveal, (L, bob, 0, _secret(L, bob, 0)));
        vm.prank(bob);
        vm.expectRevert(PageNFT.InsufficientFee.selector);
        nft.multicall(calls);
        assertEq(nft.depositOf(id), dep, "the failed bundle released nothing");
        calls = new bytes[](1);
        calls[0] = abi.encodeCall(PageNFT.release, (id));
        nft.multicall(calls);
        assertEq(nft.owed(alice), dep);
        assertEq(nft.depositOf(id), 0);
    }
}

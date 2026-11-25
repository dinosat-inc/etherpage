// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {trialCommitment} from "../../utils/TrialCommitment.sol";

import {Vm} from "forge-std/Test.sol";
import {PageNFT} from "../../../src/PageNFT.sol";
import {RulesBase} from "../../utils/RulesBase.sol";
import {LogShapes} from "../../utils/LogShapes.sol";

// makes calls as itself; it has no receive, so any ETH sent to it fails
contract NoReceivePayer {
    function exec(address to, uint256 value, bytes calldata data) external returns (bytes memory) {
        (bool ok, bytes memory ret) = to.call{value: value}(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        return ret;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}

// a holder or payee that takes names; kind 1 refuses ETH, kind 2 burns all gas on ETH, kind 3 calls back into
// PageNFT on ETH
contract HostileAccount {
    PageNFT immutable nft;
    uint8 public immutable kind;

    constructor(PageNFT n, uint8 k) {
        nft = n;
        kind = k;
    }

    function exec(address to, bytes calldata data) external {
        (bool ok, bytes memory ret) = to.call(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    receive() external payable {
        if (kind == 1) revert("no ETH");
        if (kind == 2) {
            uint256 x;
            while (true) ++x;
        }
        nft.withdraw(address(this));
    }
}

// takes names and refuses ETH
contract NameTaker {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}

// a payer whose refund reads the finished registration, or makes one call into PageNFT
contract WatchingPayer {
    PageNFT immutable nft;
    uint256 public id;
    address[] watched;
    bytes public seen;
    uint256 public refunds;
    bytes public call;
    bool public bubble;
    bytes public inner;

    constructor(PageNFT n) {
        nft = n;
    }

    function watch(uint256 tokenId, address[] calldata accounts) external {
        id = tokenId;
        watched = accounts;
    }

    function arm(bytes calldata c, bool b) external {
        call = c;
        bubble = b;
        delete inner;
    }

    function exec(address to, uint256 value, bytes calldata data) external returns (bytes memory) {
        (bool ok, bytes memory ret) = to.call{value: value}(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        return ret;
    }

    // the views a refund can read, in one blob
    function views() public view returns (bytes memory) {
        uint256[] memory owed = new uint256[](watched.length);
        for (uint256 i; i < watched.length; ++i) owed[i] = nft.owed(watched[i]);
        (string memory l, uint256 p, uint64 e, uint64 ep, uint64 pe) = nft.records(id);
        return abi.encode(
            nft.ownerOf(id), nft.depositOf(id), owed, nft.referrerOf(id), l, p, e, ep, pe, nft.recordVersion(id),
            address(nft).balance
        );
    }

    receive() external payable {
        ++refunds;
        if (call.length == 0) {
            seen = views();
            return;
        }
        (bool ok, bytes memory ret) = address(nft).call(call);
        if (!ok && bubble) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        inner = ok ? bytes("ok") : ret;
    }
}

// a payee whose receive renews a name, paying the yearly fee it was given, which it can do outside a payout
contract RenewingPayee {
    PageNFT immutable nft;
    uint256 immutable fee;
    uint256 public target;
    bool public bubble;
    bytes public inner;

    constructor(PageNFT n, uint256 f) {
        nft = n;
        fee = f;
    }

    function set(uint256 t, bool b) external {
        target = t;
        bubble = b;
    }

    function exec(address to, uint256 value, bytes calldata data) external returns (bytes memory) {
        (bool ok, bytes memory ret) = to.call{value: value}(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        return ret;
    }

    receive() external payable {
        (bool ok, bytes memory ret) = address(nft).call{value: fee}(abi.encodeCall(PageNFT.renew, (target)));
        if (!ok && bubble) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        inner = ok ? bytes("ok") : ret;
    }
}

// The change of a registration or a renewal goes back to its payer in the same call and to nobody else. Only the
// payer's own code can make that fail, and then its own call reverts as a whole.
contract PayerRefundsTest is RulesBase {
    bytes4 constant ETH_TRANSFER_FAILED = 0xb12d13eb;
    bytes4 constant REENTRANCY = 0xab143c06;

    function _id(string memory l) internal view returns (uint256) {
        return uint256(keccak256(abi.encodePacked(nft.ROOT(), keccak256(bytes(l)))));
    }

    // registers l for to with referrer ref, paid by payer at the exact price
    function _register(address payer, string memory l, address to, uint256 ref) internal returns (uint256 id) {
        bytes32 c = nft.makeCommitment(l, to, ref, _s(l, to, ref));
        vm.prank(payer);
        nft.commit(c);
        vm.warp(vm.getBlockTimestamp() + 61);
        (,,, uint256 total) = nft.quote(l);
        vm.deal(payer, payer.balance + total);
        vm.prank(payer);
        id = nft.reveal{value: total}(l, to, ref, _s(l, to, ref));
    }

    // a payer contract with no receive overpays: its own call reverts and its commitment stays; the exact amount works
    function test_refundToRejectingPayerRevertsOwnCall() public {
        NoReceivePayer p = new NoReceivePayer();
        vm.deal(address(p), 10 ether);
        string memory l = "alpha";
        bytes32 s = _s(l, address(p), 0);
        bytes32 c = nft.makeCommitment(l, address(p), 0, s);
        p.exec(address(nft), 0, abi.encodeCall(nft.commit, (c)));
        uint256 committedAt = vm.getBlockTimestamp();
        vm.warp(committedAt + 61);
        (,,, uint256 total) = nft.quote(l);
        bytes memory rv = abi.encodeCall(nft.reveal, (l, address(p), 0, s));
        vm.expectRevert(ETH_TRANSFER_FAILED);
        p.exec(address(nft), total + 1, rv);
        // the commitment survived, so the exact amount registers
        uint256 id = abi.decode(p.exec(address(nft), total, rv), (uint256));
        assertEq(nft.ownerOf(id), address(p));
        assertEq(address(p).balance, 10 ether - total);

        // a renewal the same way
        uint256 fee = nft.getFee(5);
        uint256 e = nft.expiresAt(id);
        bytes memory rn = abi.encodeCall(nft.renew, (id));
        vm.expectRevert(ETH_TRANSFER_FAILED);
        p.exec(address(nft), fee + 1, rn);
        p.exec(address(nft), fee, rn);
        assertEq(nft.expiresAt(id), e + 365 days);
        assertEq(nft.owed(address(p)), 0);
        assertEq(address(p).balance, 10 ether - total - fee);
    }

    // a sponsor with no receive registers for someone else: the exact total works, an overpayment reverts its own
    // call with its commitment kept, and the excess is never credited or sent to the owner
    function test_sponsorWithNoReceiveRegistersForAnother() public {
        NoReceivePayer p = new NoReceivePayer();
        vm.deal(address(p), 10 ether);
        string[2] memory ls = ["first", "second"];
        bytes32[2] memory cs;
        for (uint256 i; i < 2; ++i) {
            cs[i] = nft.makeCommitment(ls[i], user, 0, _s(ls[i], user, 0));
            p.exec(address(nft), 0, abi.encodeCall(nft.commit, (cs[i])));
        }
        uint256 committedAt = vm.getBlockTimestamp();
        vm.warp(committedAt + 61);
        (,,, uint256 total) = nft.quote(ls[0]);
        bytes memory first = abi.encodeCall(nft.reveal, (ls[0], user, 0, _s(ls[0], user, 0)));
        uint256 id = abi.decode(p.exec(address(nft), total, first), (uint256));
        assertEq(nft.ownerOf(id), user);
        assertEq(address(p).balance, 10 ether - total);

        bytes memory rv = abi.encodeCall(nft.reveal, (ls[1], user, 0, _s(ls[1], user, 0)));
        vm.expectRevert(ETH_TRANSFER_FAILED);
        p.exec(address(nft), total + 1 ether, rv);
        // the commitment survived, so the exact total registers
        uint256 id2 = abi.decode(p.exec(address(nft), total, rv), (uint256));
        assertEq(nft.ownerOf(id2), user);
        assertEq(address(p).balance, 10 ether - 2 * total);
    }

    function _hostile(uint8 k) internal returns (address) {
        return address(new HostileAccount(nft, k));
    }

    struct Scenario {
        uint256 prize;
        address payee;
        address refPayee;
        uint256 carried;
    }

    // prize, referred by refname, with a hostile holder, payee or referrer payee as asked
    function _setUpScenario(uint8 holderKind, uint8 payeeKind, uint8 refKind) internal returns (Scenario memory s) {
        // the referrer name is held by dave, who points it at a hostile account when asked
        uint256 ref = _register(dave, "refname", dave, 0);
        s.refPayee = dave;
        if (refKind != 0) {
            s.refPayee = _hostile(refKind);
            vm.prank(dave);
            nft.setAddr(ref, s.refPayee);
        }
        address holder = holderKind == 0 ? bob : _hostile(holderKind);
        s.prize = _register(bob, "prize", holder, ref);
        s.payee = holder;
        if (payeeKind != 0) {
            s.payee = _hostile(payeeKind);
            if (holder == bob) {
                vm.prank(bob);
                nft.setAddr(s.prize, s.payee);
            } else {
                HostileAccount(payable(holder)).exec(address(nft), abi.encodeCall(nft.setAddr, (s.prize, s.payee)));
            }
        }
        s.carried = nft.depositOf(s.prize);
    }

    // a hostile previous holder, payee or referrer payee, each in turn and all at once, cannot stop an auction or
    // change the change an ordinary payer gets back, and the new owner may be a contract that refuses ETH
    function test_refundCannotBeBlockedByThirdParty() public {
        uint256 snap = vm.snapshotState();
        uint8[4][12] memory cases;
        for (uint8 k = 1; k <= 3; ++k) {
            cases[(k - 1) * 4] = [k, 0, 0, 0];
            cases[(k - 1) * 4 + 1] = [0, k, 0, 1];
            cases[(k - 1) * 4 + 2] = [0, 0, k, 0];
            cases[(k - 1) * 4 + 3] = [k, k, k, 1];
        }
        for (uint256 i; i < cases.length; ++i) {
            vm.revertToState(snap);
            Scenario memory s = _setUpScenario(cases[i][0], cases[i][1], cases[i][2]);
            // the new owner refuses ETH in half the cases; in the others the payer registers for itself
            address to = cases[i][3] == 1 ? address(new NameTaker()) : carol;
            vm.warp(nft.expiresAt(s.prize) + 90 days + 1);
            bytes32 sec = _s("prize", to, 0);
            bytes32 c = nft.makeCommitment("prize", to, 0, sec);
            vm.prank(carol);
            nft.commit(c);
            vm.warp(vm.getBlockTimestamp() + 61);
            (, uint256 carried, uint256 premium, uint256 total) = nft.quote("prize");
            assertEq(carried, s.carried);
            assertGt(premium, 0, "inside the premium window");
            vm.deal(carol, total + 2 ether);
            uint256 before = carol.balance;
            vm.prank(carol);
            nft.reveal{value: total + 1 ether}("prize", to, 0, sec);
            assertEq(before - carol.balance, total, string.concat("the payer keeps its change, case ", vm.toString(i)));
            assertEq(nft.ownerOf(s.prize), to);
            uint256 refShare = premium * 2500 / 10000;
            if (s.payee == s.refPayee) {
                assertEq(nft.owed(s.payee), carried + premium);
            } else {
                assertEq(nft.owed(s.payee), carried + premium - refShare, "the old payee's credit");
                assertEq(nft.owed(s.refPayee), refShare, "the referrer payee's credit");
            }
            // a renewal by the same payer, overpaid
            uint256 fee = nft.getFee(5);
            before = carol.balance;
            vm.prank(carol);
            nft.renew{value: fee + 1 ether}(s.prize);
            assertEq(before - carol.balance, fee, "the renewal keeps exactly the fee");
        }
    }

    // the payer's refund runs after everything else: inside it every view already holds its final value, and
    // the contract's balance is the deposits plus the credits
    function test_refundHookSeesFinishedCall() public {
        uint256 r1 = _register(dave, "refone", dave, 0);
        uint256 r2 = _register(dave, "reftwo", dave, 0);
        uint256 prize = _register(bob, "prize", bob, r1);
        vm.warp(nft.expiresAt(prize) + 90 days + 1);
        WatchingPayer w = new WatchingPayer(nft);
        vm.deal(address(w), 1000 ether);
        address[] memory accounts = new address[](4);
        accounts[0] = bob;
        accounts[1] = dave;
        accounts[2] = DEAD;
        accounts[3] = address(w);
        w.watch(prize, accounts);
        bytes32 sec = _s("prize", carol, r2);
        w.exec(address(nft), 0, abi.encodeCall(nft.commit, (nft.makeCommitment("prize", carol, r2, sec))));
        vm.warp(vm.getBlockTimestamp() + 61);
        (,,, uint256 total) = nft.quote("prize");
        w.exec(address(nft), total + 1 ether, abi.encodeCall(nft.reveal, ("prize", carol, r2, sec)));
        assertEq(w.refunds(), 1);
        assertEq(keccak256(w.seen()), keccak256(w.views()), "every view read in the refund is final");
        assertEq(nft.ownerOf(prize), carol);
        assertEq(nft.referrerOf(prize), r2);
        uint256 held = nft.depositOf(r1) + nft.depositOf(r2) + nft.depositOf(prize) + nft.owed(bob) + nft.owed(dave)
            + nft.owed(DEAD);
        (,,,,,,,,,, uint256 balanceSeen) = abi.decode(
            w.seen(), (address, uint256, uint256[], uint256, string, uint256, uint64, uint64, uint64, uint256, uint256)
        );
        assertEq(balanceSeen, held, "the balance inside the refund is the deposits plus the credits");
        assertEq(address(nft).balance, held);

        // a renewal by the same payer
        uint256 fee = nft.getFee(5);
        w.exec(address(nft), fee + 1 ether, abi.encodeCall(nft.renew, (prize)));
        assertEq(w.refunds(), 2);
        assertEq(keccak256(w.seen()), keccak256(w.views()), "every view read in the renewal refund is final");
    }

    // the same refund calling a guarded entry point gets Reentrancy; when it passes that on, its own call fails
    function test_refundHookCannotEnterAndFailsItsOwnCall() public {
        uint256 other = _register(bob, "other", bob, 0);
        _trial("ended", user);
        WatchingPayer w = new WatchingPayer(nft);
        vm.deal(address(w), 1000 ether);
        bytes[4] memory calls = [
            abi.encodeCall(nft.reveal, ("zzzzz", carol, 0, bytes32(0))),
            abi.encodeCall(nft.renew, (other)),
            abi.encodeCall(nft.release, (_id("ended"))),
            abi.encodeCall(nft.withdraw, (bob))
        ];
        uint256 fee = nft.getFee(5);
        for (uint256 i; i < 4; ++i) {
            // the refund records what the call gave
            w.arm(calls[i], false);
            w.exec(address(nft), fee + 1, abi.encodeCall(nft.renew, (other)));
            assertEq(w.inner(), abi.encodeWithSelector(REENTRANCY), string.concat("call ", vm.toString(i)));
            // the refund passes the refusal on: the payer's renewal reverts as a whole
            w.arm(calls[i], true);
            uint256 e = nft.expiresAt(other);
            vm.expectRevert(ETH_TRANSFER_FAILED);
            w.exec(address(nft), fee + 1, abi.encodeCall(nft.renew, (other)));
            // the exact fee makes no call, so the same payer renews
            w.exec(address(nft), fee, abi.encodeCall(nft.renew, (other)));
            assertEq(nft.expiresAt(other), e + 365 days);
        }
        // a registration whose refund passes the refusal on reverts too, and its commitment stays
        w.arm(calls[3], true);
        bytes32 sec = _s("fresh", carol, 0);
        bytes32 c = nft.makeCommitment("fresh", carol, 0, sec);
        w.exec(address(nft), 0, abi.encodeCall(nft.commit, (c)));
        uint256 committedAt = vm.getBlockTimestamp();
        vm.warp(committedAt + 61);
        (,,, uint256 total) = nft.quote("fresh");
        vm.expectRevert(ETH_TRANSFER_FAILED);
        w.exec(address(nft), total + 1, abi.encodeCall(nft.reveal, ("fresh", carol, 0, sec)));
        // the commitment survived, so the exact total registers
        w.exec(address(nft), total, abi.encodeCall(nft.reveal, ("fresh", carol, 0, sec)));
        assertEq(nft.ownerOf(_id("fresh")), carol);
    }

    // the credit of DEAD leaves only through withdraw(DEAD), which anyone may call and which logs Withdrawn
    function test_withdrawDeadBurnsCredit() public {
        uint256 id = _register(bob, "alpha", bob, 0);
        vm.warp(nft.expiresAt(id) + 90 days + 1);
        _commitPaid(carol, "alpha", carol, 0);
        vm.warp(vm.getBlockTimestamp() + 61);
        (,, uint256 premium, uint256 total) = nft.quote("alpha");
        vm.prank(carol);
        nft.reveal{value: total}("alpha", carol, 0, _s("alpha", carol, 0));
        uint256 owedDead = nft.owed(DEAD);
        assertEq(owedDead, premium * 2500 / 10000, "a name with no referrer gives the referrer share to DEAD");
        uint256 deadBalance = DEAD.balance;
        uint256 nftBalance = address(nft).balance;
        vm.recordLogs();
        vm.prank(dave);
        uint256 paid = nft.withdraw(DEAD);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].emitter, address(nft));
        assertEq(LogShapes.hashOf(logs[0]), LogShapes.withdrawn(DEAD, dave, owedDead), "Withdrawn(DEAD, caller, amount)");
        assertEq(paid, owedDead);
        assertEq(DEAD.balance, deadBalance + owedDead, "the credit reaches DEAD");
        assertEq(address(nft).balance, nftBalance - owedDead);
        assertEq(nft.owed(DEAD), 0);
        vm.prank(user);
        vm.expectRevert(PageNFT.NothingToWithdraw.selector);
        nft.withdraw(DEAD);
    }

    // a payee whose receive renews a name and passes on the refusal cannot be paid, whoever asks, and its credit
    // stays; the refusal it passes on is the reentrancy guard
    function test_withdrawRevertsForCallbackingPayee() public {
        uint256 target = _register(bob, "target", bob, 0);
        uint256 targetFee = nft.getFee(bytes("target").length);
        RenewingPayee p = new RenewingPayee(nft, targetFee);
        vm.deal(address(p), 1 ether);
        // the payee is credited back the price of a trial it paid for, once someone pays the year
        string memory l = "credit";
        bytes32 tc = trialCommitment(address(nft), l, user, 0, _s(l, user, 0));
        p.exec(address(nft), 0, abi.encodeCall(nft.commit, (tc)));
        vm.warp(vm.getBlockTimestamp() + 61);
        uint256 price = _price(l);
        bytes memory rt = abi.encodeCall(nft.revealTrial, (l, user, 0, _s(l, user, 0)));
        uint256 t = abi.decode(p.exec(address(nft), price, rt), (uint256));
        uint256 year = nft.getFee(6);
        vm.prank(carol);
        nft.renew{value: year}(t);
        assertEq(nft.owed(address(p)), price);

        // outside a payout the payee renews the target
        uint256 e = nft.expiresAt(target);
        p.exec(address(nft), targetFee, abi.encodeCall(nft.renew, (target)));
        assertEq(nft.expiresAt(target), e + 365 days);
        e = nft.expiresAt(target);

        p.set(target, true);
        vm.expectRevert(ETH_TRANSFER_FAILED);
        p.exec(address(nft), 0, abi.encodeCall(nft.withdraw, (address(p))));
        vm.prank(dave);
        vm.expectRevert(ETH_TRANSFER_FAILED);
        nft.withdraw(address(p));

        // when it keeps the refusal instead, the payout goes through and shows the refusal was Reentrancy
        p.set(target, false);
        uint256 balance = address(p).balance;
        vm.prank(dave);
        nft.withdraw(address(p));
        assertEq(p.inner(), abi.encodeWithSelector(REENTRANCY));
        assertEq(nft.expiresAt(target), e, "no renewal happened inside the payout");
        assertEq(address(p).balance, balance + price);
        assertEq(nft.owed(address(p)), 0);
    }
}

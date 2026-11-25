// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {trialCommitmentRaw} from "../utils/TrialCommitment.sol";

import {Test, Vm} from "forge-std/Test.sol";
import {PageNFT} from "../../src/PageNFT.sol";
import {PageCard} from "../../src/PageCard.sol";

// random walks of trials, paid registrations, renewals, transfers, subpages, releases and withdrawals;
// trial prices are held and credited back to their payers
contract TrialHandler is Test {
    PageNFT public nft;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address[4] public actors;
    string[5] public labels = ["a", "abc", "alpha", "bravo", "charlie-d"];
    string[2] public subLabels = ["x", "yy"];

    // money that came in through trial prices and through everything else, and what withdrawals paid to DEAD
    // and to the actors
    uint256 public trialIn;
    uint256 public otherIn;
    uint256 public outDead;
    uint256 public outOthers;
    // what the last trial of each id looked like
    mapping(uint256 => address) public trialOwner;
    mapping(uint256 => uint256) public trialStart;
    mapping(uint256 => uint64) public trialEpoch;
    // the epoch in which a name was last paid for
    mapping(uint256 => uint64) public paidEpoch;
    mapping(uint256 => bool) public paidInEpoch;
    bool public subUnderUnpaid;
    uint256 public trials;
    uint256 public conversions;
    uint256 public lapsesRetaken;
    // trial money as the handler models it: held per id, and what the TrialRefunded logs gave back
    mapping(uint256 => address) public heldPayer;
    mapping(uint256 => uint256) public heldAmount;
    uint256 public refunded;
    bool public wrongRefund;

    bytes32 constant T_REFUNDED = keccak256("TrialRefunded(uint256,address,uint256)");
    bytes32 constant T_STARTED = keccak256("TrialStarted(uint256,address,uint256)");

    // every call is recorded; each refund must name the payer the model holds for that id, with its
    // amount, and each new trial is added to the model
    modifier logged() {
        vm.recordLogs();
        _;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(nft) || logs[i].topics.length == 0) continue;
            if (logs[i].topics[0] == T_REFUNDED) {
                uint256 id = uint256(logs[i].topics[1]);
                address to = address(uint160(uint256(logs[i].topics[2])));
                uint256 amount = abi.decode(logs[i].data, (uint256));
                if (to != heldPayer[id] || amount != heldAmount[id] || amount == 0) wrongRefund = true;
                refunded += amount;
                heldAmount[id] = 0;
                heldPayer[id] = address(0);
            } else if (logs[i].topics[0] == T_STARTED) {
                uint256 id = uint256(logs[i].topics[1]);
                if (heldAmount[id] != 0) wrongRefund = true;
                heldPayer[id] = address(uint160(uint256(logs[i].topics[2])));
                heldAmount[id] = abi.decode(logs[i].data, (uint256));
            }
        }
    }

    constructor(PageNFT n) {
        nft = n;
        actors = [makeAddr("a0"), makeAddr("a1"), makeAddr("a2"), makeAddr("a3")];
        for (uint256 i; i < 4; ++i) vm.deal(actors[i], 1e9 ether);
    }

    function _id(uint256 li) internal view returns (uint256) {
        return nft.computeId(labels[li % 5]);
    }

    function _commit(address from, string memory l, address owner, bytes32 s, bool trialForm) internal returns (bool) {
        bytes32 c = nft.makeCommitment(l, owner, 0, s);
        if (trialForm) c = trialCommitmentRaw(l, owner, 0, s);
        vm.prank(from);
        try nft.commit(c) {
            return true;
        } catch {
            return false;
        }
    }

    function trial(uint256 li, uint256 oi, uint256 pi, uint256 extra) external logged {
        string memory l = labels[li % 5];
        address owner = actors[oi % 4];
        address payer = actors[pi % 4];
        bytes32 s = keccak256(abi.encode(l, owner, block.timestamp));
        if (!_commit(payer, l, owner, s, true)) return;
        vm.warp(block.timestamp + 61);
        uint256 id = nft.computeId(l);
        uint256 price = nft.getFee(bytes(l).length) / 10;
        extra = bound(extra, 0, 1 ether);
        bool hadRecord = nft.expiresAt(id) != 0;
        vm.prank(payer);
        try nft.revealTrial{value: price + extra}(l, owner, 0, s) {
            trialIn += price;
            trialOwner[id] = owner;
            trialStart[id] = block.timestamp;
            trialEpoch[id] = nft.epochOf(id);
            paidInEpoch[id] = false;
            ++trials;
            if (hadRecord) ++lapsesRetaken;
        } catch {}
    }

    function paid(uint256 li, uint256 oi) external logged {
        string memory l = labels[li % 5];
        address owner = actors[oi % 4];
        bytes32 s = keccak256(abi.encode("paid", l, owner, block.timestamp));
        if (!_commit(owner, l, owner, s, false)) return;
        vm.warp(block.timestamp + 61);
        (,,, uint256 total) = nft.quote(l);
        uint256 id = nft.computeId(l);
        vm.prank(owner);
        try nft.reveal{value: total}(l, owner, 0, s) {
            otherIn += total;
            paidEpoch[id] = nft.epochOf(id);
            paidInEpoch[id] = true;
        } catch {}
    }

    function renew(uint256 li, uint256 pi) external logged {
        uint256 id = _id(li);
        uint256 fee = nft.getFee(bytes(labels[li % 5]).length);
        bool unpaid = nft.depositOf(id) == 0;
        vm.prank(actors[pi % 4]);
        try nft.renew{value: fee}(id) {
            otherIn += fee;
            paidEpoch[id] = nft.epochOf(id);
            paidInEpoch[id] = true;
            if (unpaid) ++conversions;
        } catch {}
    }

    function transfer(uint256 li, uint256 ti, bool toDead) external logged {
        uint256 id = _id(li);
        address from;
        try nft.ownerOf(id) returns (address o) {
            from = o;
        } catch {
            return;
        }
        if (from == DEAD) return;
        address to = toDead ? DEAD : actors[ti % 4];
        vm.prank(from);
        try nft.transferFrom(from, to, id) {} catch {}
    }

    function sub(uint256 li, uint256 si) external logged {
        uint256 id = _id(li);
        address owner;
        try nft.ownerOf(id) returns (address o) {
            owner = o;
        } catch {
            return;
        }
        bool unpaid = nft.depositOf(id) == 0;
        vm.prank(owner);
        try nft.registerSubpage(subLabels[si % 2], id) {
            if (unpaid) subUnderUnpaid = true;
        } catch {}
    }

    function release(uint256 li) external logged {
        try nft.release(_id(li)) {} catch {}
    }

    function withdraw(uint256 ai, bool dead) external logged {
        address a = dead ? DEAD : actors[ai % 4];
        uint256 amount = nft.owed(a);
        try nft.withdraw(a) {
            if (dead) outDead += amount;
            else outOthers += amount;
        } catch {}
    }

    function warp(uint256 secs) external {
        // mostly short steps so trials are often live, sometimes long ones to reach grace, auction and release
        if (secs % 4 == 0) vm.warp(block.timestamp + bound(secs, 1, 130 days));
        else vm.warp(block.timestamp + bound(secs, 1, 4 days));
    }
}

contract TrialInvariantTest is Test {
    PageNFT nft;
    TrialHandler h;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    function setUp() public {
        vm.warp(1_800_000_000);
        nft = new PageNFT(new PageCard());
        h = new TrialHandler(nft);
        targetContract(address(h));
    }

    function _sums() internal view returns (uint256 deposits, uint256 owedOthers, uint256 held) {
        for (uint256 i; i < 5; ++i) {
            uint256 id = nft.computeId(h.labels(i));
            deposits += nft.depositOf(id);
            (, uint256 a) = nft.trialPaymentOf(id);
            held += a;
        }
        for (uint256 i; i < 4; ++i) owedOthers += nft.owed(h.actors(i));
    }

    // every wei held is a deposit, a credit or a trial price still held
    function invariant_balanceIsLedgers() public view {
        (uint256 d, uint256 o, uint256 held) = _sums();
        assertEq(address(nft).balance, d + o + nft.owed(DEAD) + held);
    }

    // trial money is held for its payer and goes back only to that payer: the contract holds exactly
    // what the model holds, every refund named the modelled payer and amount, and nothing is lost
    function invariant_trialMoneyGoesBackToItsPayer() public view {
        assertFalse(h.wrongRefund(), "a refund went to someone other than the payer, or with another amount");
        (,, uint256 held) = _sums();
        assertEq(held + h.refunded(), h.trialIn(), "every trial price is held or was refunded");
        for (uint256 i; i < 5; ++i) {
            uint256 id = nft.computeId(h.labels(i));
            (address p, uint256 a) = nft.trialPaymentOf(id);
            assertEq(p, h.heldPayer(id));
            assertEq(a, h.heldAmount(id));
        }
    }

    // per name: no premium and no grace without a deposit, isAvailable agrees with the grace end,
    // an unpaid live name is the trial's, and a paid name never loses its deposit while live
    function invariant_perName() public view {
        for (uint256 i; i < 5; ++i) {
            string memory l = h.labels(i);
            uint256 id = nft.computeId(l);
            uint256 e = nft.expiresAt(id);
            if (e == 0) {
                assertTrue(nft.isAvailable(l, 0));
                continue;
            }
            uint256 dep = nft.depositOf(id);
            uint256 graceEnd = dep == 0 ? e : e + 90 days;
            if (dep == 0) {
                assertEq(nft.getPremium(id), 0, "no premium without a deposit");
                assertFalse(nft.inGracePeriod(id), "no grace without a deposit");
            }
            assertEq(nft.isAvailable(l, 0), block.timestamp > graceEnd, "availability");
            assertEq(nft.isExpired(id), block.timestamp > graceEnd, "isExpired");
            bool live = block.timestamp <= e;
            (, uint256 held) = nft.trialPaymentOf(id);
            assertTrue(held == 0 || dep == 0, "held money and a deposit never together");
            if (live && dep == 0) {
                address o = nft.ownerOf(id);
                assertGt(held, 0, "a live trial holds its price");
                assertTrue(o == h.trialOwner(id) || o == DEAD, "an unpaid name stays with its trial owner");
                assertEq(e, h.trialStart(id) + 14 days, "a trial lasts fourteen days");
                assertEq(nft.epochOf(id), h.trialEpoch(id));
                assertFalse(h.paidInEpoch(id) && h.paidEpoch(id) == nft.epochOf(id), "a paid live name keeps a deposit");
            }
            // subpages of an unpaid parent never count
            for (uint256 j; j < 2; ++j) {
                uint256 sid = nft.computeId(string.concat(h.subLabels(j), ".", l));
                if (dep == 0 && live) assertEq(nft.resolve(sid), address(0), "no live subpage under a trial");
            }
        }
        assertFalse(h.subUnderUnpaid(), "no subpage minted under an unpaid parent");
    }

    function afterInvariant() public {
        vm.createDir("logs", true);
        vm.writeLine(
            "logs/inv-stats.txt",
            string.concat(
                vm.toString(h.trials()), " ", vm.toString(h.conversions()), " ", vm.toString(h.lapsesRetaken())
            )
        );
    }
}

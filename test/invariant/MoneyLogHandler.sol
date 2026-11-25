// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {trialCommitmentRaw} from "../utils/TrialCommitment.sol";

import {Vm} from "forge-std/Test.sol";
import {PageNFT} from "../../src/PageNFT.sol";
import {MoneyLogReplay, LedgerForce, LedgerRefuser, LedgerHolder} from "../utils/MoneyLogReplay.sol";

// Random walks over paid registrations with and without referrers, auctions, renewals, trials and every way
// their money goes back, releases, withdrawals, bundles, and transfers and saved addresses that move the
// payee, plus subpages and ETH forced in. Payers send a random excess, which must come straight back. The
// money events of every call that succeeded are replayed, and the checks compare the replay with the
// contract after every call. Three key wallets, a contract that holds names and takes ETH, a payer that
// takes no ETH and the dead address are the accounts. Every withdrawal, alone or in a bundle, is also watched on
// the balances of every account, the caller included: only the account it pays may gain, by exactly what it
// was owed, and only the PageNFT may lose.
contract MoneyLogHandler is MoneyLogReplay {
    PageNFT public nft;
    LedgerRefuser public refuser;
    LedgerHolder public holder;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 constant GRACE = 90 days;
    uint256 constant DECAY = 21 days;
    address[3] public actors;
    string[6] public labels = ["a", "ab", "abc", "alpha", "bravo", "charlie"];
    // the top level id of each label, each followed by the id of its subpage x
    uint256[] public ids;
    uint256 public forced;
    uint256 nonce;

    // what the money events of calls that succeeded credited to each account
    mapping(address => uint256) public credited;
    // the ETH each account gained during withdrawals, read on its balance
    mapping(address => uint256) public received;
    // withdrawals that moved a balance other than the one they paid or paid other than what was owed, and the
    // first of them
    uint256 public strays;
    string public firstStray;

    // what the walk reached
    uint256 public registrations;
    uint256 public auctions;
    uint256 public trials;
    uint256 public renewals;
    uint256 public conversions;
    uint256 public depositReleases;
    uint256 public trialReleases;
    uint256 public withdrawals;
    uint256 public bundles;
    uint256 public moves;
    uint256 public refusedRefunds;

    constructor(PageNFT n) {
        nft = n;
        refuser = new LedgerRefuser();
        holder = new LedgerHolder();
        actors = [makeAddr("money-log-a0"), makeAddr("money-log-a1"), makeAddr("money-log-a2")];
        for (uint256 i; i < 3; ++i) {
            vm.deal(actors[i], 1e9 ether);
            _track(actors[i]);
        }
        _track(address(refuser));
        _track(address(holder));
        _track(DEAD);
        for (uint256 i; i < 6; ++i) {
            ids.push(n.computeId(labels[i]));
            ids.push(n.computeId(string.concat("x.", labels[i])));
        }
    }

    function idsLength() external view returns (uint256) {
        return ids.length;
    }

    function _top(uint256 li) internal view returns (uint256) {
        return ids[2 * (li % 6)];
    }

    // In half of the calls, the first label from li on that suits the action, so that most attempts can
    // succeed: one in its auction, else a free one, for a registration; a free one with no deposit for a
    // trial; a live or grace one for a renewal; a releasable one for a release.
    function _pick(uint256 li, uint256 kind) internal view returns (uint256) {
        uint256 start = li % 6;
        if ((li >> 128) % 2 == 1) return start;
        for (uint256 round; round < 2; ++round) {
            for (uint256 i; i < 6; ++i) {
                uint256 k = (start + i) % 6;
                uint256 id = ids[2 * k];
                bool fits;
                if (kind == 0) fits = round == 0 ? nft.getPremium(id) != 0 : nft.isAvailable(labels[k], 0);
                else if (kind == 1) fits = nft.isAvailable(labels[k], 0) && nft.depositOf(id) == 0;
                else if (kind == 2) fits = nft.expiresAt(id) != 0 && !nft.isExpired(id);
                else fits = nft.isReleasable(id);
                if (fits) return k;
            }
            if (kind != 0) break;
        }
        return start;
    }

    function _ownerOf(uint256 id) internal view returns (address o) {
        try nft.ownerOf(id) returns (address x) {
            o = x;
        } catch {}
    }

    function _ownerFor(uint256 oi) internal view returns (address) {
        if (oi % 8 == 7) return DEAD;
        if (oi % 4 == 3) return address(holder);
        return actors[oi % 3];
    }

    function _payerFor(uint256 pi) internal view returns (address) {
        return pi % 4 == 3 ? address(refuser) : actors[pi % 3];
    }

    // no referrer, a top level name of the pool, a subpage or an id with no record
    function _refFor(uint256 ri, uint256 id) internal view returns (uint256 ref) {
        uint256 k = ri % 5;
        if (k == 0) return 0;
        if (k == 3) return nft.computeId("ghost");
        if (k == 4) return ids[2 * ((ri >> 8) % 6) + 1];
        ref = ids[2 * ((ri >> 8) % 6)];
        if (ref == id) ref = 0;
    }

    // what a payer sends above the price; the payer that takes no ETH mostly pays exactly
    function _excess(address payer, uint256 extra) internal view returns (uint256) {
        if (payer == address(refuser) && extra % 4 != 0) return 0;
        return extra % 3 == 0 ? 0 : bound(extra, 1, 1 ether);
    }

    // the first account from index ai on that is owed something, or one in turn when none is
    function _funded(uint256 ai) internal view returns (address) {
        uint256 n = logAccounts.length;
        uint256 start = ai % n;
        for (uint256 i; i < n; ++i) {
            address a = logAccounts[(start + i) % n];
            if (nft.owed(a) != 0) return a;
        }
        return logAccounts[start];
    }

    function _commit(address payer, bytes32 c) internal {
        if (payer == address(refuser)) {
            try refuser.commit(nft, c) {} catch {}
        } else {
            vm.prank(payer);
            try nft.commit(c) {} catch {}
        }
    }

    // a call made by an account: an actor through a prank, the holder through its exec
    function _as(address who, bytes memory data) internal returns (bool ok) {
        if (who == address(holder)) {
            try holder.exec(address(nft), data) {
                ok = true;
            } catch {}
        } else {
            vm.prank(who);
            (ok,) = address(nft).call(data);
        }
    }

    // a fresh recording just before the money call
    function _begin() internal {
        vm.recordLogs();
    }

    // the logs of the money call are replayed when it succeeded and dropped when it reverted
    function _end(bool ok) internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        if (!ok) return;
        _replay(address(nft), logs);
        _countCredits(logs);
    }

    // adds what each credit event gave its account
    function _countCredits(Vm.Log[] memory logs) internal {
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory l = logs[i];
            if (l.emitter != address(nft) || l.topics.length == 0) continue;
            bytes32 t = l.topics[0];
            if (t == LOG_BOUGHT_OUT || t == LOG_RELEASED || t == LOG_OWNER_PREMIUM || t == LOG_TRIAL_REFUNDED) {
                credited[_who(l.topics[2])] += abi.decode(l.data, (uint256));
            } else if (t == LOG_REF_PREMIUM) {
                credited[_who(l.topics[3])] += abi.decode(l.data, (uint256));
            }
        }
    }

    // every account a withdrawal must leave alone or pay: the tracked ones, the caller, the account paid, this
    // handler and the PageNFT
    function _watchList(address caller, address dest) internal view returns (address[] memory w) {
        uint256 n = logAccounts.length;
        w = new address[](n + 4);
        for (uint256 i; i < n; ++i) w[i] = logAccounts[i];
        w[n] = caller;
        w[n + 1] = dest;
        w[n + 2] = address(this);
        w[n + 3] = address(nft);
    }

    function _balancesOf(address[] memory w) internal view returns (uint256[] memory b) {
        b = new uint256[](w.length);
        for (uint256 i; i < w.length; ++i) b[i] = w[i].balance;
    }

    function _stray(string memory why) internal {
        if (strays == 0) firstStray = why;
        ++strays;
    }

    // checks a withdrawal of amount for dest: dest gained exactly amount, the PageNFT lost exactly amount and
    // every other balance stayed, or nothing moved when the withdrawal failed; every gain counts as received
    function _settle(address[] memory w, uint256[] memory before, bool ok, address dest, uint256 amount) internal {
        for (uint256 i; i < w.length; ++i) {
            address a = w[i];
            bool listed;
            for (uint256 j; j < i; ++j) if (w[j] == a) listed = true;
            if (listed) continue;
            uint256 b = a.balance;
            if (a != address(nft) && b > before[i]) received[a] += b - before[i];
            uint256 want = before[i];
            if (ok && a == dest) want += amount;
            if (ok && a == address(nft)) want = want >= amount ? want - amount : 0;
            if (b != want) _stray(string.concat("a withdrawal moved the balance of ", vm.toString(a)));
        }
        if (ok) _track(dest);
    }

    // what the releases of a bundle credit to account, read from the views before the bundle runs
    function _releaseCredits(address account) internal view returns (uint256 sum) {
        for (uint256 i; i < 6; ++i) {
            uint256 id = ids[2 * i];
            if (!nft.isReleasable(id)) continue;
            (address payer, uint96 held) = nft.trialPaymentOf(id);
            if (held != 0) {
                address to = payer == address(0) || payer == address(nft) ? DEAD : payer;
                if (to == account) sum += held;
            } else if (nft.payee(id) == account) {
                sum += nft.depositOf(id);
            }
        }
    }

    // actions

    function register(uint256 li, uint256 oi, uint256 pi, uint256 ri, uint256 extra) external {
        string memory l = labels[_pick(li, 0)];
        uint256 id = nft.computeId(l);
        address owner = _ownerFor(oi);
        address payer = _payerFor(pi);
        uint256 ref = _refFor(ri, id);
        bytes32 s = keccak256(abi.encode("paid", l, owner, ref, ++nonce));
        _commit(payer, nft.makeCommitment(l, owner, ref, s));
        vm.warp(vm.getBlockTimestamp() + 61);
        (,,, uint256 total) = nft.quote(l);
        uint256 premium = nft.getPremium(id);
        uint256 value = total + _excess(payer, extra);
        bool ok;
        if (payer == address(refuser)) {
            vm.deal(address(this), value);
            _begin();
            try refuser.reveal{value: value}(nft, l, owner, ref, s) {
                ok = true;
            } catch {}
        } else {
            _begin();
            vm.prank(payer);
            try nft.reveal{value: value}(l, owner, ref, s) {
                ok = true;
            } catch {}
        }
        _end(ok);
        if (ok) {
            ++registrations;
            if (premium != 0) ++auctions;
        } else if (payer == address(refuser) && value != total && nft.isAvailable(l, 0)) {
            // a free name and a mature commitment, so only the refund to the refusing payer failed
            ++refusedRefunds;
        }
    }

    function trial(uint256 li, uint256 oi, uint256 pi, uint256 ri, uint256 extra) external {
        string memory l = labels[_pick(li, 1)];
        uint256 id = nft.computeId(l);
        address owner = _ownerFor(oi);
        address payer = _payerFor(pi);
        uint256 ref = _refFor(ri, id);
        bytes32 s = keccak256(abi.encode("trial", l, owner, ref, ++nonce));
        _commit(payer, trialCommitmentRaw(l, owner, ref, s));
        vm.warp(vm.getBlockTimestamp() + 61);
        uint256 value = nft.getFee(bytes(l).length) / 10 + _excess(payer, extra);
        bool ok;
        if (payer == address(refuser)) {
            vm.deal(address(this), value);
            _begin();
            try refuser.revealTrial{value: value}(nft, l, owner, ref, s) {
                ok = true;
            } catch {}
        } else {
            _begin();
            vm.prank(payer);
            try nft.revealTrial{value: value}(l, owner, ref, s) {
                ok = true;
            } catch {}
        }
        _end(ok);
        if (ok) ++trials;
    }

    function renew(uint256 li, uint256 pi, uint256 extra) external {
        uint256 k = _pick(li, 2);
        uint256 id = ids[2 * k];
        address payer = _payerFor(pi);
        uint256 value = nft.getFee(bytes(labels[k]).length) + _excess(payer, extra);
        (, uint96 held) = nft.trialPaymentOf(id);
        bool ok;
        if (payer == address(refuser)) {
            vm.deal(address(this), value);
            _begin();
            try refuser.renew{value: value}(nft, id) {
                ok = true;
            } catch {}
        } else {
            _begin();
            vm.prank(payer);
            try nft.renew{value: value}(id) {
                ok = true;
            } catch {}
        }
        _end(ok);
        if (ok) {
            ++renewals;
            if (held != 0) ++conversions;
        }
    }

    function release(uint256 li, uint256 ci) external {
        uint256 id = ids[2 * _pick(li, 3)];
        (, uint96 held) = nft.trialPaymentOf(id);
        _begin();
        vm.prank(actors[ci % 3]);
        bool ok;
        try nft.release(id) {
            ok = true;
        } catch {}
        _end(ok);
        if (ok) {
            if (held != 0) ++trialReleases;
            else ++depositReleases;
        }
    }

    function withdraw(uint256 ai, uint256 ci) external {
        address account = _funded(ai);
        address caller = actors[ci % 3];
        uint256 amount = nft.owed(account);
        address[] memory w = _watchList(caller, account);
        uint256[] memory before = _balancesOf(w);
        _begin();
        vm.prank(caller);
        bool ok;
        uint256 paid;
        try nft.withdraw(account) returns (uint256 a) {
            ok = true;
            paid = a;
        } catch {}
        _end(ok);
        if (ok && paid != amount) _stray("a withdrawal paid other than the credit owed");
        _settle(w, before, ok, account, amount);
        if (ok) ++withdrawals;
    }

    // a caller bundles the release of every releasable name and the withdrawal of one funded account
    function bundle(uint256 ci, uint256 ai) external {
        uint256 n;
        for (uint256 i; i < 6; ++i) {
            if (nft.isReleasable(ids[2 * i])) ++n;
        }
        address account = _funded(ai);
        bytes[] memory calls = new bytes[](n + 1);
        uint256 k;
        for (uint256 i; i < 6; ++i) {
            if (nft.isReleasable(ids[2 * i])) calls[k++] = abi.encodeCall(PageNFT.release, (ids[2 * i]));
        }
        calls[k] = abi.encodeCall(PageNFT.withdraw, (account));
        address caller = actors[ci % 3];
        uint256 amount = nft.owed(account) + _releaseCredits(account);
        address[] memory w = _watchList(caller, account);
        uint256[] memory before = _balancesOf(w);
        _begin();
        vm.prank(caller);
        bool ok;
        try nft.multicall(calls) {
            ok = true;
        } catch {}
        _end(ok);
        _settle(w, before, ok, account, amount);
        if (ok) ++bundles;
    }

    // the holder sends its name to an actor, the holder contract or the dead address, which moves the payee
    function transfer(uint256 li, uint256 ti, uint256 kind) external {
        uint256 id = _top(li);
        address from = _ownerOf(id);
        if (from == address(0) || from == DEAD) return;
        address to = kind % 5 == 0 ? DEAD : kind % 5 == 1 ? address(holder) : actors[ti % 3];
        _begin();
        bool ok = _as(from, abi.encodeCall(PageNFT.transferFrom, (from, to, id)));
        _end(ok);
        if (ok) ++moves;
    }

    // the holder saves a main address, which becomes the payee, or clears it with zero
    function setMain(uint256 li, uint256 ai) external {
        uint256 id = _top(li);
        address o = _ownerOf(id);
        if (o == address(0) || o == DEAD) return;
        uint256 k = ai % 5;
        address a = k == 0 ? address(0) : k == 1 ? address(holder) : k == 2 ? address(refuser) : actors[ai % 3];
        _begin();
        bool ok = _as(o, abi.encodeCall(PageNFT.setAddr, (id, a)));
        _end(ok);
    }

    function clearRecords(uint256 li) external {
        uint256 id = _top(li);
        address o = _ownerOf(id);
        if (o == address(0) || o == DEAD) return;
        _begin();
        bool ok = _as(o, abi.encodeCall(PageNFT.clearRecords, (id)));
        _end(ok);
    }

    function sub(uint256 li, uint256 ti) external {
        uint256 parent = _top(li);
        address o = _ownerOf(parent);
        if (o == address(0) || o == DEAD) return;
        address to = ti % 4 == 3 ? DEAD : actors[ti % 3];
        _begin();
        bool ok = _as(o, abi.encodeCall(PageNFT.registerSubpageFor, ("x", parent, to)));
        _end(ok);
    }

    function force(uint256 amount) external {
        amount = bound(amount, 1, 1 ether);
        vm.deal(address(this), amount);
        new LedgerForce{value: amount}(payable(address(nft)));
        forced += amount;
    }

    function warp(uint256 secs) external {
        if (secs % 4 == 0) vm.warp(vm.getBlockTimestamp() + bound(secs, 1, 200 days));
        else vm.warp(vm.getBlockTimestamp() + bound(secs, 1, 10 days));
    }

    // jumps to an edge of a name's life: its expiry, the end of its grace, its auction or its release
    function warpNear(uint256 li, uint256 k) external {
        uint256 e = nft.expiresAt(_top(li));
        if (e == 0) return;
        uint256 m = k % 7;
        uint256 target;
        if (m == 0) target = e;
        else if (m == 1) target = e + 1;
        else if (m == 2) target = e + GRACE;
        else if (m == 3) target = e + GRACE + 1;
        else if (m == 4) target = e + GRACE + 1 + (k >> 8) % DECAY;
        else if (m == 5) target = e + GRACE + DECAY;
        else target = e + GRACE + DECAY + 1;
        if (target > vm.getBlockTimestamp()) vm.warp(target);
    }

    // checks

    function checkOwedAndDeposits() external view {
        _assertOwedAndDeposits(nft, ids);
    }

    function checkTrialMoney() external view {
        _assertTrialMoney(nft, ids);
    }

    function checkBalance() external view {
        _assertBalance(nft, ids, forced);
    }

    // every account received exactly what the money events credited to it less what it is still owed
    function checkReceived() external view {
        for (uint256 i; i < logAccounts.length; ++i) {
            address a = logAccounts[i];
            assertEq(received[a] + nft.owed(a), credited[a], string.concat("ETH received by ", vm.toString(a)));
        }
    }

    // no withdrawal moved the balance of an account other than the one it paid, the caller included
    function checkNoStray() external view {
        assertEq(strays, 0, firstStray);
    }

    // one line per run, as sum_stats reads it
    function statLine() external view returns (string memory) {
        string memory a = string.concat(
            vm.toString(registrations), " registrations, ", vm.toString(auctions), " auctions, ",
            vm.toString(trials), " trials, ", vm.toString(renewals), " renewals, ", vm.toString(conversions),
            " conversions, ", vm.toString(depositReleases), " deposit releases, "
        );
        string memory b = string.concat(
            vm.toString(trialReleases), " trial releases, ", vm.toString(withdrawals), " withdrawals, ",
            vm.toString(bundles), " bundles, ", vm.toString(moves), " moves, ", vm.toString(refusedRefunds),
            " refused refunds, "
        );
        string memory c = string.concat(
            vm.toString(logCounts[1]), " buyouts, ", vm.toString(logCounts[3]), " referrer premiums, ",
            vm.toString(logCounts[2]), " released deposits, ", vm.toString(logCounts[7]), " trial refunds"
        );
        return string.concat(a, b, c);
    }
}

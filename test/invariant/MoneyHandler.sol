// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {trialCommitment} from "../utils/TrialCommitment.sol";

import {Test} from "forge-std/Test.sol";
import {Base64} from "solady/utils/Base64.sol";
import {LibString} from "solady/utils/LibString.sol";
import {PageNFT} from "../../src/PageNFT.sol";
import {PageCard} from "../../src/PageCard.sol";

// a payer contract that refuses ETH: it can only pay the exact price, and its credits stay owed
contract RefusingPayer {
    PageNFT immutable nft;

    constructor(PageNFT n) {
        nft = n;
    }

    function commit(bytes32 c) external {
        nft.commit(c);
    }

    function trial(string calldata l, address owner, uint256 ref, bytes32 s) external payable {
        nft.revealTrial{value: msg.value}(l, owner, ref, s);
    }

    receive() external payable {
        revert("no ETH");
    }
}

// random walks over trials, conversions, lapses, pauses, releases of trial money, bundles, paid
// registrations with referrers and auctions, transfers, subpages, deletions and withdrawals.
// Three payers (two key wallets and a contract that refuses ETH) only ever pay trials for others, so
// every wei they are owed or withdrew is trial money. After every action the status of the top level name
// its first seed picks and of one more name, in turn, is compared with the Status the metadata shows.
contract MoneyHandler is Test {
    PageNFT public nft;
    RefusingPayer public cpayer;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 constant GRACE = 90 days;
    uint256 constant DECAY = 21 days;
    uint256 constant PAUSE = 14 days;
    address[3] public actors;
    address[3] public payers;
    string[5] public labels = ["a", "abc", "alpha", "bravo", "charlie-d"];
    string[2] public subLabels = ["x", "yy"];
    string[5] statusNames = ["Active", "Grace", "Expired", "Invalid", "Trial"];
    uint256[] public ids;

    // the model of held trial money, per id
    mapping(uint256 => address) public mPayer;
    mapping(uint256 => uint256) public mAmount;
    // money in and out, split between trial money and everything else
    mapping(address => uint256) public trialPaid;
    mapping(address => uint256) public withdrawn;
    uint256 public otherIn;
    uint256 public otherOut;

    // failures found while walking; each must stay false
    bool public refLeak;
    bool public pauseBroken;
    bool public releaseMismatch;
    bool public refundWrong;
    bool public unpaidMoved;
    bool public subUnderTrial;
    bool public statusMismatch;
    bool public conversionWrong;
    bool public profileWrong;

    // what the walk reached
    uint256 public trials;
    uint256 public conversions;
    uint256 public trialReleases;
    uint256 public autoRefunds;
    uint256 public pausedRefusals;
    uint256 public paidOverLapsedTrial;
    uint256 public bundles;
    uint256 public statusChecks;
    uint256 public auctions;
    uint256 public staleOrDeletedSeen;
    uint256 public trialStatusSeen;
    uint256 public profileWrites;
    uint256 public profileKeeps;
    uint256 public profileShown;
    uint256 rot;

    constructor(PageNFT n) {
        nft = n;
        actors = [makeAddr("a0"), makeAddr("a1"), makeAddr("a2")];
        cpayer = new RefusingPayer(n);
        payers = [makeAddr("p0"), makeAddr("p1"), address(cpayer)];
        for (uint256 i; i < 3; ++i) vm.deal(actors[i], 1e9 ether);
        vm.deal(payers[0], 1e9 ether);
        vm.deal(payers[1], 1e9 ether);
        for (uint256 i; i < 5; ++i) {
            uint256 id = nft.computeId(labels[i]);
            ids.push(id);
            for (uint256 j; j < 2; ++j) ids.push(nft.computeId(string.concat(subLabels[j], ".", labels[i])));
        }
    }

    function idsLength() external view returns (uint256) {
        return ids.length;
    }

    function _id(uint256 li) internal view returns (uint256) {
        return nft.computeId(labels[li % 5]);
    }

    function _owner(uint256 id) internal view returns (address o) {
        try nft.ownerOf(id) returns (address x) {
            o = x;
        } catch {}
    }

    function _isPayer(address a) internal view returns (bool) {
        return a == payers[0] || a == payers[1] || a == payers[2];
    }

    // the status check
    function _metaStatus(uint256 id) internal view returns (string memory) {
        string memory json = string(Base64.decode(LibString.slice(nft.tokenURI(id), 29)));
        for (uint256 i; i < 5; ++i) {
            if (LibString.contains(json, string.concat('"Status","value":"', statusNames[i], '"'))) return statusNames[i];
        }
        return "";
    }

    function _checkStatus(uint256 id) internal {
        if (nft.expiresAt(id) == 0 && nft.parentOf(id) == 0) {
            // no record: both revert
            try nft.status(id) {
                statusMismatch = true;
            } catch {}
            try nft.tokenURI(id) {
                statusMismatch = true;
            } catch {}
            return;
        }
        PageCard.Status s = nft.status(id);
        if (keccak256(bytes(statusNames[uint256(s)])) != keccak256(bytes(_metaStatus(id)))) statusMismatch = true;
        if (s == PageCard.Status.Invalid) ++staleOrDeletedSeen;
        if (s == PageCard.Status.Trial) ++trialStatusSeen;
        ++statusChecks;
    }

    // a profile entry shows only while its writer holds the name
    function _checkProfile(uint256 id) internal {
        bool any = bytes(nft.text(id, "avatar")).length != 0 || nft.contenthash(id).length != 0;
        if (!any) return;
        ++profileShown;
        if (nft.profileWriter(id) != _owner(id) || nft.resolve(id) == address(0)) profileWrong = true;
    }

    modifier checks(uint256 li) {
        _;
        _checkStatus(_id(li));
        _checkProfile(_id(li));
        uint256 other = ids[rot++ % ids.length];
        _checkStatus(other);
        _checkProfile(other);
    }

    // refunds seen by a payer's ledger
    // reads the modelled trial payer and amount of a name and that payer's credit before a call, so that _settleRefund
    // can check the call credited exactly that amount
    function _expectRefund(uint256 id) internal view returns (address p, uint256 a, uint256 before) {
        p = mPayer[id];
        a = mAmount[id];
        before = p == address(0) ? 0 : nft.owed(p);
    }

    function _settleRefund(uint256 id, address p, uint256 a, uint256 before) internal {
        if (a == 0) return;
        if (nft.owed(p) != before + a) refundWrong = true;
        mPayer[id] = address(0);
        mAmount[id] = 0;
    }

    // actions
    function trial(uint256 li, uint256 oi, uint256 pi, uint256 ri, uint256 extra) external checks(li) {
        string memory l = labels[li % 5];
        address owner = oi % 7 == 0 ? DEAD : actors[oi % 3];
        address payer = payers[pi % 3];
        uint256 id = nft.computeId(l);
        uint256 ref = ri % 3 == 0 ? 0 : _id(ri);
        if (ref == id) ref = 0;
        bytes32 s = keccak256(abi.encode(l, owner, ref, block.timestamp, "t"));
        bytes32 c = trialCommitment(address(nft), l, owner, ref, s);
        if (payer == address(cpayer)) cpayer.commit(c);
        else {
            vm.prank(payer);
            nft.commit(c);
        }
        vm.warp(block.timestamp + 61);
        uint256 price = nft.getFee(bytes(l).length) / 10;
        uint256 e = nft.expiresAt(id);
        bool exists = e != 0;
        bool paused = exists && nft.depositOf(id) == 0 && block.timestamp > e && block.timestamp <= e + PAUSE;
        (address p, uint256 a, uint256 before) = _expectRefund(id);
        bool ok;
        if (payer == address(cpayer)) {
            vm.deal(address(this), price);
            try cpayer.trial{value: price}(l, owner, ref, s) {
                ok = true;
            } catch {}
        } else {
            vm.prank(payer);
            try nft.revealTrial{value: price + bound(extra, 0, 1 ether)}(l, owner, ref, s) {
                ok = true;
            } catch {}
        }
        if (ok) {
            if (paused) pauseBroken = true;
            _settleRefund(id, p, a, before);
            if (a != 0) ++autoRefunds;
            trialPaid[payer] += price;
            mPayer[id] = payer;
            mAmount[id] = price;
            if (nft.depositOf(id) != 0 || nft.expiresAt(id) != block.timestamp + 14 days) conversionWrong = true;
            ++trials;
        } else if (paused) {
            ++pausedRefusals;
        }
    }

    function paid(uint256 li, uint256 oi, uint256 ri) external checks(li) {
        string memory l = labels[li % 5];
        address owner = actors[oi % 3];
        uint256 id = nft.computeId(l);
        uint256 ref = ri % 4 == 0 ? 0 : _id(ri);
        if (ref == id) ref = 0;
        bytes32 s = keccak256(abi.encode(l, owner, ref, block.timestamp, "p"));
        bytes32 commitment = nft.makeCommitment(l, owner, ref, s);
        vm.prank(owner);
        nft.commit(commitment);
        vm.warp(block.timestamp + 61);
        (,,, uint256 total) = nft.quote(l);
        bool lapsedTrial = mAmount[id] != 0 || (nft.expiresAt(id) != 0 && nft.depositOf(id) == 0);
        uint256 oldRef = nft.referrerOf(id);
        address refPayee = oldRef == 0 ? address(0) : nft.payee(oldRef);
        uint256 refBefore = refPayee == address(0) ? 0 : nft.owed(refPayee);
        uint256 premium = nft.getPremium(id);
        (address p, uint256 a, uint256 before) = _expectRefund(id);
        vm.prank(owner);
        try nft.reveal{value: total}(l, owner, ref, s) {
            otherIn += total;
            _settleRefund(id, p, a, before);
            if (a != 0) ++autoRefunds;
            if (nft.referrerOf(id) != ref) refLeak = true;
            if (lapsedTrial) {
                ++paidOverLapsedTrial;
                if (premium != 0) refLeak = true;
                // the old referrer's payee gains nothing, also when it is the new registrant
                if (refPayee != address(0) && nft.owed(refPayee) != refBefore) refLeak = true;
            }
            if (premium != 0) ++auctions;
        } catch {}
    }

    function renew(uint256 li, uint256 ai) external checks(li) {
        uint256 id = _id(li);
        uint256 fee = nft.getFee(bytes(labels[li % 5]).length);
        bool unpaid = nft.depositOf(id) == 0;
        uint256 refBefore = nft.referrerOf(id);
        uint256 e = nft.expiresAt(id);
        (address p, uint256 a, uint256 before) = _expectRefund(id);
        vm.prank(actors[ai % 3]);
        try nft.renew{value: fee}(id) {
            otherIn += fee;
            if (unpaid) {
                ++conversions;
                _settleRefund(id, p, a, before);
                if (nft.referrerOf(id) != refBefore) refLeak = true;
                if (nft.expiresAt(id) != e + 365 days || nft.depositOf(id) != fee) conversionWrong = true;
            }
        } catch {
            if (unpaid && a != 0 && block.timestamp <= e) conversionWrong = true;
        }
    }

    function transfer(uint256 li, uint256 ti, uint256 kind) external checks(li) {
        uint256 id = _id(li);
        address from = _owner(id);
        if (from == address(0) || from == DEAD) return;
        address to = kind % 5 == 0 ? DEAD : actors[ti % 3];
        bool trialLive = nft.depositOf(id) == 0 && block.timestamp <= nft.expiresAt(id);
        vm.prank(from);
        try nft.transferFrom(from, to, id) {
            if (trialLive && to != DEAD) unpaidMoved = true;
        } catch {}
    }

    function sub(uint256 li, uint256 si, uint256 ti, bool toDead) external checks(li) {
        uint256 id = _id(li);
        address owner = _owner(id);
        if (owner == address(0) || owner == DEAD) return;
        bool unpaid = nft.depositOf(id) == 0;
        address to = toDead ? DEAD : actors[ti % 3];
        vm.prank(owner);
        try nft.registerSubpageFor(subLabels[si % 2], id, to) returns (uint256 sid) {
            if (unpaid) subUnderTrial = true;
            _checkStatus(sid);
        } catch {}
    }

    function deleteSub(uint256 li, uint256 si) external checks(li) {
        uint256 sid = nft.computeId(string.concat(subLabels[si % 2], ".", labels[li % 5]));
        address o = _owner(sid);
        if (o == address(0) || o == DEAD) return;
        vm.prank(o);
        try nft.transferFrom(o, DEAD, sid) {
            _checkStatus(sid);
        } catch {}
    }

    function release(uint256 li, uint256 ci) external checks(li) {
        uint256 id = _id(li);
        bool can = nft.isReleasable(id);
        (address p, uint256 a, uint256 before) = _expectRefund(id);
        uint256 dep = nft.depositOf(id);
        vm.prank(actors[ci % 3]);
        try nft.release(id) {
            if (!can) releaseMismatch = true;
            if (a != 0) {
                _settleRefund(id, p, a, before);
                ++trialReleases;
                if (nft.depositOf(id) != 0) refundWrong = true;
            } else if (dep == 0) {
                releaseMismatch = true;
            }
        } catch {
            if (can) releaseMismatch = true;
        }
    }

    // a payer bundles the release of every releasable name and then its own withdrawal, and must receive its earlier
    // credit plus its own trial money from those releases
    function bundle(uint256 pi) external checks(pi) {
        address payer = payers[pi % 2];
        uint256 n;
        for (uint256 i; i < 5; ++i) if (nft.isReleasable(_id(i))) ++n;
        bytes[] memory calls = new bytes[](n + 1);
        uint256 k;
        for (uint256 i; i < 5; ++i) {
            uint256 id = _id(i);
            if (nft.isReleasable(id)) calls[k++] = abi.encodeCall(PageNFT.release, (id));
        }
        calls[k] = abi.encodeCall(PageNFT.withdraw, (payer));
        address[5] memory ps;
        uint256[5] memory as_;
        for (uint256 i; i < 5; ++i) {
            ps[i] = mPayer[_id(i)];
            as_[i] = mAmount[_id(i)];
        }
        uint256 bal = payer.balance;
        uint256 owedBefore = nft.owed(payer);
        vm.prank(payer);
        try nft.multicall(calls) {
            ++bundles;
            uint256 got = payer.balance - bal;
            withdrawn[payer] += got;
            uint256 expect = owedBefore;
            for (uint256 i; i < 5; ++i) {
                uint256 id = _id(i);
                if (as_[i] != 0 && _heldNow(id) == 0) {
                    if (ps[i] == payer) expect += as_[i];
                    mPayer[id] = address(0);
                    mAmount[id] = 0;
                    ++trialReleases;
                }
            }
            if (got != expect) refundWrong = true;
        } catch {}
    }

    function _heldNow(uint256 id) internal view returns (uint256 a) {
        (, a) = nft.trialPaymentOf(id);
    }

    function withdraw(uint256 ai, uint256 kind) external checks(ai) {
        address a = kind % 3 == 0 ? payers[ai % 3] : kind % 3 == 1 ? actors[ai % 3] : DEAD;
        uint256 amount = nft.owed(a);
        try nft.withdraw(a) {
            if (_isPayer(a)) withdrawn[a] += amount;
            else otherOut += amount;
        } catch {}
    }

    // profile writes, keeps and clears by the holder or someone else, each checked against the rule
    function profile(uint256 ii, uint256 ai, uint256 k) external checks(ii) {
        uint256 id = ids[ii % ids.length];
        address o = _owner(id);
        address who = ai % 4 == 0 ? actors[ai % 3] : o;
        if (who == address(0) || who == DEAD) return;
        bool active = nft.resolve(id) != address(0);
        address w = nft.profileWriter(id);
        uint256 m = k % 4;
        vm.prank(who);
        if (m == 2) {
            try nft.keepProfile(id) {
                if (!active || o != who || w == who || nft.profileWriter(id) != who) profileWrong = true;
                ++profileKeeps;
            } catch {
                if (active && o == who && w != who) profileWrong = true;
            }
        } else if (m == 3) {
            try nft.clearRecords(id) {
                if (bytes(nft.text(id, "avatar")).length != 0 || nft.profileWriter(id) != w) profileWrong = true;
            } catch {}
        } else {
            string memory v = string.concat("v", vm.toString(k));
            bool ok = true;
            if (m == 0) {
                try nft.setText(id, "avatar", v) {} catch { ok = false; }
            } else {
                try nft.setContenthash(id, bytes(v)) {} catch { ok = false; }
            }
            if (ok != (active && o == who)) profileWrong = true;
            if (ok) {
                ++profileWrites;
                if (nft.profileWriter(id) != who) profileWrong = true;
                bool shows = m == 0 ? keccak256(bytes(nft.text(id, "avatar"))) == keccak256(bytes(v))
                    : keccak256(nft.contenthash(id)) == keccak256(bytes(v));
                if (!shows) profileWrong = true;
                // a fresh start leaves nothing of the other entry
                if (w != who && (m == 0 ? nft.contenthash(id).length != 0 : bytes(nft.text(id, "avatar")).length != 0)) {
                    profileWrong = true;
                }
            }
        }
    }

    function setMain(uint256 li, uint256 ai) external checks(li) {
        uint256 id = _id(li);
        address o = _owner(id);
        if (o == address(0) || o == DEAD) return;
        vm.prank(o);
        try nft.setAddr(id, actors[ai % 3]) {} catch {}
    }

    // jumps to a moment near the end of a name, where the conversion, release and pause edges are
    function warpNearEnd(uint256 li, uint256 k) external checks(li) {
        uint256 e = nft.expiresAt(_id(li));
        uint256 m = k % 6;
        uint256 target;
        if (m == 0) target = e;
        else if (m == 1) target = e + 1;
        else if (m == 2) target = e + PAUSE;
        else if (m == 3) target = e + PAUSE + 1;
        else if (m == 4) target = e + GRACE + 1 + (k >> 8) % DECAY;
        else target = e + GRACE + DECAY + 1;
        if (target > block.timestamp) vm.warp(target);
    }

    function warp(uint256 secs) external checks(secs) {
        if (secs % 4 == 0) vm.warp(block.timestamp + bound(secs, 1, 130 days));
        else vm.warp(block.timestamp + bound(secs, 1, 8 days));
    }
}

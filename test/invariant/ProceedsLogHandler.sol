// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Test, Vm} from "forge-std/Test.sol";
import {PageNFT} from "../../src/PageNFT.sol";
import {SubpageRegistrar} from "../../src/SubpageRegistrar.sol";
import {MockERC20} from "../utils/MinterMocks.sol";
import {LedgerForce} from "../utils/MoneyLogReplay.sol";
import {
    PlainPayout, HeavyPayoutLogic, HeavyPayout, SwitchPayout, ReenteringPayout, NoChangeBuyer
} from "../utils/ProceedsMocks.sol";

// Random walks over registrar sales in ETH and in a token, direct and by commit and reveal, with ETH buyers
// often sending a random excess, new terms with other payouts, prices and fee tokens, claims through both
// functions to many destinations, a sweep that pushes every balance, a payout that switches to refusing ETH,
// a payout that tries to claim again while it is paid, and ETH forced in. Only the registrar's SubpageSold
// and ProceedsClaimed events of calls that succeeded are replayed, and the replay must give proceedsOf for
// every account after every call. Every claim is also watched on the balances of every account, the caller
// included: only the account it pays may gain, by exactly what was owed, and only the registrar may lose.
contract ProceedsLogHandler is Test {
    PageNFT public nft;
    SubpageRegistrar public reg;
    MockERC20 public usd;
    PlainPayout public plain;
    HeavyPayout public heavy;
    SwitchPayout public sw;
    ReenteringPayout public re;
    NoChangeBuyer public cbuyer;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    bytes32 constant SOLD = keccak256("SubpageSold(uint256,uint256,address,address,address,address,uint256,string)");
    bytes32 constant CLAIMED = keccak256("ProceedsClaimed(address,address,uint256)");

    uint256[2] public parents;
    address[2] public holders;
    address[2] public buyers;
    address[2] public callers;
    // the payouts the terms pick from, accounts with no code and four kinds of contract
    address[] public payouts;
    // every account the checks cover
    address[] public accounts;
    mapping(address => bool) internal tracked;

    // proceedsOf as the logs give it, and the ETH the logs say came in and went out
    mapping(address => uint256) public logProceeds;
    uint256 public logIn;
    uint256 public logOut;
    uint256 public forced;
    uint256 nonce;

    // each stays false; each is a log the proceeds rules do not allow
    bool public zeroClaim;
    bool public claimToNobody;
    bool public partialClaim;
    bool public saleToNobody;

    // what the walk's ETH sales credited to each payout, by the terms read before each sale
    mapping(address => uint256) public credited;
    // the ETH each account gained during claims, read on its balance
    mapping(address => uint256) public received;
    // credit an account sent to another address with claimProceeds, out of the account and into the destination
    mapping(address => uint256) public sentOut;
    mapping(address => uint256) public sentIn;
    // claims that moved a balance other than the one they paid or paid other than what was owed, and the first
    uint256 public strays;
    string public firstStray;

    // what the walk reached
    uint256 public ethSales;
    uint256 public tokenSales;
    uint256 public revealSales;
    uint256 public ownClaims;
    uint256 public pushedClaims;
    uint256 public sweptClaims;
    uint256 public refusedClaims;
    uint256 public configs;

    constructor(PageNFT n, SubpageRegistrar r) {
        nft = n;
        reg = r;
        usd = new MockERC20();
        plain = new PlainPayout();
        heavy = new HeavyPayout(address(new HeavyPayoutLogic()));
        sw = new SwitchPayout();
        cbuyer = new NoChangeBuyer();
        holders = [makeAddr("proceeds-h0"), makeAddr("proceeds-h1")];
        buyers = [makeAddr("proceeds-b0"), makeAddr("proceeds-b1")];
        callers = [makeAddr("proceeds-c0"), makeAddr("proceeds-c1")];
        re = new ReenteringPayout(r, makeAddr("proceeds-p0"));
        payouts = [
            makeAddr("proceeds-p0"), makeAddr("proceeds-p1"), address(plain), address(heavy), address(sw), DEAD,
            address(re)
        ];
        for (uint256 i; i < payouts.length; ++i) _track(payouts[i]);
        for (uint256 i; i < 2; ++i) {
            _track(holders[i]);
            _track(buyers[i]);
            _track(callers[i]);
            vm.deal(holders[i], 1000 ether);
            vm.deal(buyers[i], 1e9 ether);
            usd.mint(buyers[i], 1e30);
            vm.prank(buyers[i]);
            usd.approve(address(r), type(uint256).max);
        }
        _track(address(cbuyer));
    }

    // registers two parents, picks the registrar as their minter and sets their first terms
    function bootstrap() external {
        string[2] memory ls = ["club", "zoo"];
        for (uint256 i; i < 2; ++i) {
            address h = holders[i];
            bytes32 secret = keccak256(abi.encode("proceeds", ls[i]));
            bytes32 c = nft.makeCommitment(ls[i], h, 0, secret);
            vm.prank(h);
            nft.commit(c);
            vm.warp(vm.getBlockTimestamp() + 61);
            (,,, uint256 total) = nft.quote(ls[i]);
            vm.prank(h);
            parents[i] = nft.reveal{value: total}(ls[i], h, 0, secret);
            vm.prank(h);
            nft.setSubpageMinter(parents[i], address(reg));
        }
        vm.prank(holders[0]);
        reg.configure(parents[0], address(re), address(0), 0.05 ether, true, address(0), 0, false);
        vm.prank(holders[1]);
        reg.configure(parents[1], address(heavy), address(0), 0.3 ether, true, address(0), 0, true);
    }

    function _track(address a) internal {
        if (tracked[a]) return;
        tracked[a] = true;
        accounts.push(a);
    }

    function accountsLength() external view returns (uint256) {
        return accounts.length;
    }

    function _who(bytes32 topic) internal pure returns (address) {
        return address(uint160(uint256(topic)));
    }

    // the first account from index ai on that is owed proceeds, or one in turn when none is
    function _funded(uint256 ai) internal view returns (address) {
        uint256 n = accounts.length;
        uint256 start = ai % n;
        for (uint256 i; i < n; ++i) {
            address a = accounts[(start + i) % n];
            if (reg.proceedsOf(a) != 0) return a;
        }
        return accounts[start];
    }

    function _begin() internal {
        vm.recordLogs();
    }

    // every account a claim must leave alone or pay: the tracked ones, the caller, the destination, this
    // handler, the registrar and the PageNFT
    function _watchList(address caller, address dest) internal view returns (address[] memory w) {
        uint256 n = accounts.length;
        w = new address[](n + 5);
        for (uint256 i; i < n; ++i) w[i] = accounts[i];
        w[n] = caller;
        w[n + 1] = dest;
        w[n + 2] = address(this);
        w[n + 3] = address(reg);
        w[n + 4] = address(nft);
    }

    function _balancesOf(address[] memory w) internal view returns (uint256[] memory b) {
        b = new uint256[](w.length);
        for (uint256 i; i < w.length; ++i) b[i] = w[i].balance;
    }

    function _stray(string memory why) internal {
        if (strays == 0) firstStray = why;
        ++strays;
    }

    // checks a claim of account's balance, amount when the call began, sent to dest: dest gained exactly amount,
    // the registrar lost exactly amount and every other balance stayed, or nothing moved when the claim failed;
    // every gain counts as received
    function _settle(
        address[] memory w,
        uint256[] memory before,
        bool ok,
        address account,
        address dest,
        uint256 amount,
        uint256 paid
    ) internal {
        if (ok) {
            if (paid != amount) _stray("a claim paid other than the balance owed");
            if (dest != account) {
                sentOut[account] += amount;
                sentIn[dest] += amount;
            }
        }
        for (uint256 i; i < w.length; ++i) {
            address a = w[i];
            bool listed;
            for (uint256 j; j < i; ++j) if (w[j] == a) listed = true;
            if (listed) continue;
            uint256 b = a.balance;
            if (a != address(reg) && b > before[i]) received[a] += b - before[i];
            uint256 want = before[i];
            if (ok && a == dest) want += amount;
            if (ok && a == address(reg)) want = want >= amount ? want - amount : 0;
            if (b != want) _stray(string.concat("a claim moved the balance of ", vm.toString(a)));
        }
        if (ok) _track(dest);
    }

    // replays the registrar's logs of a call that succeeded; the logs of a reverted call are dropped
    function _end(bool ok) internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        if (!ok) return;
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory l = logs[i];
            if (l.emitter != address(reg) || l.topics.length == 0) continue;
            if (l.topics[0] == SOLD) {
                (address to, address payout, address feeToken, uint256 price,) =
                    abi.decode(l.data, (address, address, address, uint256, string));
                if (to == address(0) || payout == address(0)) saleToNobody = true;
                // an ETH sale credits its price to the payout, a token sale credits nothing
                if (feeToken == address(0)) {
                    logProceeds[payout] += price;
                    logIn += price;
                }
                _track(payout);
            } else if (l.topics[0] == CLAIMED) {
                address account = _who(l.topics[1]);
                address to = _who(l.topics[2]);
                uint256 amount = abi.decode(l.data, (uint256));
                if (amount == 0) zeroClaim = true;
                if (to == address(0) || to == address(reg)) claimToNobody = true;
                // a claim pays out the whole balance
                if (amount != logProceeds[account]) partialClaim = true;
                logProceeds[account] = amount > logProceeds[account] ? 0 : logProceeds[account] - amount;
                logOut += amount;
                _track(account);
                _track(to);
            }
        }
    }

    // actions

    // a buyer pays for a fresh subpage under a parent on its current terms, for itself or for another buyer
    function sell(uint256 pi, uint256 bi, uint256 ti, uint256 extra) external {
        uint256 parentId = parents[pi % 2];
        (,, bool commitReveal, address feeToken, uint96 price,,, address payout,) = reg.config(parentId);
        string memory label = string.concat("s", vm.toString(++nonce));
        bool byContract = bi % 3 == 2 && feeToken == address(0);
        address buyer = byContract ? address(cbuyer) : buyers[bi % 2];
        address to = ti % 3 == 0 ? buyers[(bi % 2 + 1) % 2] : buyer;
        uint256 excess;
        if (feeToken == address(0)) excess = byContract ? (extra % 4 == 0 ? 1 : 0) : (extra % 3 == 0 ? 0 : bound(extra, 1, 1 ether));
        uint256 value = feeToken == address(0) ? uint256(price) + excess : 0;
        bytes32 secret = keccak256(abi.encode("secret", nonce));
        if (commitReveal) {
            bytes32 c = reg.makeSubpageCommitment(parentId, label, to, secret);
            if (byContract) {
                cbuyer.commit(reg, c);
            } else {
                vm.prank(buyer);
                reg.commitSubpage(c);
            }
            vm.warp(vm.getBlockTimestamp() + 61);
        }
        bool ok;
        if (byContract) {
            vm.deal(address(this), value);
            _begin();
            if (commitReveal) {
                try cbuyer.reveal{value: value}(reg, parentId, label, to, secret, price) {
                    ok = true;
                } catch {}
            } else {
                try cbuyer.buy{value: value}(reg, parentId, label, to, price) {
                    ok = true;
                } catch {}
            }
        } else {
            _begin();
            vm.prank(buyer);
            if (commitReveal) {
                try reg.revealSubpageFor{value: value}(parentId, label, to, secret, price, feeToken) {
                    ok = true;
                } catch {}
            } else {
                try reg.registerSubpageFor{value: value}(parentId, label, to, price, feeToken) {
                    ok = true;
                } catch {}
            }
        }
        _end(ok);
        if (ok) {
            if (feeToken == address(0)) {
                ++ethSales;
                credited[payout] += price;
                _track(payout);
            } else {
                ++tokenSales;
            }
            if (commitReveal) ++revealSales;
        }
    }

    // the holder sets new terms: a payout from the set, zero for itself, or one the registrar refuses
    function configure(uint256 pi, uint256 payS, uint256 priceS, uint256 kind) external {
        uint256 parentId = parents[pi % 2];
        uint256 m = payS % 10;
        address payout = m < 7 ? payouts[m] : m == 7 ? address(0) : m == 8 ? address(reg) : address(nft);
        address feeToken = kind % 4 == 0 ? address(usd) : address(0);
        uint256 price = priceS % 5 == 0 ? 0 : bound(priceS, 1, 2 ether);
        _begin();
        vm.prank(nft.ownerOf(parentId));
        bool ok;
        try reg.configure(parentId, payout, feeToken, price, kind % 9 != 0, address(0), 0, kind % 3 == 1) {
            ok = true;
        } catch {}
        _end(ok);
        if (ok) ++configs;
    }

    // an account that can make calls claims its own proceeds to itself, to another account, to the
    // registrar, which is refused, or to the PageNFT, which takes no ETH
    function claimOwn(uint256 ai, uint256 ti) external {
        address[6] memory claimants = [payouts[0], payouts[1], address(sw), address(re), holders[0], holders[1]];
        uint256 start = ai % 6;
        address account = claimants[start];
        if ((ai >> 128) % 2 == 0) {
            for (uint256 i; i < 6; ++i) {
                if (reg.proceedsOf(claimants[(start + i) % 6]) != 0) {
                    account = claimants[(start + i) % 6];
                    break;
                }
            }
        }
        uint256 m = ti % 8;
        address to = m == 0 ? address(0) : m == 1 ? account : m == 2 ? address(reg) : m == 3 ? address(nft)
            : m == 4 ? callers[ti % 2] : payouts[(ti >> 8) % payouts.length];
        address dest = to == address(0) ? account : to;
        uint256 amount = reg.proceedsOf(account);
        address[] memory w = _watchList(account, dest);
        uint256[] memory before = _balancesOf(w);
        _begin();
        bool ok;
        uint256 paid;
        if (account == address(sw)) {
            try sw.claim(reg, to) returns (uint256 a) {
                ok = true;
                paid = a;
            } catch {}
        } else if (account == address(re)) {
            try re.claim(to) returns (uint256 a) {
                ok = true;
                paid = a;
            } catch {}
        } else {
            vm.prank(account);
            try reg.claimProceeds(to) returns (uint256 a) {
                ok = true;
                paid = a;
            } catch {}
        }
        _end(ok);
        _settle(w, before, ok, account, dest, amount, paid);
        if (ok) ++ownClaims;
        else if (reg.proceedsOf(account) != 0) ++refusedClaims;
    }

    // anyone pushes one account's proceeds, mostly a funded one
    function claimFor(uint256 ai, uint256 ci) external {
        address account = ai % 4 == 0 ? accounts[(ai >> 8) % accounts.length] : _funded(ai);
        address caller = ci % 3 == 2 ? buyers[ci % 2] : callers[ci % 2];
        uint256 amount = reg.proceedsOf(account);
        address[] memory w = _watchList(caller, account);
        uint256[] memory before = _balancesOf(w);
        _begin();
        vm.prank(caller);
        bool ok;
        uint256 paid;
        try reg.claimProceedsFor(account) returns (uint256 a) {
            ok = true;
            paid = a;
        } catch {}
        _end(ok);
        _settle(w, before, ok, account, account, amount, paid);
        if (ok) ++pushedClaims;
        else if (reg.proceedsOf(account) != 0) ++refusedClaims;
    }

    // a caller pushes every balance, one claim at a time
    function sweep(uint256 ci) external {
        for (uint256 i; i < accounts.length; ++i) {
            address a = accounts[i];
            uint256 amount = reg.proceedsOf(a);
            if (amount == 0) continue;
            address[] memory w = _watchList(callers[ci % 2], a);
            uint256[] memory before = _balancesOf(w);
            _begin();
            vm.prank(callers[ci % 2]);
            bool ok;
            uint256 paid;
            try reg.claimProceedsFor(a) returns (uint256 got) {
                ok = true;
                paid = got;
            } catch {}
            _end(ok);
            _settle(w, before, ok, a, a, amount, paid);
            if (ok) ++sweptClaims;
            else ++refusedClaims;
        }
    }

    function toggle(bool on) external {
        sw.setRefusing(on);
    }

    function force(uint256 amount) external {
        amount = bound(amount, 1, 1 ether);
        vm.deal(address(this), amount);
        new LedgerForce{value: amount}(payable(address(reg)));
        forced += amount;
    }

    // time passes; a parent close to its expiry is renewed so that it keeps selling
    function warp(uint256 secs) external {
        vm.warp(vm.getBlockTimestamp() + bound(secs, 1, 3 days));
        for (uint256 i; i < 2; ++i) {
            if (nft.expiresAt(parents[i]) < vm.getBlockTimestamp() + 60 days) {
                uint256 fee = nft.getFee(bytes(nft.getPageName(parents[i])).length);
                vm.deal(holders[i], holders[i].balance + fee);
                vm.prank(holders[i]);
                nft.renew{value: fee}(parents[i]);
            }
        }
    }

    // the replayed proceeds of every tracked account equal proceedsOf, nothing is ever owed to address zero,
    // the registrar or the PageNFT, the logs account for the registrar's balance apart from ETH forced in,
    // and the tracked balances hold all of it
    function checkReplay() external view {
        uint256 sum = forced;
        for (uint256 i; i < accounts.length; ++i) {
            address a = accounts[i];
            uint256 p = reg.proceedsOf(a);
            assertEq(logProceeds[a], p, string.concat("proceeds of ", vm.toString(a)));
            sum += p;
        }
        assertEq(reg.proceedsOf(address(0)), 0, "proceeds of address zero");
        assertEq(reg.proceedsOf(address(reg)), 0, "proceeds of the registrar");
        assertEq(reg.proceedsOf(address(nft)), 0, "proceeds of the PageNFT");
        assertEq(address(reg).balance + logOut, logIn + forced, "the logs account for every wei");
        assertEq(address(reg).balance, sum, "the tracked proceeds hold the whole balance");
        assertFalse(zeroClaim, "a claim of zero");
        assertFalse(claimToNobody, "a claim paid to address zero or the registrar");
        assertFalse(partialClaim, "a claim of less or more than the balance");
        assertFalse(saleToNobody, "a sale naming address zero");
        assertEq(re.reentered(), 0, "a claim from inside a payment went through");
    }

    // every account received exactly what the walk's ETH sales credited to it less what it is still owed,
    // counting the credit it sent to another address with claimProceeds and the credit others sent to it
    function checkReceived() external view {
        for (uint256 i; i < accounts.length; ++i) {
            address a = accounts[i];
            assertEq(
                received[a] + sentOut[a] + reg.proceedsOf(a),
                credited[a] + sentIn[a],
                string.concat("ETH received by ", vm.toString(a))
            );
        }
    }

    // no claim moved the balance of an account other than the one it paid, the caller included
    function checkNoStray() external view {
        assertEq(strays, 0, firstStray);
    }

    // one line per run, as sum_stats reads it
    function statLine() external view returns (string memory) {
        return string.concat(
            vm.toString(ethSales), " ETH sales, ", vm.toString(tokenSales), " token sales, ",
            vm.toString(revealSales), " sales by reveal, ", vm.toString(configs), " configurations, ",
            vm.toString(ownClaims), " own claims, ", vm.toString(pushedClaims), " pushed claims, ",
            vm.toString(sweptClaims), " swept claims, ", vm.toString(refusedClaims), " refused claims, ",
            vm.toString(re.refused()), " refused claims from inside a payment"
        );
    }
}

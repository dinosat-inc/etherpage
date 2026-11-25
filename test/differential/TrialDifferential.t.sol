// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {PageNFT} from "../../src/PageNFT.sol";
import {PageCard} from "../../src/PageCard.sol";
import {PageNFTNoTrial} from "./harness/PageNFTNoTrial.sol";

// the same random walk of paid actions, without any trial, on a build with no trials (a) and on src (b):
// every call must succeed or fail alike with the same return or revert data, and every view must agree
// after every step
contract DiffHandler is Test {
    PageNFTNoTrial public a;
    PageNFT public b;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address[3] public actors;
    string[4] public labels = ["a", "abc", "alpha", "bravo"];
    string[2] public subs = ["x", "yy"];
    uint256 public calls;
    uint256 public mismatches;

    constructor(PageNFTNoTrial a_, PageNFT b_) {
        a = a_;
        b = b_;
        actors = [makeAddr("d0"), makeAddr("d1"), makeAddr("d2")];
        for (uint256 i; i < 3; ++i) vm.deal(actors[i], 1e9 ether);
    }

    function _both(address from, uint256 value, bytes memory data) internal returns (bool ok) {
        vm.prank(from);
        (bool okA, bytes memory rA) = address(a).call{value: value}(data);
        vm.prank(from);
        (bool okB, bytes memory rB) = address(b).call{value: value}(data);
        assertEq(okA, okB, "same success");
        assertEq(keccak256(rA), keccak256(rB), "same return or revert data");
        ++calls;
        return okA;
    }

    function _id(uint256 li) internal view returns (uint256) {
        return b.computeId(labels[li % 4]);
    }

    function _owner(uint256 id) internal view returns (address o) {
        try b.ownerOf(id) returns (address x) {
            o = x;
        } catch {}
    }

    function paid(uint256 li, uint256 oi, uint256 extra) external {
        string memory l = labels[li % 4];
        address o = actors[oi % 3];
        bytes32 s = keccak256(abi.encode(l, o, block.timestamp));
        bytes32 c = b.makeCommitment(l, o, 0, s);
        if (!_both(o, 0, abi.encodeCall(PageNFT.commit, (c)))) return;
        vm.warp(block.timestamp + 61);
        (,,, uint256 total) = b.quote(l);
        _both(o, total + bound(extra, 0, 1 ether), abi.encodeCall(PageNFT.reveal, (l, o, 0, s)));
    }

    function renew(uint256 li, uint256 pi, bool under) external {
        uint256 fee = b.getFee(bytes(labels[li % 4]).length);
        _both(actors[pi % 3], under ? fee - 1 : fee, abi.encodeCall(PageNFT.renew, (_id(li))));
    }

    function transfer(uint256 li, uint256 ti, bool toDead) external {
        uint256 id = _id(li);
        address from = _owner(id);
        if (from == address(0)) return;
        _both(from, 0, abi.encodeCall(PageNFT.transferFrom, (from, toDead ? DEAD : actors[ti % 3], id)));
    }

    function sub(uint256 li, uint256 si, uint256 ci, bool subTransfer) external {
        uint256 id = _id(li);
        address o = _owner(id);
        address caller = ci % 2 == 0 && o != address(0) ? o : actors[ci % 3];
        _both(caller, 0, abi.encodeCall(PageNFT.registerSubpageFor, (subs[si % 2], id, actors[(ci % 3 + 1) % 3])));
        if (subTransfer) {
            uint256 sid = b.computeId(string.concat(subs[si % 2], ".", labels[li % 4]));
            address so = _owner(sid);
            if (so != address(0)) _both(so, 0, abi.encodeCall(PageNFT.transferFrom, (so, DEAD, sid)));
        }
    }

    function minter(uint256 li, uint256 mi) external {
        uint256 id = _id(li);
        address o = _owner(id);
        if (o == address(0)) return;
        _both(o, 0, abi.encodeCall(PageNFT.setSubpageMinter, (id, actors[mi % 3])));
    }

    function setAddr(uint256 li, uint256 ai) external {
        uint256 id = _id(li);
        address o = _owner(id);
        if (o == address(0)) return;
        _both(o, 0, abi.encodeCall(PageNFT.setAddr, (id, actors[ai % 3])));
    }

    function primary(uint256 li, uint256 ai) external {
        _both(actors[ai % 3], 0, abi.encodeWithSignature("setPrimaryPage(uint256)", _id(li)));
    }

    function release(uint256 li) external {
        _both(actors[0], 0, abi.encodeCall(PageNFT.release, (_id(li))));
    }

    function withdraw(uint256 ai, bool dead) external {
        _both(actors[1], 0, abi.encodeCall(PageNFT.withdraw, (dead ? DEAD : actors[ai % 3])));
    }

    function warp(uint256 secs) external {
        if (secs % 3 == 0) vm.warp(block.timestamp + bound(secs, 1, 200 days));
        else vm.warp(block.timestamp + bound(secs, 1, 5 days));
    }
}

contract TrialDifferentialTest is Test {
    PageNFTNoTrial a;
    PageNFT b;
    DiffHandler h;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    function setUp() public {
        vm.warp(1_800_000_000);
        PageCard card = new PageCard();
        a = new PageNFTNoTrial(card);
        b = new PageNFT(card);
        h = new DiffHandler(a, b);
        targetContract(address(h));
    }

    function invariant_sameViews() public view {
        assertEq(address(a).balance, address(b).balance, "balance");
        assertEq(a.owed(DEAD), b.owed(DEAD), "owed dead");
        for (uint256 j; j < 3; ++j) {
            address x = h.actors(j);
            assertEq(a.owed(x), b.owed(x), "owed");
            assertEq(a.primaryPage(x), b.primaryPage(x), "primary");
            assertEq(a.reverseResolve(x), b.reverseResolve(x), "reverse");
        }
        for (uint256 i; i < 4; ++i) {
            string memory l = h.labels(i);
            uint256 id = b.computeId(l);
            assertEq(a.isAvailable(l, 0), b.isAvailable(l, 0), "isAvailable");
            assertEq(a.isExpired(id), b.isExpired(id), "isExpired");
            assertEq(a.inGracePeriod(id), b.inGracePeriod(id), "inGracePeriod");
            assertEq(a.getPremium(id), b.getPremium(id), "premium");
            assertEq(a.depositOf(id), b.depositOf(id), "deposit");
            assertEq(a.expiresAt(id), b.expiresAt(id), "expiry");
            assertEq(a.resolve(id), b.resolve(id), "resolve");
            assertEq(a.isReleasable(id), b.isReleasable(id), "releasable");
            (,,, uint256 ta) = a.quote(l);
            (,,, uint256 tb) = b.quote(l);
            assertEq(ta, tb, "quote");
            if (b.expiresAt(id) != 0) {
                assertEq(keccak256(bytes(a.tokenURI(id))), keccak256(bytes(b.tokenURI(id))), "tokenURI");
            }
            for (uint256 k; k < 2; ++k) {
                string memory s = h.subs(k);
                uint256 sid = b.computeId(string.concat(s, ".", l));
                assertEq(a.isAvailable(s, id), b.isAvailable(s, id), "sub isAvailable");
                assertEq(a.resolve(sid), b.resolve(sid), "sub resolve");
            }
        }
    }

    function afterInvariant() public {
        vm.createDir("logs", true);
        vm.writeLine("logs/no-trial-diff-stats.txt", vm.toString(h.calls()));
    }
}

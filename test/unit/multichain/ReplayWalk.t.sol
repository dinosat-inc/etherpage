// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Vm} from "forge-std/Test.sol";
import {PageNFT} from "../../../src/PageNFT.sol";
import {SubpageRegistrar} from "../../../src/SubpageRegistrar.sol";
import {MinterBase} from "../../utils/MinterBase.sol";
import {Holder721, SafeLike} from "../../utils/MinterMocks.sol";
import {LogShapes} from "../../utils/LogShapes.sol";

// Two indexers read nothing but the address events of PageNFT: one keeps the last main address and OP answer, both
// from the OP announcement, and the last Ethereum answer and AddrChanged of each name, the other also empties a name
// on VersionChanged. A fixed walk runs every kind of step at least once and checks along the way, after every
// transaction that announces an address, after a jump in time and after a code change, that both indexers hold what
// the views answer for every active name and every deleted page. Its last step mints subpages again, one of them to
// DEAD, so the indexer that empties a name is compared right after the VersionChanged of each such mint. A code
// change at an address changes no answer, so it leaves no gap: the coin type 60 answer is compared at every check
// too, the one right after a code change included.
contract ReplayWalkTest is MinterBase {
    uint256 constant DEF = 0x80000000;
    uint256 constant BASE = 0x80002105;
    uint256 constant PRICE = 0.01 ether;
    uint256 constant STEPS = 13;

    struct Idx {
        address main;
        bytes op;
        bytes eth;
        address node;
    }

    mapping(uint256 => Idx) plain;
    mapping(uint256 => Idx) wiping;
    uint256[] tracked;
    uint256[STEPS] ran;
    bool sawOtherChain;
    uint256 comparisons;

    function _track(uint256 id) internal {
        tracked.push(id);
    }

    // a page the dead address holds is never active
    function _active(uint256 id) internal view returns (bool) {
        (string memory l, uint256 parent, uint64 exp,, uint64 pe) = nft.records(id);
        if (bytes(l).length == 0) return false;
        if (nft.ownerOf(id) == DEAD) return false;
        if (parent == 0) return vm.getBlockTimestamp() <= exp;
        (,, uint64 pexp, uint64 pep,) = nft.records(parent);
        if (pe != pep) return false;
        return vm.getBlockTimestamp() <= pexp;
    }

    // a page the dead address holds, a subpage only in the registration of its parent it was made in
    function _deleted(uint256 id) internal view returns (bool) {
        (string memory l, uint256 parent,,, uint64 pe) = nft.records(id);
        if (bytes(l).length == 0 || nft.ownerOf(id) != DEAD) return false;
        if (parent == 0) return true;
        (,,, uint64 pep,) = nft.records(parent);
        return pe == pep;
    }

    // the shape rules on the log: an OP answer is followed at once by the Ethereum answer, an Ethereum answer is
    // followed at once by AddrChanged with the same address, AddrChanged comes only there, and another chain is
    // announced only by a save for that chain; otherCoin is the chain the step saves, and 0 means it saves none, so
    // that no other chain, coin type 0 included, may be announced
    function _shapes(Vm.Log[] memory logs, uint256 otherCoin) internal {
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory l = logs[i];
            if (l.emitter != address(nft)) continue;
            if (l.topics[0] == LogShapes.ADDR_CHANGED) {
                assertGt(i, 0, "AddrChanged follows the Ethereum answer");
                Vm.Log memory p = logs[i - 1];
                assertEq(p.emitter, address(nft));
                assertEq(p.topics[0], LogShapes.ADDRESS_CHANGED, "AddrChanged only right after the Ethereum answer");
                assertEq(p.topics[1], l.topics[1], "for the same name");
                (uint256 prev,) = abi.decode(p.data, (uint256, bytes));
                assertEq(prev, 60, "AddrChanged only right after the Ethereum answer");
                continue;
            }
            if (l.topics[0] != LogShapes.ADDRESS_CHANGED) continue;
            (uint256 coin, bytes memory v) = abi.decode(l.data, (uint256, bytes));
            if (coin == COIN_OP) {
                assertLt(i + 1, logs.length, "the OP answer is followed by the Ethereum answer");
                assertEq(logs[i + 1].topics[0], LogShapes.ADDRESS_CHANGED, "then the Ethereum answer");
                assertEq(logs[i + 1].topics[1], l.topics[1]);
                (uint256 next,) = abi.decode(logs[i + 1].data, (uint256, bytes));
                assertEq(next, 60);
            } else if (coin == 60) {
                assertLt(i + 1, logs.length, "the Ethereum answer is followed by AddrChanged");
                address a = v.length == 0 ? address(0) : address(bytes20(v));
                assertEq(LogShapes.hashOf(logs[i + 1]), LogShapes.addrChanged(uint256(l.topics[1]), a), "then AddrChanged");
            } else {
                assertTrue(otherCoin != 0 && coin == otherCoin, "another chain is announced only by its own save");
                sawOtherChain = true;
            }
        }
    }

    function _replay(Vm.Log[] memory logs) internal {
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory l = logs[i];
            if (l.emitter != address(nft) || l.topics.length != 2) continue;
            uint256 id = uint256(l.topics[1]);
            if (l.topics[0] == LogShapes.ADDR_CHANGED) {
                address a = abi.decode(l.data, (address));
                plain[id].node = a;
                wiping[id].node = a;
            } else if (l.topics[0] == LogShapes.ADDRESS_CHANGED) {
                (uint256 coin, bytes memory v) = abi.decode(l.data, (uint256, bytes));
                if (coin == COIN_OP) {
                    address a = v.length == 0 ? address(0) : address(bytes20(v));
                    plain[id].main = a;
                    wiping[id].main = a;
                    plain[id].op = v;
                    wiping[id].op = v;
                } else if (coin == 60) {
                    plain[id].eth = v;
                    wiping[id].eth = v;
                }
            } else if (l.topics[0] == LogShapes.VERSION) {
                delete wiping[id];
            }
        }
    }

    function _compare() internal {
        for (uint256 i; i < tracked.length; ++i) {
            uint256 id = tracked[i];
            if (!_active(id) && !_deleted(id)) continue;
            ++comparisons;
            address r = nft.resolve(id);
            bytes memory op = nft.addr(id, COIN_OP);
            bytes memory eth = nft.addr(id, 60);
            address node = nft.addr(bytes32(id));
            assertEq(plain[id].main, r, "plain indexer, main address");
            assertEq(plain[id].op, op, "plain indexer, OP");
            assertEq(wiping[id].main, r, "wiping indexer, main address");
            assertEq(wiping[id].op, op, "wiping indexer, OP");
            assertEq(plain[id].eth, eth, "plain indexer, Ethereum");
            assertEq(wiping[id].eth, eth, "wiping indexer, Ethereum");
            assertEq(plain[id].node, node, "plain indexer, addr by node");
            assertEq(wiping[id].node, node, "wiping indexer, addr by node");
        }
    }

    function _after(uint256 step, uint256 otherCoin) internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        _shapes(logs, otherCoin);
        _replay(logs);
        _compare();
        ++ran[step];
        vm.recordLogs();
    }

    function test_replayEveryStep() public {
        vm.recordLogs();
        uint256 club = _reg(alice, "club");
        _track(club);
        _after(0, 0);
        uint256 gold = _reg(bob, "gold");
        _track(gold);
        _after(0, 0);

        // 1. setAddr with carol, zero, the registrar, DEAD and dave; PageNFT is refused and logs nothing
        address[5] memory mains = [carol, address(0), address(reg), DEAD, dave];
        for (uint256 i; i < mains.length; ++i) {
            vm.prank(alice);
            nft.setAddr(club, mains[i]);
            _after(1, 0);
        }
        vm.prank(alice);
        vm.expectRevert(PageNFT.InvalidRecipient.selector);
        nft.setAddr(club, address(nft));
        vm.prank(alice);
        vm.expectRevert(PageNFT.InvalidRecipient.selector);
        nft.setAddrForCoin(club, COIN_OP, abi.encodePacked(address(nft)));
        _after(1, 0);

        // 2. setAddrForCoin for OP, for Ethereum and for another chain
        vm.prank(alice);
        nft.setAddrForCoin(club, COIN_OP, abi.encodePacked(carol));
        _after(2, 0);
        vm.prank(alice);
        nft.setAddrForCoin(club, 60, abi.encodePacked(dave));
        _after(2, 0);
        vm.prank(alice);
        nft.setAddrForCoin(club, BASE, abi.encodePacked(dave));
        _after(2, BASE);

        // 3. a transfer on each of the five paths, and back to the seller
        vm.prank(bob);
        nft.setAddr(gold, hot);
        _after(3, 0);
        vm.prank(bob);
        nft.setAddrForCoin(gold, 60, abi.encodePacked(hot2));
        _after(3, 0);
        SafeLike safe = new SafeLike(bob);
        vm.prank(bob);
        nft.transferFrom(bob, carol, gold);
        _after(3, 0);
        vm.prank(carol);
        nft.approve(dave, gold);
        vm.prank(dave);
        nft.transferFrom(carol, bob, gold);
        _after(3, 0);
        vm.prank(bob);
        nft.setApprovalForAll(stranger, true);
        vm.prank(stranger);
        nft.transferFrom(bob, carol, gold);
        _after(3, 0);
        vm.prank(carol);
        nft.safeTransferFrom(carol, address(safe), gold);
        _after(3, 0);
        vm.prank(bob);
        safe.exec(address(nft), 0, abi.encodeWithSignature(
            "safeTransferFrom(address,address,uint256,bytes)", address(safe), carol, gold, bytes("data")
        ));
        _after(3, 0);
        vm.prank(carol);
        nft.transferFrom(carol, bob, gold);
        _after(3, 0);
        assertEq(nft.resolve(gold), hot, "back with the seller, its saves count again");

        // 4. clearRecords
        vm.prank(alice);
        nft.clearRecords(club);
        _after(4, 0);

        // 5. a minter pick, the parent away, and the old setter's switch off while away
        _setMinter(club, hot);
        _after(5, 0);
        vm.prank(alice);
        nft.transferFrom(alice, carol, club);
        _after(5, 0);
        vm.prank(alice);
        nft.setSubpageMinter(club, address(0));
        _after(5, 0);
        vm.prank(carol);
        nft.transferFrom(carol, alice, club);
        _after(5, 0);

        // 6. registrar sales, one to a buyer that saves on its new subpage at once
        _sellSetup(club, PRICE);
        _after(6, 0);
        vm.prank(buyer);
        uint256 sold = reg.registerSubpage{value: PRICE}(club, "sold", PRICE, address(0));
        _track(sold);
        _after(6, 0);
        vm.prank(buyer);
        nft.setAddr(sold, carol);
        _after(6, 0);
        Holder721 h = new Holder721();
        vm.prank(buyer);
        uint256 boxed = reg.registerSubpageFor{value: PRICE}(club, "boxed", address(h), PRICE, address(0));
        _track(boxed);
        _after(6, 0);

        // 7. a renewal in grace
        vm.warp(nft.expiresAt(club) + 1);
        _after(7, 0);
        uint256 fee = nft.getFee(4);
        vm.prank(stranger);
        nft.renew{value: fee}(club);
        _after(7, 0);

        // 8. a registration over a lapsed name
        vm.warp(nft.expiresAt(gold) + 111 days + 1);
        _reg(dave, "gold");
        _after(8, 0);

        // 9. subpages: by the holder, by its minter, a move, a save, a clear and a send to DEAD
        vm.prank(alice);
        uint256 kid = nft.registerSubpageFor("kid", club, carol);
        _track(kid);
        _after(9, 0);
        _setMinter(club, hot);
        vm.prank(hot);
        uint256 minted = nft.registerSubpageFor("minted", club, dave);
        _track(minted);
        _after(9, 0);
        vm.prank(carol);
        nft.transferFrom(carol, bob, kid);
        _after(9, 0);
        vm.prank(bob);
        nft.setAddr(kid, dave);
        _after(9, 0);
        vm.prank(bob);
        nft.clearRecords(kid);
        _after(9, 0);
        vm.prank(bob);
        nft.transferFrom(bob, DEAD, kid);
        _after(9, 0);
        assertTrue(_deleted(kid));
        vm.prank(alice);
        uint256 straight = nft.registerSubpageFor("straight", club, DEAD);
        _track(straight);
        _after(9, 0);

        // 10. a plain transfer into the registrar
        vm.prank(dave);
        nft.transferFrom(dave, address(reg), gold);
        _after(10, 0);

        // 11. code appears at an address a name answers on coin type 60: no answer changes and nothing is logged, so
        // both indexers stay in step; the next transfer of that name announces its new answer
        vm.prank(dave);
        nft.setAddrForCoin(minted, DEF, abi.encodePacked(dave));
        _after(11, DEF);
        assertEq(nft.addr(minted, 60), abi.encodePacked(dave), "the subpage dave holds answers dave by its default");
        bytes[] memory before = new bytes[](tracked.length);
        for (uint256 i; i < tracked.length; ++i) before[i] = nft.addr(tracked[i], 60);
        vm.etch(dave, address(new Holder721()).code);
        uint256 changed;
        for (uint256 i; i < tracked.length; ++i) {
            if (keccak256(nft.addr(tracked[i], 60)) != keccak256(before[i])) ++changed;
        }
        assertEq(changed, 0, "code appearing at an address changes no answer");
        assertEq(nft.addr(minted, 60), abi.encodePacked(dave), "the subpage dave holds still answers dave");
        _after(11, 0);
        vm.prank(dave);
        nft.transferFrom(dave, carol, minted);
        _after(11, 0);
        assertEq(plain[minted].eth, "", "the transfer announced the new answer, empty since carol saved nothing");

        // 12. subpages minted again, each logging VersionChanged: by the holder over one DEAD holds, by the minter
        // over one minted straight to DEAD, by the holder over a live one whose holder saved a main address, by the
        // holder to DEAD, and by a registrar sale over that one
        vm.prank(alice);
        nft.registerSubpageFor("kid", club, bob);
        _after(12, 0);
        vm.prank(hot);
        nft.registerSubpageFor("straight", club, stranger);
        _after(12, 0);
        vm.prank(alice);
        nft.registerSubpageFor("sold", club, hot2);
        _after(12, 0);
        vm.prank(alice);
        nft.registerSubpageFor("minted", club, DEAD);
        _after(12, 0);
        assertTrue(_deleted(minted), "minted again to DEAD, the subpage is deleted");
        _setMinter(club, address(reg));
        vm.prank(buyer);
        reg.registerSubpage{value: PRICE}(club, "minted", PRICE, address(0));
        _after(12, 0);
        assertEq(nft.ownerOf(minted), buyer);
        assertEq(nft.epochOf(kid), 2);
        assertEq(nft.epochOf(straight), 2);
        assertEq(nft.epochOf(sold), 2);
        assertEq(nft.epochOf(minted), 3);

        for (uint256 i; i < STEPS; ++i) assertGt(ran[i], 0, string.concat("step ", vm.toString(i), " ran"));
        assertTrue(sawOtherChain, "a save of another chain was seen");
        assertGt(comparisons, 60, "the walk compared the indexers with the views");
    }
}

// A holder contract that saves coin type 60 and the main address in its ERC721 hook, and lets the walk call PageNFT
// as itself.
contract ReplaySavingReceiver {
    PageNFT immutable nft;
    bool public saveOnReceive = true;

    constructor(PageNFT n) {
        nft = n;
    }

    function setSave(bool s) external {
        saveOnReceive = s;
    }

    function onERC721Received(address, address, uint256 id, bytes calldata) external returns (bytes4) {
        if (saveOnReceive) {
            nft.setAddrForCoin(id, 60, abi.encodePacked(address(0xBEEF)));
            nft.setAddr(id, address(0xCAFE));
        }
        return this.onERC721Received.selector;
    }

    function exec(bytes calldata data) external returns (bool ok) {
        (ok,) = address(nft).call(data);
    }
}

// Random walks over every step that can move the main address or the coin type 60 answer: saves for five coin types,
// clearRecords, plain and safe transfers, also to the dead address and to a contract that saves in its hook, new
// mints of subpages, registrations again, also as trials or to the dead address, renewals and jumps in time, setData
// and batches. After each step that succeeds, the log keeps the shape rules, an indexer that replays only the address
// events holds what the views answer for every active page and every page the dead address holds, a single save
// announces what the views answer after it, a transfer or a mint announces only the home chain and coin type 60, and
// setData announces no address. Foundry keeps the logs of a call that reverted, so the logs of a refused step are
// thrown away.
contract ReplayFuzzTest is MinterBase {
    uint256 constant DEF = 0x80000000;
    uint256 constant BASE = 0x80002105;
    uint256 constant BTC = 0;

    // what a step does, for the checks of its log
    uint256 constant SAVE = 1;
    uint256 constant MOVE = 2;
    uint256 constant DATA = 3;
    uint256 constant OTHER = 4;

    ReplaySavingReceiver recv;
    uint256[] tracked;
    string[] topLabels;
    uint256[] tops;
    string[] subLabels;
    uint256[] subParents;

    mapping(uint256 => bytes) idxOp;
    mapping(uint256 => bytes) idxEth;
    mapping(uint256 => address) idxNode;

    uint256 stepKind;
    uint256[] annIds;
    uint256[] annCoins;
    bytes[] annVals;

    uint256 checks;
    uint256 ethChecks;
    uint256 deadChecks;

    function setUp() public override {
        super.setUp();
        recv = new ReplaySavingReceiver(nft);
        vm.recordLogs();
        topLabels.push("club");
        topLabels.push("gold");
        tops.push(_reg(alice, "club"));
        tops.push(_reg(bob, "gold"));
        tracked.push(tops[0]);
        tracked.push(tops[1]);
        string[4] memory sl = ["s0", "s1", "s2", "g0"];
        uint256[4] memory sp = [tops[0], tops[0], tops[0], tops[1]];
        for (uint256 i; i < 4; ++i) {
            subLabels.push(sl[i]);
            subParents.push(sp[i]);
            tracked.push(_subId(sl[i], sp[i]));
        }
        vm.prank(alice);
        nft.registerSubpageFor("s0", tops[0], carol);
        vm.prank(alice);
        nft.registerSubpageFor("s1", tops[0], address(recv));
        vm.prank(bob);
        nft.registerSubpageFor("g0", tops[1], dave);
        stepKind = OTHER;
        _process();
    }

    function _r(uint256 seed, uint256 salt) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(seed, salt)));
    }

    function _addr(uint256 r) internal view returns (address) {
        address[9] memory a =
            [address(0), alice, bob, carol, dave, DEAD, address(recv), address(0xBEEF), address(0xCAFE)];
        return a[r % 9];
    }

    function _to(uint256 r) internal view returns (address) {
        address[11] memory a = [alice, bob, carol, dave, DEAD, address(recv), alice, bob, carol, dave, address(recv)];
        return a[r % 11];
    }

    function _coin(uint256 r) internal pure returns (uint256) {
        uint256[5] memory c = [COIN_OP, 60, DEF, BASE, BTC];
        return c[r % 5];
    }

    function _val(uint256 coin, uint256 r) internal view returns (bytes memory) {
        uint256 k = r % 4;
        if (k == 0) return "";
        if (k == 1) return new bytes(20);
        if (coin == BTC && k == 2) return hex"0014aa";
        return abi.encodePacked(_addr(r >> 8));
    }

    // calls PageNFT as the holder, and tells whether the call succeeded
    function _as(address who, bytes memory data) internal returns (bool ok) {
        if (who == DEAD || who == address(0)) return false;
        if (who == address(recv)) return recv.exec(data);
        vm.prank(who);
        (ok,) = address(nft).call(data);
    }

    function _holder(uint256 id) internal view returns (address h) {
        try nft.ownerOf(id) returns (address o) {
            h = o;
        } catch {}
    }

    function _saveCall(uint256 id, uint256 r) internal view returns (bytes memory) {
        if (r % 3 == 0) return abi.encodeCall(PageNFT.setAddr, (id, _addr(r >> 4)));
        uint256 c = _coin(r >> 4);
        return abi.encodeCall(PageNFT.setAddrForCoin, (id, c, _val(c, r >> 12)));
    }

    function _step(uint256 seed, uint256 n) internal {
        uint256 r = _r(seed, n);
        uint256 op = r % 11;
        uint256 id = tracked[(r >> 8) % tracked.length];
        address h = _holder(id);
        delete annIds;
        delete annCoins;
        delete annVals;
        vm.recordLogs();
        bool ok = true;
        if (op <= 2) {
            stepKind = SAVE;
            ok = _as(h, _saveCall(id, r >> 16));
        } else if (op == 3) {
            stepKind = SAVE;
            ok = _as(h, abi.encodeCall(PageNFT.clearRecords, (id)));
        } else if (op == 4 || op == 5) {
            stepKind = MOVE;
            recv.setSave(((r >> 40) & 1) == 0);
            address to = _to(r >> 16);
            if (((r >> 24) & 1) == 0) {
                ok = _as(h, abi.encodeWithSignature("transferFrom(address,address,uint256)", h, to, id));
            } else {
                ok = _as(h, abi.encodeWithSignature("safeTransferFrom(address,address,uint256)", h, to, id));
            }
        } else if (op == 6) {
            stepKind = MOVE;
            recv.setSave(((r >> 40) & 1) == 0);
            uint256 j = (r >> 16) % subLabels.length;
            uint256 parent = subParents[j];
            ok = _as(_holder(parent), abi.encodeCall(PageNFT.registerSubpageFor, (subLabels[j], parent, _to(r >> 24))));
        } else if (op == 7) {
            stepKind = DATA;
            ok = _as(h, abi.encodeCall(PageNFT.setData, (id, "k", abi.encodePacked(r))));
        } else if (op == 8) {
            stepKind = OTHER;
            uint256 len = 1 + (r >> 16) % 3;
            bytes[] memory calls = new bytes[](len);
            for (uint256 i; i < len; ++i) {
                uint256 q = _r(r, i);
                uint256 k = q % 5;
                if (k <= 1) calls[i] = _saveCall(id, q >> 8);
                else if (k == 2) calls[i] = abi.encodeCall(PageNFT.clearRecords, (id));
                else if (k == 3) calls[i] = abi.encodeCall(PageNFT.setData, (id, "k", hex"01"));
                else calls[i] = abi.encodeWithSignature("transferFrom(address,address,uint256)", h, _to(q >> 8), id);
            }
            ok = _as(h, abi.encodeCall(PageNFT.multicall, (calls)));
        } else if (op == 9) {
            stepKind = OTHER;
            uint256[6] memory jumps = [uint256(1 hours), 30 days, 200 days, 400 days, 500 days, 100 days];
            vm.warp(vm.getBlockTimestamp() + jumps[(r >> 16) % 6]);
            uint256 t = tops[(r >> 24) % tops.length];
            if (((r >> 32) & 1) == 0) {
                uint256 fee = nft.getFee(4);
                vm.prank(stranger);
                (ok,) = address(nft).call{value: fee}(abi.encodeCall(PageNFT.renew, (t)));
            }
        } else {
            stepKind = MOVE;
            recv.setSave(((r >> 40) & 1) == 0);
            uint256 j = (r >> 16) % topLabels.length;
            ok = _tryRegister(topLabels[j], _to(r >> 24), ((r >> 32) % 3) == 0);
        }
        if (ok) _process();
        else vm.getRecordedLogs();
    }

    function _tryRegister(string memory label, address to, bool trial) internal returns (bool ok) {
        if (!nft.isAvailable(label, 0)) return true;
        bytes32 secret = keccak256(abi.encode(label, to, vm.getBlockTimestamp()));
        bytes32 c = trial
            ? keccak256(abi.encode(bytes(label), to, uint256(0), secret, true))
            : nft.makeCommitment(label, to, 0, secret);
        vm.prank(stranger);
        nft.commit(c);
        vm.warp(vm.getBlockTimestamp() + 61);
        (,,, uint256 total) = nft.quote(label);
        if (trial) total = nft.getFee(bytes(label).length) / 10;
        vm.deal(stranger, stranger.balance + total);
        vm.prank(stranger);
        (ok,) = address(nft).call{value: total}(
            trial
                ? abi.encodeCall(PageNFT.revealTrial, (label, to, 0, secret))
                : abi.encodeCall(PageNFT.reveal, (label, to, 0, secret))
        );
    }

    function _dec(bytes memory v) internal pure returns (address) {
        return v.length == 0 ? address(0) : address(bytes20(v));
    }

    function _process() internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory l = logs[i];
            if (l.emitter != address(nft)) continue;
            bytes32 t0 = l.topics[0];
            if (t0 == LogShapes.ADDR_CHANGED) {
                assertGt(i, 0, "AddrChanged first");
                Vm.Log memory p = logs[i - 1];
                assertEq(p.emitter, address(nft), "AddrChanged after a log of PageNFT");
                assertEq(p.topics[0], LogShapes.ADDRESS_CHANGED, "AddrChanged right after AddressChanged");
                assertEq(p.topics[1], l.topics[1], "for the same name");
                (uint256 pc, bytes memory pv) = abi.decode(p.data, (uint256, bytes));
                assertEq(pc, 60, "AddrChanged right after AddressChanged(60)");
                address a = abi.decode(l.data, (address));
                assertEq(_dec(pv), a, "AddrChanged carries the address of AddressChanged(60)");
                assertEq(keccak256(pv), keccak256(LogShapes.enc(a)), "zero is announced as empty");
                idxNode[uint256(l.topics[1])] = a;
            } else if (t0 == LogShapes.ADDRESS_CHANGED) {
                uint256 id = uint256(l.topics[1]);
                (uint256 c, bytes memory v) = abi.decode(l.data, (uint256, bytes));
                annIds.push(id);
                annCoins.push(c);
                annVals.push(v);
                if (c == 60 || c == COIN_OP) {
                    assertLt(i + 1, logs.length, "followed");
                    Vm.Log memory nx = logs[i + 1];
                    assertEq(nx.emitter, address(nft));
                    assertEq(nx.topics[1], l.topics[1], "the next log is for the same name");
                    if (c == 60) {
                        assertEq(nx.topics[0], LogShapes.ADDR_CHANGED, "AddressChanged(60), then AddrChanged");
                        idxEth[id] = v;
                    } else {
                        assertEq(nx.topics[0], LogShapes.ADDRESS_CHANGED, "the home chain, then coin type 60");
                        (uint256 nc,) = abi.decode(nx.data, (uint256, bytes));
                        assertEq(nc, 60, "the home chain, then AddressChanged(60)");
                        idxOp[id] = v;
                    }
                    assertTrue(v.length == 0 || v.length == 20, "an EVM answer is empty or 20 bytes");
                    if (v.length == 20) assertTrue(_dec(v) != address(0), "zero is never 20 bytes");
                } else {
                    assertTrue(stepKind == SAVE || stepKind == OTHER, "only a save announces another chain");
                }
            }
        }
        if (stepKind == DATA) assertEq(annIds.length, 0, "setData announces no address");
        // a single save: the last value announced for each name and coin type is the view after the step
        if (stepKind == SAVE) {
            for (uint256 i; i < annIds.length; ++i) {
                bool last = true;
                for (uint256 j = i + 1; j < annIds.length; ++j) {
                    if (annIds[j] == annIds[i] && annCoins[j] == annCoins[i]) last = false;
                }
                if (last) assertEq(nft.addr(annIds[i], annCoins[i]), annVals[i], "the announced value is the view");
            }
        }
        _compare();
    }

    function _active(uint256 id) internal view returns (bool) {
        (string memory l, uint256 parent, uint64 exp,, uint64 pe) = nft.records(id);
        if (bytes(l).length == 0) return false;
        if (_holder(id) == DEAD) return false;
        if (parent == 0) return vm.getBlockTimestamp() <= exp;
        (,, uint64 pexp, uint64 pep,) = nft.records(parent);
        if (pe != pep) return false;
        return vm.getBlockTimestamp() <= pexp;
    }

    function _compare() internal {
        for (uint256 i; i < tracked.length; ++i) {
            uint256 id = tracked[i];
            (string memory l,,,,) = nft.records(id);
            if (bytes(l).length == 0) continue;
            bool dead = _holder(id) == DEAD;
            if (!_active(id) && !dead) continue;
            ++checks;
            if (dead) ++deadChecks;
            bytes memory op = nft.addr(id, COIN_OP);
            bytes memory eth = nft.addr(id, 60);
            assertEq(idxOp[id], op, "indexer, home chain");
            assertEq(idxEth[id], eth, "indexer, coin type 60");
            assertEq(idxNode[id], nft.addr(bytes32(id)), "indexer, addr by node");
            assertEq(_dec(idxOp[id]), nft.resolve(id), "indexer, main address");
            assertEq(nft.addr(bytes32(id)), _dec(eth), "addr by node is the coin type 60 answer");
            assertEq(nft.addr(bytes32(id), 60), eth, "addr by node for coin type 60");
            if (eth.length != 0) ++ethChecks;
            if (dead) {
                assertEq(op.length, 0, "a page the dead address holds answers nothing");
                assertEq(eth.length, 0, "nothing for coin type 60 either");
            }
        }
    }

    function testFuzz_eventsMatchTheViews(uint256 seed) public {
        for (uint256 n; n < 40; ++n) _step(seed, n);
    }

    // a long fixed walk that meets saved coin type 60 answers and pages the dead address holds often enough
    function test_longWalk() public {
        for (uint256 s; s < 6; ++s) {
            for (uint256 n; n < 120; ++n) _step(s, n);
        }
        emit log_named_uint("checks", checks);
        emit log_named_uint("checks with a coin type 60 answer", ethChecks);
        emit log_named_uint("checks of a page the dead address holds", deadChecks);
        assertGt(ethChecks, 50);
        assertGt(deadChecks, 10);
    }
}

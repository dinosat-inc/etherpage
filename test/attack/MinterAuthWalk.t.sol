// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {console} from "forge-std/Test.sol";
import {PageNFT} from "../../src/PageNFT.sol";
import {MinterBase} from "../utils/MinterBase.sol";

// Random walks against a model of the minter rules: who may pick, who may mint, and what a minter,
// which only creates, may overwrite. The model tracks its own epochs, picks and subpage liveness.
contract MinterAuthWalkTest is MinterBase {
    struct Pick {
        address minter;
        uint64 epoch;
        address setter;
    }

    uint256[2] parents;
    string[2] plabels = ["club", "gold"];
    string[3] slabels = ["s0", "s1", "s2"];
    address key = makeAddr("key");

    mapping(uint256 => Pick) gPick;
    mapping(uint256 => uint64) gEpoch;
    mapping(uint256 => bool) gSubExists;
    mapping(uint256 => uint64) gSubParentEpoch;

    uint256 cMinterMint;
    uint256 cRevived;
    uint256 cReReg;
    uint256 cNotParent;
    uint256 cAlready;
    uint256 cExpired;
    uint256 cAwayClear;
    uint256 cSetRefused;
    bool biased;

    function setUp() public override {
        super.setUp();
        vm.deal(key, 1000 ether);
        parents[0] = _reg(alice, "club");
        parents[1] = _reg(bob, "gold");
        gEpoch[parents[0]] = 1;
        gEpoch[parents[1]] = 1;
    }

    function _actor(uint256 r) internal view returns (address) {
        address[5] memory a = [alice, bob, carol, dave, key];
        return a[r % 5];
    }

    function _pickAddr(uint256 r) internal view returns (address) {
        address[8] memory a = [address(0), alice, bob, carol, dave, key, address(nft), DEAD];
        return a[r % 8];
    }

    function _now() internal view returns (uint256) {
        return vm.getBlockTimestamp();
    }

    function _counted(uint256 p) internal view returns (bool) {
        Pick storage w = gPick[p];
        return w.setter == nft.ownerOf(p) && w.epoch == gEpoch[p];
    }

    function _checkView(uint256 p) internal view {
        address m = nft.subpageMinterOf(p);
        if (_counted(p)) assertEq(m, gPick[p].minter, "view minter");
        else assertEq(m, address(0), "view minter off");
    }

    function _opSet(uint256 r) internal {
        uint256 p = parents[r % 2];
        address caller = biased && (r >> 40) % 3 != 0 ? nft.ownerOf(p) : _actor(r >> 8);
        address pick = _pickAddr(r >> 16);
        address owner = nft.ownerOf(p);
        bool expired = _now() > nft.expiresAt(p);
        bytes4 want;
        if (pick != address(0) && expired) want = PageNFT.Expired.selector;
        else if (caller != owner && (pick != address(0) || gPick[p].setter != caller)) want = PageNFT.Unauthorized.selector;
        vm.prank(caller);
        try nft.setSubpageMinter(p, pick) {
            assertEq(want, bytes4(0), "set succeeded where the model refuses");
            if (caller != owner) cAwayClear++;
            gPick[p] = Pick(pick, gEpoch[p], caller);
        } catch (bytes memory err) {
            assertEq(bytes4(err), want, "set error");
            assertTrue(want != bytes4(0), "set refused where the model allows");
            cSetRefused++;
        }
    }

    function _opMint(uint256 r) internal {
        uint256 p = parents[r % 2];
        address caller = _actor(r >> 8);
        if (biased && (r >> 40) % 3 != 0 && gPick[p].minter != address(0)) caller = gPick[p].minter;
        address to = _actor(r >> 16);
        string memory label = slabels[(r >> 24) % 3];
        uint256 sub = _subId(label, p);
        address owner = nft.ownerOf(p);
        bool live = gSubExists[sub] && gSubParentEpoch[sub] == gEpoch[p];
        bool counted = _counted(p);
        bytes4 want;
        if (_now() > nft.expiresAt(p)) want = PageNFT.Expired.selector;
        else if (caller != owner) {
            address m = counted ? gPick[p].minter : address(0);
            if (m != caller) want = PageNFT.NotParentOwner.selector;
            else if (live) want = PageNFT.AlreadyRegistered.selector;
        }
        vm.prank(caller);
        try nft.registerSubpageFor(label, p, to) returns (uint256 id) {
            assertEq(want, bytes4(0), "mint succeeded where the model refuses");
            assertEq(id, sub);
            assertEq(nft.ownerOf(sub), to);
            if (caller != owner) cMinterMint++;
            gSubExists[sub] = true;
            gSubParentEpoch[sub] = gEpoch[p];
        } catch (bytes memory err) {
            assertEq(bytes4(err), want, "mint error");
            assertTrue(want != bytes4(0), "mint refused where the model allows");
            if (want == PageNFT.NotParentOwner.selector) cNotParent++;
            if (want == PageNFT.AlreadyRegistered.selector) cAlready++;
            if (want == PageNFT.Expired.selector) cExpired++;
        }
    }

    function _opTransfer(uint256 r) internal {
        uint256 p = parents[r % 2];
        address owner = nft.ownerOf(p);
        if (owner == DEAD) return;
        address to = ((r >> 8) % 23 == 0) ? DEAD : _actor(r >> 16);
        bool before = _counted(p);
        bool byOperator = (r >> 24) & 1 == 1;
        address mover = owner;
        if (byOperator) {
            mover = _actor(r >> 32);
            vm.prank(owner);
            nft.setApprovalForAll(mover, true);
        }
        if (_now() > nft.expiresAt(p)) {
            vm.prank(mover);
            vm.expectRevert(PageNFT.Expired.selector);
            nft.transferFrom(owner, to, p);
            return;
        }
        vm.prank(mover);
        nft.transferFrom(owner, to, p);
        if (!before && _counted(p) && gPick[p].minter != address(0)) cRevived++;
    }

    function _opRenew(uint256 r) internal {
        uint256 p = parents[r % 2];
        if (_now() > nft.expiresAt(p) + 90 days) return;
        uint256 fee = nft.getFee(4);
        if (nft.expiresAt(p) + 365 days > _now() + 3650 days) return;
        vm.prank(stranger);
        nft.renew{value: fee}(p);
    }

    function _opReReg(uint256 r) internal {
        uint256 i = r % 2;
        if (!nft.isAvailable(plabels[i], 0)) return;
        _reg(_actor(r >> 8), plabels[i]);
        gEpoch[parents[i]]++;
        cReReg++;
    }

    function _opRelease(uint256 r) internal {
        uint256 p = parents[r % 2];
        if (nft.isReleasable(p)) nft.release(p);
    }

    function _walk(uint256 seed, uint256 steps) internal {
        biased = seed % 2 == 0;
        for (uint256 i; i < steps; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            uint256 op = r % 16;
            r >>= 8;
            if (op < 4) _opSet(r);
            else if (op < 9) _opMint(r);
            else if (op < 12) _opTransfer(r);
            else if (op == 12) vm.warp(_now() + 1 + (r % 30 days));
            else if (op == 13 && (!biased || (r >> 60) % 3 == 0)) vm.warp(_now() + 60 days + (r % 200 days));
            else if (op == 14) _opRenew(r);
            else {
                _opReReg(r);
                _opRelease(r >> 4);
            }
            _checkView(parents[0]);
            _checkView(parents[1]);
        }
    }

    /// forge-config: default.fuzz.runs = 1000

    /// forge-config: deep.fuzz.runs = 1000
    function testFuzz_walk(uint256 seed) public {
        _walk(seed, 60);
    }

    function _long(uint256 seed) internal {
        _walk(seed, 1500);
        console.log("minterMints", cMinterMint);
        console.log("revived", cRevived, "reRegs", cReReg);
        console.log("notParent", cNotParent, "already", cAlready);
        console.log("expired", cExpired, "awayClear", cAwayClear);
        console.log("setRefused", cSetRefused);
    }

    function test_longWalk1() public { _long(1); }
    function test_longWalk2() public { _long(2); }
    function test_longWalk3() public { _long(3); }
    function test_longWalk4() public { _long(0xdead); }
    function test_longWalk5() public { _long(5); }
    function test_longWalk6() public { _long(7); }
}

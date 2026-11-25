// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {PageNFT} from "../../src/PageNFT.sol";
import {SubpageRegistrar} from "../../src/SubpageRegistrar.sol";
import {MinterBase} from "../utils/MinterBase.sol";

// A random walk over two parents, checked against a model of the sale rules.
// Every sale must succeed exactly when the model says the current holder set an enabled config and picked the
// registrar as minter in the current registration, the parent has not expired, and the label is not live.
contract RegistrarModelWalkTest is MinterBase {
    struct G {
        string label;
        uint256 id;
        address owner;
        uint64 epoch;
        uint256 expires;
        // minter record as last written
        address mSetter;
        address mMinter;
        uint64 mEpoch;
        // sale config as last written
        address cController;
        uint64 cEpoch;
        bool cEnabled;
        address cPayout;
        uint256 cPrice;
    }

    struct S {
        bool exists;
        uint64 parentEpoch;
        address owner;
    }

    G[2] g;
    mapping(uint256 => mapping(uint256 => S)) subs; // by parent index, then label index
    string[5] labels = ["a", "b", "c", "dd", "e5"];
    address[4] actors;
    address[4] pays;
    mapping(address => uint256) gProceeds;

    uint256 public sales;
    uint256 public refusedSales;
    uint256 public reRegs;
    uint256 public revivals;

    function setUp() public override {
        super.setUp();
        actors = [alice, bob, carol, dave];
        for (uint256 i; i < 4; ++i) pays[i] = makeAddr(string.concat("pay", vm.toString(i)));
        g[0].label = "club";
        g[1].label = "zoo";
        for (uint256 p; p < 2; ++p) {
            g[p].id = _reg(actors[p], g[p].label);
            g[p].owner = actors[p];
            g[p].epoch = 1;
            g[p].expires = nft.expiresAt(g[p].id);
        }
        // every actor also gives the registrar an operator approval, which must stay inert
        for (uint256 i; i < 4; ++i) {
            vm.prank(actors[i]);
            nft.setApprovalForAll(address(reg), true);
        }
    }

    function _now() internal view returns (uint256) {
        return vm.getBlockTimestamp();
    }

    function _active(uint256 p) internal view returns (bool) {
        return _now() <= g[p].expires;
    }

    function _counted(uint256 p) internal view returns (address) {
        if (g[p].mSetter != g[p].owner || g[p].mEpoch != g[p].epoch) return address(0);
        return g[p].mMinter;
    }

    function _live(uint256 p, uint256 l) internal view returns (bool) {
        return subs[p][l].exists && subs[p][l].parentEpoch == g[p].epoch;
    }

    function _pick(uint256 seed, uint256 salt, uint256 n) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(seed, salt))) % n;
    }

    function _upper(string memory s) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        bytes memory o = new bytes(b.length);
        for (uint256 i; i < b.length; ++i) {
            uint8 c = uint8(b[i]);
            o[i] = (c >= 0x61 && c <= 0x7a) ? bytes1(c - 32) : b[i];
        }
        return string(o);
    }

    // the error the model expects from a sale, zero for success
    function _expectedSaleError(uint256 p, uint256 l) internal view returns (bytes4) {
        G storage x = g[p];
        if (!x.cEnabled) return SubpageRegistrar.NotEnabled.selector;
        if (x.cEpoch != x.epoch) return SubpageRegistrar.StaleConfig.selector;
        if (x.owner != x.cController) return SubpageRegistrar.StaleController.selector;
        if (_counted(p) != address(reg)) return SubpageRegistrar.NotMinter.selector;
        if (!_active(p) || _live(p, l)) return SubpageRegistrar.NotAvailable.selector;
        return bytes4(0);
    }

    function _step(uint256 seed, uint256 i) internal {
        uint256 s = uint256(keccak256(abi.encode(seed, i)));
        uint256 p = _pick(s, 1, 2);
        G storage x = g[p];
        uint256 k = _pick(s, 2, 20);
        // weights out of 20: transfer 3, pick 2, away 1, configure 2, disable 1, sale 4, reveal 1, mints 2,
        // warp 1, jump 1, claim 2; then a jump becomes a warp two times in three
        uint256 kind = k < 3 ? 0 : k < 5 ? 1 : k < 6 ? 2 : k < 8 ? 3 : k < 9 ? 4 : k < 13 ? 5 : k < 14 ? 6
            : k < 15 ? 7 : k < 16 ? 8 : k < 17 ? 9 : k < 18 ? 10 : 11;
        address actor = actors[_pick(s, 3, 4)];
        if ((kind == 3 || kind == 4) && _pick(s, 17, 2) == 0) actor = x.owner;
        if (kind == 10 && _pick(s, 18, 3) != 0) kind = 9;

        if (kind == 0) {
            // transfer the parent away or back
            if (actor == x.owner) return;
            address from = x.owner;
            vm.prank(from);
            if (!_active(p)) {
                vm.expectRevert(PageNFT.Expired.selector);
                nft.transferFrom(from, actor, x.id);
                return;
            }
            nft.transferFrom(from, actor, x.id);
            if (actor == x.cController && x.cEnabled && x.mSetter == actor && x.mMinter == address(reg)) revivals++;
            x.owner = actor;
        } else if (kind == 1) {
            // the holder picks a minter
            uint256 c = _pick(s, 4, 3);
            address m = c == 0 || _pick(s, 19, 2) == 0 ? address(reg) : c == 1 ? address(0) : hot;
            vm.prank(x.owner);
            if (m != address(0) && !_active(p)) {
                vm.expectRevert(PageNFT.Expired.selector);
                nft.setSubpageMinter(x.id, m);
                return;
            }
            nft.setSubpageMinter(x.id, m);
            (x.mSetter, x.mMinter, x.mEpoch) = (x.owner, m, x.epoch);
        } else if (kind == 2) {
            // someone who does not hold the parent tries to switch off, or to pick a nonzero minter
            if (actor == x.owner) return;
            bool nonZero = _pick(s, 6, 3) == 0;
            vm.prank(actor);
            if (nonZero) {
                if (!_active(p)) vm.expectRevert(PageNFT.Expired.selector);
                else vm.expectRevert(PageNFT.Unauthorized.selector);
                nft.setSubpageMinter(x.id, address(reg));
                return;
            }
            if (actor != x.mSetter) {
                vm.expectRevert(PageNFT.Unauthorized.selector);
                nft.setSubpageMinter(x.id, address(0));
                return;
            }
            nft.setSubpageMinter(x.id, address(0));
            (x.mSetter, x.mMinter, x.mEpoch) = (actor, address(0), x.epoch);
        } else if (kind == 3) {
            // configure by anyone
            uint256 price = _pick(s, 7, 3) * 0.01 ether;
            address pay = pays[_pick(s, 8, 4)];
            vm.prank(actor);
            if (actor != x.owner) {
                vm.expectRevert(SubpageRegistrar.NotAuthorized.selector);
                reg.configure(x.id, pay, address(0), price, true, address(0), 0, false);
                return;
            }
            reg.configure(x.id, pay, address(0), price, true, address(0), 0, false);
            (x.cController, x.cEpoch, x.cEnabled, x.cPayout, x.cPrice) = (actor, x.epoch, true, pay, price);
        } else if (kind == 4) {
            // disable by anyone
            vm.prank(actor);
            if (actor != x.owner) {
                vm.expectRevert(SubpageRegistrar.NotAuthorized.selector);
                reg.disable(x.id);
                return;
            }
            reg.disable(x.id);
            x.cEnabled = false;
        } else if (kind == 5 || kind == 6) {
            // a sale, direct or through commit and reveal, sometimes with an uppercase label
            uint256 l = _pick(s, 9, labels.length);
            string memory label = _pick(s, 10, 3) == 0 ? _upper(labels[l]) : labels[l];
            address to = _pick(s, 11, 2) == 0 ? buyer : stranger;
            uint256 extra = _pick(s, 12, 2) == 0 ? 0 : 0.003 ether;
            uint256 value = x.cPrice + extra;
            bytes4 err = _expectedSaleError(p, l);
            address liveOwner = _live(p, l) ? nft.ownerOf(_subId(labels[l], x.id)) : address(0);
            uint256 before = buyer.balance;
            if (kind == 6) {
                bytes32 secret = bytes32(s);
                bytes32 subCommitment = reg.makeSubpageCommitment(x.id, label, to, secret);
                vm.prank(buyer);
                reg.commitSubpage(subCommitment);
                vm.warp(_now() + 61);
                err = _expectedSaleError(p, l);
                vm.prank(buyer);
                if (err != bytes4(0)) {
                    vm.expectRevert(err);
                    reg.revealSubpageFor{value: value}(x.id, label, to, secret, x.cPrice, address(0));
                } else {
                    reg.revealSubpageFor{value: value}(x.id, label, to, secret, x.cPrice, address(0));
                }
            } else {
                vm.prank(buyer);
                if (err != bytes4(0)) {
                    vm.expectRevert(err);
                    reg.registerSubpageFor{value: value}(x.id, label, to, x.cPrice, address(0));
                } else {
                    reg.registerSubpageFor{value: value}(x.id, label, to, x.cPrice, address(0));
                }
            }
            if (err != bytes4(0)) {
                refusedSales++;
                if (err == SubpageRegistrar.NotAvailable.selector && _live(p, l)) {
                    assertEq(nft.ownerOf(_subId(labels[l], x.id)), liveOwner, "live sub untouched");
                }
                assertEq(buyer.balance, before, "refused sale costs nothing");
                return;
            }
            sales++;
            assertEq(buyer.balance, before - x.cPrice, "buyer pays the price exactly");
            gProceeds[x.cPayout] += x.cPrice;
            subs[p][l] = S(true, x.epoch, to);
            assertEq(nft.ownerOf(_subId(labels[l], x.id)), to);
        } else if (kind == 7) {
            // the holder mints or takes back directly
            uint256 l = _pick(s, 9, labels.length);
            address to = actors[_pick(s, 13, 4)];
            vm.prank(x.owner);
            if (!_active(p)) {
                vm.expectRevert(PageNFT.Expired.selector);
                nft.registerSubpageFor(labels[l], x.id, to);
                return;
            }
            nft.registerSubpageFor(labels[l], x.id, to);
            subs[p][l] = S(true, x.epoch, to);
        } else if (kind == 8) {
            // the hot key mints directly, as a minter or not
            uint256 l = _pick(s, 9, labels.length);
            address m = _counted(p);
            vm.prank(hot);
            if (!_active(p)) vm.expectRevert(PageNFT.Expired.selector);
            else if (m != hot) vm.expectRevert(PageNFT.NotParentOwner.selector);
            else if (_live(p, l)) vm.expectRevert(PageNFT.AlreadyRegistered.selector);
            else {
                nft.registerSubpageFor(labels[l], x.id, hot);
                subs[p][l] = S(true, x.epoch, hot);
                return;
            }
            nft.registerSubpageFor(labels[l], x.id, hot);
        } else if (kind == 9) {
            vm.warp(_now() + 1 hours + _pick(s, 14, 20 days));
        } else if (kind == 10) {
            // a long jump, then a renewal attempt half of the time if grace has not ended, or a new
            // registration if it has
            vm.warp(_now() + _pick(s, 14, 400 days));
            if (_now() <= x.expires + 90 days) {
                if (_pick(s, 15, 2) == 0) return;
                vm.prank(stranger);
                try nft.renew{value: 1 ether}(x.id) {
                    x.expires = nft.expiresAt(x.id);
                } catch {}
                return;
            }
            address who = actor;
            _reg(who, x.label);
            reRegs++;
            x.owner = who;
            x.epoch += 1;
            x.expires = nft.expiresAt(x.id);
        } else {
            // claims, by the payout or by a stranger for the payout
            address pay = pays[_pick(s, 8, 4)];
            uint256 owedNow = gProceeds[pay];
            uint256 b = pay.balance;
            if (owedNow == 0) {
                vm.prank(pay);
                vm.expectRevert(SubpageRegistrar.NothingToClaim.selector);
                reg.claimProceeds(address(0));
                return;
            }
            if (_pick(s, 16, 2) == 0) {
                vm.prank(pay);
                reg.claimProceeds(address(0));
            } else {
                vm.prank(stranger);
                reg.claimProceedsFor(pay);
            }
            assertEq(pay.balance, b + owedNow);
            gProceeds[pay] = 0;
        }
    }

    function _check() internal view {
        uint256 sum;
        for (uint256 i; i < 4; ++i) {
            assertEq(reg.proceedsOf(pays[i]), gProceeds[pays[i]], "proceeds ledger");
            sum += gProceeds[pays[i]];
        }
        assertEq(address(reg).balance, sum, "registrar holds exactly the proceeds");
        for (uint256 p; p < 2; ++p) {
            assertEq(nft.ownerOf(g[p].id), g[p].owner, "owner");
            assertEq(nft.epochOf(g[p].id), g[p].epoch, "epoch");
            assertEq(nft.subpageMinterOf(g[p].id), _counted(p), "counted minter");
            for (uint256 l; l < labels.length; ++l) {
                if (_live(p, l)) assertEq(nft.ownerOf(_subId(labels[l], g[p].id)), subs[p][l].owner, "sub owner");
            }
        }
    }

    function _walk(uint256 seed, uint256 n) internal {
        for (uint256 i; i < n; ++i) {
            _step(seed, i);
            _check();
        }
    }

    /// forge-config: default.fuzz.runs = 1500

    /// forge-config: deep.fuzz.runs = 1500
    function testFuzz_saleIffHolderChoseBoth(uint256 seed) public {
        _walk(seed, 80);
    }

    function test_longWalks() public {
        uint256 tSales;
        uint256 tRefused;
        for (uint256 k; k < 12; ++k) {
            uint256 snap = vm.snapshotState();
            sales = 0;
            refusedSales = 0;
            reRegs = 0;
            revivals = 0;
            _walk(uint256(keccak256(abi.encode("walk", k))), 500);
            emit log_named_uint("walk", k);
            emit log_named_uint("  sales", sales);
            emit log_named_uint("  refused sales", refusedSales);
            emit log_named_uint("  re-registrations", reRegs);
            emit log_named_uint("  returns to a controller with a live pick", revivals);
            tSales += sales;
            tRefused += refusedSales;
            vm.revertToState(snap);
        }
        assertGt(tSales, 0);
        assertGt(tRefused, 0);
    }
}

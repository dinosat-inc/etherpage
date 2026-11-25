// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {PageNFT} from "../../../src/PageNFT.sol";
import {MinterBase} from "../../utils/MinterBase.sol";

// Takes the page in the mint callback and saves a main address in the same second.
contract SavesOnReceipt {
    function onERC721Received(address, address, uint256 id, bytes calldata) external returns (bytes4) {
        PageNFT(msg.sender).setAddr(id, address(0xBEEF));
        return this.onERC721Received.selector;
    }
}

// addressesUpdatedAt moves on every save or clear of addresses, by setAddr, setAddrForCoin or clearRecords, and on
// nothing else.
contract AddressesUpdatedAtTest is MinterBase {
    uint256 constant COIN_60 = 60;
    uint256 constant DEFAULT_EVM = 0x80000000;
    uint256 constant BASE = 0x80002105;

    function test_zeroUntilAnAddressIsSaved() public {
        uint256 id = _reg(alice, "alice");
        assertEq(nft.addressesUpdatedAt(id), 0);
        assertEq(nft.addressesUpdatedAt(_id("nobody")), 0);
    }

    function test_everyAddressWriteSetsIt() public {
        uint256 id = _reg(alice, "alice");
        uint256[6] memory coins = [COIN_OP, COIN_60, DEFAULT_EVM, BASE, uint256(0), uint256(1) << 200];
        for (uint256 i; i < coins.length; ++i) {
            vm.warp(vm.getBlockTimestamp() + 10);
            vm.prank(alice);
            nft.setAddrForCoin(id, coins[i], abi.encodePacked(hot));
            assertEq(nft.addressesUpdatedAt(id), vm.getBlockTimestamp(), "setAddrForCoin");
        }
        // a clear sets it too
        for (uint256 i; i < coins.length; ++i) {
            vm.warp(vm.getBlockTimestamp() + 10);
            vm.prank(alice);
            nft.setAddrForCoin(id, coins[i], "");
            assertEq(nft.addressesUpdatedAt(id), vm.getBlockTimestamp(), "setAddrForCoin with an empty value");
        }
        vm.warp(vm.getBlockTimestamp() + 10);
        vm.prank(alice);
        nft.setAddr(id, hot2);
        assertEq(nft.addressesUpdatedAt(id), vm.getBlockTimestamp(), "setAddr");

        vm.warp(vm.getBlockTimestamp() + 10);
        vm.prank(alice);
        nft.setAddr(id, address(0));
        assertEq(nft.addressesUpdatedAt(id), vm.getBlockTimestamp(), "setAddr back to the holder");

        vm.warp(vm.getBlockTimestamp() + 10);
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeWithSignature("clearRecords(uint256)", id);
        vm.prank(alice);
        nft.multicall(calls);
        assertEq(nft.addressesUpdatedAt(id), vm.getBlockTimestamp(), "clearRecords through multicall");
    }

    function test_nothingElseMovesIt() public {
        uint256 id = _reg(alice, "alice");
        vm.prank(alice);
        nft.setAddr(id, hot);
        uint256 t = vm.getBlockTimestamp();
        vm.warp(t + 100);
        vm.startPrank(alice);
        nft.setText(id, "url", "x");
        nft.setContenthash(id, hex"e301");
        nft.setData(id, "payment-preference", hex"01");
        nft.setPrimaryPage(id);
        nft.setSubpageMinter(id, dave);
        nft.registerSubpage("pay", id);
        nft.transferFrom(alice, bob, id);
        vm.stopPrank();
        vm.prank(bob);
        nft.keepProfile(id);
        vm.prank(stranger);
        nft.renew{value: 0.0001 ether}(id);
        assertEq(nft.addressesUpdatedAt(id), t);
        _lapseAndRegister(id, carol);
        assertEq(nft.addressesUpdatedAt(id), t, "a new registration does not move it");
    }

    // a new holder can save addresses in the same second as the transfer, so both values can be equal
    function test_canEqualHolderSince() public {
        uint256 id = _reg(alice, "alice");
        vm.warp(vm.getBlockTimestamp() + 50);
        vm.prank(alice);
        nft.transferFrom(alice, bob, id);
        vm.prank(bob);
        nft.setAddrForCoin(id, COIN_60, abi.encodePacked(hot));
        assertEq(nft.addressesUpdatedAt(id), nft.holderSince(id));
    }

    // a time before holderSince was written before the current holder last got the page, and the saved addresses of
    // that holder count again when the page comes back
    function test_olderThanHolderSinceAfterAReturn() public {
        uint256 id = _reg(alice, "alice");
        vm.prank(alice);
        nft.setAddr(id, hot);
        uint256 saved = vm.getBlockTimestamp();
        vm.warp(saved + 100);
        vm.prank(alice);
        nft.transferFrom(alice, bob, id);
        vm.warp(saved + 200);
        vm.prank(bob);
        nft.transferFrom(bob, alice, id);
        assertEq(nft.addressesUpdatedAt(id), saved);
        assertEq(nft.holderSince(id), saved + 200);
        assertEq(nft.resolve(id), hot, "her saved main address counts again");
    }

    // the old holder saves and then moves the page in one batch: the time equals holderSince though the new holder
    // saved nothing. Every answer is the new holder's, so the rule only warns once too often.
    function test_aSaveThenATransferInOneBatch() public {
        uint256 id = _reg(alice, "alice");
        vm.warp(vm.getBlockTimestamp() + 7);
        bytes[] memory calls = new bytes[](3);
        calls[0] = abi.encodeWithSignature("setAddr(uint256,address)", id, hot);
        calls[1] =
            abi.encodeWithSignature("setAddrForCoin(uint256,uint256,bytes)", id, COIN_60, abi.encodePacked(hot2));
        calls[2] = abi.encodeWithSignature("transferFrom(address,address,uint256)", alice, bob, id);
        vm.prank(alice);
        nft.multicall(calls);
        assertEq(nft.addressesUpdatedAt(id), nft.holderSince(id), "the rule says the new holder changed addresses");
        assertEq(nft.resolve(id), bob, "but the main address is the holder");
        assertEq(nft.addr(id, COIN_60).length, 0);
        assertEq(nft.addr(bytes32(id)), address(0));
    }

    // a subpage minted again in the second its old holder saved: the two values are equal, and nothing of the new
    // holder's is saved
    function test_aSubpageMintedAgainInTheSecondOfASave() public {
        uint256 shop = _reg(alice, "shop");
        vm.prank(alice);
        uint256 s = nft.registerSubpageFor("s", shop, bob);
        vm.warp(vm.getBlockTimestamp() + 7);
        vm.prank(bob);
        nft.setAddr(s, hot);
        vm.prank(alice);
        nft.registerSubpageFor("s", shop, carol);
        assertEq(nft.addressesUpdatedAt(s), nft.holderSince(s));
        assertEq(nft.resolve(s), carol);
    }

    // a subpage minted again for the same holder: its old saves are gone and the time is older than holderSince
    function test_aSubpageMintedAgainForTheSameHolder() public {
        uint256 shop = _reg(alice, "shop");
        vm.prank(alice);
        uint256 s = nft.registerSubpageFor("s", shop, bob);
        vm.prank(bob);
        nft.setAddr(s, hot);
        vm.warp(vm.getBlockTimestamp() + 7);
        vm.prank(alice);
        nft.registerSubpageFor("s", shop, bob);
        assertLt(nft.addressesUpdatedAt(s), nft.holderSince(s));
        assertEq(nft.resolve(s), bob);
    }

    // a top level page registered again: a save in the last second of the old registration is older than the new
    // holderSince, as the page is free only from the next second
    function test_aNewRegistrationIsNeverInTheSecondOfTheLastSave() public {
        bytes32 secret = keccak256("trial");
        vm.prank(alice);
        nft.commit(keccak256(abi.encode(bytes("fast"), alice, uint256(0), secret, true)));
        vm.warp(vm.getBlockTimestamp() + 61);
        vm.prank(alice);
        uint256 id = nft.revealTrial{value: nft.getFee(4) / 10}("fast", alice, 0, secret);
        vm.warp(nft.expiresAt(id) - 100);
        secret = keccak256("again");
        vm.prank(bob);
        nft.commit(nft.makeCommitment("fast", bob, 0, secret));

        vm.warp(nft.expiresAt(id));
        vm.prank(alice);
        nft.setAddr(id, hot);
        uint256 saved = vm.getBlockTimestamp();
        vm.prank(bob);
        vm.expectRevert(PageNFT.AlreadyRegistered.selector);
        nft.reveal{value: 1 ether}("fast", bob, 0, secret);
        vm.warp(saved + 1);
        vm.prank(bob);
        nft.reveal{value: 1 ether}("fast", bob, 0, secret);
        assertEq(nft.holderSince(id), saved + 1);
        assertLt(nft.addressesUpdatedAt(id), nft.holderSince(id));
        assertEq(nft.resolve(id), bob);
    }

    // a holder contract that saves inside the mint callback does so in the second it got the page
    function test_aSaveInsideTheMintCallback() public {
        uint256 id = _regTo(alice, "fwd", address(new SavesOnReceipt()));
        assertEq(nft.addressesUpdatedAt(id), nft.holderSince(id));
        assertEq(nft.resolve(id), address(0xBEEF));
    }
}

// The wallet rule as a property: whenever the address answers of an active page differ from what they were at an
// earlier moment when it was active, holderSince or addressesUpdatedAt is at or after that moment. So a payer that
// remembers when it last looked is always warned of a change. Random walks over every write that can move a page or
// its addresses, for a top level page and a subpage.
contract WalletRuleWalkTest is MinterBase {
    uint256 constant COIN_60 = 60;
    uint256 constant DEFAULT_EVM = 0x80000000;
    uint256 constant BASE = 0x80002105;

    struct Seen {
        uint256 time;
        bytes32 answers;
    }

    uint256 shop;
    uint256 sub;
    Seen[] shopSeen;
    Seen[] subSeen;
    address[4] actors;

    function setUp() public override {
        super.setUp();
        shop = _reg(alice, "shop");
        vm.prank(alice);
        sub = nft.registerSubpageFor("s", shop, bob);
        actors = [alice, bob, carol, dave];
    }

    function _answers(uint256 id) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                nft.resolve(id),
                nft.addr(bytes32(id)),
                nft.addr(id, COIN_OP),
                nft.addr(id, DEFAULT_EVM),
                nft.addr(id, BASE),
                nft.addr(id, 0),
                nft.addr(id, 0x80000001)
            )
        );
    }

    // resolve is zero exactly when the page is not active, as a saved main address is never zero
    function _active(uint256 id) internal view returns (bool) {
        return nft.resolve(id) != address(0);
    }

    function _check(uint256 id, Seen[] storage seen) internal {
        if (!_active(id)) return;
        bytes32 a = _answers(id);
        uint256 since = nft.holderSince(id);
        uint256 updated = nft.addressesUpdatedAt(id);
        for (uint256 i; i < seen.length; ++i) {
            if (seen[i].answers != a) {
                assertTrue(since >= seen[i].time || updated >= seen[i].time, "answers changed with no warning");
            }
        }
        seen.push(Seen(vm.getBlockTimestamp(), a));
    }

    function _pick(uint256 r) internal view returns (address) {
        return actors[r % 4];
    }

    function _val(uint256 r) internal view returns (address) {
        uint256 k = r % 4;
        if (k == 0) return address(0);
        if (k == 1) return hot;
        if (k == 2) return hot2;
        return actors[(r >> 8) % 4];
    }

    // a step may be refused; the walk goes on from the state it leaves
    function _call(address who, bytes memory data) internal {
        vm.prank(who);
        (bool ok,) = address(nft).call(data);
        ok;
    }

    function _step(uint256 r) internal {
        uint256 target = (r >> 4) & 1 == 0 ? shop : sub;
        address holder = nft.ownerOf(target);
        uint256 v = r >> 16;
        uint256 action = r % 16;
        if (action == 0) {
            _call(holder, abi.encodeCall(nft.setAddr, (target, _val(v))));
        } else if (action == 1) {
            _call(holder, abi.encodeCall(nft.setAddrForCoin, (target, COIN_60, abi.encodePacked(_val(v)))));
        } else if (action == 2) {
            _call(holder, abi.encodeCall(nft.setAddrForCoin, (target, DEFAULT_EVM, abi.encodePacked(_val(v)))));
        } else if (action == 3) {
            _call(holder, abi.encodeCall(nft.setAddrForCoin, (target, BASE, abi.encodePacked(_val(v)))));
        } else if (action == 4) {
            bytes memory b = v % 3 == 0 ? bytes("") : abi.encodePacked(uint16(v));
            _call(holder, abi.encodeCall(nft.setAddrForCoin, (target, 0, b)));
        } else if (action == 5) {
            _call(holder, abi.encodeCall(nft.clearRecords, (target)));
        } else if (action == 6) {
            _call(holder, abi.encodeWithSignature("transferFrom(address,address,uint256)", holder, _pick(v), target));
        } else if (action == 7) {
            vm.warp(vm.getBlockTimestamp() + v % 3);
        } else if (action == 8) {
            // the holder of the parent mints the subpage again for someone
            _call(nft.ownerOf(shop), abi.encodeCall(nft.registerSubpageFor, ("s", shop, _pick(v))));
        } else if (action == 9) {
            // the holder of the subpage deletes it
            address h = nft.ownerOf(sub);
            _call(h, abi.encodeWithSignature("transferFrom(address,address,uint256)", h, DEAD, sub));
        } else if (action == 10) {
            // a save, then a move, in one transaction
            bytes[] memory calls = new bytes[](2);
            calls[0] = abi.encodeCall(nft.setAddrForCoin, (target, COIN_60, abi.encodePacked(_val(v))));
            calls[1] = abi.encodeWithSignature("transferFrom(address,address,uint256)", holder, _pick(v >> 4), target);
            _call(holder, abi.encodeCall(nft.multicall, (calls)));
        } else if (action == 11) {
            bytes[] memory calls = new bytes[](3);
            calls[0] = abi.encodeCall(nft.setData, (target, "k", abi.encodePacked(v)));
            calls[1] = abi.encodeWithSignature("setText(uint256,string,string)", target, "url", "x");
            calls[2] = abi.encodeCall(nft.keepProfile, (target));
            _call(holder, abi.encodeCall(nft.multicall, (calls)));
        } else if (action == 12) {
            // into the grace period, then a renewal brings it back
            vm.warp(nft.expiresAt(shop) + 1 + v % 1000);
            _check(shop, shopSeen);
            _check(sub, subSeen);
            vm.prank(stranger);
            (bool ok,) = address(nft).call{value: nft.getFee(4)}(abi.encodeCall(nft.renew, (shop)));
            assertTrue(ok, "a renewal in the grace period");
        } else if (action == 13 && v % 4 == 0) {
            // the top level page lapses and is registered again
            _lapseAndRegister(shop, _pick(v >> 2));
        } else if (action == 14) {
            // the minter mints the subpage again, also when the dead address holds it or it is stale
            _call(nft.ownerOf(shop), abi.encodeCall(nft.setSubpageMinter, (shop, stranger)));
            _call(stranger, abi.encodeCall(nft.registerSubpageFor, ("s", shop, _pick(v))));
        } else {
            // the page goes to someone and comes back
            address other = _pick(v);
            _call(holder, abi.encodeWithSignature("transferFrom(address,address,uint256)", holder, other, target));
            _call(other, abi.encodeWithSignature("transferFrom(address,address,uint256)", other, holder, target));
        }
    }

    function testFuzz_answersNeverChangeWithoutAWarning(uint256 seed) public {
        _check(shop, shopSeen);
        _check(sub, subSeen);
        for (uint256 i; i < 40; ++i) {
            _step(uint256(keccak256(abi.encode(seed, i))));
            _check(shop, shopSeen);
            _check(sub, subSeen);
        }
    }

    // the same walk with a sharper check: a change of answers at time t always leaves one of the two values at t
    function testFuzz_aChangeStampsItsSecond(uint256 seed) public {
        bytes32 shopA = _answers(shop);
        bytes32 subA = _answers(sub);
        bool shopOn = true;
        bool subOn = true;
        for (uint256 i; i < 40; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            // jumps in time are left to the walk above
            if (r % 16 == 12 || r % 16 == 13) continue;
            _step(r);
            (shopA, shopOn) = _sharp(shop, shopA, shopOn);
            (subA, subOn) = _sharp(sub, subA, subOn);
        }
    }

    function _sharp(uint256 id, bytes32 before, bool wasOn) internal view returns (bytes32, bool) {
        if (!_active(id)) return (before, wasOn);
        bytes32 a = _answers(id);
        if (wasOn && a != before) {
            uint256 t = vm.getBlockTimestamp();
            bool stamped = nft.holderSince(id) == t || nft.addressesUpdatedAt(id) == t;
            assertTrue(stamped, "a change not stamped with its second");
        }
        return (a, true);
    }
}

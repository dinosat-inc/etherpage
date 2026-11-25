// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {EdgesBase} from "./EdgesBase.sol";

// For a top level name, resolveAs(id, account) answers what resolve would answer if account held the name: the
// main address account saved while it held the name, else account itself, and zero while the name is not
// active. Whether it is active is judged with its current holder, so once the dead address holds the name it
// answers zero for every account. Checked on a top level name for any account, and for an account that then takes
// the name, against resolve.
contract ResolveAsFuzzTest is EdgesBase {
    uint256 id;

    function setUp() public override {
        super.setUp();
        id = _buy(alice, "alpha", alice, 0);
        vm.prank(alice);
        nft.setAddr(id, hot);
    }

    function testFuzz_resolveAsAnswersForAnyAccount(address x) public {
        address want = x == alice ? hot : x;
        assertEq(nft.resolveAs(id, x), want, "the saver's choice for alice, the account itself for anyone else");
        assertEq(nft.resolveAs(id, alice), hot);
        assertEq(nft.resolve(id), hot);

        // once x holds the name, resolve agrees with what resolveAs said for it
        if (x != alice && x != address(0) && x != address(nft) && x != DEAD && x.code.length == 0) {
            vm.prank(alice);
            nft.transferFrom(alice, x, id);
            assertEq(nft.resolve(id), nft.resolveAs(id, x), "resolve is resolveAs of the holder");
            assertEq(nft.resolve(id), x);
            assertEq(nft.resolveAs(id, alice), hot, "alice's choice is kept for her");
        }
        // the dead address deletes the name it takes, so nothing answers for anyone
        if (x == DEAD) {
            vm.prank(alice);
            nft.transferFrom(alice, DEAD, id);
            assertEq(nft.resolve(id), address(0), "a name the dead address holds resolves to nothing");
            assertEq(nft.resolveAs(id, DEAD), address(0), "nor for the dead address");
            assertEq(nft.resolveAs(id, alice), address(0), "nor for alice");
        }

        // nothing answers once the name is past its expiry
        vm.warp(nft.expiresAt(id) + 1);
        assertEq(nft.resolveAs(id, x), address(0));
        assertEq(nft.resolveAs(id, alice), address(0));
    }

    // the dead address as the account, on every run
    function test_resolveAsWhenTheDeadAddressTakesTheName() public {
        testFuzz_resolveAsAnswersForAnyAccount(DEAD);
    }

    // an id with no record answers zero for any account
    function testFuzz_resolveAsOfAnIdWithNoRecordIsZero(uint256 other, address x) public view {
        (string memory stored,,,,) = nft.records(other);
        vm.assume(bytes(stored).length == 0);
        assertEq(nft.resolveAs(other, x), address(0));
    }
}

// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {PageCard} from "../../../src/PageCard.sol";

// render is deterministic: the same five arguments give identical bytes in any block and any transaction, from any
// deployment of the card and with any amount of gas the call is given.
contract RenderDeterminismTest is Test {
    PageCard card;

    struct Args {
        string label;
        string parent;
        bytes32 id;
        uint8 status;
        uint256 expiry;
    }

    // the most extra gas the fuzz gives a second call over what the first one used
    uint256 constant EXTRA_GAS = 1_000_000;

    function setUp() public {
        card = new PageCard();
    }

    // every status, a cut name, bytes that draw the box, multibyte text, an empty label under a parent, the largest
    // expiries and the widest card of all, which costs the most; only the first and the last draw a date
    function _cases() internal pure returns (Args[7] memory c) {
        c[0] = Args("alice", "", bytes32(uint256(1)), 0, 1821312000);
        c[1] = Args("bob", "alice", keccak256("bob"), 1, 0);
        c[2] = Args("abcdefghijklmnopqrstuvwxyz", "", keccak256("x"), 2, type(uint256).max);
        c[3] = Args("a<b>&\"'", "c'd", bytes32(type(uint256).max), 3, 0);
        c[4] = Args(unicode"日本語のなまえです", unicode"🚀🚀🚀🚀🚀", bytes32(0), 4, type(uint64).max);
        c[5] = Args("", "web3-dao", bytes32(uint256(0x8f3a1c) << 232), 0, 253402300800);
        c[6] = Args(
            "888888888888888888",
            "",
            0x8888888888888888888888888888888888888888888888888888888888888888,
            0,
            106943003999999999999999999999999999999999999999999999999999999999937828201600
        );
    }

    function _draw(PageCard target, Args memory a) internal view returns (string memory) {
        return target.render(a.label, a.parent, a.id, PageCard.Status(a.status), a.expiry);
    }

    function _drawAll(PageCard target) internal view returns (string[7] memory out) {
        Args[7] memory c = _cases();
        for (uint256 i; i < 7; ++i) out[i] = _draw(target, c[i]);
    }

    // another block number, clock, chain id, coinbase, base fee, randomness and gas price, and another sender and
    // origin for each call
    function test_sameBytesInAnyBlockAndTransaction() public {
        string[7] memory first = _drawAll(card);
        Args[7] memory c = _cases();
        vm.roll(vm.getBlockNumber() + 1_000_000);
        vm.warp(vm.getBlockTimestamp() + 400 days);
        vm.chainId(10);
        vm.coinbase(address(0xc0ffee));
        vm.fee(123 gwei);
        vm.prevrandao(bytes32(uint256(42)));
        vm.txGasPrice(7 gwei);
        for (uint256 i; i < 7; ++i) {
            vm.prank(address(uint160(0x1000 + i)), address(uint160(0x2000 + i)));
            string memory again = _draw(card, c[i]);
            assertEq(again, first[i], "same bytes in another context");
        }
    }

    // a second card at another address draws the same bytes
    function test_sameBytesFromAnotherDeployment() public {
        PageCard other = new PageCard();
        string[7] memory a = _drawAll(card);
        string[7] memory b = _drawAll(other);
        for (uint256 i; i < 7; ++i) assertEq(b[i], a[i], "same bytes from another deployment");
    }

    // the gas a call is given changes nothing, down to a difference of one unit. Each case is measured rather than
    // given a fixed amount, as a card costs about half a million gas to a million and the widest card of all about
    // 4.5 million, more without the optimizer: one unit less than it uses runs out, and from exactly what it uses up
    // to a block's worth the bytes are the same.
    function test_sameBytesWithAnyGas() public view {
        Args[7] memory c = _cases();
        for (uint256 i; i < 7; ++i) {
            string memory first = _draw(card, c[i]);
            uint256 need = vm.lastCallGas().gasTotalUsed;
            try card.render{gas: need - 1}(c[i].label, c[i].parent, c[i].id, PageCard.Status(c[i].status), c[i].expiry)
            returns (string memory) {
                assertTrue(false, "one unit less is not enough");
            } catch {}
            uint256[7] memory gas = [need, need + 1, need + 2, need + 3, need + 5, 3 * need + 7, 30_000_000];
            for (uint256 k; k < gas.length; ++k) {
                string memory again = card.render{gas: gas[k]}(
                    c[i].label, c[i].parent, c[i].id, PageCard.Status(c[i].status), c[i].expiry
                );
                assertEq(again, first, "same bytes with any gas");
            }
        }
    }

    function testFuzz_sameBytesInAnyContext(
        string memory label,
        string memory parent,
        bytes32 id,
        uint8 status,
        uint256 expiry,
        uint64 blocks,
        uint64 secs,
        uint64 chain,
        bytes32 rand,
        address caller,
        uint256 extraGas
    ) public {
        PageCard.Status st = PageCard.Status(status % 5);
        string memory first = card.render(label, parent, id, st, expiry);
        // the second call gets what the first used and a varying amount more
        uint256 g = vm.lastCallGas().gasTotalUsed + 1000 + extraGas % EXTRA_GAS;
        vm.roll(vm.getBlockNumber() + 1 + blocks);
        vm.warp(vm.getBlockTimestamp() + 1 + secs);
        vm.chainId(1 + uint256(chain) % 1_000_000_000);
        vm.prevrandao(rand);
        vm.coinbase(caller);
        vm.prank(caller, caller);
        string memory again = card.render{gas: g}(label, parent, id, st, expiry);
        assertEq(again, first, "same bytes in any context");
    }
}

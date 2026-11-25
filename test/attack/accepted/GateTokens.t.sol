// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {SubpageRegistrar} from "../../../src/SubpageRegistrar.sol";
import {AcceptedBase} from "./AcceptedBase.sol";

// burns the gas it is given down to a small reserve, then answers a balance that passes any gate
contract BurnThenAnswerGate {
    function balanceOf(address) external view returns (uint256) {
        assembly ("memory-safe") {
            for {} gt(gas(), 30000) {} { mstore(0, keccak256(0, 32)) }
        }
        return type(uint96).max;
    }
}

// The registrar asks a gate token for the buyer's balance with all the gas it has, of which the EVM passes on all
// but a sixty fourth, and reads the first word of any answer of at least a word. A gate whose balanceOf burns gas
// therefore spends most of the buyer's gas limit and sells only under a huge one, since the rest of the sale must
// fit in the sixty fourth kept back and whatever gas the gate leaves. A precompile that answers a word reads as a
// huge balance and lets every buyer through, while one that answers nothing, like an address with no code, blocks
// everyone. The parent's holder chooses the gate.
contract AcceptedGateTokensTest is AcceptedBase {
    address buyer = makeAddr("buyer");
    uint256 club;

    function setUp() public override {
        super.setUp();
        club = _buy(alice, "club", alice, 0);
        vm.prank(alice);
        nft.setSubpageMinter(club, address(reg));
    }

    // free sales behind the gate token with the given minimum balance
    function _gate(address token, uint256 minBalance) internal {
        vm.prank(alice);
        reg.configure(club, payout, address(0), 0, true, token, minBalance, false);
    }

    // gas limits of 1M and 5M fail and 16M sells, and every attempt spends more than nine tenths of its limit
    function test_gasBurningGateSpendsMostOfTheBuyersGasLimit() public {
        _gate(address(new BurnThenAnswerGate()), 1);
        uint256[3] memory limits = [uint256(1_000_000), 5_000_000, 16_000_000];
        string[3] memory labels = ["a1", "a2", "a3"];
        for (uint256 i; i < 3; ++i) {
            bytes memory data = abi.encodeCall(SubpageRegistrar.registerSubpage, (club, labels[i], 0, address(0)));
            uint256 g = gasleft();
            vm.prank(buyer);
            (bool ok,) = address(reg).call{gas: limits[i]}(data);
            uint256 used = g - gasleft();
            emit log_named_uint("gas limit", limits[i]);
            emit log_named_uint("gas used", used);
            assertEq(ok, i == 2, "only the largest limit sells");
            assertGt(used, limits[i] * 9 / 10, "most of the limit is spent");
            assertEq(nft.isAvailable(labels[i], club), i != 2);
        }
    }

    // The same gate with the outcome alone: 16M still sells, now that a mint also stores holderSince, and 5M does
    // not. Unlike the gas spent, which the test above checks, the outcome does not depend on how the runner meters
    // the call.
    function test_gasBurningGateStillSellsUnderTheLargestLimit() public {
        _gate(address(new BurnThenAnswerGate()), 1);
        bytes memory data = abi.encodeCall(SubpageRegistrar.registerSubpage, (club, "a3", 0, address(0)));
        vm.prank(buyer);
        (bool ok,) = address(reg).call{gas: 16_000_000}(data);
        assertTrue(ok, "16M sells");
        assertEq(nft.ownerOf(nft.computeId("a3.club")), buyer);
        data = abi.encodeCall(SubpageRegistrar.registerSubpage, (club, "a2", 0, address(0)));
        vm.prank(buyer);
        (ok,) = address(reg).call{gas: 5_000_000}(data);
        assertFalse(ok, "5M does not");
        assertTrue(nft.isAvailable("a2", club));
    }

    // sha256 and ripemd160 answer a hash word and identity echoes the call, so each passes the highest minimum
    function test_precompileGatesPassEveryBuyer() public {
        address[3] memory gates = [address(2), address(3), address(4)];
        address[2] memory buyers = [buyer, address(0x1234567890123456789012345678901234567890)];
        for (uint256 i; i < 3; ++i) {
            _gate(gates[i], type(uint96).max);
            for (uint256 j; j < 2; ++j) {
                string memory label = string.concat("g", vm.toString(i), "b", vm.toString(j));
                vm.prank(buyers[j]);
                uint256 id = reg.registerSubpage(club, label, 0, address(0));
                assertEq(nft.ownerOf(id), buyers[j]);
            }
        }
    }

    // the same for any buyer with no code, outside the precompile range
    function testFuzz_precompileGatesPassAnyBuyer(address who) public {
        vm.assume(who.code.length == 0 && uint160(who) > 0xffff && who != DEAD && who != address(vm));
        address[3] memory gates = [address(2), address(3), address(4)];
        for (uint256 i; i < 3; ++i) {
            _gate(gates[i], type(uint96).max);
            string memory label = string.concat("g", vm.toString(i));
            vm.prank(who);
            uint256 id = reg.registerSubpage(club, label, 0, address(0));
            assertEq(nft.ownerOf(id), who);
        }
    }

    // ecrecover answers nothing for this input, and neither does an address with no code
    function test_emptyAnswerGatesBlockEveryBuyer() public {
        address[2] memory gates = [address(1), makeAddr("nocode")];
        for (uint256 i; i < 2; ++i) {
            _gate(gates[i], 1);
            vm.prank(buyer);
            vm.expectRevert(SubpageRegistrar.GateFailed.selector);
            reg.registerSubpage(club, "blocked", 0, address(0));
        }
    }

    // as a fee token the identity precompile is refused, since it has no code and its answer is not true
    function test_identityPrecompileAsFeeTokenReverts() public {
        vm.prank(alice);
        reg.configure(club, payout, address(4), 1 ether, true, address(0), 0, false);
        vm.prank(buyer);
        vm.expectRevert(SubpageRegistrar.TransferFromFailed.selector);
        reg.registerSubpage(club, "paid", 1 ether, address(4));
        assertTrue(nft.isAvailable("paid", club));
    }
}

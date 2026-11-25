// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {SubpageRegistrar} from "../../src/SubpageRegistrar.sol";
import {MinterBase} from "../utils/MinterBase.sol";
import {RevertGate, WriteGate} from "../utils/TokenMocks.sol";

// how much gas a refused gate costs a buyer who sends a 1,000,000 gas limit
contract RegistrarGateGasTest is MinterBase {
    function test_gateGasCost() public {
        uint256 club = _reg(alice, "club");
        _setMinter(club, address(reg));
        address[2] memory gates = [address(new RevertGate()), address(new WriteGate())];
        for (uint256 i; i < 2; ++i) {
            vm.prank(alice);
            reg.configure(club, payout, address(0), 0, true, gates[i], 1, false);
            uint256 g0 = gasleft();
            vm.prank(buyer);
            (bool ok, bytes memory r) =
                address(reg).call{gas: 1_000_000}(abi.encodeCall(reg.registerSubpage, (club, "a", 0, address(0))));
            uint256 used = g0 - gasleft();
            assertFalse(ok);
            assertEq(bytes4(r), SubpageRegistrar.GateFailed.selector);
            emit log_named_uint(i == 0 ? "reverting gate, gas used" : "state-writing gate, gas used", used);
        }
    }
}

// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Test, console2} from "forge-std/Test.sol";
import {PageCard} from "../../../src/PageCard.sol";

contract StatusEnumTest is Test {
    function test_statusOutOfRange() public {
        PageCard card = new PageCard();
        bytes memory data =
            abi.encodeWithSelector(PageCard.render.selector, "a", "", bytes32(0), uint256(5), uint256(0));
        (bool ok, bytes memory ret) = address(card).call(data);
        assertFalse(ok);
        console2.log("revert data length", ret.length);
        console2.logBytes(ret);
    }
}

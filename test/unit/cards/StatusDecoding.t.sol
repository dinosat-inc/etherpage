// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {PageCard} from "../../../src/PageCard.sol";

// The status is a uint8 in the ABI and the enum has five members, so the decoder of render refuses every value
// from 5 up with empty revert data before the body runs. Other malformed calldata is refused there too, and a
// call that sends ETH is refused before the decoder, as render is not payable.
contract StatusDecodingTest is Test {
    PageCard card;

    function setUp() public {
        card = new PageCard();
    }

    function _data(uint256 status) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(
            PageCard.render.selector, "alice", "bob", bytes32(uint256(7)), status, uint256(0)
        );
    }

    // calls render with raw calldata and returns the gas the card itself used
    function _call(bytes memory data, uint256 value) internal returns (bool ok, bytes memory ret, uint256 used) {
        (ok, ret) = address(card).call{value: value}(data);
        used = vm.lastCallGas().gasTotalUsed;
    }

    // the gas of a call that draws the card, to show a refused call stops long before the drawing
    function _drawGas() internal returns (uint256 used) {
        bool ok;
        (ok,, used) = _call(_data(4), 0);
        assertTrue(ok, "status 4 is drawn");
    }

    // writes a 32 byte word at a byte offset of the calldata
    function _put(bytes memory data, uint256 at, uint256 word) internal pure {
        assembly {
            mstore(add(add(data, 0x20), at), word)
        }
    }

    function test_statusFiveAndUpRevertsWithEmptyData() public {
        for (uint256 s; s < 5; ++s) {
            (bool ok, bytes memory ret,) = _call(_data(s), 0);
            assertTrue(ok, "0 to 4 decode");
            assertGt(bytes(abi.decode(ret, (string))).length, 0, "and draw a card");
        }
        uint256 draw = _drawGas();
        uint256[12] memory bad = [
            uint256(5), 6, 7, 8, 15, 255, 256, 260, 1 << 128, 1 << 255, type(uint256).max - 1, type(uint256).max
        ];
        for (uint256 i; i < bad.length; ++i) {
            (bool ok, bytes memory ret, uint256 used) = _call(_data(bad[i]), 0);
            assertFalse(ok, "refused");
            assertEq(ret.length, 0, "with empty revert data");
            // the body never ran: the refusal costs a small part of the gas of a drawing
            assertLt(used * 20, draw, "refused before the body");
        }
    }

    // the head of the calldata is five words after the selector: the two string offsets, id, status and expiry. The
    // label length is the word at byte 164 and the parent length the word at byte 228.
    function test_otherMalformedCalldataIsRefusedBeforeTheBody() public {
        uint256 draw = _drawGas();
        bytes[6] memory cases;
        // the calldata cut short inside the head, before the expiry word
        bytes memory head = _data(4);
        cases[0] = new bytes(4 + 4 * 32);
        for (uint256 i; i < cases[0].length; ++i) cases[0][i] = head[i];
        // the calldata cut short right after the parent length, so none of the parent label's bytes are there
        bytes memory full = _data(4);
        cases[1] = new bytes(full.length - 32);
        for (uint256 i; i < cases[1].length; ++i) cases[1][i] = full[i];
        // a label offset past the end of the calldata
        cases[2] = _data(4);
        _put(cases[2], 4, 0x1000);
        // a label offset that needs 65 bits
        cases[3] = _data(4);
        _put(cases[3], 4, 1 << 64);
        // a label length past the end of the calldata
        cases[4] = _data(4);
        _put(cases[4], 4 + 160, 1000);
        // a label length that needs 65 bits, which the decoder cannot allocate
        cases[5] = _data(4);
        _put(cases[5], 4 + 160, 1 << 64);
        for (uint256 i; i < 6; ++i) {
            (bool ok, bytes memory ret, uint256 used) = _call(cases[i], 0);
            assertFalse(ok, "refused");
            assertLt(used * 20, draw, "refused before the body");
            if (i < 5) {
                assertEq(ret.length, 0, "with empty revert data");
            } else {
                assertEq(ret, abi.encodeWithSignature("Panic(uint256)", 0x41), "an allocation panic");
            }
        }
    }

    // render is not payable: a call that sends ETH is refused with empty data, whatever the arguments
    function test_callWithValueIsRefused() public {
        vm.deal(address(this), 1 ether);
        uint256 draw = _drawGas();
        (bool ok, bytes memory ret, uint256 used) = _call(_data(4), 1);
        assertFalse(ok, "refused");
        assertEq(ret.length, 0, "with empty revert data");
        assertLt(used * 20, draw, "refused before the body");
        assertEq(address(card).balance, 0, "the card holds no ETH");
    }
}

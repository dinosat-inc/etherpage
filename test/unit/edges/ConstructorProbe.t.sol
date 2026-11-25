// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {PageNFT} from "../../../src/PageNFT.sol";
import {PageCard} from "../../../src/PageCard.sol";

// a renderer whose render reverts with the bytes it was given
contract RevertingCard {
    bytes data;

    constructor(bytes memory d) {
        data = d;
    }

    function render(string memory, string memory, bytes32, PageCard.Status, uint256)
        external
        view
        returns (string memory)
    {
        bytes memory d = data;
        assembly ("memory-safe") {
            revert(add(d, 0x20), mload(d))
        }
    }
}

// a renderer whose render divides by zero
contract PanicCard {
    uint256 zero;

    function render(string memory label, string memory, bytes32, PageCard.Status, uint256)
        external
        view
        returns (string memory)
    {
        return string(new bytes(bytes(label).length / zero));
    }
}

// a contract that answers every call with the raw bytes it was given
contract RawAnswerCard {
    bytes answer;

    constructor(bytes memory a) {
        answer = a;
    }

    fallback() external {
        bytes memory a = answer;
        assembly ("memory-safe") {
            return(add(a, 0x20), mload(a))
        }
    }
}

// The constructor probe: a probe that reverts, or whose answer cannot be decoded as a string, as with an
// address that has no code, fails the deployment with that failure and not with InvalidRenderer. The zero
// address and the 99 and 100 byte cards are in PageNFTCoverageTest, each in a test of its own.
contract ConstructorProbeTest is Test {
    error CardBroken(uint256 code);

    bytes constant INVALID_RENDERER = abi.encodeWithSelector(PageNFT.InvalidRenderer.selector);

    // deploys a PageNFT bound to c and returns the outcome and the revert data
    function _deploy(address c) internal returns (bool ok, bytes memory reason, address deployed) {
        try new PageNFT(PageCard(c)) returns (PageNFT n) {
            return (true, "", address(n));
        } catch (bytes memory r) {
            return (false, r, address(0));
        }
    }

    function _assertFailsWith(address c, bytes memory want, string memory what) internal {
        (bool ok, bytes memory reason,) = _deploy(c);
        assertFalse(ok, string.concat(what, ": the deployment fails"));
        assertEq(reason, want, string.concat(what, ": with the probe's own failure"));
        assertTrue(keccak256(reason) != keccak256(INVALID_RENDERER), string.concat(what, ": not InvalidRenderer"));
    }

    // an account with no code answers the call with no data, and decoding no data as a string reverts
    // with empty revert data: an account with a balance and a nonce, and one nobody ever touched
    function test_probeOfAnAccountWithNoCodeFailsTheDeployment() public {
        address eoa = makeAddr("eoa");
        vm.deal(eoa, 1 ether);
        vm.setNonce(eoa, 7);
        address empty = address(uint160(uint256(keccak256("an address nobody touched"))));
        assertEq(eoa.code.length, 0);
        assertEq(empty.code.length, 0);
        assertEq(empty.balance, 0);
        assertEq(vm.getNonce(empty), 0);
        _assertFailsWith(eoa, "", "account with a balance and a nonce");
        _assertFailsWith(empty, "", "empty account");
    }

    function testFuzz_probeOfAnyAddressWithNoCodeFailsTheDeployment(address a) public {
        // no code, and not zero, a precompile or an address forge answers itself
        assumeUnusedAddress(a);
        _assertFailsWith(a, "", "address with no code");
    }

    function deployFor(address c) external returns (address) {
        return address(new PageNFT(PageCard(c)));
    }

    // every precompile of the test chain has no code as well, and none of them answers the probe with
    // a string, so each one fails the deployment. A failing precompile burns the gas it was given, so each
    // deployment runs in a call with its own gas
    function test_probeOfAPrecompileFailsTheDeployment() public {
        for (uint160 i = 1; i <= 0x11; ++i) {
            address a = address(i);
            assertEq(a.code.length, 0);
            try this.deployFor{gas: 50_000_000}(a) returns (address) {
                fail("a precompile was accepted as the card");
            } catch (bytes memory reason) {
                assertEq(reason.length, 0, "a failed call or a failed decoding, not InvalidRenderer");
            }
        }
    }

    // a render that reverts fails the deployment with exactly its own revert data
    function test_probeThatRevertsFailsTheDeploymentWithItsOwnRevert() public {
        bytes[4] memory payloads = [
            abi.encodeWithSelector(CardBroken.selector, 7),
            abi.encodeWithSignature("Error(string)", "the card is down"),
            bytes(""),
            abi.encodePacked(bytes4(0xdeadbeef), new bytes(300))
        ];
        for (uint256 i; i < payloads.length; ++i) {
            _assertFailsWith(address(new RevertingCard(payloads[i])), payloads[i], "reverting card");
        }
        _assertFailsWith(address(new PanicCard()), abi.encodeWithSignature("Panic(uint256)", 0x12), "panic");
    }

    // an answer that is not an ABI encoded string fails the deployment in the decoder
    function test_probeAnswerThatCannotBeDecodedFailsTheDeployment() public {
        // code that answers nothing
        _assertFailsWith(address(new RawAnswerCard("")), "", "no answer");
        // less than one word
        _assertFailsWith(address(new RawAnswerCard(new bytes(31))), "", "31 bytes");
        // an offset past the end
        _assertFailsWith(address(new RawAnswerCard(abi.encode(uint256(0x40)))), "", "offset past the end");
        // an offset too large for 64 bits
        _assertFailsWith(address(new RawAnswerCard(abi.encode(uint256(1) << 64))), "", "offset too large for 64 bits");
        // a length longer than the bytes that follow it
        _assertFailsWith(
            address(new RawAnswerCard(abi.encode(uint256(0x20), uint256(1000), bytes32("short")))), "", "long length"
        );
        // a length no memory can hold, which the decoder refuses with Panic 0x41
        _assertFailsWith(
            address(new RawAnswerCard(abi.encode(uint256(0x20), type(uint256).max))),
            abi.encodeWithSignature("Panic(uint256)", 0x41),
            "huge length"
        );
    }

    // the same raw answers decode when they are well formed: a string of 100 bytes is accepted, and one
    // word of zeros decodes as the empty string, which is too short
    function test_wellFormedRawAnswersDecode() public {
        RawAnswerCard good = new RawAnswerCard(abi.encode(string(new bytes(100))));
        (bool ok,, address n) = _deploy(address(good));
        assertTrue(ok, "100 bytes deploy");
        assertEq(address(PageNFT(n).card()), address(good));

        bytes memory reason;
        (ok, reason,) = _deploy(address(new RawAnswerCard(abi.encode(string(new bytes(99))))));
        assertFalse(ok);
        assertEq(reason, INVALID_RENDERER, "99 bytes are too short");
        (ok, reason,) = _deploy(address(new RawAnswerCard(abi.encode(uint256(0)))));
        assertFalse(ok);
        assertEq(reason, INVALID_RENDERER, "one word of zeros is the empty string");
    }
}

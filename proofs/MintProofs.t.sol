// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {PageCard} from "../src/PageCard.sol";
import {PageNFT} from "../src/PageNFT.sol";
import {PageNFTHarness} from "./MinterHarness.sol";

/// @notice A contract that accepts every name and records each call of its hook.
contract AcceptingReceiver {
    uint256 public calls;
    address public lastOperator;
    address public lastFrom;
    uint256 public lastId;

    function onERC721Received(address operator, address from, uint256 id, bytes calldata) external returns (bytes4) {
        ++calls;
        lastOperator = operator;
        lastFrom = from;
        lastId = id;
        return this.onERC721Received.selector;
    }
}

/// @notice A contract with no onERC721Received and no fallback.
contract PlainContract {
    uint256 public pokes;

    function poke() external {
        ++pokes;
    }
}

/// @notice Symbolic proofs of the mint rule: a name goes straight to the caller itself or to an account
/// run by a key (no code, or the 23 byte EIP7702 designator that starts with 0xef0100); any other
/// recipient is a contract that must accept it through onERC721Received. For reveal, revealTrial and
/// registerSubpageFor, with a symbolic label and a caller that is a contract with the hook, a contract
/// without it or an account with no code, the recipient is one of six kinds: the caller itself, an
/// account with no code (symbolic for the two reveals, one of three fixed ones for the subpage), the
/// designator, a contract without the hook, a contract whose hook
/// returns the selector, and 23 bytes of code that are not a designator. The mint succeeds exactly when
/// the recipient is the caller, has no code, is the designator or is the accepting contract; the hook
/// is called exactly when the recipient is none of the caller, no code or the designator; a refused
/// mint reverts with TransferToNonERC721ReceiverImplementer, the error raised only after the hook was
/// called, and mints nothing.
/// Halmos: FOUNDRY_PROFILE=proofs halmos --contract MintProofsTest --function check_ --forge-build-out out-proofs --loop 4 --storage-layout generic
contract MintProofsTest is Test {
    PageNFTHarness n;
    AcceptingReceiver rcv;
    AcceptingReceiver rcvCaller;
    PlainContract plain;
    PlainContract plainCaller;

    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address constant KEY = address(0xCA11E2);
    address constant DESIGNATED = address(0x7702);
    address constant NOT_DESIGNATED = address(0x2323);
    bytes32 constant ROOT = 0x62460c06d95b73747abf6ea4f28aefd78b4ad2abee112e7cf15fe6a924cca3c6;
    uint256 constant T0 = 1_800_000_000;
    bytes4 constant REFUSED = 0xd1a57ed6;

    function setUp() public {
        n = new PageNFTHarness(new PageCard());
        rcv = new AcceptingReceiver();
        rcvCaller = new AcceptingReceiver();
        plain = new PlainContract();
        plainCaller = new PlainContract();
        // an EIP7702 account delegating to the accepting contract, and 23 bytes that only look alike
        vm.etch(DESIGNATED, abi.encodePacked(hex"ef0100", address(rcv)));
        vm.etch(NOT_DESIGNATED, abi.encodePacked(hex"fe0100", address(rcv)));
    }

    // a caller with the hook, one without it, or an account with no code
    function _caller(uint8 k) internal view returns (address) {
        uint8 m = k % 3;
        if (m == 0) return address(rcvCaller);
        if (m == 1) return address(plainCaller);
        return KEY;
    }

    function _to(uint8 k, address caller, address keyless) internal view returns (address) {
        if (k == 0) return caller;
        if (k == 1) return keyless;
        if (k == 2) return DESIGNATED;
        if (k == 3) return address(plain);
        if (k == 4) return address(rcv);
        return NOT_DESIGNATED;
    }

    // three symbolic characters from a to z and 0 to 9, so every such label is valid
    function _label(bytes3 raw) internal pure returns (string memory) {
        for (uint256 i; i < 3; ++i) {
            uint8 c = uint8(raw[i]);
            vm.assume((c >= 0x61 && c <= 0x7a) || (c >= 0x30 && c <= 0x39));
        }
        return string(abi.encodePacked(raw));
    }

    function _keyless(address a, address caller) internal view {
        vm.assume(a != address(0) && a != address(n) && a != caller && a.code.length == 0);
    }

    function _check(
        bool ok, bytes memory ret, uint8 k, uint256 id, address to, address caller, uint256 callsBefore,
        uint256 callerCallsBefore
    ) internal view {
        bool accepted = k != 3 && k != 5;
        bool hooked = k >= 3;
        assert(ok == accepted);
        if (ok) assert(n.ownerOf(id) == to);
        else {
            assert(ret.length == 4 && bytes4(ret) == REFUSED);
            assert(n.h_ownerOf(id) == address(0));
        }
        assert(rcvCaller.calls() == callerCallsBefore);
        if (k == 4) {
            assert(rcv.calls() == callsBefore + 1);
            assert(rcv.lastOperator() == caller && rcv.lastFrom() == address(0) && rcv.lastId() == id);
        } else {
            assert(rcv.calls() == callsBefore);
        }
        // the accepting contract is asked and accepts, the plain contract and the 23 bytes are asked
        // and refuse, and the other three kinds are never asked
        if (!hooked) assert(ok);
    }

    function _reveal(bool trial, bytes3 raw, uint8 cPick, uint8 tPick, address keyless, bytes32 secret) internal {
        address caller = _caller(cPick);
        uint8 k = tPick % 6;
        if (k == 1) _keyless(keyless, caller);
        address to = _to(k, caller, keyless);
        string memory label = _label(raw);
        uint256 id = uint256(keccak256(abi.encodePacked(ROOT, keccak256(bytes(label)))));
        vm.warp(T0);
        bytes32 c = n.makeCommitment(label, to, 0, secret);
        n.commit(trial ? keccak256(abi.encode(bytes(label), to, uint256(0), secret, true)) : c);
        vm.warp(T0 + 60);
        uint256 fee = n.getFee(3);
        uint256 price = trial ? fee / 10 : fee;
        vm.deal(caller, price);
        uint256 callsBefore = rcv.calls();
        uint256 callerCallsBefore = rcvCaller.calls();
        bytes memory d = trial
            ? abi.encodeCall(PageNFT.revealTrial, (label, to, 0, secret))
            : abi.encodeCall(PageNFT.reveal, (label, to, 0, secret));
        vm.prank(caller);
        (bool ok, bytes memory ret) = address(n).call{value: price}(d);
        _check(ok, ret, k, id, to, caller, callsBefore, callerCallsBefore);
    }

    /// @notice HM1r: the mint rule for reveal.
    /// @dev Technique: symbolic label, caller kind and recipient kind. Classification: DIRECT.
    function check_HM1r_reveal(bytes3 raw, uint8 cPick, uint8 tPick, address keyless, bytes32 secret) public {
        _reveal(false, raw, cPick, tPick, keyless, secret);
    }

    /// @notice HM1t: the mint rule for revealTrial.
    /// @dev Technique: symbolic label, caller kind and recipient kind. Classification: DIRECT.
    function check_HM1t_revealTrial(bytes3 raw, uint8 cPick, uint8 tPick, address keyless, bytes32 secret) public {
        _reveal(true, raw, cPick, tPick, keyless, secret);
    }

    /// @notice HM1s: the mint rule for registerSubpageFor by the holder of a live paid parent.
    /// @dev Technique: symbolic label, caller kind and recipient kind. Classification: DIRECT.
    function check_HM1s_registerSubpageFor(bytes3 raw, uint8 cPick, uint8 tPick, uint8 aPick) public {
        address caller = _caller(cPick);
        uint8 k = tPick % 6;
        // Justification: the account with no code is one of three fixed ones, DEAD included, as a symbolic
        // one makes the subpage mint use a symbolic memory offset that Halmos cannot follow (as in MP2)
        uint8 a = aPick % 3;
        address keyless = a == 0 ? address(0xC0FFEE) : a == 1 ? address(0xB0B) : DEAD;
        address to = _to(k, caller, keyless);
        string memory label = _label(raw);
        uint256 pid = uint256(keccak256(abi.encodePacked(ROOT, keccak256(bytes("club")))));
        uint256 id = uint256(keccak256(abi.encodePacked(bytes32(pid), keccak256(bytes(label)))));
        vm.warp(T0);
        n.h_setRecord(pid, "club", 0, uint64(T0 + 365 days), 1, 0);
        n.h_mint(caller, pid);
        uint256 callsBefore = rcv.calls();
        uint256 callerCallsBefore = rcvCaller.calls();
        vm.prank(caller);
        (bool ok, bytes memory ret) = address(n).call(abi.encodeCall(PageNFT.registerSubpageFor, (label, pid, to)));
        _check(ok, ret, k, id, to, caller, callsBefore, callerCallsBefore);
    }
}

// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Vm} from "forge-std/Test.sol";
import {PageNFT} from "../../../src/PageNFT.sol";
import {MinterBase} from "../../utils/MinterBase.sol";
import {NoHook} from "../../utils/MinterMocks.sol";

// a receiver that reads the name's answers from inside its hook, logs a marker, and can save a main
// address there, as a custody contract does for its depositor
contract ViewingReceiver {
    event Marker(uint256 indexed id, address resolved, address payee);

    PageNFT public immutable nft;
    address public saveAs;
    address public seenResolve;
    address public seenPayee;
    address public seenAsSender;
    bytes public seenOp;
    uint256 public calls;

    constructor(PageNFT n) {
        nft = n;
    }

    function arm(address a) external {
        saveAs = a;
    }

    function onERC721Received(address, address from, uint256 id, bytes calldata) external returns (bytes4) {
        require(msg.sender == address(nft), "only PageNFT");
        seenResolve = nft.resolve(id);
        seenPayee = nft.payee(id);
        seenOp = nft.addr(id, 0x8000000a);
        seenAsSender = from == address(0) ? address(0) : nft.resolveAs(id, from);
        ++calls;
        emit Marker(id, seenResolve, seenPayee);
        if (saveAs != address(0)) nft.setAddr(id, saveAs);
        return this.onERC721Received.selector;
    }
}

// The transfer hook announces the move before the receiver's hook runs, so inside that hook the name
// already answers the receiver; a custody contract is the payee of what it holds unless it saves otherwise.
contract HookViewsTest is MinterBase {
    bytes32 constant T_ADDRESS = keccak256("AddressChanged(bytes32,uint256,bytes)");
    bytes32 constant T_ADDR = keccak256("AddrChanged(bytes32,address)");
    bytes32 constant T_META = keccak256("MetadataUpdate(uint256)");
    bytes32 constant T_REGISTERED = keccak256("PageRegistered(uint256,string,address,uint256)");
    bytes32 constant T_MARKER = keccak256("Marker(uint256,address,address)");

    // index of the first log from emitter with topic, or the log count when there is none
    function _find(Vm.Log[] memory logs, address emitter, bytes32 topic) internal pure returns (uint256 i) {
        for (; i < logs.length; ++i) if (logs[i].emitter == emitter && logs[i].topics[0] == topic) return i;
    }

    // the Transfer of the move, its announcement of the receiver as OP and main address, the receiver's coin type 60
    // answer with its AddrChanged, and for a transfer its MetadataUpdate all come before the marker; an address event
    // after the marker is a save the receiver made inside its hook, so it announces that save. Nobody here saves an
    // entry for coin type 60 or a default, so every AddrChanged carries an empty coin type 60 answer
    function _assertMoveLoggedFirst(Vm.Log[] memory logs, ViewingReceiver r, uint256 id, bool isTransfer)
        internal
        view
        returns (uint256 marker)
    {
        marker = _find(logs, address(r), T_MARKER);
        assertLt(marker, logs.length, "the receiver logged its marker");
        bool transferSeen;
        bool opSeen;
        bool ethSeen;
        bool metaSeen;
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory l = logs[i];
            if (l.emitter != address(nft)) continue;
            bytes32 t = l.topics[0];
            if (t == T_TRANSFER && uint256(l.topics[3]) == id && i < marker) transferSeen = true;
            if (t == T_META && i < marker) metaSeen = true;
            if (l.topics.length < 2 || l.topics[1] != bytes32(id)) continue;
            if (t == T_ADDR) {
                assertEq(abi.decode(l.data, (address)), address(0), "AddrChanged carries the coin type 60 answer");
                if (i < marker) ethSeen = true;
                else assertTrue(r.saveAs() != address(0), "no address event after the hook unless the receiver saved");
            } else if (t == T_ADDRESS) {
                (uint256 coin, bytes memory v) = abi.decode(l.data, (uint256, bytes));
                if (i < marker) {
                    if (coin == COIN_OP) opSeen = opSeen || keccak256(v) == keccak256(abi.encodePacked(address(r)));
                } else {
                    assertTrue(r.saveAs() != address(0), "no address event after the hook unless the receiver saved");
                    if (coin == COIN_OP) {
                        assertEq(v, abi.encodePacked(r.saveAs()), "after the hook only its own save is announced");
                    }
                }
            }
        }
        assertTrue(transferSeen, "Transfer before the hook");
        assertTrue(opSeen, "the OP answer of the receiver before the hook");
        assertTrue(ethSeen, "the coin type 60 answer of the receiver before the hook");
        if (isTransfer) assertTrue(metaSeen, "MetadataUpdate of the transfer before the hook");
    }

    // a safe mint, both safeTransferFrom forms and a safe transfer into a custody contract that then saves:
    // inside each hook resolve and payee are already the receiver, as is the OP answer in the first three,
    // and the logs of the move come before the receiver's marker; a mint logs PageRegistered after the hook
    function test_afterHookRunsBeforeReceiver() public {
        ViewingReceiver r = new ViewingReceiver(nft);
        string memory l = "hooked";
        bytes32 secret = keccak256("hooked");
        bytes32 c = nft.makeCommitment(l, address(r), 0, secret);
        vm.prank(bob);
        nft.commit(c);
        vm.warp(vm.getBlockTimestamp() + 61);
        (,,, uint256 total) = nft.quote(l);
        vm.recordLogs();
        vm.prank(bob);
        uint256 id = nft.reveal{value: total}(l, address(r), 0, secret);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(r.calls(), 1);
        assertEq(r.seenResolve(), address(r), "the mint already answers the receiver");
        assertEq(r.seenPayee(), address(r));
        assertEq(r.seenOp(), abi.encodePacked(address(r)));
        uint256 marker = _assertMoveLoggedFirst(logs, r, id, false);
        assertGt(_find(logs, address(nft), T_REGISTERED), marker, "PageRegistered after the hook");

        // both safeTransferFrom forms, the first from a holder that saved a main address and the second
        // from the first receiver, which saved none
        uint256 a = _reg(alice, "alicename");
        vm.prank(alice);
        nft.setAddr(a, hot);
        for (uint256 form; form < 2; ++form) {
            ViewingReceiver to = new ViewingReceiver(nft);
            address from = nft.ownerOf(a);
            vm.recordLogs();
            vm.prank(from);
            if (form == 0) nft.safeTransferFrom(from, address(to), a);
            else nft.safeTransferFrom(from, address(to), a, "data");
            logs = vm.getRecordedLogs();
            assertEq(to.seenResolve(), address(to), "the sender's save does not count inside the hook");
            assertEq(to.seenPayee(), address(to));
            assertEq(to.seenOp(), abi.encodePacked(address(to)));
            _assertMoveLoggedFirst(logs, to, a, true);
        }

        // a custody contract that saves dave as the main address inside the hook
        ViewingReceiver custody = new ViewingReceiver(nft);
        custody.arm(dave);
        address holder = nft.ownerOf(a);
        vm.recordLogs();
        vm.prank(holder);
        nft.safeTransferFrom(holder, address(custody), a);
        logs = vm.getRecordedLogs();
        assertEq(custody.seenResolve(), address(custody));
        assertEq(custody.seenPayee(), address(custody));
        _assertMoveLoggedFirst(logs, custody, a, true);
        assertEq(nft.resolve(a), dave, "the save inside the hook counts");
        assertEq(nft.payee(a), dave);
    }

    // a plain transfer into a contract that saves nothing makes it the main address and the payee although
    // the sender had saved another; a safe transfer into a custody contract shows the sender's choice through
    // resolveAs inside the hook, and the custody contract's own save there counts
    function test_custodyContractIsPayee() public {
        uint256 id = _reg(alice, "custodied");
        vm.prank(alice);
        nft.setAddr(id, hot);
        assertEq(nft.payee(id), hot);
        NoHook vault = new NoHook();
        vm.prank(alice);
        nft.transferFrom(alice, address(vault), id);
        assertEq(nft.resolve(id), address(vault), "resolve is the vault");
        assertEq(nft.payee(id), address(vault), "payee is the vault");
        assertEq(nft.addr(id, COIN_OP), abi.encodePacked(address(vault)));
        assertEq(nft.resolveAs(id, alice), hot, "alice's save would count again for alice");

        uint256 id2 = _reg(alice, "custodied2");
        vm.prank(alice);
        nft.setAddr(id2, hot);
        ViewingReceiver custody = new ViewingReceiver(nft);
        custody.arm(hot2);
        vm.prank(alice);
        nft.safeTransferFrom(alice, address(custody), id2);
        assertEq(custody.seenAsSender(), hot, "resolveAs of the sender inside the hook is the sender's choice");
        assertEq(custody.seenResolve(), address(custody));
        assertEq(custody.seenPayee(), address(custody));
        assertEq(nft.resolve(id2), hot2, "the custody contract's save counts");
        assertEq(nft.payee(id2), hot2);
        assertEq(nft.ownerOf(id2), address(custody));
    }
}

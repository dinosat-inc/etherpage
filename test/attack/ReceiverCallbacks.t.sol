// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Vm} from "forge-std/Test.sol";
import {PageNFT} from "../../src/PageNFT.sol";
import {SubpageRegistrar} from "../../src/SubpageRegistrar.sol";
import {MinterBase} from "../utils/MinterBase.sol";
import {LogShapes} from "../utils/LogShapes.sol";

// From inside its receiver hook it saves a main address and an entry for Base, clears, saves again, picks a minter
// for a top level name, and moves the name on; every call must work, or the hook fails as a whole.
contract CallbackReceiver {
    PageNFT immutable nft;
    address public next;
    address public minter;
    uint256 public hooks;

    constructor(PageNFT n) {
        nft = n;
    }

    function set(address nextHolder, address pick) external {
        next = nextHolder;
        minter = pick;
    }

    function _do(bytes memory d) internal {
        (bool ok, bytes memory ret) = address(nft).call(d);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }

    function onERC721Received(address, address, uint256 id, bytes calldata) external returns (bytes4) {
        ++hooks;
        _do(abi.encodeCall(PageNFT.setAddr, (id, address(0xA1))));
        _do(abi.encodeCall(PageNFT.setAddrForCoin, (id, 0x80002105, abi.encodePacked(address(0xB1)))));
        _do(abi.encodeCall(PageNFT.clearRecords, (id)));
        _do(abi.encodeCall(PageNFT.setAddr, (id, address(0xA2))));
        if (nft.parentOf(id) == 0) _do(abi.encodeCall(PageNFT.setSubpageMinter, (id, minter)));
        _do(abi.encodeWithSignature("transferFrom(address,address,uint256)", address(this), next, id));
        return this.onERC721Received.selector;
    }
}

// A receiver acts on its name from inside the hook of a mint, of a sale and of an operator's safe transfer.
// Each time the call succeeds, everything the receiver causes is logged right after the events of the move
// that reached it and, in the mint and the sale, before the registration event. PageRegistered and
// SubpageSold name the account minted to, the VersionChanged events count the record version, and the
// address events end on what the views answer.
contract ReceiverCallbacksTest is MinterBase {
    uint256 constant BASE = 0x80002105;
    address constant A1 = address(0xA1);
    address constant A2 = address(0xA2);
    address constant B1 = address(0xB1);

    // what an indexer of the address events holds for each id, and how many VersionChanged it saw
    mapping(uint256 => address) idxAddr;
    mapping(uint256 => bytes) idxOp;
    mapping(uint256 => bytes) idx60;
    mapping(uint256 => uint256) versions;

    function _index(Vm.Log[] memory logs) internal {
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory l = logs[i];
            if (l.emitter != address(nft) || l.topics.length != 2) continue;
            uint256 id = uint256(l.topics[1]);
            if (l.topics[0] == LogShapes.ADDR_CHANGED) {
                idxAddr[id] = abi.decode(l.data, (address));
            } else if (l.topics[0] == LogShapes.ADDRESS_CHANGED) {
                (uint256 c, bytes memory v) = abi.decode(l.data, (uint256, bytes));
                if (c == COIN_OP) idxOp[id] = v;
                if (c == 60) idx60[id] = v;
            } else if (l.topics[0] == LogShapes.VERSION) {
                ++versions[id];
            }
        }
    }

    function _assertIndexed(uint256 id) internal view {
        assertEq(idxAddr[id], nft.addr(bytes32(id)), "indexed AddrChanged answer, coin type 60");
        assertEq(idxOp[id], nft.addr(id, COIN_OP), "indexed OP answer, the main address");
        assertEq(idx60[id], nft.addr(id, 60), "indexed Ethereum answer");
        assertEq(versions[id], nft.recordVersion(id), "VersionChanged count");
    }

    function _assertLogs(Vm.Log[] memory got, bytes32[] memory want, uint256 skip) internal view {
        assertEq(got.length, want.length + skip, "log count");
        for (uint256 i; i < want.length; ++i) {
            assertEq(got[i].emitter, address(nft), string.concat("emitter of log ", vm.toString(i)));
            assertEq(LogShapes.hashOf(got[i]), want[i], string.concat("log ", vm.toString(i)));
        }
    }

    // the receiver's own calls on a name it got with record version 0 and epoch 1, as they log, from position from:
    // the save, the Base entry, the clear, the second save, the minter pick of a top level name, and the move to next.
    // Nobody saves an entry for coin type 60 or a default, so every announced coin type 60 answer is empty, whatever
    // the main address is
    function _receiverLogs(bytes32[] memory want, uint256 from, uint256 id, address r, address next, address pick)
        internal
        pure
        returns (uint256)
    {
        LogShapes.trio(id, A1, address(0), want, from);
        want[from + 3] = LogShapes.meta(id);
        want[from + 4] = LogShapes.coin(id, BASE, abi.encodePacked(B1));
        want[from + 5] = LogShapes.version(id, 1);
        LogShapes.trio(id, r, address(0), want, from + 6);
        want[from + 9] = LogShapes.meta(id);
        LogShapes.trio(id, A2, address(0), want, from + 10);
        want[from + 13] = LogShapes.meta(id);
        uint256 k = from + 14;
        if (pick != address(0)) {
            want[k++] = LogShapes.minterSet(id, r, pick, 1);
        }
        want[k] = LogShapes.transfer(r, next, id);
        LogShapes.trio(id, next, address(0), want, k + 1);
        want[k + 4] = LogShapes.meta(id);
        return k + 5;
    }

    function test_receiverActsInsideItsCallback() public {
        CallbackReceiver r = new CallbackReceiver(nft);

        // 1. a registration that names the receiver as owner
        r.set(carol, hot);
        bytes32 secret = keccak256("gift");
        bytes32 c = nft.makeCommitment("gift", address(r), 0, secret);
        vm.prank(bob);
        nft.commit(c);
        vm.warp(vm.getBlockTimestamp() + 61);
        uint256 fee = nft.getFee(4);
        vm.recordLogs();
        vm.prank(bob);
        uint256 id = nft.reveal{value: fee}("gift", address(r), 0, secret);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        _index(logs);
        bytes32[] memory want = new bytes32[](28);
        want[0] = LogShapes.referrerSet(id, 0);
        want[1] = LogShapes.depositAdded(id, bob, fee, fee);
        want[2] = LogShapes.transfer(address(0), address(r), id);
        LogShapes.trio(id, address(r), address(0), want, 3);
        uint256 k = _receiverLogs(want, 6, id, address(r), carol, hot);
        want[k] = LogShapes.nameRegistered(id, "gift", address(r), vm.getBlockTimestamp() + 365 days);
        want[k + 1] = LogShapes.meta(id);
        _assertLogs(logs, want, 0);
        assertEq(r.hooks(), 1);
        assertEq(nft.ownerOf(id), carol, "the receiver moved the name on");
        _assertIndexed(id);
        // the minter the receiver picked stopped counting when it moved the name on
        assertEq(nft.subpageMinterOf(id), address(0));

        // 2. a sale through the registrar to the receiver
        _sellSetup(id, 0);
        r.set(dave, address(0));
        vm.recordLogs();
        vm.prank(buyer);
        uint256 sub = reg.registerSubpageFor(id, "kid", address(r), 0, address(0));
        logs = vm.getRecordedLogs();
        _index(logs);
        want = new bytes32[](24);
        want[0] = LogShapes.transfer(address(0), address(r), sub);
        LogShapes.trio(sub, address(r), address(0), want, 1);
        k = _receiverLogs(want, 4, sub, address(r), dave, address(0));
        want[k] = LogShapes.subRegistered(sub, id, "kid");
        _assertLogs(logs, want, 1);
        Vm.Log memory sold = logs[logs.length - 1];
        assertEq(sold.emitter, address(reg));
        assertEq(sold.topics[0], SubpageRegistrar.SubpageSold.selector);
        (address soldTo,,,,) = abi.decode(sold.data, (address, address, address, uint256, string));
        assertEq(soldTo, address(r), "SubpageSold names the account minted to");
        assertEq(r.hooks(), 2);
        assertEq(nft.ownerOf(sub), dave);
        _assertIndexed(sub);
        _assertIndexed(id);

        // 3. an operator's safe transfer to the receiver
        uint256 other = _reg(alice, "other");
        vm.prank(alice);
        nft.setApprovalForAll(stranger, true);
        r.set(bob, hot2);
        vm.recordLogs();
        vm.prank(stranger);
        nft.safeTransferFrom(alice, address(r), other);
        logs = vm.getRecordedLogs();
        _index(logs);
        want = new bytes32[](25);
        want[0] = LogShapes.transfer(alice, address(r), other);
        LogShapes.trio(other, address(r), address(0), want, 1);
        want[4] = LogShapes.meta(other);
        _receiverLogs(want, 5, other, address(r), bob, hot2);
        _assertLogs(logs, want, 0);
        assertEq(r.hooks(), 3);
        assertEq(nft.ownerOf(other), bob);
        _assertIndexed(other);
        _assertIndexed(id);
        _assertIndexed(sub);
    }
}

// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {PageCard} from "../../../src/PageCard.sol";
import {PageNFT} from "../../../src/PageNFT.sol";
import {trialCommitment} from "../../utils/TrialCommitment.sol";

// takes names and writes nothing
contract QuietReceiver {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}

// The storage slots of PageNFT a transfer writes, read with vm.record and vm.accesses. A transfer writes the
// ERC721 owner slot of the token, the balance slots of its two endpoints, holderSince of the token, the token's
// approval slot when an account was approved for it, and primaryPage of the sender when it names the moved name.
// Nothing else: no record, version, saved address, address time, profile, minter pick, deposit, trial money,
// referrer or owed balance.
contract TransferWriteSetTest is Test {
    PageNFT nft;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("operator carol");
    address dave = makeAddr("approved dave");
    address hot = makeAddr("hot wallet");
    address minter = makeAddr("minter");
    address relayer = makeAddr("relayer");
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    uint256 constant ETH = 60;
    uint256 constant BTC = 0;
    uint256 constant BASE = 0x80002105;

    // PageNFT storage slots, as the storage layout gives them
    uint256 constant RECORDS = 0;
    uint256 constant VERSION = 1;
    uint256 constant PRIMARY = 3;
    uint256 constant REFERRER = 4;
    uint256 constant DEPOSIT = 5;
    uint256 constant OWED = 6;
    uint256 constant RESOLVED = 7;
    uint256 constant CONTENTHASH = 8;
    uint256 constant COIN = 9;
    uint256 constant SAVER = 11;
    uint256 constant MINTER = 12;
    uint256 constant HOLDER = 13;
    uint256 constant TRIAL = 14;
    uint256 constant PROFILE = 15;
    uint256 constant HOLDER_SINCE = 16;
    uint256 constant ADDRESSES_UPDATED_AT = 17;

    enum Path {
        Owner,
        Approved,
        Operator,
        Safe,
        SafeWithData
    }

    uint256 parent;
    uint256 other;

    function setUp() public {
        vm.warp(1_800_000_000);
        nft = new PageNFT(new PageCard());
        address[4] memory who = [alice, bob, relayer, hot];
        for (uint256 i; i < who.length; ++i) vm.deal(who[i], 100 ether);
        parent = _register("club", alice);
        other = _register("other", alice);
    }

    function _register(string memory label, address to) internal returns (uint256 id) {
        bytes32 secret = keccak256(abi.encode(label, to));
        bytes32 c = nft.makeCommitment(label, to, 0, secret);
        vm.prank(to);
        nft.commit(c);
        vm.warp(vm.getBlockTimestamp() + 61);
        (,,, uint256 total) = nft.quote(label);
        vm.prank(to);
        id = nft.reveal{value: total}(label, to, 0, secret);
    }

    function _trial(string memory label, address to) internal returns (uint256 id) {
        bytes32 secret = keccak256(abi.encode(label, to));
        bytes32 c = trialCommitment(address(nft), label, to, 0, secret);
        vm.prank(relayer);
        nft.commit(c);
        vm.warp(vm.getBlockTimestamp() + 61);
        uint256 price = nft.getFee(bytes(label).length) / 10;
        vm.prank(relayer);
        id = nft.revealTrial{value: price}(label, to, 0, secret);
    }

    // a name with every kind of record saved by its holder
    function _load(uint256 id, address holder) internal {
        vm.startPrank(holder);
        nft.setAddr(id, hot);
        nft.setAddrForCoin(id, ETH, abi.encodePacked(hot));
        nft.setAddrForCoin(id, BASE, abi.encodePacked(bob));
        nft.setAddrForCoin(id, BTC, hex"0014aabbccdd");
        nft.setText(id, "avatar", "eip155:1/erc721:0xb47e3cd837ddf8e4c57f05d70ab865de6e193bbb/5822");
        nft.setContenthash(id, hex"e301017012201234");
        vm.stopPrank();
    }

    // solady ERC721 slots
    function _ownerSlot(uint256 id) internal pure returns (bytes32 s) {
        assembly ("memory-safe") {
            mstore(0x00, id)
            mstore(0x1c, shl(192, 0x7d8825530a5a2e7a))
            s := add(id, add(id, keccak256(0x00, 0x20)))
        }
    }

    function _approvalSlot(uint256 id) internal pure returns (bytes32) {
        return bytes32(uint256(_ownerSlot(id)) + 1);
    }

    function _balanceSlot(address a) internal pure returns (bytes32 s) {
        assembly ("memory-safe") {
            mstore(0x1c, shl(192, 0x7d8825530a5a2e7a))
            mstore(0x00, a)
            s := keccak256(0x0c, 0x1c)
        }
    }

    function _operatorSlot(address owner, address operator) internal pure returns (bytes32 s) {
        assembly ("memory-safe") {
            mstore(0x1c, or(shl(192, 0x7d8825530a5a2e7a), operator))
            mstore(0x00, owner)
            s := keccak256(0x0c, 0x30)
        }
    }

    function _map(uint256 key, uint256 slot) internal pure returns (bytes32) {
        return keccak256(abi.encode(key, slot));
    }

    function _map(address key, uint256 slot) internal pure returns (bytes32) {
        return keccak256(abi.encode(key, slot));
    }

    function _nested(bytes32 outer, uint256 key) internal pure returns (bytes32) {
        return keccak256(abi.encode(key, outer));
    }

    // the slot formulas read back what the views answer
    function _checkSlots(uint256 id, address holder) internal view {
        assertEq(address(uint160(uint256(vm.load(address(nft), _ownerSlot(id))))), nft.ownerOf(id), "owner slot");
        assertEq(uint256(vm.load(address(nft), _balanceSlot(holder))) & 0xffffffff, nft.balanceOf(holder), "balance slot");
        assertEq(address(uint160(uint256(vm.load(address(nft), _approvalSlot(id))))), nft.getApproved(id), "approval slot");
        assertEq(uint256(vm.load(address(nft), _map(holder, PRIMARY))), nft.primaryPage(holder), "primaryPage slot");
        assertEq(uint256(vm.load(address(nft), _map(id, VERSION))), nft.recordVersion(id), "version slot");
        assertEq(uint256(vm.load(address(nft), _map(id, DEPOSIT))), nft.depositOf(id), "deposit slot");
        assertEq(uint256(vm.load(address(nft), _map(id, HOLDER_SINCE))), nft.holderSince(id), "holderSince slot");
    }

    // the record, profile, saved address and Ethereum entry formulas read back what the loaded name holds
    function _checkRecordSlots(uint256 id, address holder) internal view {
        uint256 v = nft.recordVersion(id);
        bytes32 rec = _map(id, RECORDS);
        assertEq(uint64(uint256(vm.load(address(nft), bytes32(uint256(rec) + 2)))), nft.expiresAt(id), "record slot");
        assertEq(address(uint160(uint256(vm.load(address(nft), _map(id, PROFILE))))), nft.profileWriter(id), "profile slot");
        assertEq(address(uint160(uint256(vm.load(address(nft), _nested(_map(id, RESOLVED), v))))), hot, "saved slot");
        assertEq(address(uint160(uint256(vm.load(address(nft), _nested(_map(id, SAVER), v))))), holder, "saver slot");
        bytes32 coin = keccak256(abi.encode(ETH, _nested(_map(id, COIN), v)));
        assertEq(address(uint160(uint256(vm.load(address(nft), coin)))), holder, "Ethereum entry slot");
        bytes32 updated = vm.load(address(nft), _map(id, ADDRESSES_UPDATED_AT));
        assertEq(uint256(updated), nft.addressesUpdatedAt(id), "address time slot");
    }

    // moves id from `from` to `to` on one path and returns the slots of PageNFT the move wrote, each once
    function _move(Path p, address from, address to, uint256 id) internal returns (bytes32[] memory) {
        address sender = from;
        if (p == Path.Approved) {
            vm.prank(from);
            nft.approve(dave, id);
            sender = dave;
        } else if (p == Path.Operator) {
            vm.prank(from);
            nft.setApprovalForAll(carol, true);
            sender = carol;
        }
        _checkSlots(id, from);
        vm.record();
        vm.prank(sender);
        if (p == Path.Safe) nft.safeTransferFrom(from, to, id);
        else if (p == Path.SafeWithData) nft.safeTransferFrom(from, to, id, "listing");
        else nft.transferFrom(from, to, id);
        (, bytes32[] memory w) = vm.accesses(address(nft));
        vm.stopRecord();
        assertEq(nft.ownerOf(id), to, "the move happened");
        assertEq(nft.holderSince(id), vm.getBlockTimestamp(), "the receiver holds it from now");
        return _unique(w);
    }

    function _unique(bytes32[] memory w) internal pure returns (bytes32[] memory out) {
        out = new bytes32[](w.length);
        uint256 n;
        for (uint256 i; i < w.length; ++i) {
            bool dup;
            for (uint256 j; j < n; ++j) if (out[j] == w[i]) dup = true;
            if (!dup) out[n++] = w[i];
        }
        assembly ("memory-safe") {
            mstore(out, n)
        }
    }

    function _has(bytes32[] memory set, bytes32 s) internal pure returns (bool) {
        for (uint256 i; i < set.length; ++i) if (set[i] == s) return true;
        return false;
    }

    // the exact write set of a move between two different accounts
    function _expected(uint256 id, address from, address to, bool approved, bool display)
        internal
        pure
        returns (bytes32[] memory s)
    {
        s = new bytes32[](6);
        uint256 n;
        s[n++] = _ownerSlot(id);
        s[n++] = _balanceSlot(from);
        s[n++] = _balanceSlot(to);
        s[n++] = _map(id, HOLDER_SINCE);
        if (approved) s[n++] = _approvalSlot(id);
        if (display) s[n++] = _map(from, PRIMARY);
        assembly ("memory-safe") {
            mstore(s, n)
        }
    }

    function _assertSet(bytes32[] memory got, bytes32[] memory want) internal pure {
        for (uint256 i; i < want.length; ++i) assertTrue(_has(got, want[i]), "an expected slot was not written");
        for (uint256 i; i < got.length; ++i) assertTrue(_has(want, got[i]), "a slot outside the expected set was written");
        assertEq(got.length, want.length, "the write set");
    }

    // the record, the version, the saved addresses and their time, the profile, the minter pick, the money and the
    // display holders of the move stay unwritten
    function _assertUntouched(bytes32[] memory got, uint256 id, address from, address to) internal view {
        uint256 v = nft.recordVersion(id);
        bytes32 rec = _map(id, RECORDS);
        bytes32 coin = keccak256(abi.encode(ETH, _nested(_map(id, COIN), v)));
        bytes32 btc = keccak256(abi.encode(BTC, _nested(_map(id, COIN), v)));
        bytes32[18] memory never = [
            rec,
            bytes32(uint256(rec) + 1),
            bytes32(uint256(rec) + 2),
            _map(id, VERSION),
            _map(id, REFERRER),
            _map(id, DEPOSIT),
            _map(id, TRIAL),
            _map(id, PROFILE),
            _map(id, MINTER),
            bytes32(uint256(_map(id, MINTER)) + 1),
            _nested(_map(id, RESOLVED), v),
            _nested(_map(id, SAVER), v),
            coin,
            btc,
            _nested(_map(id, CONTENTHASH), v),
            _map(id, ADDRESSES_UPDATED_AT),
            _map(from, OWED),
            _map(to, OWED)
        ];
        for (uint256 i; i < never.length; ++i) assertFalse(_has(got, never[i]), "a record, money or pick slot was written");
        assertFalse(_has(got, _map(to, PRIMARY)), "the receiver's display name");
        assertFalse(_has(got, _map(from, HOLDER)), "the sender's display holder");
        assertFalse(_has(got, _map(to, HOLDER)), "the receiver's display holder");
        assertFalse(_has(got, _operatorSlot(from, carol)), "the operator approval");
    }

    function _check(Path p, address from, address to, uint256 id, bool display) internal {
        bytes32[] memory w = _move(p, from, to, id);
        _assertSet(w, _expected(id, from, to, p == Path.Approved, display));
        _assertUntouched(w, id, from, to);
    }

    function test_plainTransferWritesOnlyOwnershipOnEveryPath() public {
        uint256 id = _register("loaded", alice);
        _load(id, alice);
        _checkRecordSlots(id, alice);
        address wallet = address(new QuietReceiver());
        address seven = makeAddr("7702 account");
        vm.etch(seven, abi.encodePacked(hex"ef0100", address(new QuietReceiver())));
        _check(Path.Owner, alice, bob, id, false);
        _check(Path.Approved, bob, wallet, id, false);
        vm.prank(wallet);
        nft.transferFrom(wallet, bob, id);
        _check(Path.Operator, bob, seven, id, false);
        vm.prank(seven);
        nft.transferFrom(seven, alice, id);
        _check(Path.Safe, alice, wallet, id, false);
        vm.prank(wallet);
        nft.transferFrom(wallet, alice, id);
        _check(Path.SafeWithData, alice, seven, id, false);
        // the seller's records are still stored and count again when the name returns
        vm.prank(seven);
        nft.transferFrom(seven, alice, id);
        assertEq(nft.resolve(id), hot);
        assertEq(nft.addr(id, BTC), hex"0014aabbccdd");
        assertEq(nft.text(id, "avatar"), "eip155:1/erc721:0xb47e3cd837ddf8e4c57f05d70ab865de6e193bbb/5822");
    }

    // the one write a transfer adds: the sender's display name, deleted when it names the moved name
    function test_sendersDisplayNameIsTheOneExtraWrite() public {
        uint256 id = _register("shown", alice);
        _load(id, alice);
        vm.prank(alice);
        nft.setPrimaryPage(id);
        // the main address chose it too, and the receiver, the main address of another name, chose that other name
        vm.prank(hot);
        nft.setPrimaryPage(id);
        vm.prank(alice);
        nft.setAddr(other, bob);
        vm.prank(bob);
        nft.setPrimaryPage(other);
        bytes32 holderWord = vm.load(address(nft), _map(alice, HOLDER));
        _check(Path.Owner, alice, bob, id, true);
        assertEq(nft.primaryPage(alice), 0, "deleted");
        assertEq(nft.primaryPage(hot), id, "another account's choice stays stored");
        assertEq(nft.primaryPage(bob), other, "the receiver's choice stays");
        assertEq(vm.load(address(nft), _map(alice, HOLDER)), holderWord, "the display holder stays");
        // on the approved, operator and safe with data paths too
        vm.prank(bob);
        nft.setPrimaryPage(id);
        _check(Path.Approved, bob, alice, id, true);
        vm.prank(alice);
        nft.setPrimaryPage(id);
        _check(Path.Operator, alice, bob, id, true);
        vm.prank(bob);
        nft.setPrimaryPage(id);
        _check(Path.SafeWithData, bob, alice, id, true);
        // a display name that names another name is left alone
        vm.prank(alice);
        nft.setPrimaryPage(other);
        _check(Path.Owner, alice, bob, id, false);
        assertEq(nft.primaryPage(alice), other);
    }

    function test_minterPickIsNotWritten() public {
        vm.prank(alice);
        nft.setSubpageMinter(parent, minter);
        bytes32 w0 = vm.load(address(nft), _map(parent, MINTER));
        bytes32 w1 = vm.load(address(nft), bytes32(uint256(_map(parent, MINTER)) + 1));
        _check(Path.Owner, alice, bob, parent, false);
        assertEq(nft.subpageMinterOf(parent), address(0), "paused for the new holder");
        _check(Path.Owner, bob, alice, parent, false);
        assertEq(nft.subpageMinterOf(parent), minter, "counts again for its setter, with no write");
        assertEq(vm.load(address(nft), _map(parent, MINTER)), w0);
        assertEq(vm.load(address(nft), bytes32(uint256(_map(parent, MINTER)) + 1)), w1);
    }

    function test_approvalsWriteOnlyTheTokenApproval() public {
        uint256 id = _register("approved", alice);
        // an operator that is also approved for the token: the token approval is cleared, the operator stays
        vm.startPrank(alice);
        nft.setApprovalForAll(carol, true);
        nft.approve(dave, id);
        vm.stopPrank();
        _checkSlots(id, alice);
        vm.record();
        vm.prank(carol);
        nft.transferFrom(alice, bob, id);
        (, bytes32[] memory w) = vm.accesses(address(nft));
        vm.stopRecord();
        w = _unique(w);
        _assertSet(w, _expected(id, alice, bob, true, false));
        _assertUntouched(w, id, alice, bob);
        assertEq(nft.getApproved(id), address(0));
        assertTrue(nft.isApprovedForAll(alice, carol), "the operator approval is not written");
        // the approved path and the operator path alone
        _check(Path.Approved, bob, alice, id, false);
        _check(Path.Operator, alice, bob, id, false);
    }

    function test_transferToDeadWritesNoMoreThanAnyTransfer() public {
        uint256 id = _register("burned", alice);
        _load(id, alice);
        vm.prank(alice);
        nft.setPrimaryPage(id);
        _check(Path.Owner, alice, DEAD, id, true);
        assertEq(nft.text(id, "avatar"), "", "a top level name at DEAD reads no profile");
        assertEq(nft.resolve(id), address(0), "deleted, so it resolves to nothing");
    }

    function test_subpageMoveAndDeleteWriteNoMoreThanAnyTransfer() public {
        vm.prank(alice);
        uint256 sub = nft.registerSubpageFor("shop", parent, alice);
        _load(sub, alice);
        _check(Path.Owner, alice, bob, sub, false);
        _check(Path.Approved, bob, alice, sub, false);
        // a delete: the subpage goes to DEAD and the sender's display name for it goes with it
        vm.prank(alice);
        nft.setPrimaryPage(sub);
        _check(Path.Owner, alice, DEAD, sub, true);
        assertEq(nft.resolve(sub), address(0), "deleted");
        assertEq(nft.addr(sub, BTC), "");
    }

    function test_unpaidTrialToDeadWritesNoMoreThanAnyTransfer() public {
        uint256 id = _trial("trial", alice);
        assertEq(nft.depositOf(id), 0);
        (, uint96 held) = nft.trialPaymentOf(id);
        assertGt(held, 0);
        vm.prank(alice);
        nft.setPrimaryPage(id);
        _check(Path.Owner, alice, DEAD, id, true);
        (, uint96 heldAfter) = nft.trialPaymentOf(id);
        assertEq(heldAfter, held, "the trial money stays held");
    }

    // a self transfer writes the owner slot and one balance slot with their own values, and nothing else
    function test_selfTransferWritesOnlyOwnership() public {
        uint256 id = _register("myself", alice);
        vm.prank(alice);
        nft.setPrimaryPage(id);
        bytes32 ownerWord = vm.load(address(nft), _ownerSlot(id));
        bytes32 balanceWord = vm.load(address(nft), _balanceSlot(alice));
        vm.record();
        vm.prank(alice);
        nft.transferFrom(alice, alice, id);
        (, bytes32[] memory w) = vm.accesses(address(nft));
        vm.stopRecord();
        w = _unique(w);
        assertEq(w.length, 2);
        assertTrue(_has(w, _ownerSlot(id)));
        assertTrue(_has(w, _balanceSlot(alice)));
        assertEq(vm.load(address(nft), _ownerSlot(id)), ownerWord);
        assertEq(vm.load(address(nft), _balanceSlot(alice)), balanceWord);
        assertEq(nft.primaryPage(alice), id, "a self transfer keeps the display name");
    }

    // every path, to an account with no code, a contract, a 7702 account, DEAD or the name's own main address,
    // for a top level name and a subpage, with and without the sender's display name on it
    function testFuzz_transferWriteSetIsExact(uint8 pathSeed, uint8 toSeed, bool display, bool subpage) public {
        Path p = Path(pathSeed % 5);
        uint256 id;
        if (subpage) {
            vm.prank(alice);
            id = nft.registerSubpageFor("fuzzed", parent, alice);
        } else {
            id = _register("fuzzed", alice);
        }
        _load(id, alice);
        if (display) {
            vm.prank(alice);
            nft.setPrimaryPage(id);
        }
        address seven = makeAddr("7702 receiver");
        vm.etch(seven, abi.encodePacked(hex"ef0100", address(new QuietReceiver())));
        address[5] memory receivers = [bob, address(new QuietReceiver()), seven, DEAD, hot];
        address to = receivers[toSeed % 5];
        _check(p, alice, to, id, display);
        if (display) assertEq(nft.primaryPage(alice), 0, "the sender's display name is deleted");
    }

    // a mint and a burn inside a registration write only what the registration writes, and the hook adds only
    // holderSince on the mint
    function test_mintAndBurnHooksAddOnlyHolderSince() public {
        uint256 sub = uint256(keccak256(abi.encodePacked(bytes32(parent), keccak256("held"))));
        bytes32 rec = _map(sub, RECORDS);
        vm.record();
        vm.prank(alice);
        nft.registerSubpageFor("held", parent, bob);
        (, bytes32[] memory w) = vm.accesses(address(nft));
        vm.stopRecord();
        w = _unique(w);
        bytes32[] memory want = new bytes32[](6);
        want[0] = rec;
        want[1] = bytes32(uint256(rec) + 1);
        want[2] = bytes32(uint256(rec) + 2);
        want[3] = _ownerSlot(sub);
        want[4] = _balanceSlot(bob);
        want[5] = _map(sub, HOLDER_SINCE);
        _assertSet(w, want);

        // the holder mints it again to carol over bob, who chose it as display name
        vm.prank(bob);
        nft.setPrimaryPage(sub);
        vm.record();
        vm.prank(alice);
        nft.registerSubpageFor("held", parent, carol);
        (, w) = vm.accesses(address(nft));
        vm.stopRecord();
        w = _unique(w);
        want = new bytes32[](9);
        want[0] = _map(bob, PRIMARY);
        want[1] = _ownerSlot(sub);
        want[2] = _balanceSlot(bob);
        want[3] = _map(sub, VERSION);
        want[4] = rec;
        want[5] = bytes32(uint256(rec) + 1);
        want[6] = bytes32(uint256(rec) + 2);
        want[7] = _balanceSlot(carol);
        want[8] = _map(sub, HOLDER_SINCE);
        _assertSet(w, want);
        assertEq(nft.ownerOf(sub), carol);
        assertEq(nft.recordVersion(sub), 1);
    }
}

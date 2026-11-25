// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Vm} from "forge-std/Test.sol";
import {PageNFT} from "../../src/PageNFT.sol";
import {SubpageRegistrar} from "../../src/SubpageRegistrar.sol";
import {MinterBase} from "../utils/MinterBase.sol";

// mints many labels in one transaction, the way a leaked minter key driving a script would
contract JunkMinter {
    PageNFT immutable nft;

    constructor(PageNFT n) {
        nft = n;
    }

    function flood(uint256 parentId, uint256 from, uint256 n, address[] calldata victims) external {
        for (uint256 i; i < n; ++i) {
            nft.registerSubpageFor(string.concat("j", _u(from + i)), parentId, victims[i % victims.length]);
        }
    }

    function _u(uint256 v) internal pure returns (string memory s) {
        if (v == 0) return "0";
        while (v != 0) {
            s = string.concat(string(abi.encodePacked(bytes1(uint8(48 + v % 10)))), s);
            v /= 10;
        }
    }
}

// records the operator argument a mint hands to the recipient hook
contract OperatorRecorder {
    address public lastOperator;

    function onERC721Received(address operator, address, uint256, bytes calldata) external returns (bytes4) {
        lastOperator = operator;
        return this.onERC721Received.selector;
    }
}

contract MinterStateTest is MinterBase {
    bytes32 constant T_SUB_REG = keccak256("SubpageRegistered(uint256,uint256,string)");
    bytes32 constant T_PRIMARY = keccak256("PrimaryPageSet(address,uint256)");

    function _logsHash(Vm.Log[] memory l) internal pure returns (bytes32 h) {
        for (uint256 i; i < l.length; ++i) h = keccak256(abi.encode(h, l[i].emitter, l[i].topics, l[i].data));
    }

    function _count(Vm.Log[] memory l, bytes32 t) internal pure returns (uint256 n) {
        for (uint256 i; i < l.length; ++i) if (l[i].topics.length > 0 && l[i].topics[0] == t) ++n;
    }

    // An owner mint and a minter mint of the same label to the same account leave identical logs
    // and state, so no log says who minted. Only the hook's operator argument and the tx trace differ.
    function test_logsCannotTellMinterFromOwner() public {
        uint256 p = _reg(alice, "club");
        _setMinter(p, hot);
        OperatorRecorder rec = new OperatorRecorder();

        uint256 snap = vm.snapshotState();
        vm.recordLogs();
        vm.prank(alice);
        uint256 a = nft.registerSubpageFor("x", p, address(rec));
        bytes32 hOwner = _logsHash(vm.getRecordedLogs());
        string memory uriOwner = nft.tokenURI(a);
        address opOwner = rec.lastOperator();
        vm.revertToState(snap);

        vm.recordLogs();
        vm.prank(hot);
        uint256 b = nft.registerSubpageFor("x", p, address(rec));
        bytes32 hMinter = _logsHash(vm.getRecordedLogs());
        assertEq(a, b);
        assertEq(hOwner, hMinter, "logs identical");
        assertEq(nft.tokenURI(b), uriOwner, "card identical");
        assertEq(opOwner, alice);
        assertEq(rec.lastOperator(), hot, "only the hook operator names the minter");
    }

    // Transfers, a return to the setter and a new registration change which minter counts without any
    // SubpageMinterSet event.
    function test_autoOffAndReviveEmitNoMinterEvent() public {
        uint256 p = _reg(alice, "club");
        _setMinter(p, hot);
        assertEq(_minter(p), hot);

        vm.recordLogs();
        vm.prank(alice);
        nft.transferFrom(alice, bob, p);
        Vm.Log[] memory l1 = vm.getRecordedLogs();
        assertEq(_count(l1, T_MINTER_SET), 0);
        assertEq(_minter(p), address(0), "off at bob");

        vm.recordLogs();
        vm.prank(bob);
        nft.transferFrom(bob, alice, p);
        Vm.Log[] memory l2 = vm.getRecordedLogs();
        assertEq(_count(l2, T_MINTER_SET), 0);
        assertEq(_minter(p), hot, "silently back on at alice");

        // the revived minter still only creates
        vm.prank(alice);
        nft.registerSubpageFor("s", p, carol);
        vm.prank(hot);
        vm.expectRevert(PageNFT.AlreadyRegistered.selector);
        nft.registerSubpageFor("s", p, hot);
        assertEq(nft.ownerOf(_subId("s", p)), carol, "the revived minter cannot seize carol's subpage");

        vm.recordLogs();
        _lapseAndRegister(p, alice);
        assertEq(_count(vm.getRecordedLogs(), T_MINTER_SET), 0);
        assertEq(_minter(p), address(0), "off after re-registration");
    }

    // clearRecords on the parent bumps its version and resets saved addresses, but leaves the minter.
    function test_clearRecordsKeepsMinter() public {
        uint256 p = _reg(alice, "club");
        vm.prank(alice);
        nft.setAddr(p, carol);
        _setMinter(p, hot);
        vm.prank(alice);
        nft.clearRecords(p);
        assertEq(nft.resolve(p), alice, "address reset");
        assertEq(_minter(p), hot, "minter survives clearRecords");
    }

    // The old setter keeps a write right on the slot after the sale and can emit any number of
    // SubpageMinterSet events naming the new holder's parent, until the new holder writes once.
    function test_awaySetterEmitsEventsForAnotherHoldersParent() public {
        uint256 p = _reg(alice, "club");
        _setMinter(p, hot);
        vm.prank(alice);
        nft.transferFrom(alice, bob, p);

        vm.recordLogs();
        for (uint256 i; i < 3; ++i) {
            vm.prank(alice);
            nft.setSubpageMinter(p, address(0));
        }
        assertEq(_count(vm.getRecordedLogs(), T_MINTER_SET), 3);
        (address m, uint64 e, address s) = _raw(p);
        assertEq(m, address(0));
        assertEq(e, 1);
        assertEq(s, alice);
        address vm_ = nft.subpageMinterOf(p);
        assertEq(vm_, address(0));

        // back at alice the view reports zero
        vm.prank(bob);
        nft.transferFrom(bob, alice, p);
        vm_ = nft.subpageMinterOf(p);
        assertEq(vm_, address(0));
        vm.prank(alice);
        nft.transferFrom(alice, bob, p);

        vm.prank(bob);
        nft.setSubpageMinter(p, address(0));
        vm.prank(alice);
        vm.expectRevert(PageNFT.Unauthorized.selector);
        nft.setSubpageMinter(p, address(0));
    }

    // A minter can burn a stale subpage held by someone else and clear their
    // primary pointer, emitting PrimaryPageSet for that third party.
    function test_createOnlyMinterClearsThirdPartyStalePrimary() public {
        uint256 p = _reg(alice, "club");
        vm.prank(alice);
        uint256 s = nft.registerSubpageFor("c", p, carol);
        vm.prank(carol);
        nft.setPrimaryPage(s);
        assertEq(nft.reverseResolve(carol), "c.club");

        // the minter cannot touch it while live
        _setMinter(p, hot);
        vm.prank(hot);
        vm.expectRevert(PageNFT.AlreadyRegistered.selector);
        nft.registerSubpageFor("c", p, dave);
        assertEq(nft.reverseResolve(carol), "c.club");

        _lapseAndRegister(p, alice);
        assertEq(nft.reverseResolve(carol), "", "stale hides it");
        assertEq(nft.primaryPage(carol), s, "pointer still stored");
        _setMinter(p, hot);

        vm.recordLogs();
        vm.prank(hot);
        nft.registerSubpageFor("c", p, dave);
        Vm.Log[] memory l = vm.getRecordedLogs();
        bool seen;
        for (uint256 i; i < l.length; ++i) {
            if (l[i].topics[0] == T_PRIMARY && address(uint160(uint256(l[i].topics[1]))) == carol) seen = true;
        }
        assertTrue(seen, "PrimaryPageSet(carol, 0) from a minter mint");
        assertEq(nft.primaryPage(carol), 0);
        assertEq(nft.balanceOf(carol), 0, "carol's stale token burned");
    }

    // One minter slot per parent: an app minter and the registrar cannot both mint.
    function test_oneMinterSlotAppAndRegistrarExclusive() public {
        uint256 p = _reg(alice, "club");
        _sellSetup(p, 0);
        vm.prank(buyer);
        reg.registerSubpage(p, "one", 0, address(0));
        _setMinter(p, hot);
        vm.prank(buyer);
        vm.expectRevert(SubpageRegistrar.NotMinter.selector);
        reg.registerSubpage(p, "two", 0, address(0));
    }

    // The parent's card and records are untouched by picking, clearing and minter mints.
    function test_parentCardUnchangedByMinter() public {
        uint256 p = _reg(alice, "club");
        string memory u0 = nft.tokenURI(p);
        _setMinter(p, hot);
        assertEq(nft.tokenURI(p), u0);
        vm.prank(hot);
        nft.registerSubpageFor("k", p, carol);
        vm.prank(hot);
        vm.expectRevert(PageNFT.AlreadyRegistered.selector);
        nft.registerSubpageFor("k", p, dave);
        assertEq(nft.tokenURI(p), u0);
        _setMinter(p, address(0));
        assertEq(nft.tokenURI(p), u0);
        assertEq(nft.payee(p), alice);
    }

    address[] victims;

    // A leaked minter floods junk. Measures the marginal gas per junk subpage, shows the owner stops
    // it in one transaction, and what is left behind.
    function test_junkFloodAndCleanup() public {
        uint256 p = _reg(alice, "club");
        JunkMinter j = new JunkMinter(nft);
        _setMinter(p, address(j));
        for (uint256 i; i < 10; ++i) victims.push(makeAddr(string.concat("victim", vm.toString(i))));

        uint256 g0 = gasleft();
        j.flood(p, 0, 50, victims);
        uint256 g50 = g0 - gasleft();
        g0 = gasleft();
        j.flood(p, 50, 150, victims);
        uint256 g150 = g0 - gasleft();
        emit log_named_uint("gas for 50 junk mints", g50);
        emit log_named_uint("gas for 150 junk mints", g150);
        emit log_named_uint("marginal gas per junk mint", g150 / 150);
        emit log_named_uint("junk mints per 30M gas", 30_000_000 / (g150 / 150));
        emit log_named_uint("junk mints per 60M gas", 60_000_000 / (g150 / 150));
        assertEq(nft.balanceOf(victims[0]), 20);

        // the owner stops it in one transaction
        uint256 gs = gasleft();
        vm.prank(alice);
        nft.setSubpageMinter(p, address(0));
        emit log_named_uint("gas for the owner's switch-off call", gs - gasleft());
        vm.expectRevert(PageNFT.NotParentOwner.selector);
        j.flood(p, 200, 1, victims);

        // what is left: 200 live junk subpages, each blocking its label
        assertFalse(nft.isAvailable("j0", p));
        assertFalse(nft.isAvailable("j199", p));
        assertEq(nft.getPageName(_subId("j7", p)), "j7.club");
        (address m, uint64 e, address s) = _raw(p);
        assertEq(m, address(0));
        assertEq(e, 1);
        assertEq(s, alice, "slot keeps the owner as setter");

        // cleanup is one mint by the owner per label to the dead address, which frees the label
        gs = gasleft();
        vm.prank(alice);
        nft.registerSubpageFor("j0", p, DEAD);
        emit log_named_uint("gas for one owner take-back to DEAD", gs - gasleft());
        assertEq(nft.ownerOf(_subId("j0", p)), DEAD);
        assertTrue(nft.isAvailable("j0", p), "a subpage held by DEAD is free");
        assertFalse(nft.isAvailable("j1", p), "the others stay taken");

        // a sale of the parent keeps every junk subpage live under the buyer
        vm.prank(alice);
        nft.transferFrom(alice, bob, p);
        assertEq(nft.ownerOf(_subId("j1", p)), victims[1]);
        assertEq(nft.getPageName(_subId("j1", p)), "j1.club");
    }

    // A leaked minter cannot wipe a live subpage. Only the holder minting it again wipes its records,
    // here after the minter is switched off.
    function test_leakedMinterCannotWipeOnlyHolderMintAgainDoes() public {
        uint256 p = _reg(alice, "club");
        vm.prank(alice);
        uint256 s = nft.registerSubpageFor("c", p, carol);
        vm.startPrank(carol);
        nft.setText(s, "url", "https://carol.example");
        nft.setAddr(s, dave);
        nft.setPrimaryPage(s);
        vm.stopPrank();

        _setMinter(p, hot);
        vm.prank(hot);
        vm.expectRevert(PageNFT.AlreadyRegistered.selector);
        nft.registerSubpageFor("c", p, hot);
        assertEq(nft.text(s, "url"), "https://carol.example", "a leaked create-only key leaves data alone");
        assertEq(nft.resolve(s), dave);
        assertEq(nft.primaryPage(carol), s);
        _setMinter(p, address(0));
        vm.prank(alice);
        nft.registerSubpageFor("c", p, carol);

        assertEq(nft.ownerOf(s), carol);
        assertEq(nft.text(s, "url"), "", "text gone");
        assertEq(nft.resolve(s), carol, "saved address gone");
        assertEq(nft.primaryPage(carol), 0, "primary cleared");
        assertEq(nft.recordVersion(s), 1, "only the holder's own re-mint wipes it");
    }

    // A minter recorded by the old setter revives when anyone hands the parent back to that setter.
    // The giver needs nothing from the setter: a plain transfer to them is enough.
    function test_anyHolderCanReviveOldPickByGivingNameBack() public {
        uint256 p = _reg(alice, "club");
        _setMinter(p, hot);
        vm.prank(alice);
        nft.transferFrom(alice, bob, p);
        vm.prank(bob);
        nft.registerSubpageFor("u", p, carol);
        assertEq(_minter(p), address(0));
        vm.prank(bob);
        nft.transferFrom(bob, alice, p);
        assertEq(_minter(p), hot);
        vm.prank(hot);
        vm.expectRevert(PageNFT.AlreadyRegistered.selector);
        nft.registerSubpageFor("u", p, hot);
        assertEq(nft.ownerOf(_subId("u", p)), carol);
        vm.prank(hot);
        nft.registerSubpageFor("u2", p, hot);
        assertEq(nft.ownerOf(_subId("u2", p)), hot);
    }

    // The minter and the epoch share word 0: every epoch value round trips and the rest of the word stays zero.
    function testFuzz_packingRoundTrip(uint64 epoch, address minter) public {
        vm.assume(minter != address(0));
        uint256 p = _reg(alice, "club");
        // set the parent's epoch directly: records slot 0, the epoch sits in its third word, bits 64 to 127
        bytes32 base = keccak256(abi.encode(p, uint256(0)));
        bytes32 w3 = vm.load(address(nft), bytes32(uint256(base) + 2));
        uint256 v = uint256(w3);
        v = (v & ~(uint256(type(uint64).max) << 64)) | (uint256(epoch) << 64);
        vm.store(address(nft), bytes32(uint256(base) + 2), bytes32(v));
        assertEq(nft.epochOf(p), epoch, "epoch poked");
        _setMinter(p, minter);
        (address m, uint64 e, address s) = _raw(p);
        assertEq(m, minter);
        assertEq(e, epoch);
        assertEq(s, alice);
        address vm_ = nft.subpageMinterOf(p);
        assertEq(vm_, minter);
    }

    // The away clear stamps the current epoch, so after a new registration by someone else and a
    // transfer back, the cleared pick reads as zero through the view. Pins the epoch the event carries.
    function test_awayClearStampsCurrentEpoch() public {
        uint256 p = _reg(alice, "club");
        _setMinter(p, hot);
        _lapseAndRegister(p, bob);
        assertEq(nft.epochOf(p), 2);
        _expectMinterSet(p, alice, address(0), 2);
        vm.prank(alice);
        nft.setSubpageMinter(p, address(0));
        (, uint64 e,) = _raw(p);
        assertEq(e, 2);
        vm.prank(bob);
        nft.transferFrom(bob, alice, p);
        address m = nft.subpageMinterOf(p);
        assertEq(m, address(0));
    }
}

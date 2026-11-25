// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Vm} from "forge-std/Test.sol";
import {PageNFT} from "../../../src/PageNFT.sol";
import {SubpageRegistrar} from "../../../src/SubpageRegistrar.sol";
import {MinterBase} from "../../utils/MinterBase.sol";
import {SafeLike, Delegate7702, HookCaller, NoHook} from "../../utils/MinterMocks.sol";

// What a minter can and cannot mint, and that it can do nothing else.
contract MinterMintTest is MinterBase {
    uint256 club;
    uint256 gold;

    function setUp() public override {
        super.setUp();
        club = _reg(alice, "club");
        gold = _reg(bob, "gold");
    }

    // create only: a live subpage is refused and left exactly as it was
    function test_createOnlyCannotOverwriteALiveSubpage() public {
        vm.prank(alice);
        uint256 s = nft.registerSubpageFor("live", club, carol);
        vm.startPrank(carol);
        nft.setText(s, "k", "v");
        nft.setAddr(s, dave);
        nft.setPrimaryPage(s);
        vm.stopPrank();
        _setMinter(club, hot);
        uint256 v = nft.recordVersion(s);
        vm.recordLogs();
        vm.prank(hot);
        vm.expectRevert(PageNFT.AlreadyRegistered.selector);
        nft.registerSubpageFor("live", club, hot);
        vm.prank(hot);
        vm.expectRevert(PageNFT.AlreadyRegistered.selector);
        nft.registerSubpageFor("LIVE", club, carol);
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(nft.ownerOf(s), carol);
        assertEq(nft.recordVersion(s), v);
        assertEq(nft.text(s, "k"), "v");
        assertEq(nft.resolve(s), dave);
        assertEq(nft.primaryPage(carol), s);
        (,, , uint64 epoch,) = nft.records(s);
        assertEq(epoch, 1);
    }

    // create only: free labels and stale labels mint, a stale one exactly as the owner would
    function test_createOnlyMintsFreeAndStaleLabels() public {
        _setMinter(club, hot);
        vm.prank(hot);
        uint256 f = nft.registerSubpageFor("free", club, carol);
        assertEq(nft.ownerOf(f), carol);

        // a subpage of the first registration goes stale when alice registers club again
        vm.prank(alice);
        uint256 s = nft.registerSubpageFor("old", club, carol);
        vm.startPrank(carol);
        nft.setText(s, "k", "v");
        nft.setPrimaryPage(s);
        vm.stopPrank();
        _lapseAndRegister(club, alice);
        assertEq(nft.resolve(s), address(0));
        assertEq(nft.reverseResolve(carol), "");
        _setMinter(club, hot);

        vm.recordLogs();
        vm.prank(hot);
        uint256 s2 = nft.registerSubpageFor("old", club, dave);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(s2, s);
        assertEq(nft.ownerOf(s), dave);
        assertEq(nft.recordVersion(s), 1);
        assertEq(nft.primaryPage(carol), 0);
        assertEq(nft.text(s, "k"), "");
        (,, , uint64 epoch, uint64 parentEpoch) = nft.records(s);
        assertEq(epoch, 2);
        assertEq(parentEpoch, 2);
        // PrimaryPageSet, burn Transfer and trio, VersionChanged, mint Transfer and trio, SubpageRegistered
        assertEq(logs.length, 11);
        assertEq(logs[0].topics[0], PageNFT.PrimaryPageSet.selector);
        assertEq(logs[1].topics[0], T_TRANSFER);
        assertEq(logs[5].topics[0], PageNFT.VersionChanged.selector);
        assertEq(logs[6].topics[0], T_TRANSFER);
        assertEq(logs[10].topics[0], PageNFT.SubpageRegistered.selector);
    }

    // the minter cannot take back a live subpage, and on a stale label it mints exactly as the owner does
    function test_minterRefusedOnLiveAndLikeTheOwnerOnStale() public {
        vm.prank(alice);
        uint256 s = nft.registerSubpageFor("member", club, carol);
        vm.startPrank(carol);
        nft.setText(s, "k", "v");
        nft.setContenthash(s, hex"e301");
        nft.setAddr(s, dave);
        nft.setAddrForCoin(s, 60, abi.encodePacked(dave));
        nft.setPrimaryPage(s);
        vm.stopPrank();
        _setMinter(club, hot);

        // create only: the minter's attempt to take it back is refused, logs nothing and changes nothing
        bytes memory before = _state(s);
        vm.recordLogs();
        vm.prank(hot);
        vm.expectRevert(PageNFT.AlreadyRegistered.selector);
        nft.registerSubpageFor("member", club, bob);
        assertEq(vm.getRecordedLogs().length, 0, "refused take-back logs nothing");
        assertEq(keccak256(_state(s)), keccak256(before), "refused take-back changes nothing");
        assertEq(nft.ownerOf(s), carol);
        assertEq(nft.text(s, "k"), "v");
        assertEq(nft.primaryPage(carol), s);

        // on a stale label the minter mints again exactly as the owner does
        _lapseAndRegister(club, alice);
        _setMinter(club, hot);
        uint256 snap = vm.snapshotState();
        vm.recordLogs();
        vm.prank(alice);
        nft.registerSubpageFor("member", club, bob);
        Vm.Log[] memory ownerLogs = vm.getRecordedLogs();
        bytes memory ownerState = _state(s);
        vm.revertToState(snap);

        vm.recordLogs();
        vm.prank(hot);
        nft.registerSubpageFor("member", club, bob);
        Vm.Log[] memory minterLogs = vm.getRecordedLogs();
        bytes memory minterState = _state(s);

        assertEq(keccak256(minterState), keccak256(ownerState), "state");
        assertEq(minterLogs.length, ownerLogs.length, "log count");
        for (uint256 i; i < ownerLogs.length; ++i) {
            assertEq(minterLogs[i].emitter, ownerLogs[i].emitter);
            assertEq(keccak256(abi.encode(minterLogs[i].topics)), keccak256(abi.encode(ownerLogs[i].topics)));
            assertEq(keccak256(minterLogs[i].data), keccak256(ownerLogs[i].data));
        }
        assertEq(nft.ownerOf(s), bob);
        assertEq(nft.text(s, "k"), "");
        assertEq(nft.contenthash(s), "");
        assertEq(nft.resolve(s), bob);
        assertEq(nft.primaryPage(carol), 0);
        assertEq(nft.recordVersion(s), 1);
        assertEq(ownerLogs[0].topics[0], PageNFT.PrimaryPageSet.selector);
        assertEq(ownerLogs[0].topics[1], bytes32(uint256(uint160(carol))));
        assertEq(ownerLogs[0].topics[2], bytes32(0));
    }

    function _state(uint256 s) internal view returns (bytes memory) {
        (string memory l, uint256 p, uint64 e, uint64 ep, uint64 pe) = nft.records(s);
        return abi.encode(
            l, p, e, ep, pe, nft.ownerOf(s), nft.recordVersion(s), nft.primaryPage(carol), nft.resolve(s),
            nft.addr(s, 60), nft.text(s, "k"), nft.contenthash(s), nft.tokenURI(s)
        );
    }

    // a minter mints only under its own parent
    function test_minterOnlyUnderItsParent() public {
        _setMinter(club, hot);
        vm.prank(bob);
        uint256 g = nft.registerSubpageFor("member", gold, carol);
        vm.prank(hot);
        vm.expectRevert(PageNFT.NotParentOwner.selector);
        nft.registerSubpageFor("member", gold, hot);
        vm.prank(hot);
        vm.expectRevert(PageNFT.NotParentOwner.selector);
        nft.registerSubpageFor("fresh", gold, hot);
        assertEq(nft.ownerOf(g), carol);
        // a subpage as parent is refused before any minter check
        vm.prank(hot);
        uint256 own = nft.registerSubpageFor("mine", club, hot);
        vm.prank(hot);
        vm.expectRevert(PageNFT.NotTopLevel.selector);
        nft.registerSubpageFor("deep", own, hot);
    }

    // with a minter picked the owner still mints, overwrites what the minter made and uses both entry points
    function test_ownerKeepsEveryPowerWithAMinter() public {
        _setMinter(club, hot);
        vm.prank(hot);
        uint256 s = nft.registerSubpageFor("bymint", club, carol);
        vm.prank(alice);
        nft.registerSubpageFor("bymint", club, alice);
        assertEq(nft.ownerOf(s), alice);
        vm.prank(alice);
        uint256 own = nft.registerSubpage("self", club);
        assertEq(nft.ownerOf(own), alice);
        vm.prank(alice);
        nft.registerSubpage("self", club);
        _setMinter(club, hot);
        vm.prank(alice);
        nft.registerSubpageFor("bymint", club, bob);
        assertEq(nft.ownerOf(s), bob);
        // the owner as its own minter changes nothing
        _setMinter(club, alice);
        vm.prank(alice);
        nft.registerSubpageFor("bymint", club, carol);
        assertEq(nft.ownerOf(s), carol);
    }

    // the minter cannot touch the parent, its records, others' names, the ledgers or primary names
    function test_minterHasNoOtherPower() public {
        vm.startPrank(alice);
        nft.setPrimaryPage(club);
        nft.setAddr(club, payout);
        nft.setText(club, "k", "v");
        vm.stopPrank();
        vm.prank(payout);
        nft.setPrimaryPage(club);
        _setMinter(club, hot);
        uint256 dep = nft.depositOf(club);
        uint256 bal = address(nft).balance;

        vm.startPrank(hot);
        vm.expectRevert(NOT_OWNER_NOR_APPROVED);
        nft.transferFrom(alice, hot, club);
        vm.expectRevert(NOT_OWNER_NOR_APPROVED);
        nft.approve(hot, club);
        vm.expectRevert(PageNFT.Unauthorized.selector);
        nft.setAddr(club, hot);
        vm.expectRevert(PageNFT.Unauthorized.selector);
        nft.setAddrForCoin(club, 60, abi.encodePacked(hot));
        vm.expectRevert(PageNFT.Unauthorized.selector);
        nft.setText(club, "k", "x");
        vm.expectRevert(PageNFT.Unauthorized.selector);
        nft.setContenthash(club, hex"01");
        vm.expectRevert(PageNFT.Unauthorized.selector);
        nft.clearRecords(club);
        vm.expectRevert(PageNFT.Unauthorized.selector);
        nft.setPrimaryPage(club);
        vm.expectRevert(PageNFT.Unauthorized.selector);
        nft.setSubpageMinter(club, hot2);
        vm.expectRevert(PageNFT.NothingToWithdraw.selector);
        nft.withdraw(alice);
        vm.expectRevert(PageNFT.NotReleasable.selector);
        nft.release(club);
        // a top level name cannot be minted by the minter without the commit and reveal of anyone
        vm.expectRevert(PageNFT.CommitmentNotFound.selector);
        nft.reveal{value: 1 ether}("brandnew", address(this), 0, bytes32(0));
        vm.stopPrank();

        // minting sets nobody's primary name and moves no money
        vm.prank(hot);
        uint256 s = nft.registerSubpageFor("gift", club, carol);
        assertEq(nft.primaryPage(carol), 0);
        assertEq(nft.primaryPage(alice), club);
        assertEq(nft.primaryPage(payout), club);
        assertEq(nft.reverseResolve(payout), "club");
        assertEq(nft.reverseResolve(alice), "");
        assertEq(nft.resolve(club), payout);
        assertEq(nft.text(club, "k"), "v");
        assertEq(nft.depositOf(club), dep);
        assertEq(nft.depositOf(s), 0);
        assertEq(nft.referrerOf(s), 0);
        assertEq(address(nft).balance, bal);
        assertEq(nft.owed(hot), 0);
        // what it minted for someone else is theirs
        vm.prank(hot);
        vm.expectRevert(PageNFT.Unauthorized.selector);
        nft.setText(s, "k", "x");
        vm.prank(hot);
        vm.expectRevert(NOT_OWNER_NOR_APPROVED);
        nft.transferFrom(carol, hot, s);
    }

    // a parent held by the dead address has no minter and can get none; the account that picked the
    // minter may still switch it off
    function test_deadHeldParent() public {
        uint256 burned = _reg(alice, "maple");
        _setMinter(burned, hot);
        _configure(burned, alice, address(0), 0, false);
        vm.prank(alice);
        nft.transferFrom(alice, DEAD, burned);
        assertEq(_minter(burned), address(0));
        vm.prank(hot);
        vm.expectRevert(PageNFT.NotParentOwner.selector);
        nft.registerSubpageFor("alice", burned, hot);
        vm.prank(alice);
        vm.expectRevert(PageNFT.NotParentOwner.selector);
        nft.registerSubpageFor("alice", burned, alice);
        vm.prank(alice);
        vm.expectRevert(PageNFT.Unauthorized.selector);
        nft.setSubpageMinter(burned, hot);
        vm.prank(stranger);
        vm.expectRevert(PageNFT.Unauthorized.selector);
        nft.setSubpageMinter(burned, stranger);
        vm.prank(alice);
        nft.setSubpageMinter(burned, address(0));
        vm.prank(buyer);
        vm.expectRevert(SubpageRegistrar.StaleController.selector);
        reg.registerSubpage(burned, "alice", 0, address(0));
        // renewals by anyone keep it held
        vm.prank(stranger);
        nft.renew{value: 0.0001 ether}(burned);
        assertEq(nft.ownerOf(burned), DEAD);
    }

    // a contract holder shaped like a Safe picks and switches a minter through its own calls
    function test_safeLikeHolder() public {
        SafeLike safe = new SafeLike(alice);
        uint256 vault = _regTo(alice, "vault", address(safe));
        vm.prank(alice);
        safe.exec(address(nft), 0, abi.encodeCall(PageNFT.setSubpageMinter, (vault, hot)));
        assertEq(_minter(vault), hot);
        vm.prank(hot);
        uint256 s = nft.registerSubpageFor("app", vault, carol);
        assertEq(nft.ownerOf(s), carol);
        // the safe's owner key alone is nobody here
        vm.prank(alice);
        vm.expectRevert(PageNFT.Unauthorized.selector);
        nft.setSubpageMinter(vault, hot2);
        // the safe moves the name away and switches off from afar
        vm.prank(alice);
        safe.exec(address(nft), 0, abi.encodeCall(nft.transferFrom, (address(safe), bob, vault)));
        assertEq(_minter(vault), address(0));
        vm.prank(alice);
        safe.exec(address(nft), 0, abi.encodeCall(PageNFT.setSubpageMinter, (vault, address(0))));
        vm.prank(bob);
        nft.safeTransferFrom(bob, address(safe), vault);
        assertEq(_minter(vault), address(0));
        // a safe as the minter of someone else's parent
        _setMinter(club, address(safe));
        vm.prank(alice);
        safe.exec(address(nft), 0, abi.encodeCall(PageNFT.registerSubpageFor, ("bysafe", club, carol)));
        assertEq(nft.ownerOf(_subId("bysafe", club)), carol);
    }

    // an EIP7702 account holds the parent, picks a minter and receives plain mints, since it counts as a key wallet
    function test_eip7702Holder() public {
        (address eoa, uint256 pk) = makeAddrAndKey("eoa7702");
        vm.deal(eoa, 10 ether);
        Delegate7702 impl = new Delegate7702();
        vm.signAndAttachDelegation(address(impl), pk);
        vm.prank(stranger);
        (bool ok,) = eoa.call("");
        assertTrue(ok);
        assertEq(eoa.code.length, 23);
        uint256 p = _regTo(stranger, "seven", eoa);
        assertEq(nft.ownerOf(p), eoa);
        vm.prank(eoa);
        nft.setSubpageMinter(p, hot);
        vm.prank(hot);
        uint256 s = nft.registerSubpageFor("x", p, eoa);
        assertEq(nft.ownerOf(s), eoa);
        vm.prank(hot);
        vm.expectRevert(PageNFT.AlreadyRegistered.selector);
        nft.registerSubpageFor("x", p, carol);
        assertEq(nft.ownerOf(s), eoa);

        // a 7702 account whose delegate has no hook still receives a minted subpage, since its key can move it
        (address eoa2, uint256 pk2) = makeAddrAndKey("eoa7702b");
        NoHook none = new NoHook();
        vm.signAndAttachDelegation(address(none), pk2);
        vm.prank(stranger);
        (ok,) = eoa2.call("");
        assertEq(eoa2.code.length, 23);
        vm.prank(hot);
        uint256 y = nft.registerSubpageFor("y", p, eoa2);
        assertEq(nft.ownerOf(y), eoa2);
        vm.prank(eoa2, eoa2);
        nft.transferFrom(eoa2, carol, y);
        assertEq(nft.ownerOf(y), carol);
        // a plain contract with no hook still cannot receive a subpage someone else mints to it
        address plain = address(new NoHook());
        vm.prank(hot);
        vm.expectRevert(NON_RECEIVER);
        nft.registerSubpageFor("w", p, plain);
        // the hookless 7702 account can hold a parent sent by plain transfer and pick a minter
        vm.prank(bob);
        nft.transferFrom(bob, eoa2, gold);
        vm.prank(eoa2);
        nft.setSubpageMinter(gold, hot2);
        vm.prank(hot2);
        nft.registerSubpageFor("z", gold, carol);
    }

    function _armAndMint(HookCaller h, address target, bytes memory data, address minter, string memory label)
        internal
        returns (bool ok, bytes memory ret)
    {
        h.arm(target, data, false);
        vm.prank(minter);
        nft.registerSubpageFor(label, club, address(h));
        assertTrue(h.called());
        ok = h.ok();
        ret = h.ret();
    }

    // reentry through the recipient's hook on a minter mint and an owner mint
    function test_reentryThroughTheRecipientHook() public {
        _setMinter(club, hot);
        HookCaller h = new HookCaller();
        address[2] memory minters = [hot, alice];
        for (uint256 i; i < 2; ++i) {
            string memory tag = i == 0 ? "m" : "o";
            // guarded entry points of PageNFT refuse
            (bool ok, bytes memory ret) = _armAndMint(
                h, address(nft), abi.encodeCall(PageNFT.registerSubpageFor, ("again", club, address(h))), minters[i],
                string.concat(tag, "1")
            );
            assertFalse(ok);
            assertEq(bytes4(ret), REENTRANCY);
            (ok, ret) = _armAndMint(
                h, address(nft), abi.encodeCall(PageNFT.registerSubpage, ("again", club)), minters[i],
                string.concat(tag, "2")
            );
            assertFalse(ok);
            assertEq(bytes4(ret), REENTRANCY);
            (ok, ret) = _armAndMint(
                h, address(nft), abi.encodeCall(PageNFT.withdraw, (address(h))), minters[i], string.concat(tag, "3")
            );
            assertFalse(ok);
            assertEq(bytes4(ret), REENTRANCY);
            // a registrar sale from inside fails too, here at NotMinter since hot and not the registrar is
            // the minter of club
            _configure(club, payout, address(0), 0, false);
            (ok, ret) = _armAndMint(
                h, address(reg),
                abi.encodeCall(SubpageRegistrar.registerSubpage, (club, "viareg", 0, address(0))), minters[i],
                string.concat(tag, "4")
            );
            assertFalse(ok);
            assertTrue(bytes4(ret) == REENTRANCY || bytes4(ret) == SubpageRegistrar.NotMinter.selector);
            // the recipient is not the holder, so it cannot change the minter
            (ok, ret) = _armAndMint(
                h, address(nft), abi.encodeCall(PageNFT.setSubpageMinter, (club, address(h))), minters[i],
                string.concat(tag, "5")
            );
            assertFalse(ok);
            assertEq(bytes4(ret), PageNFT.Unauthorized.selector);
        }
        // a hook that bubbles its failure reverts the whole mint
        h.arm(address(nft), abi.encodeCall(PageNFT.registerSubpage, ("again", club)), true);
        vm.prank(hot);
        vm.expectRevert(REENTRANCY);
        nft.registerSubpageFor("bubble", club, address(h));
        assertEq(_minter(club), hot);
    }

    // odd picks give nobody anything new: PageNFT, the registrar without a config, DEAD, the holder
    // itself; a minter cannot mint to PageNFT or to zero either
    function test_oddChoicesAreHarmless() public {
        _setMinter(club, address(nft));
        assertEq(_minter(club), address(nft));
        _setMinter(club, DEAD);
        vm.prank(DEAD);
        nft.registerSubpageFor("dead", club, carol);
        _setMinter(club, alice);
        vm.prank(alice);
        nft.registerSubpageFor("self", club, carol);
        _setMinter(club, address(reg));
        vm.prank(buyer);
        vm.expectRevert(SubpageRegistrar.NotEnabled.selector);
        reg.registerSubpage(club, "x", 0, address(0));
        _setMinter(club, hot);
        vm.prank(hot);
        vm.expectRevert(PageNFT.InvalidRecipient.selector);
        nft.registerSubpageFor("x", club, address(nft));
        vm.prank(hot);
        vm.expectRevert(bytes4(0xea553b34)); // TransferToZeroAddress()
        nft.registerSubpageFor("x", club, address(0));
    }

    // every other mint path: a top level reveal, the holder minting to itself, a minter contract
    // minting to itself, and taking a name back, which burns before it mints
    function test_reentryOnEveryOtherMintPath() public {
        bytes memory guarded = abi.encodeCall(PageNFT.registerSubpageFor, ("x", club, carol));
        // a top level reveal to a contract by someone else: the guard holds, the new holder may pick a minter
        HookCaller h = new HookCaller();
        h.arm(address(nft), guarded, false);
        uint256 p = _regTo(alice, "hooked", address(h));
        assertEq(bytes4(h.ret()), REENTRANCY);
        h.arm(address(nft), abi.encodeCall(PageNFT.setSubpageMinter, (_id("hooked2"), hot)), false);
        uint256 p2 = _regTo(alice, "hooked2", address(h));
        assertTrue(h.ok());
        assertEq(_minter(p2), hot);
        // the contract buying a top level name for itself makes no hook call
        h.arm(address(nft), guarded, false);
        bytes32 sec = keccak256("hooked3");
        h.exec(address(nft), 0, abi.encodeCall(PageNFT.commit, (nft.makeCommitment("hooked3", address(h), 0, sec))));
        vm.warp(vm.getBlockTimestamp() + 61);
        (,,, uint256 total) = nft.quote("hooked3");
        vm.deal(address(h), total);
        h.exec(address(nft), total, abi.encodeCall(PageNFT.reveal, ("hooked3", address(h), 0, sec)));
        assertFalse(h.called());
        assertEq(nft.ownerOf(_id("hooked3")), address(h));
        // the holder contract mints to itself with registerSubpage; a mint to the caller makes no hook call
        h.arm(address(nft), guarded, false);
        h.exec(address(nft), 0, abi.encodeCall(PageNFT.registerSubpage, ("self", p)));
        assertFalse(h.called());
        assertEq(nft.ownerOf(_subId("self", p)), address(h));
        // the same holder contract minting to itself through registerSubpageFor makes no hook call either
        h.exec(address(nft), 0, abi.encodeCall(PageNFT.registerSubpageFor, ("selffor", p, address(h))));
        assertFalse(h.called());
        assertEq(nft.ownerOf(_subId("selffor", p)), address(h));
        // a minter contract mints to itself with registerSubpage
        HookCaller m = new HookCaller();
        _setMinter(club, address(m));
        m.arm(address(nft), guarded, false);
        m.exec(address(nft), 0, abi.encodeCall(PageNFT.registerSubpage, ("mine", club)));
        assertFalse(m.called());
        assertEq(nft.ownerOf(_subId("mine", club)), address(m));
        // the minter cannot take back carol's token; the holder can, which burns it and mints to a hook
        vm.prank(alice);
        uint256 s = nft.registerSubpageFor("member", club, carol);
        vm.expectRevert(PageNFT.AlreadyRegistered.selector);
        m.exec(address(nft), 0, abi.encodeCall(PageNFT.registerSubpageFor, ("member", club, address(m))));
        assertEq(nft.ownerOf(s), carol);
        m.arm(address(nft), guarded, false);
        vm.prank(alice);
        nft.registerSubpageFor("member", club, address(m));
        assertEq(bytes4(m.ret()), REENTRANCY);
        assertEq(nft.ownerOf(s), address(m));
        // a recipient that is the minter of club cannot use that power in the middle of a fresh mint either
        m.arm(address(nft), guarded, false);
        vm.prank(alice);
        nft.registerSubpageFor("gift", club, address(m));
        assertEq(bytes4(m.ret()), REENTRANCY);
    }

    // the holder as recipient may switch the minter off from inside a mint; the mint still completes
    function test_holderHookSwitchesTheMinterMidMint() public {
        HookCaller h = new HookCaller();
        uint256 p = _regTo(alice, "hooked", address(h));
        h.exec(address(nft), 0, abi.encodeCall(PageNFT.setSubpageMinter, (p, hot)));
        h.arm(address(nft), abi.encodeCall(PageNFT.setSubpageMinter, (p, address(0))), false);
        vm.prank(hot);
        uint256 s = nft.registerSubpageFor("in", p, address(h));
        assertTrue(h.ok());
        assertEq(nft.ownerOf(s), address(h));
        assertEq(_minter(p), address(0));
        vm.prank(hot);
        vm.expectRevert(PageNFT.NotParentOwner.selector);
        nft.registerSubpageFor("next", p, carol);
    }

    // anything minted by any caller other than the holder came from the counted minter and landed on a free label:
    // one with no record, one DEAD holds or one of an earlier registration of the parent, never a live one
    function testFuzz_nonOwnerMintImpliesCountedMinter(address caller, uint8 which, uint8 state) public {
        vm.assume(caller != address(0) && caller != alice);
        // state 0 leaves the label with no record, 1 gives it to carol, 2 to DEAD, 3 to carol before club is
        // registered again, which makes it stale, and 4 to alice, the holder of club
        state %= 5;
        address held = state == 2 ? DEAD : state == 4 ? alice : carol;
        if (state != 0) {
            vm.prank(alice);
            nft.registerSubpageFor("target", club, held);
        }
        if (state == 3) _lapseAndRegister(club, alice);
        if (which % 3 == 0) _setMinter(club, caller);
        else if (which % 3 == 1) _setMinter(club, hot);
        address m = nft.subpageMinterOf(club);
        vm.prank(caller);
        (bool ok,) = address(nft).call(abi.encodeCall(PageNFT.registerSubpageFor, ("target", club, dave)));
        assertEq(ok, caller == m && state != 1 && state != 4);
        if (ok || state != 0) assertEq(nft.ownerOf(_subId("target", club)), ok ? dave : held);
    }
}

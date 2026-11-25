// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Vm} from "forge-std/Test.sol";
import {PageNFT} from "../../../src/PageNFT.sol";
import {MinterBase} from "../../utils/MinterBase.sol";
import {Holder721, Delegate7702} from "../../utils/MinterMocks.sol";
import {LogShapes} from "../../utils/LogShapes.sol";

// The exact address events of a mint, a burn, a main address save, a subpage taken back and a registration over a
// lapsed name, what changes with no address event at all, and the VersionChanged count of every id.
contract AddressAnnouncementsTest is MinterBase {
    uint256 constant BASE = 0x80002105;
    uint256 constant BTC = 0;

    uint256 club;

    function setUp() public override {
        super.setUp();
        club = _reg(alice, "club");
    }

    function _assertLogs(Vm.Log[] memory got, bytes32[] memory want) internal view {
        assertEq(got.length, want.length, "log count");
        for (uint256 i; i < got.length; ++i) {
            assertEq(got[i].emitter, address(nft), string.concat("emitter of log ", vm.toString(i)));
            assertEq(LogShapes.hashOf(got[i]), want[i], string.concat("log ", vm.toString(i)));
        }
    }

    function _commitFor(address payer, string memory label, address to) internal returns (bytes32 secret) {
        secret = keccak256(abi.encode(payer, label, to, vm.getBlockTimestamp()));
        bytes32 c = nft.makeCommitment(label, to, 0, secret);
        vm.prank(payer);
        nft.commit(c);
        vm.warp(vm.getBlockTimestamp() + 61);
    }

    function _revealExact(address payer, string memory label, address to, bytes32 secret) internal returns (uint256 id) {
        (,,, uint256 total) = nft.quote(label);
        vm.deal(payer, payer.balance + total);
        vm.prank(payer);
        id = nft.reveal{value: total}(label, to, 0, secret);
    }

    // the saved main address, its saver and the saver of the Ethereum entry, all at the current record version,
    // read from storage
    function _savedWords(uint256 id) internal view returns (bytes32 main, bytes32 saver, bytes32 eth) {
        uint256 v = nft.recordVersion(id);
        main = vm.load(address(nft), keccak256(abi.encode(v, keccak256(abi.encode(id, uint256(7))))));
        saver = vm.load(address(nft), keccak256(abi.encode(v, keccak256(abi.encode(id, uint256(11))))));
        bytes32 entry = keccak256(abi.encode(uint256(60), keccak256(abi.encode(v, keccak256(abi.encode(id, uint256(9)))))));
        eth = vm.load(address(nft), entry);
    }

    function _assertNothingSaved(uint256 id) internal view {
        (bytes32 main, bytes32 saver, bytes32 eth) = _savedWords(id);
        assertEq(main, bytes32(0), "no main address saved");
        assertEq(saver, bytes32(0), "no saver written");
        assertEq(eth, bytes32(0), "no Ethereum entry written");
    }

    function _versionEvents(Vm.Log[] memory logs, uint256 id) internal view returns (uint256 n, uint256 last) {
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory l = logs[i];
            if (l.emitter != address(nft) || l.topics.length != 2 || l.topics[0] != LogShapes.VERSION) continue;
            if (l.topics[1] != bytes32(id)) continue;
            ++n;
            last = abi.decode(l.data, (uint64));
        }
    }

    // every AddressChanged of the logs is for the OP or the Ethereum coin type
    function _onlyMainCoins(Vm.Log[] memory logs) internal pure {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] != LogShapes.ADDRESS_CHANGED) continue;
            (uint256 c,) = abi.decode(logs[i].data, (uint256, bytes));
            assertTrue(c == COIN_OP || c == 60, string.concat("an AddressChanged for coin type ", vm.toString(c)));
        }
    }

    // a mint logs Transfer and then the trio for the recipient, with an empty coin type 60 answer as nothing is
    // saved at the new record version, whatever the code of the recipient; a burn logs Transfer and the trio empty;
    // neither saves anything and neither logs MetadataUpdate from the hook
    function test_mintAndBurnAnnounceAddresses() public {
        // a subpage to a key wallet: its coin type 60 answer is empty, as the account saved nothing
        uint256 a = _subId("eoa", club);
        vm.recordLogs();
        vm.prank(alice);
        nft.registerSubpageFor("eoa", club, carol);
        bytes32[] memory want = new bytes32[](5);
        want[0] = LogShapes.transfer(address(0), carol, a);
        LogShapes.trio(a, carol, address(0), want, 1);
        want[4] = LogShapes.subRegistered(a, club, "eoa");
        _assertLogs(vm.getRecordedLogs(), want);
        _assertNothingSaved(a);

        // a subpage to a contract: its coin type 60 answer is empty too
        Holder721 h = new Holder721();
        uint256 b = _subId("box", club);
        vm.recordLogs();
        vm.prank(alice);
        nft.registerSubpageFor("box", club, address(h));
        want[0] = LogShapes.transfer(address(0), address(h), b);
        LogShapes.trio(b, address(h), address(0), want, 1);
        want[4] = LogShapes.subRegistered(b, club, "box");
        _assertLogs(vm.getRecordedLogs(), want);
        _assertNothingSaved(b);

        // a subpage to an EIP7702 account, which is a key wallet: empty as well
        (address k, uint256 pk) = makeAddrAndKey("account7702");
        Delegate7702 impl = new Delegate7702();
        vm.signAndAttachDelegation(address(impl), pk);
        vm.prank(stranger);
        (bool ok,) = k.call("");
        assertTrue(ok);
        assertEq(k.code.length, 23);
        uint256 c = _subId("seven", club);
        vm.recordLogs();
        vm.prank(alice);
        nft.registerSubpageFor("seven", club, k);
        want[0] = LogShapes.transfer(address(0), k, c);
        LogShapes.trio(c, k, address(0), want, 1);
        want[4] = LogShapes.subRegistered(c, club, "seven");
        _assertLogs(vm.getRecordedLogs(), want);
        _assertNothingSaved(c);

        // the burn of a subpage taken back announces the empty trio before the new mint
        vm.recordLogs();
        vm.prank(alice);
        nft.registerSubpageFor("eoa", club, dave);
        want = new bytes32[](10);
        want[0] = LogShapes.transfer(carol, address(0), a);
        LogShapes.trio(a, address(0), address(0), want, 1);
        want[4] = LogShapes.version(a, 1);
        want[5] = LogShapes.transfer(address(0), dave, a);
        LogShapes.trio(a, dave, address(0), want, 6);
        want[9] = LogShapes.subRegistered(a, club, "eoa");
        _assertLogs(vm.getRecordedLogs(), want);
        _assertNothingSaved(a);

        // a top level registration: the trio follows the Transfer, and the one MetadataUpdate comes after
        // PageRegistered, from the registration itself
        bytes32 s = _commitFor(bob, "topname", bob);
        uint256 fee = nft.getFee(7);
        vm.recordLogs();
        uint256 id = _revealExact(bob, "topname", bob, s);
        uint256 exp = vm.getBlockTimestamp() + 365 days;
        want = new bytes32[](8);
        want[0] = LogShapes.referrerSet(id, 0);
        want[1] = LogShapes.depositAdded(id, bob, fee, fee);
        want[2] = LogShapes.transfer(address(0), bob, id);
        LogShapes.trio(id, bob, address(0), want, 3);
        want[6] = LogShapes.nameRegistered(id, "topname", bob, exp);
        want[7] = LogShapes.meta(id);
        _assertLogs(vm.getRecordedLogs(), want);
        _assertNothingSaved(id);

        // the burn at a registration after the premium window announces the empty trio, after the release of the
        // old deposit
        vm.warp(exp + 111 days + 1);
        s = _commitFor(dave, "topname", dave);
        vm.recordLogs();
        _revealExact(dave, "topname", dave, s);
        uint256 exp2 = vm.getBlockTimestamp() + 365 days;
        want = new bytes32[](14);
        want[0] = LogShapes.released(id, bob, fee);
        want[1] = LogShapes.transfer(bob, address(0), id);
        LogShapes.trio(id, address(0), address(0), want, 2);
        want[5] = LogShapes.version(id, 1);
        want[6] = LogShapes.referrerSet(id, 0);
        want[7] = LogShapes.depositAdded(id, dave, fee, fee);
        want[8] = LogShapes.transfer(address(0), dave, id);
        LogShapes.trio(id, dave, address(0), want, 9);
        want[12] = LogShapes.nameRegistered(id, "topname", dave, exp2);
        want[13] = LogShapes.meta(id);
        _assertLogs(vm.getRecordedLogs(), want);
        _assertNothingSaved(id);

        // the storage read above finds a save once the holder makes one
        vm.prank(dave);
        nft.setAddr(id, carol);
        (bytes32 main, bytes32 saver,) = _savedWords(id);
        assertEq(main, bytes32(uint256(uint160(carol))), "the saved main address is where the check reads it");
        assertEq(saver, bytes32(uint256(uint160(dave))), "and its saver");
    }

    // a registration over a lapsed name to a contract: the burn announced an empty Ethereum answer and so does the
    // mint, which is what addr(node, 60) answers
    function test_reRegistrationToAContract() public {
        uint256 id = _reg(alice, "vault");
        uint256 carried = nft.depositOf(id);
        uint256 fee = nft.getFee(5);
        vm.warp(nft.expiresAt(id) + 111 days + 1);
        Holder721 h = new Holder721();
        bytes32 s = _commitFor(buyer, "vault", address(h));
        vm.recordLogs();
        _revealExact(buyer, "vault", address(h), s);
        uint256 exp = vm.getBlockTimestamp() + 365 days;
        bytes32[] memory want = new bytes32[](14);
        want[0] = LogShapes.released(id, alice, carried);
        want[1] = LogShapes.transfer(alice, address(0), id);
        LogShapes.trio(id, address(0), address(0), want, 2);
        want[5] = LogShapes.version(id, 1);
        want[6] = LogShapes.referrerSet(id, 0);
        want[7] = LogShapes.depositAdded(id, buyer, fee, fee);
        want[8] = LogShapes.transfer(address(0), address(h), id);
        LogShapes.trio(id, address(h), address(0), want, 9);
        want[12] = LogShapes.nameRegistered(id, "vault", address(h), exp);
        want[13] = LogShapes.meta(id);
        _assertLogs(vm.getRecordedLogs(), want);
        assertEq(nft.ownerOf(id), address(h));
        assertEq(nft.addr(id, 60), "", "nothing is saved at the new record version, so no coin type 60 answer");
        assertEq(nft.addr(id, COIN_OP), abi.encodePacked(address(h)));
        assertEq(nft.resolve(id), address(h));
    }

    // a transfer, clearRecords and a registration over a lapsed name change the answers of other chains with no
    // AddressChanged for them; the last two log VersionChanged
    function test_otherChainsChangeWithNoAddressEvent() public {
        uint256 id = _reg(alice, "multi");
        vm.startPrank(alice);
        nft.setAddrForCoin(id, BASE, abi.encodePacked(dave));
        nft.setAddrForCoin(id, BTC, hex"0014aa");
        vm.stopPrank();
        assertEq(nft.addr(id, BASE), abi.encodePacked(dave));
        assertEq(nft.addr(id, BTC), hex"0014aa");

        vm.recordLogs();
        vm.prank(alice);
        nft.transferFrom(alice, bob, id);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        _onlyMainCoins(logs);
        (uint256 n,) = _versionEvents(logs, id);
        assertEq(n, 0, "a transfer logs no VersionChanged");
        assertEq(nft.addr(id, BASE), "", "the seller's Base entry stops counting and the buyer saved no default");
        assertEq(nft.addr(id, BTC), "", "the seller's Bitcoin entry stops counting");

        // a save of another chain is the one call that announces it
        vm.recordLogs();
        vm.startPrank(bob);
        nft.setAddrForCoin(id, BASE, abi.encodePacked(carol));
        nft.setAddrForCoin(id, BTC, hex"0014bb");
        vm.stopPrank();
        logs = vm.getRecordedLogs();
        assertEq(logs.length, 2);
        assertEq(LogShapes.hashOf(logs[0]), LogShapes.coin(id, BASE, abi.encodePacked(carol)));
        assertEq(LogShapes.hashOf(logs[1]), LogShapes.coin(id, BTC, hex"0014bb"));

        vm.recordLogs();
        vm.prank(bob);
        nft.clearRecords(id);
        logs = vm.getRecordedLogs();
        _onlyMainCoins(logs);
        (n,) = _versionEvents(logs, id);
        assertEq(n, 1, "clearRecords announces it through VersionChanged");
        assertEq(nft.addr(id, BASE), "", "the Base entry is gone and no default is left");
        assertEq(nft.addr(id, BTC), "", "the Bitcoin entry is gone");

        vm.startPrank(bob);
        nft.setAddrForCoin(id, BASE, abi.encodePacked(carol));
        nft.setAddrForCoin(id, BTC, hex"0014cc");
        vm.stopPrank();
        assertEq(nft.addr(id, BASE), abi.encodePacked(carol));
        assertEq(nft.addr(id, BTC), hex"0014cc");
        vm.warp(nft.expiresAt(id) + 111 days + 1);
        bytes32 s = _commitFor(dave, "multi", dave);
        vm.recordLogs();
        _revealExact(dave, "multi", dave, s);
        logs = vm.getRecordedLogs();
        _onlyMainCoins(logs);
        (n,) = _versionEvents(logs, id);
        assertEq(n, 1, "a new registration announces it through VersionChanged");
        assertEq(nft.addr(id, BASE), "", "the old Base entry is gone and the new holder saved no default");
        assertEq(nft.addr(id, BTC), "", "the old Bitcoin entry is gone");
    }

    // the trio and MetadataUpdate of one call of the main address setters
    function _mainCall(bytes memory data, uint256 id, address main, address eth) internal {
        vm.recordLogs();
        vm.prank(nft.ownerOf(id));
        (bool ok,) = address(nft).call(data);
        assertTrue(ok, "the save went through");
        bytes32[] memory want = new bytes32[](4);
        LogShapes.trio(id, main, eth, want, 0);
        want[3] = LogShapes.meta(id);
        _assertLogs(vm.getRecordedLogs(), want);
    }

    // every setAddr and every OP save logs the trio and MetadataUpdate, also when the same value is saved again and
    // nothing moved; the coin type 60 event carries the holder's own answer there, never the main address
    function test_setAddrAlwaysAnnouncesEthereum() public {
        uint256 id = club;
        for (uint256 i; i < 2; ++i) {
            _mainCall(abi.encodeCall(PageNFT.setAddr, (id, dave)), id, dave, address(0));
            _mainCall(
                abi.encodeCall(PageNFT.setAddrForCoin, (id, COIN_OP, abi.encodePacked(dave))), id, dave, address(0)
            );
        }
        // zero, empty OP bytes and twenty zero bytes point the name back at its holder, and are announced each time
        for (uint256 i; i < 2; ++i) {
            _mainCall(abi.encodeCall(PageNFT.setAddr, (id, address(0))), id, alice, address(0));
            _mainCall(abi.encodeCall(PageNFT.setAddrForCoin, (id, COIN_OP, bytes(""))), id, alice, address(0));
            _mainCall(abi.encodeCall(PageNFT.setAddrForCoin, (id, COIN_OP, new bytes(20))), id, alice, address(0));
        }
        // with an Ethereum entry saved, the Ethereum event carries that entry
        address x = makeAddr("x60");
        vm.prank(alice);
        nft.setAddrForCoin(id, 60, abi.encodePacked(x));
        for (uint256 i; i < 2; ++i) {
            _mainCall(abi.encodeCall(PageNFT.setAddr, (id, dave)), id, dave, x);
        }
        // a contract as main address and no Ethereum entry: the Ethereum event is empty, as for any main address
        vm.prank(alice);
        nft.setAddrForCoin(id, 60, bytes(""));
        Holder721 h = new Holder721();
        for (uint256 i; i < 2; ++i) {
            _mainCall(abi.encodeCall(PageNFT.setAddr, (id, address(h))), id, address(h), address(0));
        }
    }

    // the holder of the parent mints over a live subpage: the old holder's display name is cleared, the burn logs
    // the empty trio, then VersionChanged, the mint and its trio, then SubpageRegistered
    function test_subpageReMintEmitsVersionChanged() public {
        uint256 kid = _subId("kid", club);
        vm.prank(alice);
        nft.registerSubpageFor("kid", club, carol);
        vm.startPrank(carol);
        nft.setAddr(kid, dave);
        nft.setAddrForCoin(kid, 60, abi.encodePacked(dave));
        nft.setAddrForCoin(kid, BTC, hex"0014cc");
        nft.setText(kid, "url", "https://carol.example");
        nft.setContenthash(kid, hex"e301");
        nft.setPrimaryPage(kid);
        vm.stopPrank();
        uint256 v = nft.recordVersion(kid);
        vm.recordLogs();
        vm.prank(alice);
        nft.registerSubpageFor("kid", club, bob);
        bytes32[] memory want = new bytes32[](11);
        want[0] = LogShapes.primary(carol, 0);
        want[1] = LogShapes.transfer(carol, address(0), kid);
        LogShapes.trio(kid, address(0), address(0), want, 2);
        want[5] = LogShapes.version(kid, v + 1);
        want[6] = LogShapes.transfer(address(0), bob, kid);
        LogShapes.trio(kid, bob, address(0), want, 7);
        want[10] = LogShapes.subRegistered(kid, club, "kid");
        _assertLogs(vm.getRecordedLogs(), want);
        assertEq(nft.recordVersion(kid), v + 1);

        // nothing of carol's saves counts for the new holder, her entry for coin type 60 included
        assertEq(nft.resolve(kid), bob);
        assertEq(nft.addr(kid, 60), "");
        assertEq(nft.addr(kid, BTC), "");
        assertEq(nft.text(kid, "url"), "");
        assertEq(nft.contenthash(kid), "");
        // nor for carol when the subpage comes back to her
        vm.prank(bob);
        nft.transferFrom(bob, carol, kid);
        assertEq(nft.resolve(kid), carol, "her old main address does not come back");
        assertEq(nft.addr(kid, 60), "", "nor her old entry for coin type 60");
        assertEq(nft.addr(kid, BTC), "");
        assertEq(nft.text(kid, "url"), "");
        assertEq(nft.contenthash(kid), "");
        assertEq(nft.reverseResolve(carol), "");
    }

    // over a mix of registrations, registrations over lapsed names, subpages taken back and clears, the
    // VersionChanged events of each id count its record version, and the last one carries it
    function test_versionChangedCountsVersion() public {
        vm.recordLogs();
        uint256 b = _reg(bob, "bname");
        uint256 one = _subId("one", club);
        uint256 two = _subId("two", club);
        uint256 three = _subId("three", club);
        vm.startPrank(alice);
        nft.registerSubpageFor("one", club, carol);
        nft.registerSubpageFor("two", club, dave);
        nft.clearRecords(club);
        nft.clearRecords(club);
        vm.stopPrank();
        vm.prank(carol);
        nft.clearRecords(one);
        vm.startPrank(alice);
        nft.registerSubpageFor("one", club, dave);
        nft.registerSubpageFor("one", club, DEAD);
        nft.registerSubpageFor("one", club, carol);
        vm.stopPrank();
        vm.prank(dave);
        nft.transferFrom(dave, DEAD, two);
        vm.prank(alice);
        nft.registerSubpageFor("three", club, bob);
        vm.prank(bob);
        nft.clearRecords(b);

        // both names lapse and are registered again; the subpages of club go stale and one is made again
        vm.warp(nft.expiresAt(b) + 111 days + 1);
        _reg(carol, "bname");
        _reg(dave, "club");
        vm.prank(carol);
        nft.clearRecords(b);
        vm.prank(dave);
        nft.registerSubpageFor("one", club, bob);
        vm.prank(dave);
        nft.registerSubpageFor("four", club, bob);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256[6] memory ids = [club, b, one, two, three, _subId("four", club)];
        uint256[6] memory expect = [uint256(3), 3, 5, 0, 0, 0];
        for (uint256 i; i < ids.length; ++i) {
            (uint256 n, uint256 last) = _versionEvents(logs, ids[i]);
            uint256 v = nft.recordVersion(ids[i]);
            assertEq(v, expect[i], string.concat("record version of id ", vm.toString(i)));
            assertEq(n, v, string.concat("VersionChanged count of id ", vm.toString(i)));
            if (n != 0) assertEq(last, v, string.concat("the last VersionChanged carries the version, id ", vm.toString(i)));
        }
    }
}

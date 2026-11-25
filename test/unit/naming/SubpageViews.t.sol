// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Vm} from "forge-std/Test.sol";
import {PageNFT} from "../../../src/PageNFT.sol";
import {MinterBase} from "../../utils/MinterBase.sol";

// The record views a subpage answers through, its own records, its answers while its parent is in grace or
// registered again, and its full name read back into its id.
contract SubpageViewsTest is MinterBase {
    uint256 constant BASE = 0x80002105;
    uint256 constant BTC = 0;

    uint256 club;

    function setUp() public override {
        super.setUp();
        club = _reg(alice, "club");
    }

    function _matchesRecord(uint256 id) internal view {
        (, uint256 parent,, uint64 epoch,) = nft.records(id);
        assertEq(nft.parentOf(id), parent, "parentOf is the stored parent");
        assertEq(nft.epochOf(id), epoch, "epochOf is the stored epoch");
    }

    // parentOf and epochOf answer the stored fields for a top level name, a live subpage, a stale subpage and an id
    // with no record, which answers zero; after the parent is registered again its epoch is one higher while the
    // child keeps the parent epoch it was made in
    function testFuzz_parentOfEpochOfMatchRecord(uint256 ghost) public {
        uint256 kid = _subId("kid", club);
        vm.prank(alice);
        nft.registerSubpageFor("kid", club, carol);
        _matchesRecord(club);
        _matchesRecord(kid);
        assertEq(nft.parentOf(kid), club);
        assertEq(nft.epochOf(club), 1);

        (string memory label,,,,) = nft.records(ghost);
        vm.assume(bytes(label).length == 0);
        assertEq(nft.parentOf(ghost), 0, "a ghost id has no parent");
        assertEq(nft.epochOf(ghost), 0, "and no epoch");
        assertEq(nft.parentOf(0), 0);
        assertEq(nft.epochOf(0), 0);

        vm.warp(nft.expiresAt(club) + 111 days + 1);
        _reg(dave, "club");
        assertEq(nft.epochOf(club), 2, "the parent's epoch rises by one");
        (,,,, uint64 parentEpoch) = nft.records(kid);
        assertEq(parentEpoch, 1, "the child keeps the epoch it was made in");
        _matchesRecord(club);
        _matchesRecord(kid);
        assertEq(nft.getPageName(kid), "", "the stale child has no full name");
        assertEq(nft.parentOf(ghost), 0);
        assertEq(nft.epochOf(ghost), 0);
    }

    function _profile(uint256 id, address who) internal {
        vm.startPrank(who);
        nft.setAddr(id, dave);
        nft.setAddrForCoin(id, 60, abi.encodePacked(dave));
        nft.setAddrForCoin(id, BASE, abi.encodePacked(dave));
        nft.setAddrForCoin(id, BTC, hex"0014aa");
        nft.setText(id, "url", "https://kid.example");
        nft.setContenthash(id, hex"e30101");
        vm.stopPrank();
    }

    function _answers(uint256 id) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                nft.resolve(id), nft.addr(id, COIN_OP), nft.addr(id, 60), nft.addr(id, BASE), nft.addr(id, BTC),
                nft.text(id, "url"), nft.contenthash(id)
            )
        );
    }

    // no log of the call names the id
    function _nothingNames(Vm.Log[] memory logs, uint256 id) internal view {
        bytes32 meta = keccak256("MetadataUpdate(uint256)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(nft)) continue;
            for (uint256 t = 1; t < logs[i].topics.length; ++t) {
                assertTrue(logs[i].topics[t] != bytes32(id), "a log names the subpage");
            }
            if (logs[i].topics[0] == meta) assertTrue(abi.decode(logs[i].data, (uint256)) != id);
        }
    }

    // a subpage has its own records: the parent's holder cannot write them and its clear leaves them alone, the
    // subpage's holder clears them, and a take back by the parent's holder leaves nothing of them counting, also
    // when the subpage is handed back
    function test_subpageRecordsAreItsOwn() public {
        uint256 kid = _subId("kid", club);
        vm.prank(alice);
        nft.registerSubpageFor("kid", club, carol);
        _profile(kid, carol);
        bytes32 full = _answers(kid);

        vm.startPrank(alice);
        vm.expectRevert(PageNFT.Unauthorized.selector);
        nft.setAddr(kid, alice);
        vm.expectRevert(PageNFT.Unauthorized.selector);
        nft.setAddrForCoin(kid, BTC, hex"01");
        vm.expectRevert(PageNFT.Unauthorized.selector);
        nft.setText(kid, "url", "x");
        vm.expectRevert(PageNFT.Unauthorized.selector);
        nft.setContenthash(kid, hex"01");
        vm.expectRevert(PageNFT.Unauthorized.selector);
        nft.clearRecords(kid);
        vm.stopPrank();

        uint256 v = nft.recordVersion(kid);
        vm.recordLogs();
        vm.prank(alice);
        nft.clearRecords(club);
        _nothingNames(vm.getRecordedLogs(), kid);
        assertEq(nft.recordVersion(club), 1, "the parent's records are cleared");
        assertEq(nft.recordVersion(kid), v, "the subpage's version does not move");
        assertEq(_answers(kid), full, "and its records still answer");

        vm.prank(carol);
        nft.clearRecords(kid);
        assertEq(nft.recordVersion(kid), v + 1);
        assertEq(nft.resolve(kid), carol);
        assertEq(nft.addr(kid, BTC), "");
        assertEq(nft.text(kid, "url"), "");
        assertEq(nft.recordVersion(club), 1, "the subpage's clear leaves the parent alone");

        _profile(kid, carol);
        vm.recordLogs();
        vm.prank(alice);
        nft.registerSubpageFor("kid", club, alice);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 tVersion = keccak256("VersionChanged(bytes32,uint64)");
        uint256 n;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == tVersion && logs[i].topics[1] == bytes32(kid)) {
                ++n;
                assertEq(abi.decode(logs[i].data, (uint64)), v + 2);
            }
        }
        assertEq(n, 1, "the take back logs VersionChanged for the subpage");
        vm.prank(alice);
        nft.transferFrom(alice, carol, kid);
        assertEq(nft.resolve(kid), carol, "carol's earlier main address does not count");
        assertEq(nft.addr(kid, 60), "", "nor her earlier coin 60 entry");
        assertEq(nft.addr(kid, BASE), "", "nor her earlier Base entry");
        assertEq(nft.addr(kid, BTC), "");
        assertEq(nft.text(kid, "url"), "");
        assertEq(nft.contenthash(kid), "");
    }

    // a live subpage answers nothing while its parent is in grace and after its parent is registered again, its
    // payee stays where it was, and no log names it; a renewal of the parent in grace brings every answer back
    function test_subpageStopsResolvingWithItsParent() public {
        uint256 kid = _subId("kid", club);
        vm.prank(alice);
        nft.registerSubpageFor("kid", club, carol);
        _profile(kid, carol);
        vm.prank(carol);
        nft.setPrimaryPage(kid);
        bytes32 live = _answers(kid);
        address payee = nft.payee(kid);
        assertEq(payee, dave);
        assertEq(nft.reverseResolve(dave), "", "dave never chose it");
        assertEq(nft.reverseResolve(carol), "", "carol chose it but it points at dave");
        vm.prank(carol);
        nft.setAddr(kid, carol);
        assertEq(nft.reverseResolve(carol), "kid.club");
        live = _answers(kid);

        vm.warp(nft.expiresAt(club) + 1);
        _assertSilent(kid);
        assertEq(nft.payee(kid), carol, "the payee does not move");
        assertEq(nft.getPageName(kid), "kid.club");

        vm.recordLogs();
        uint256 fee = nft.getFee(4);
        vm.prank(stranger);
        nft.renew{value: fee}(club);
        _nothingNames(vm.getRecordedLogs(), kid);
        assertEq(_answers(kid), live, "a renewal in grace brings every answer back");
        assertEq(nft.reverseResolve(carol), "kid.club");

        vm.warp(nft.expiresAt(club) + 111 days + 1);
        vm.recordLogs();
        _reg(dave, "club");
        _nothingNames(vm.getRecordedLogs(), kid);
        _assertSilent(kid);
        assertEq(nft.payee(kid), carol);
        assertEq(nft.getPageName(kid), "", "stale");
    }

    function _assertSilent(uint256 kid) internal view {
        assertEq(nft.resolve(kid), address(0), "resolve");
        assertEq(nft.addr(bytes32(kid)), address(0), "addr(node)");
        assertEq(nft.addr(kid, COIN_OP), "", "OP");
        assertEq(nft.addr(kid, 60), "", "Ethereum");
        assertEq(nft.addr(kid, BASE), "", "Base");
        assertEq(nft.addr(kid, BTC), "", "Bitcoin");
        assertEq(nft.text(kid, "url"), "", "text");
        assertEq(nft.contenthash(kid), "", "contenthash");
        assertEq(nft.resolveAs(kid, carol), address(0), "resolveAs");
        assertEq(nft.reverseResolve(carol), "", "reverseResolve");
    }

    bytes constant HEAD = "abcdefghijklmnopqrstuvwxyz";
    bytes constant BODY = "abcdefghijklmnopqrstuvwxyz0123456789-";

    // a label the validator accepts: a letter first, no hyphen last, and never hyphens in both the 3rd and 4th place
    function _plain(uint256 seed, uint256 len) internal pure returns (string memory) {
        bytes memory b = new bytes(len);
        for (uint256 i; i < len; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            b[i] = i == 0 ? HEAD[seed % 26] : (i == len - 1 ? BODY[seed % 36] : BODY[seed % 37]);
        }
        if (len >= 4 && b[2] == "-" && b[3] == "-") b[3] = "a";
        return string(b);
    }

    function _upper(string memory s) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        for (uint256 i; i < b.length; ++i) {
            if (b[i] >= "a" && b[i] <= "z") b[i] = bytes1(uint8(b[i]) - 32);
        }
        return string(b);
    }

    // computeId of a full name gives back the id, for a top level name and for a live subpage, and the
    // subpage's full name in upper case gives the same id
    function testFuzz_fullNameRoundTrip(uint256 seedP, uint8 lenP, uint256 seedC, uint8 lenC) public {
        string memory pl = _plain(seedP, 1 + uint256(lenP) % 63);
        string memory cl = _plain(seedC, 1 + uint256(lenC) % 63);
        vm.assume(keccak256(bytes(pl)) != keccak256("club"));
        _roundTrip(pl, cl);
    }

    // the longest full name: a 63 character label under a 63 character parent
    function test_fullNameRoundTripLongest() public {
        bytes memory a = new bytes(63);
        bytes memory b = new bytes(63);
        for (uint256 i; i < 63; ++i) {
            a[i] = bytes1(uint8(97 + i % 26));
            b[i] = bytes1(uint8(48 + i % 10));
        }
        b[0] = "z";
        _roundTrip(string(a), string(b));
    }

    function _roundTrip(string memory pl, string memory cl) internal {
        uint256 p = _reg(bob, pl);
        vm.prank(bob);
        uint256 c = nft.registerSubpage(cl, p);
        assertEq(nft.getPageName(p), pl);
        assertEq(nft.getPageName(c), string.concat(cl, ".", pl));
        assertEq(nft.computeId(nft.getPageName(p)), p, "top level");
        assertEq(nft.computeId(nft.getPageName(c)), c, "subpage");
        assertEq(nft.computeId(_upper(nft.getPageName(c))), c, "upper case");
        // once the parent is registered again the subpage is stale and has no full name
        vm.warp(nft.expiresAt(p) + 111 days + 1);
        _reg(dave, pl);
        assertEq(nft.getPageName(c), "");
        assertEq(nft.computeId(nft.getPageName(p)), p);
    }
}

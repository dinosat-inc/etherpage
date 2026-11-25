// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Test, Vm} from "forge-std/Test.sol";
import {PageCard} from "../../../src/PageCard.sol";
import {PageNFT} from "../../../src/PageNFT.sol";
import {SubpageRegistrar, IPageNFT} from "../../../src/SubpageRegistrar.sol";
import {CardReader} from "../../utils/CardReader.sol";

contract LifeCycleTest is Test {
    PageCard card;
    PageNFT nft;
    SubpageRegistrar reg;
    CardReader reader;
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address dave = address(0xDA7E);
    address carol = address(0xCA201);
    address DEAD = 0x000000000000000000000000000000000000dEaD;

    function setUp() public {
        vm.warp(1_800_000_000);
        card = new PageCard();
        nft = new PageNFT(card);
        reg = new SubpageRegistrar(IPageNFT(address(nft)));
        vm.deal(alice, 1000 ether);
        vm.deal(bob, 1000 ether);
        vm.deal(dave, 1000 ether);
        vm.deal(carol, 1000 ether);
        reader = new CardReader();
    }

    function _register(address who, string memory label, uint256 ref) internal returns (uint256 id) {
        bytes32 secret = keccak256(abi.encode(who, label, block.timestamp));
        bytes32 commitment = nft.makeCommitment(label, who, ref, secret);
        vm.prank(who);
        nft.commit(commitment);
        vm.warp(block.timestamp + 61);
        (,,, uint256 total) = nft.quote(label);
        vm.prank(who);
        id = nft.reveal{value: total}(label, who, ref, secret);
    }

    // the left pill of an active top level page with expiry e
    function _until(uint256 e) internal view returns (string memory) {
        return reader.read(card.render("a", "", 0, PageCard.Status.Active, e)).left;
    }

    function test_dates() public view {
        assertEq(_until(0), "Until 1 Jan 1970");
        assertEq(_until(1835395200), "Until 29 Feb 2028");
        assertEq(_until(253402300799), "Until 31 Dec 9999");
        assertEq(
            _until(type(uint256).max),
            "Until 19 Feb 3669305236998687180674831492239425019668248843096144521164705134005822"
        );
        assertEq(card.shortAddress(0x12aB34CD56ef00000000000000000000007a9F3c), unicode"0x12ab34cd56ef…7a9f3c");
        assertEq(card.shortAddress(DEAD), unicode"0x000000000000…00dead");
        // a full name over 18 letters is cut with no dimmed part, and the left pill of an active subpage holds a dot
        // and its parent's label
        CardReader.Card memory c =
            reader.read(card.render("web3-builders", "optimism-rollup", 0, PageCard.Status.Active, 0));
        assertEq(c.name, unicode"web3-builders.opt…");
        assertEq(c.dimmed, "");
        assertEq(c.left, ".optimism-rollup");
        assertEq(c.dot, "");
    }

    function test_freshRegistrationLogs() public {
        bytes32 secret = bytes32("s");
        bytes32 commitment = nft.makeCommitment("alice", alice, 0, secret);
        vm.prank(alice);
        nft.commit(commitment);
        vm.warp(block.timestamp + 61);
        vm.recordLogs();
        vm.prank(alice);
        nft.reveal{value: 1 ether}("alice", alice, 0, secret);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 8);
        assertEq(logs[0].topics[0], PageNFT.ReferrerSet.selector);
        assertEq(logs[1].topics[0], PageNFT.DepositAdded.selector);
        assertEq(logs[6].topics[0], PageNFT.PageRegistered.selector);
        assertEq(logs[7].topics[0], PageNFT.MetadataUpdate.selector);
    }

    // clearRecords logs VersionChanged first and MetadataUpdate last, and empties the records
    function test_clearRecordsOrderAndGas() public {
        uint256 id = _register(alice, "alice", 0);
        vm.startPrank(alice);
        nft.setText(id, "k", "v");
        nft.setContenthash(id, hex"01");
        nft.setAddrForCoin(id, 0, hex"aa");
        vm.recordLogs();
        uint256 g = gasleft();
        nft.clearRecords(id);
        g = g - gasleft();
        vm.stopPrank();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 5);
        assertEq(logs[0].topics[0], PageNFT.VersionChanged.selector);
        assertEq(logs[4].topics[0], PageNFT.MetadataUpdate.selector);
        assertEq(nft.text(id, "k"), "");
        emit log_named_uint("clearRecords execution gas, warm name", g);
    }

    // a full life cycle: a year with a referrer, a renewal by someone else, an auction whose premium
    // is split between the payee and the referrer, then a release of the deposit
    function test_workedLifeCycle() public {
        uint256 bobId = _register(bob, "bob", 0);
        bytes32 secret = bytes32("a");
        bytes32 commitment = nft.makeCommitment("alice", alice, bobId, secret);
        vm.prank(alice);
        nft.commit(commitment);
        vm.warp(block.timestamp + 61);
        uint256 t0 = 1_800_000_122;
        vm.prank(alice);
        uint256 id = nft.reveal{value: 0.001 ether}("alice", alice, bobId, secret);
        assertEq(nft.depositOf(id), 0.0001 ether);
        address aPayout = address(0xA9);
        vm.warp(t0 + 120 days);
        vm.prank(alice);
        nft.setAddr(id, aPayout);
        vm.warp(t0 + 200 days);
        vm.prank(carol);
        nft.renew{value: 0.0001 ether}(id);
        assertEq(nft.expiresAt(id), t0 + 730 days);
        uint256 buyAt = t0 + 820 days + 725760;
        vm.warp(buyAt - 61);
        bytes32 commitment2 = nft.makeCommitment("alice", dave, 0, bytes32("d"));
        vm.prank(dave);
        nft.commit(commitment2);
        vm.warp(buyAt);
        assertEq(nft.getPremium(id), 6 ether);
        vm.prank(dave);
        nft.reveal{value: 7 ether}("alice", dave, 0, bytes32("d"));
        assertEq(nft.owed(aPayout), 4.5002 ether);
        assertEq(nft.owed(bob), 1.5 ether);
        assertEq(nft.depositOf(id), 0.0003 ether);
        vm.warp(buyAt + 365 days + 111 days + 1);
        nft.release(id);
        assertEq(nft.owed(dave), 0.0003 ether);
    }
}

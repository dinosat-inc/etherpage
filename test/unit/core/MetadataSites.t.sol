// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Vm} from "forge-std/Test.sol";
import {RulesBase} from "../../utils/RulesBase.sol";

// MetadataUpdate comes from six places: a registration, a renewal, a paid release, a main address save,
// clearRecords and a move between two accounts. Every other call logs none, and of those only a subpage mint
// changes a card, the card of the subpage it mints.
contract MetadataSitesTest is RulesBase {
    uint256 constant BASE = 0x80002105;
    uint256 constant BTC = 0;
    uint256 constant OP = 0x8000000a;

    uint256 seen;

    // the MetadataUpdate logs of nft in the step just run; when the step has one, it names id and is the step's
    // last log of nft
    function _step(uint256 id, uint256 want, string memory what) internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 n;
        uint256 last = type(uint256).max;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(nft)) continue;
            last = i;
            if (logs[i].topics[0] == T_META) {
                ++n;
                assertEq(abi.decode(logs[i].data, (uint256)), id, string.concat(what, ": the id"));
            }
        }
        assertEq(n, want, what);
        if (want != 0) assertEq(logs[last].topics[0], T_META, string.concat(what, ": the last log"));
        seen += n;
    }

    // one scripted run that reaches each of the six sites once and every other writer at least once
    function test_metadataUpdateSitesExact() public {
        // a trial that will have ended by the time it is released, started before the count begins
        uint256 tr = _trial("trial", user);
        vm.recordLogs();

        uint256 id = _buy(bob, "alpha");
        _step(id, 1, "commit and reveal");

        uint256 fee = nft.getFee(5);
        vm.prank(carol);
        nft.renew{value: fee}(id);
        _step(id, 1, "renew");

        vm.prank(bob);
        nft.setAddr(id, dave);
        _step(id, 1, "setAddr");

        vm.startPrank(bob);
        nft.setAddrForCoin(id, 60, abi.encodePacked(dave));
        _step(id, 0, "setAddrForCoin for Ethereum");
        nft.setAddrForCoin(id, BASE, abi.encodePacked(carol));
        _step(id, 0, "setAddrForCoin for another EVM chain");
        nft.setAddrForCoin(id, BTC, hex"0014aabbcc");
        _step(id, 0, "setAddrForCoin for a chain outside the EVM");
        nft.setText(id, "avatar", "ipfs://a");
        _step(id, 0, "setText");
        nft.setContenthash(id, hex"e30101");
        _step(id, 0, "setContenthash");
        nft.setPrimaryPage(id);
        _step(id, 0, "setPrimaryPage");
        nft.setSubpageMinter(id, dave);
        _step(id, 0, "setSubpageMinter");
        uint256 sub = nft.registerSubpage("sub", id);
        _step(sub, 0, "registerSubpage");
        nft.registerSubpageFor("kid", id, carol);
        _step(id, 0, "registerSubpageFor");
        nft.registerSubpageFor("kid", id, user);
        _step(id, 0, "a mint over a live subpage, which burns it");
        nft.transferFrom(bob, bob, id);
        _step(id, 0, "a move to the holder itself");
        nft.approve(carol, id);
        _step(id, 0, "approve");
        nft.setApprovalForAll(carol, true);
        _step(id, 0, "setApprovalForAll");
        nft.clearRecords(id);
        _step(id, 1, "clearRecords");
        nft.transferFrom(bob, carol, id);
        _step(id, 1, "transferFrom");
        vm.stopPrank();

        vm.startPrank(carol);
        nft.keepProfile(id);
        _step(id, 0, "keepProfile");
        nft.setPrimaryPage(0);
        _step(id, 0, "setPrimaryPage(0)");
        nft.commit(keccak256("a commitment"));
        _step(id, 0, "commit");
        vm.stopPrank();

        vm.warp(nft.expiresAt(id) + 90 days + 21 days + 1);
        nft.release(tr);
        _step(tr, 0, "release of an ended trial");
        nft.withdraw(relayer);
        _step(tr, 0, "withdraw");
        nft.release(id);
        _step(id, 1, "release");
        nft.withdraw(carol);
        _step(id, 0, "withdraw of the released deposit");

        assertEq(seen, 6, "one MetadataUpdate for each of the six sites");
    }

    // the record writers that do not touch the main address, and a subpage mint, leave the metadata as it was
    function test_noMetadataUpdateForOtherRecords() public {
        uint256 id = _buy(bob, "alpha");
        string memory uri = nft.tokenURI(id);
        bytes[7] memory calls = [
            abi.encodeCall(nft.setAddrForCoin, (id, 60, abi.encodePacked(dave))),
            abi.encodeCall(nft.setAddrForCoin, (id, BASE, abi.encodePacked(dave))),
            abi.encodeCall(nft.setAddrForCoin, (id, BTC, bytes("bc1qexample"))),
            abi.encodeCall(nft.setText, (id, "avatar", "ipfs://a")),
            abi.encodeCall(nft.setContenthash, (id, hex"e30101")),
            abi.encodeCall(nft.registerSubpage, ("sub", id)),
            abi.encodeCall(nft.registerSubpageFor, ("kid", id, carol))
        ];
        for (uint256 i; i < calls.length; ++i) {
            vm.recordLogs();
            vm.prank(bob);
            (bool ok,) = address(nft).call(calls[i]);
            assertTrue(ok, string.concat("call ", vm.toString(i)));
            Vm.Log[] memory logs = vm.getRecordedLogs();
            assertGt(logs.length, 0, "the call logged its own events");
            assertEq(_count(logs, T_META), 0, string.concat("no MetadataUpdate, call ", vm.toString(i)));
            assertEq(nft.tokenURI(id), uri, string.concat("the metadata is unchanged, call ", vm.toString(i)));
        }
        // the OP answer is the one record that moves the metadata, through the payee its description shows
        vm.prank(bob);
        nft.setAddrForCoin(id, OP, abi.encodePacked(dave));
        assertTrue(
            keccak256(bytes(nft.tokenURI(id))) != keccak256(bytes(uri)), "a new main address changes the metadata"
        );
    }
}

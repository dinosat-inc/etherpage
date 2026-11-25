// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Vm} from "forge-std/Test.sol";
import {ProfileBase} from "../utils/ProfileBase.sol";
import {StorageReader} from "../utils/NamingBase.sol";

// A keep after a clear brings back no text and no website, the profile key holds the record version above the
// profile counter, and resolveAs judges whether a name is active with its current holder.
contract PageNFTClaimsEndTest is ProfileBase {
    address hot = makeAddr("hot");

    function _at(bytes32 slot) internal view returns (bytes32) {
        return vm.load(address(nft), slot);
    }

    // where a text entry of id is stored, under _text at slot 10, then id, then the profile key, then the text key
    function _textEntry(uint256 id, uint256 key, string memory k) internal pure returns (bytes32) {
        bytes32 inner = keccak256(abi.encode(key, keccak256(abi.encode(id, uint256(10)))));
        return keccak256(abi.encodePacked(bytes(k), inner));
    }

    // where the website of id is stored, under _contenthash at slot 8, then id, then the profile key
    function _siteEntry(uint256 id, uint256 key) internal pure returns (bytes32) {
        return keccak256(abi.encode(key, keccak256(abi.encode(id, uint256(8)))));
    }

    // a value under 32 bytes as storage keeps it, the bytes from the top and twice the length in the last byte
    function _short(bytes memory b) internal pure returns (bytes32) {
        uint256 w = b.length * 2;
        for (uint256 i; i < b.length; ++i) w |= uint256(uint8(b[i])) << (248 - 8 * i);
        return bytes32(w);
    }

    // the buyer clears and keeps what it found and sees no text and no website, nor does the account that wrote
    // them once it has the name back and keeps, although both are still stored
    function test_keepAfterAClearBringsBackNoTextOrWebsite() public {
        uint256 id = _profiled(user, "alice");
        _move(user, bob, id);
        vm.prank(bob);
        nft.clearRecords(id);
        vm.recordLogs();
        _keep(bob, id);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "one writer event");
        _assertPwc(logs[0], id, bob, false);
        assertEq(nft.profileWriter(id), bob);
        _assertEmpty(id);
        _move(bob, user, id);
        _keep(user, id);
        assertEq(nft.profileWriter(id), user);
        _assertEmpty(id);
        assertEq(uint256(_at(_textEntry(id, 0, "avatar"))), bytes(PUNK).length * 2 + 1, "the old avatar is stored");
        assertEq(uint256(_at(_siteEntry(id, 0))), SITE.length * 2 + 1, "the old website is stored");
    }

    // with record version 2 and profile counter 1 the key is 2 shifted 96 bits up plus 1, and the swapped order
    // holds nothing
    function test_profileKeyHasTheRecordVersionAboveTheProfileCounter() public {
        uint256 id = _buy(bob, "alice");
        vm.prank(bob);
        nft.setText(id, "k", "old");
        _move(bob, carol, id);
        vm.startPrank(carol);
        nft.setText(id, "k", "new");
        nft.clearRecords(id);
        nft.clearRecords(id);
        nft.setText(id, "k", "x");
        nft.setContenthash(id, hex"e301");
        vm.stopPrank();
        assertEq(nft.recordVersion(id), 2, "record version");
        bytes32 word = _at(keccak256(abi.encode(id, uint256(15))));
        assertEq(uint256(word), uint256(uint160(carol)) | (uint256(1) << 160), "carol writes at profile counter 1");

        uint256 key = (uint256(2) << 96) | 1;
        assertEq(_at(_textEntry(id, key, "k")), _short(bytes("x")), "text under the key");
        assertEq(_at(_siteEntry(id, key)), _short(hex"e301"), "website under the key");
        assertEq(_at(_textEntry(id, (uint256(1) << 96) | 2, "k")), bytes32(0), "nothing under the swapped order");
        // record version 0 leaves the key equal to the profile counter
        assertEq(_at(_textEntry(id, 0, "k")), _short(bytes("old")), "bob at counter 0");
        assertEq(_at(_textEntry(id, 1, "k")), _short(bytes("new")), "carol at counter 1");

        assertEq(nft.text(id, "k"), "x");
        assertEq(nft.contenthash(id), hex"e301");
        // a storage proof reader that builds the key the same way gets the same answers
        StorageReader reader = new StorageReader(address(nft));
        assertEq(reader.text(id, "k"), "x", "reader text");
        assertEq(reader.contenthash(id), hex"e301", "reader website");
    }

    // a live subpage answers DEAD for DEAD although DEAD holding it would delete it, and once DEAD holds it the
    // account that saved an address on it gets nothing
    function test_resolveAsJudgesActivityWithTheCurrentHolder() public {
        uint256 club = _paid(user, "club");
        vm.prank(user);
        uint256 kid = nft.registerSubpageFor("kid", club, bob);
        vm.prank(bob);
        nft.setAddr(kid, hot);
        assertEq(nft.resolve(kid), hot);
        assertEq(nft.resolveAs(kid, DEAD), DEAD, "judged with bob, so active");
        assertEq(nft.resolveAs(kid, carol), carol);
        _move(bob, DEAD, kid);
        assertEq(nft.resolve(kid), address(0), "what resolve answers once DEAD holds it");
        assertEq(nft.resolveAs(kid, bob), address(0), "judged with DEAD, so not active");
    }
}

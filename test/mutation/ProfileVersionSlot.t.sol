// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {RulesBase} from "../utils/RulesBase.sol";

// The profile of a name is stored in the mapping at slot 15 under its id: the writer in the low 160 bits and the
// version above them. The version moves only when an account writes while the profile has another writer, whether
// that writer wrote or only kept it. No view returns the version, so these tests read the slot.
contract ProfileVersionSlotTest is RulesBase {
    function _stored(uint256 id) internal view returns (uint256) {
        return uint256(vm.load(address(nft), keccak256(abi.encode(id, uint256(15)))));
    }

    function _word(address writer, uint256 version) internal pure returns (uint256) {
        return uint256(uint160(writer)) | version << 160;
    }

    // the first write sets the writer at version 0, the writer writing again changes nothing, a new holder
    // writing moves to version 1, and keeping changes only the writer
    function test_storageSlot15VersionMovesOnlyOverAnotherWriter() public {
        uint256 id = _buy(bob, "alice");
        assertEq(_stored(id), 0, "nothing stored before the first write");

        vm.prank(bob);
        nft.setText(id, "k", "v1");
        assertEq(_stored(id), _word(bob, 0), "the first write keeps version 0");
        assertEq(nft.profileWriter(id), bob, "the slot holds the writer the view returns");

        vm.prank(bob);
        nft.setContenthash(id, hex"e301");
        assertEq(_stored(id), _word(bob, 0), "the writer writing again");

        vm.prank(bob);
        nft.transferFrom(bob, carol, id);
        vm.prank(carol);
        nft.setText(id, "k", "v2");
        assertEq(_stored(id), _word(carol, 1), "a new holder writing over bob's profile");

        vm.prank(carol);
        nft.transferFrom(carol, bob, id);
        vm.prank(bob);
        nft.keepProfile(id);
        assertEq(_stored(id), _word(bob, 1), "keeping changes only the writer");
        assertEq(nft.text(id, "k"), "v2", "bob reads the profile he kept");
    }

    // the profile key puts the record version above the profile version, so clearing a profile that a new
    // holder started at version 1 leaves nothing to read
    function test_clearAfterAFreshStartEmptiesTheProfile() public {
        uint256 id = _buy(bob, "alice");
        vm.prank(bob);
        nft.setText(id, "k", "old");
        vm.prank(bob);
        nft.transferFrom(bob, carol, id);
        vm.startPrank(carol);
        nft.setText(id, "k", "new");
        nft.setContenthash(id, hex"e301");
        vm.stopPrank();
        assertEq(_stored(id), _word(carol, 1), "carol writes at version 1");
        assertEq(nft.text(id, "k"), "new");

        vm.prank(carol);
        nft.clearRecords(id);
        assertEq(nft.recordVersion(id), 1, "the clear moved the record version");
        assertEq(nft.text(id, "k"), "", "the text is gone");
        assertEq(nft.contenthash(id), bytes(""), "the website is gone");
        assertEq(_stored(id), _word(carol, 1), "the clear leaves the writer and version");
    }

    // on a subpage too the first write keeps version 0, and a holder who keeps first never moves it
    function test_firstWriteOrKeepOnASubpageKeepsVersionZero() public {
        uint256 parent = _buy(bob, "club");
        vm.prank(bob);
        uint256 sub = nft.registerSubpageFor("one", parent, carol);
        vm.prank(bob);
        uint256 other = nft.registerSubpageFor("two", parent, dave);

        vm.prank(carol);
        nft.setText(sub, "k", "v");
        assertEq(_stored(sub), _word(carol, 0), "the first write on a subpage");

        vm.prank(dave);
        nft.keepProfile(other);
        assertEq(_stored(other), _word(dave, 0), "keeping an empty profile");
        vm.prank(dave);
        nft.setText(other, "k", "v");
        assertEq(_stored(other), _word(dave, 0), "writing after keeping");
    }
}

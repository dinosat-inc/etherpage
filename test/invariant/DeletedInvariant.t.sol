// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {PageNFT} from "../../src/PageNFT.sol";
import {PageCard} from "../../src/PageCard.sol";
import {DeletedHandler} from "./DeletedHandler.sol";

// A page held by the dead address is deleted, a top level page as well as a subpage. Whatever happened
// before and after, it resolves to nothing, has no address for any coin, no text, no website and no data,
// shows as Invalid, and no address shows it as its display name. Nobody can write to it or move it. A
// deleted top level page stays taken until its grace period ends, and nobody can create a subpage under
// it, while the subpages it already has keep working. A data record counts only while the account that
// saved it holds the page.
contract DeletedInvariantTest is Test {
    PageNFT nft;
    DeletedHandler h;

    function setUp() public {
        vm.warp(1_800_000_000);
        nft = new PageNFT(new PageCard());
        h = new DeletedHandler(nft);
        bytes4[] memory sels = new bytes4[](10);
        sels[0] = DeletedHandler.mintSub.selector;
        sels[1] = DeletedHandler.minterMint.selector;
        sels[2] = DeletedHandler.write.selector;
        sels[3] = DeletedHandler.choose.selector;
        sels[4] = DeletedHandler.move.selector;
        sels[5] = DeletedHandler.touchDeleted.selector;
        sels[6] = DeletedHandler.warp.selector;
        sels[7] = DeletedHandler.renewParent.selector;
        sels[8] = DeletedHandler.moveParent.selector;
        sels[9] = DeletedHandler.reregisterParent.selector;
        targetSelector(FuzzSelector({addr: address(h), selectors: sels}));
        targetContract(address(h));
    }

    // the starting state already holds a deleted subpage with records, and the address it pointed at
    // still names it as its display name
    function test_startStateHasADeletedSubpage() public view {
        uint256 id = h.subs(0);
        assertEq(nft.ownerOf(id), address(0xdEaD));
        assertEq(nft.primaryPage(h.actors(3)), 0);
        assertEq(nft.primaryPage(h.actors(2)), id);
        assertEq(nft.reverseResolve(h.actors(2)), "");
        h.checkDeleted();
        h.checkData();
    }

    function invariant_deletedAnswersNothing() public view {
        h.checkDeleted();
    }

    function invariant_deletedCannotBeWrittenOrMoved() public view {
        assertFalse(h.deletedWriteWorked(), "a write or a display name choice on a deleted page worked");
        assertFalse(h.deadMoveWorked(), "a deleted page moved away from the dead address");
        assertFalse(h.deadParentMintWorked(), "a subpage was created or a minter picked under a deleted parent");
    }

    function invariant_dataFollowsTheAddressRule() public view {
        h.checkData();
        assertFalse(h.strangerDataWorked(), "an account that does not hold a page saved a data record");
    }

    // one call of the walk: r picks one of the campaign's ten actions and gives its seeds
    function _step(uint256 r) internal {
        uint256 x = r >> 8;
        uint256 y = r >> 72;
        uint256 z = r >> 136;
        uint256 w = r >> 200;
        uint256 a = r % 10;
        if (a == 0) h.mintSub(x, y, z);
        else if (a == 1) h.minterMint(x, y, z, w);
        else if (a == 2) h.write(x, y, z);
        else if (a == 3) h.choose(x, y % 2 == 0);
        else if (a == 4) h.move(x, y, z % 2 == 0);
        else if (a == 5) h.touchDeleted(x, y, z);
        else if (a == 6) h.warp(x);
        else if (a == 7) h.renewParent(x);
        else if (a == 8) h.moveParent(x, y);
        else h.reregisterParent(x, y);
    }

    // Walks from fixed seeds through the same handler, 32 runs of 64 calls each, as deep as a run of the default
    // campaign. Each run starts from the state setUp leaves, and the checks of all three invariants run after every
    // call. Together they must delete subpages beyond the starting one and delete parents, create deleted subpages
    // again, register a lapsed parent again, a deleted one among them, write data records, end calls with a deleted
    // subpage in place and end calls with a live subpage under a deleted parent.
    function test_walkReachesDeletionsAndRecreations() public {
        uint256 deletions;
        uint256 parentDeletions;
        uint256 recreations;
        uint256 registrations;
        uint256 deadRegistrations;
        uint256 dataWrites;
        uint256 deletedStates;
        uint256 liveUnderDead;
        uint256 startDeletions = h.deletions();
        uint256 startRegistrations = h.parentRegistrations();
        uint256 startDataWrites = h.dataWrites();
        for (uint256 run; run < 32; ++run) {
            uint256 snap = vm.snapshotState();
            for (uint256 i; i < 64; ++i) {
                _step(uint256(keccak256(abi.encode("deleted walk", run, i))));
                h.checkDeleted();
                h.checkData();
                assertFalse(h.deletedWriteWorked(), "a write or a display name choice on a deleted page worked");
                assertFalse(h.deadMoveWorked(), "a deleted page moved away from the dead address");
                assertFalse(h.deadParentMintWorked(), "a subpage was created or a minter picked under a deleted parent");
                assertFalse(h.strangerDataWorked(), "an account that does not hold a page saved a data record");
            }
            deletions += h.deletions() - startDeletions;
            parentDeletions += h.parentDeletions();
            recreations += h.recreations();
            registrations += h.parentRegistrations() - startRegistrations;
            deadRegistrations += h.deadParentsRegisteredAgain();
            dataWrites += h.dataWrites() - startDataWrites;
            deletedStates += h.deletedStates();
            liveUnderDead += h.liveSubpagesUnderADeadParent();
            vm.revertToState(snap);
        }
        emit log_named_uint("deletions", deletions);
        emit log_named_uint("parent deletions", parentDeletions);
        emit log_named_uint("created again", recreations);
        emit log_named_uint("parent registrations", registrations);
        emit log_named_uint("deleted parents registered again", deadRegistrations);
        emit log_named_uint("data writes", dataWrites);
        emit log_named_uint("calls ending with a deleted subpage", deletedStates);
        emit log_named_uint("live subpages under a deleted parent at the end of a call", liveUnderDead);
        assertGt(deletions - parentDeletions, 0, "the walks deleted subpages");
        assertGt(parentDeletions, 0, "the walks deleted parents");
        assertGt(recreations, 0, "the walks created deleted subpages again");
        assertGt(registrations, 0, "a lapsed parent was registered again");
        assertGt(deadRegistrations, 0, "a deleted parent was registered again");
        assertGt(dataWrites, 0, "the walks wrote data records");
        assertGt(deletedStates, 0, "calls ended with a deleted subpage in place");
        assertGt(liveUnderDead, 0, "calls ended with a live subpage under a deleted parent");
    }

    function afterInvariant() public {
        vm.createDir("logs", true);
        string memory a = string.concat(
            vm.toString(h.deletions()), " deletions, ", vm.toString(h.parentDeletions()), " parent deletions, ",
            vm.toString(h.recreations()), " created again, ", vm.toString(h.recordWrites()), " record writes, ",
            vm.toString(h.dataWrites()), " data writes, ", vm.toString(h.primaryChoices()), " display names, "
        );
        string memory b = string.concat(
            vm.toString(h.parentRegistrations()), " parent registrations, ", vm.toString(h.deadParentsRegisteredAgain()),
            " deleted parents registered again, ", vm.toString(h.deletedStates()), " calls ending with a deleted subpage, ",
            vm.toString(h.liveSubpagesUnderADeadParent()), " live subpages under a deleted parent"
        );
        vm.writeLine("logs/deleted-inv-stats.txt", string.concat(a, b));
    }
}

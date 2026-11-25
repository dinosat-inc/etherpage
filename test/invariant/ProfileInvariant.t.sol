// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {PageNFT} from "../../src/PageNFT.sol";
import {PageCard} from "../../src/PageCard.sol";
import {ProfileHandler} from "./ProfileHandler.sol";

contract ProfileInvariantTest is Test {
    PageNFT nft;
    ProfileHandler h;

    function setUp() public {
        vm.warp(1_800_000_000);
        nft = new PageNFT(new PageCard());
        h = new ProfileHandler(nft);
        targetContract(address(h));
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = ProfileHandler.checkViews.selector;
        excludeSelector(FuzzSelector({addr: address(h), selectors: sels}));
    }

    // text and website equal the model: shown only while the writer holds an active name, never a
    // discarded value, and the stored writer equals the model's
    function invariant_profileModel() public {
        h.checkViews();
    }

    function invariant_walkFlags() public view {
        assertFalse(h.outcomeWrong(), "a write, keep or bundle succeeded or failed against the rule");
        assertFalse(h.logsWrong(), "a write or keep logged other writer events than predicted");
        assertFalse(h.wrongOrderPassed(), "a write then keep bundle succeeded");
        assertFalse(h.lockout(), "the holder of an active name could not make a profile count");
    }

    function afterInvariant() public {
        string memory a = string.concat(
            vm.toString(h.writes()), " writes, ", vm.toString(h.freshStarts()), " fresh starts, ",
            vm.toString(h.keeps()), " keeps, ", vm.toString(h.clears()), " clears, ", vm.toString(h.moves()),
            " moves, ", vm.toString(h.vaultReturns()), " vault returns, "
        );
        string memory b = string.concat(
            vm.toString(h.takeBacks()), " subpage re-mints, ", vm.toString(h.registrations()), " registrations, ",
            vm.toString(h.bundlesOk()), " bundles ok, ", vm.toString(h.shown()), " shown reads, ",
            vm.toString(h.hiddenNonEmpty()), " hidden non-empty reads, ", vm.toString(h.lockoutChecks()), " lockout probes"
        );
        vm.createDir("logs", true);
        vm.writeLine("logs/profile-inv-stats.txt", string.concat(a, b));
    }
}

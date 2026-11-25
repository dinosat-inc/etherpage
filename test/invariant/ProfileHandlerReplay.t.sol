// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {PageCard} from "../../src/PageCard.sol";
import {PageNFT} from "../../src/PageNFT.sol";
import {SubpageRegistrar, IPageNFT} from "../../src/SubpageRegistrar.sol";
import {MinterHandler} from "./MinterHandler.sol";
import {MulticallHandler} from "./MulticallHandler.sol";

// Two fixed sequences that write a profile entry around a transfer or a new registration, replayed
// through the minter and bundle handlers, then every check of their invariant_all.
contract ProfileHandlerReplayTest is Test {
    function _all(MinterHandler h) internal view {
        h.checkRecords();
        h.checkMinter();
        h.checkSaverRule();
        h.checkPrimary();
        h.checkLedgers();
        h.checkRegistrarHolds();
        h.checkMintLog();
        h.checkConfig();
        h.checkAvailability();
        h.checkIndexer();
        h.checkPrimaryIndexer();
        h.checkSellerPointer();
        h.checkTimes();
        h.checkData();
    }

    function _world(bool bundles) internal returns (MinterHandler h) {
        vm.warp(1_800_000_000);
        PageNFT nft = new PageNFT(new PageCard());
        SubpageRegistrar reg = new SubpageRegistrar(IPageNFT(address(nft)));
        h = bundles ? new MulticallHandler(nft, reg) : new MinterHandler(nft, reg);
        h.bootstrap();
    }

    function test_replayMinterContenthash() public {
        MinterHandler h = _world(false);
        h.act_approve(11232000, 106046339995222097249874710545505103470809395875400680024009445023254280220551, 14844070);
        h.act_setProfile(23338, 9590400, 6);
        h.act_transfer(9749, 38, 1506923580, 23274);
        _all(h);
    }

    function test_replayMulticallContenthash() public {
        MulticallHandler h = MulticallHandler(address(_world(true)));
        h.act_expireAndRegister(6135450406147532964077033416721918068, 2867708381051, 6473639094818241199289676381831196411093468316284678193187023192673672844139, 7);
        h.act_expireAndRegister(18, 22223, 5, 17);
        h.act_setProfile(121434947392, 1979551200492612175789964529124, 30700537816228029);
        h.act_bundle(8040, 100, 9, 365);
        _all(h);
    }
}

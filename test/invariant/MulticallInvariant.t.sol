// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {PageCard} from "../../src/PageCard.sol";
import {PageNFT} from "../../src/PageNFT.sol";
import {SubpageRegistrar, IPageNFT} from "../../src/SubpageRegistrar.sol";
import {MinterHandler} from "./MinterHandler.sol";
import {MulticallHandler} from "./MulticallHandler.sol";

// The minter campaign with bundles added: every action of the minter campaign plus act_bundle,
// which runs random actions as one multicall and checks it against the same actions one by one.
contract MulticallInvariantTest is Test {
    PageNFT nft;
    SubpageRegistrar reg;
    MulticallHandler h;

    function setUp() public {
        vm.warp(1_800_000_000);
        PageCard card = new PageCard();
        nft = new PageNFT(card);
        reg = new SubpageRegistrar(IPageNFT(address(nft)));
        h = new MulticallHandler(nft, reg);
        h.bootstrap();

        bytes4[] memory sels = new bytes4[](41);
        sels[0] = MinterHandler.act_register.selector;
        sels[1] = MinterHandler.act_expireAndRegister.selector;
        sels[2] = MinterHandler.act_renew.selector;
        sels[3] = MinterHandler.act_transfer.selector;
        sels[4] = MinterHandler.act_approve.selector;
        sels[5] = MinterHandler.act_setApprovalForAll.selector;
        sels[6] = MinterHandler.act_setMinter.selector;
        sels[7] = MinterHandler.act_mint.selector;
        sels[8] = MinterHandler.act_configure.selector;
        sels[9] = MinterHandler.act_disable.selector;
        sels[10] = MinterHandler.act_sell.selector;
        sels[11] = MinterHandler.act_claim.selector;
        sels[12] = MinterHandler.act_withdraw.selector;
        sels[13] = MinterHandler.act_release.selector;
        sels[14] = MinterHandler.act_warp.selector;
        sels[15] = MinterHandler.act_setAddr.selector;
        sels[16] = MinterHandler.act_clearRecords.selector;
        sels[17] = MinterHandler.act_setPrimary.selector;
        // some actions are listed more than once, in case the fuzzer weights by entries
        sels[18] = MinterHandler.act_mint.selector;
        sels[19] = MinterHandler.act_sell.selector;
        sels[20] = MinterHandler.act_setMinter.selector;
        sels[21] = MinterHandler.act_setupSale.selector;
        sels[22] = MinterHandler.act_minterRoutine.selector;
        sels[23] = MinterHandler.act_minterRoutine.selector;
        sels[24] = MinterHandler.act_minterOverreach.selector;
        sels[25] = MinterHandler.act_subToDead.selector;
        sels[26] = MinterHandler.act_remintToDead.selector;
        sels[27] = MinterHandler.act_recycleMint.selector;
        sels[28] = MinterHandler.act_subToDead.selector;
        sels[29] = MinterHandler.act_setProfile.selector;
        sels[30] = MinterHandler.act_setProfile.selector;
        sels[31] = MinterHandler.act_setData.selector;
        sels[32] = MinterHandler.act_setData.selector;
        for (uint256 i = 33; i < 41; ++i) sels[i] = MulticallHandler.act_bundle.selector;
        targetContract(address(h));
        targetSelector(FuzzSelector({addr: address(h), selectors: sels}));
    }

    // every property after every call of the same sequence
    function invariant_all() public view {
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

    // one line of coverage counters per run, to be summed across runs
    function afterInvariant() public {
        string memory path = vm.envOr("INV_STATS", string(""));
        if (bytes(path).length == 0) return;
        vm.writeLine(path, string.concat("mints=", vm.toString(h.mintLogLength()), ",", h.statLine()));
    }
}

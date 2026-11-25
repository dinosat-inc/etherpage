// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {PageCard} from "../../src/PageCard.sol";
import {PageNFT} from "../../src/PageNFT.sol";
import {SubpageRegistrar, IPageNFT} from "../../src/SubpageRegistrar.sol";
import {MinterHandler} from "./MinterHandler.sol";

// MinterInvariantTest with renew drawn ten times as often, so names reach the renewal horizon of 3650 days.
// A campaign driven by the handler over PageNFT and the registrar, which sells only as a minter. The
// handler predicts every call's outcome from its own model and reverts on a mismatch (fail_on_revert
// is on); the invariants below compare the whole observable state with the model after every call.
contract MinterInvariantRenewTest is Test {
    PageNFT nft;
    SubpageRegistrar reg;
    MinterHandler h;

    function setUp() public {
        vm.warp(1_800_000_000);
        PageCard card = new PageCard();
        nft = new PageNFT(card);
        reg = new SubpageRegistrar(IPageNFT(address(nft)));
        h = new MinterHandler(nft, reg);
        h.bootstrap();

        // every action once and renew ten times, with no extra warps
        bytes4[] memory sels = new bytes4[](35);
        uint256 k;
        sels[k++] = MinterHandler.act_register.selector;
        sels[k++] = MinterHandler.act_expireAndRegister.selector;
        for (uint256 i; i < 10; ++i) sels[k++] = MinterHandler.act_renew.selector;
        sels[k++] = MinterHandler.act_transfer.selector;
        sels[k++] = MinterHandler.act_approve.selector;
        sels[k++] = MinterHandler.act_setApprovalForAll.selector;
        sels[k++] = MinterHandler.act_setMinter.selector;
        sels[k++] = MinterHandler.act_mint.selector;
        sels[k++] = MinterHandler.act_configure.selector;
        sels[k++] = MinterHandler.act_disable.selector;
        sels[k++] = MinterHandler.act_sell.selector;
        sels[k++] = MinterHandler.act_claim.selector;
        sels[k++] = MinterHandler.act_withdraw.selector;
        sels[k++] = MinterHandler.act_release.selector;
        sels[k++] = MinterHandler.act_warp.selector;
        sels[k++] = MinterHandler.act_setAddr.selector;
        sels[k++] = MinterHandler.act_clearRecords.selector;
        sels[k++] = MinterHandler.act_setPrimary.selector;
        sels[k++] = MinterHandler.act_setupSale.selector;
        sels[k++] = MinterHandler.act_minterRoutine.selector;
        sels[k++] = MinterHandler.act_minterOverreach.selector;
        sels[k++] = MinterHandler.act_subToDead.selector;
        sels[k++] = MinterHandler.act_remintToDead.selector;
        sels[k++] = MinterHandler.act_recycleMint.selector;
        sels[k++] = MinterHandler.act_setProfile.selector;
        sels[k++] = MinterHandler.act_setData.selector;
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

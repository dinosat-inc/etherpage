// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {PageNFT} from "../../src/PageNFT.sol";
import {PageCard} from "../../src/PageCard.sol";
import {SubpageRegistrar, IPageNFT} from "../../src/SubpageRegistrar.sol";
import {ProceedsLogHandler} from "./ProceedsLogHandler.sol";

// An indexer that reads only SubpageSold and ProceedsClaimed must hold the registrar's proceedsOf for every
// account after every call, and the ETH those events account for, plus any ETH forced in, must be the
// registrar's balance.
contract ProceedsLogInvariantTest is Test {
    ProceedsLogHandler h;

    function setUp() public {
        vm.warp(1_800_000_000);
        PageNFT nft = new PageNFT(new PageCard());
        SubpageRegistrar reg = new SubpageRegistrar(IPageNFT(address(nft)));
        h = new ProceedsLogHandler(nft, reg);
        h.bootstrap();
        bytes4[] memory sels = new bytes4[](12);
        sels[0] = ProceedsLogHandler.sell.selector;
        sels[1] = ProceedsLogHandler.sell.selector;
        sels[2] = ProceedsLogHandler.sell.selector;
        sels[3] = ProceedsLogHandler.configure.selector;
        sels[4] = ProceedsLogHandler.claimOwn.selector;
        sels[5] = ProceedsLogHandler.claimOwn.selector;
        sels[6] = ProceedsLogHandler.claimFor.selector;
        sels[7] = ProceedsLogHandler.claimFor.selector;
        sels[8] = ProceedsLogHandler.sweep.selector;
        sels[9] = ProceedsLogHandler.toggle.selector;
        sels[10] = ProceedsLogHandler.force.selector;
        sels[11] = ProceedsLogHandler.warp.selector;
        targetContract(address(h));
        targetSelector(StdInvariant.FuzzSelector({addr: address(h), selectors: sels}));
    }

    // replaying SubpageSold and ProceedsClaimed gives proceedsOf for every tracked account, and the ETH sales
    // less the claims, plus ETH forced in, are the registrar's balance
    function invariant_proceedsLogReplay() public view {
        h.checkReplay();
    }

    // the ETH each account received from claims is what ETH sales credited to it less what it is still owed,
    // once credit sent to another address with claimProceeds is counted where it went
    function invariant_receivedEqualsCredited() public view {
        h.checkReceived();
    }

    // a claim pays only the account it names, or the address that account chose, and by exactly what was owed;
    // every other balance stays as it was, the caller's included
    function invariant_noAccountPaidAnothersCredit() public view {
        h.checkNoStray();
    }

    function afterInvariant() public {
        vm.createDir("logs", true);
        vm.writeLine("logs/proceeds-log-stats.txt", h.statLine());
    }
}

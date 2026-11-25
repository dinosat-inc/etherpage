// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {PageNFT} from "../../src/PageNFT.sol";
import {PageCard} from "../../src/PageCard.sol";
import {MoneyLogHandler} from "./MoneyLogHandler.sol";

// An indexer that reads only the money events must hold the same ledgers as the contract after every call:
// each account's credit, each name's deposit and the trial money held for each name, which, with any ETH
// forced in, make up the balance.
contract MoneyLogInvariantTest is Test {
    PageNFT nft;
    MoneyLogHandler h;

    function setUp() public {
        vm.warp(1_800_000_000);
        nft = new PageNFT(new PageCard());
        h = new MoneyLogHandler(nft);
        bytes4[] memory sels = new bytes4[](19);
        sels[0] = MoneyLogHandler.register.selector;
        sels[1] = MoneyLogHandler.register.selector;
        sels[2] = MoneyLogHandler.trial.selector;
        sels[3] = MoneyLogHandler.trial.selector;
        sels[4] = MoneyLogHandler.renew.selector;
        sels[5] = MoneyLogHandler.release.selector;
        sels[6] = MoneyLogHandler.release.selector;
        sels[7] = MoneyLogHandler.withdraw.selector;
        sels[8] = MoneyLogHandler.withdraw.selector;
        sels[9] = MoneyLogHandler.bundle.selector;
        sels[10] = MoneyLogHandler.transfer.selector;
        sels[11] = MoneyLogHandler.setMain.selector;
        sels[12] = MoneyLogHandler.clearRecords.selector;
        sels[13] = MoneyLogHandler.sub.selector;
        sels[14] = MoneyLogHandler.force.selector;
        sels[15] = MoneyLogHandler.warp.selector;
        sels[16] = MoneyLogHandler.warpNear.selector;
        sels[17] = MoneyLogHandler.warpNear.selector;
        sels[18] = MoneyLogHandler.warpNear.selector;
        targetContract(address(h));
        targetSelector(StdInvariant.FuzzSelector({addr: address(h), selectors: sels}));
    }

    // the credit of every account the logs or the walk name, and the deposit of every name, rebuilt from
    // DepositAdded, DepositBoughtOut, the two premium events, DepositReleased, TrialRefunded and Withdrawn
    function invariant_logsReproduceOwed() public view {
        h.checkOwedAndDeposits();
    }

    // the payer and amount of the trial money held for every name, rebuilt from TrialStarted and TrialRefunded
    function invariant_logsReproduceTrialMoney() public view {
        h.checkTrialMoney();
    }

    // the ETH the money events say was kept, less what Withdrawn says was paid, plus ETH forced in, is the
    // balance, and the tracked ledgers hold all of it
    function invariant_logsAccountForTheBalance() public view {
        h.checkBalance();
    }

    // the ETH each account received from withdrawals is what the money events credited to it less what it is
    // still owed
    function invariant_receivedEqualsCredited() public view {
        h.checkReceived();
    }

    // a withdrawal, alone or in a bundle, pays only the account it names and exactly what that account was owed;
    // every other balance stays as it was, the caller's included
    function invariant_noAccountPaidAnothersCredit() public view {
        h.checkNoStray();
    }

    function afterInvariant() public {
        vm.createDir("logs", true);
        vm.writeLine("logs/money-log-stats.txt", h.statLine());
    }
}

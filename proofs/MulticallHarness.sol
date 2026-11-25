// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {PageCard} from "../src/PageCard.sol";
import {DeletedHarnessB} from "./DeletedHarness.sol";

/// @notice src PageNFT with the state writers the multicall proofs need on top of
/// DeletedHarnessB. The h_ functions exist only in this test harness.
contract MulticallHarness is DeletedHarnessB {
    constructor(PageCard c) DeletedHarnessB(c) {}

    function h_setCommit(bytes32 c, uint256 t) external {
        commitments[c] = t;
    }

    function h_setOwed(address a, uint256 v) external {
        owed[a] = v;
    }

    function h_setDeposit(uint256 id, uint256 v) external {
        depositOf[id] = v;
    }

    function h_setHeld(uint256 id, address payer, uint96 amount) external {
        trialPaymentOf[id] = TrialPayment(payer, amount);
    }

    function h_setApprovalForAll(address by, address operator, bool on) external {
        _setApprovalForAll(by, operator, on);
    }

    function h_approve(address account, uint256 id) external {
        _approve(account, id);
    }
}

// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Test, Vm} from "forge-std/Test.sol";
import {PageNFT} from "../../src/PageNFT.sol";

// sends its value with selfdestruct to a contract that has no receive, such as PageNFT or the registrar, without
// calling it
contract LedgerForce {
    constructor(address payable to) payable {
        selfdestruct(to);
    }
}

// pays from the value it is sent and has no receive, so it can only pay the exact price, and what it is
// credited can never be withdrawn
contract LedgerRefuser {
    function commit(PageNFT nft, bytes32 c) external {
        nft.commit(c);
    }

    function reveal(PageNFT nft, string calldata label, address owner, uint256 ref, bytes32 secret) external payable {
        nft.reveal{value: msg.value}(label, owner, ref, secret);
    }

    function revealTrial(PageNFT nft, string calldata label, address owner, uint256 ref, bytes32 secret)
        external
        payable
    {
        nft.revealTrial{value: msg.value}(label, owner, ref, secret);
    }

    function renew(PageNFT nft, uint256 id) external payable {
        nft.renew{value: msg.value}(id);
    }
}

// holds names and takes ETH; exec makes one call and bubbles its revert
contract LedgerHolder {
    function exec(address to, bytes calldata data) external {
        (bool ok, bytes memory ret) = to.call(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    receive() external payable {}
}

// An indexer of the PageNFT money events. From the logs alone it rebuilds every account's credit, every
// name's deposit and the trial money held for every name, and adds up the ETH the logs say came in and went
// out. A recording keeps the logs of a reverted call, which no indexer sees, so callers pass only the logs
// of calls that succeeded.
abstract contract MoneyLogReplay is Test {
    bytes32 internal constant LOG_DEPOSIT_ADDED = keccak256("DepositAdded(uint256,address,uint256,uint256)");
    bytes32 internal constant LOG_BOUGHT_OUT = keccak256("DepositBoughtOut(uint256,address,uint256)");
    bytes32 internal constant LOG_RELEASED = keccak256("DepositReleased(uint256,address,uint256)");
    bytes32 internal constant LOG_REF_PREMIUM = keccak256("ReferrerPremiumCredited(uint256,uint256,address,uint256)");
    bytes32 internal constant LOG_OWNER_PREMIUM = keccak256("OwnerPremiumCredited(uint256,address,uint256)");
    bytes32 internal constant LOG_WITHDRAWN = keccak256("Withdrawn(address,address,uint256)");
    bytes32 internal constant LOG_TRIAL_STARTED = keccak256("TrialStarted(uint256,address,uint256)");
    bytes32 internal constant LOG_TRIAL_REFUNDED = keccak256("TrialRefunded(uint256,address,uint256)");

    // the three ledgers as the logs give them
    mapping(address => uint256) public logOwed;
    mapping(uint256 => uint256) public logDeposit;
    // the newTotal of the last DepositAdded of an id, or zero once a DepositReleased names it
    mapping(uint256 => uint256) public logLastTotal;
    mapping(uint256 => address) public logTrialPayer;
    mapping(uint256 => uint256) public logTrialAmount;
    // the ETH the logs say the contract kept, and paid out
    uint256 public logIn;
    uint256 public logOut;
    // the events replayed, by kind, in the order of the topics above
    uint256[8] public logCounts;

    // every account the checks cover: those a test tracks, every account a money event credits or pays out to,
    // and every trial payer
    address[] public logAccounts;
    mapping(address => bool) internal _logTracked;

    // each stays false; each is a log the ledger rules do not allow
    bool public logZeroAmount;
    bool public logZeroAccount;
    bool public logNamesTheContract;
    bool public logTotalMismatch;
    bool public logPartialRelease;
    bool public logPartialWithdraw;
    bool public logRefundMismatch;
    bool public logTrialOverwrite;

    function _track(address a) internal {
        if (_logTracked[a]) return;
        _logTracked[a] = true;
        logAccounts.push(a);
    }

    function logAccountsLength() external view returns (uint256) {
        return logAccounts.length;
    }

    function _who(bytes32 topic) internal pure returns (address) {
        return address(uint160(uint256(topic)));
    }

    // a credit names a real account other than the contract, with a non zero amount
    function _logCredit(address nft, address to, uint256 amount) internal {
        if (amount == 0) logZeroAmount = true;
        if (to == address(0)) logZeroAccount = true;
        if (to == nft) logNamesTheContract = true;
        logOwed[to] += amount;
        _track(to);
    }

    function _replay(address nft, Vm.Log[] memory logs) internal {
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory l = logs[i];
            if (l.emitter != nft || l.topics.length == 0) continue;
            bytes32 t = l.topics[0];
            if (t == LOG_DEPOSIT_ADDED) {
                uint256 id = uint256(l.topics[1]);
                (uint256 amount, uint256 newTotal) = abi.decode(l.data, (uint256, uint256));
                if (amount == 0) logZeroAmount = true;
                if (_who(l.topics[2]) == address(0)) logZeroAccount = true;
                logDeposit[id] += amount;
                if (newTotal != logDeposit[id]) logTotalMismatch = true;
                logLastTotal[id] = newTotal;
                logIn += amount;
                ++logCounts[0];
            } else if (t == LOG_BOUGHT_OUT) {
                uint256 amount = abi.decode(l.data, (uint256));
                _logCredit(nft, _who(l.topics[2]), amount);
                logIn += amount;
                ++logCounts[1];
            } else if (t == LOG_RELEASED) {
                uint256 id = uint256(l.topics[1]);
                uint256 amount = abi.decode(l.data, (uint256));
                // a release credits the whole deposit to the payee
                if (amount != logDeposit[id]) logPartialRelease = true;
                logDeposit[id] = 0;
                logLastTotal[id] = 0;
                _logCredit(nft, _who(l.topics[2]), amount);
                ++logCounts[2];
            } else if (t == LOG_REF_PREMIUM) {
                uint256 amount = abi.decode(l.data, (uint256));
                _logCredit(nft, _who(l.topics[3]), amount);
                logIn += amount;
                ++logCounts[3];
            } else if (t == LOG_OWNER_PREMIUM) {
                uint256 amount = abi.decode(l.data, (uint256));
                _logCredit(nft, _who(l.topics[2]), amount);
                logIn += amount;
                ++logCounts[4];
            } else if (t == LOG_WITHDRAWN) {
                address account = _who(l.topics[1]);
                uint256 amount = abi.decode(l.data, (uint256));
                if (amount == 0) logZeroAmount = true;
                if (account == address(0) || _who(l.topics[2]) == address(0)) logZeroAccount = true;
                if (account == nft) logNamesTheContract = true;
                // a withdrawal pays out the whole credit
                if (amount != logOwed[account]) logPartialWithdraw = true;
                logOwed[account] = amount > logOwed[account] ? 0 : logOwed[account] - amount;
                logOut += amount;
                _track(account);
                ++logCounts[5];
            } else if (t == LOG_TRIAL_STARTED) {
                uint256 id = uint256(l.topics[1]);
                address payer = _who(l.topics[2]);
                uint256 amount = abi.decode(l.data, (uint256));
                if (amount == 0) logZeroAmount = true;
                if (payer == address(0)) logZeroAccount = true;
                // the money of an earlier trial is refunded before a new one starts
                if (logTrialAmount[id] != 0) logTrialOverwrite = true;
                logTrialPayer[id] = payer;
                logTrialAmount[id] = amount;
                logIn += amount;
                _track(payer);
                ++logCounts[6];
            } else if (t == LOG_TRIAL_REFUNDED) {
                uint256 id = uint256(l.topics[1]);
                address to = _who(l.topics[2]);
                uint256 amount = abi.decode(l.data, (uint256));
                // a refund gives back exactly the money held, to the account that paid it
                if (amount != logTrialAmount[id] || to != logTrialPayer[id]) logRefundMismatch = true;
                delete logTrialPayer[id];
                delete logTrialAmount[id];
                _logCredit(nft, to, amount);
                ++logCounts[7];
            }
        }
    }

    // the replayed credit of every tracked account and the replayed deposit of every id equal the contract's,
    // the deposit also as the last newTotal, and nothing is ever credited to address zero or the contract
    function _assertOwedAndDeposits(PageNFT nft, uint256[] memory ids) internal view {
        for (uint256 i; i < logAccounts.length; ++i) {
            address a = logAccounts[i];
            assertEq(logOwed[a], nft.owed(a), string.concat("owed of ", vm.toString(a)));
        }
        assertEq(nft.owed(address(0)), 0, "owed of address zero");
        assertEq(nft.owed(address(nft)), 0, "owed of the contract");
        for (uint256 i; i < ids.length; ++i) {
            uint256 d = nft.depositOf(ids[i]);
            assertEq(logDeposit[ids[i]], d, string.concat("deposit of ", vm.toString(ids[i])));
            assertEq(logLastTotal[ids[i]], d, string.concat("last newTotal of ", vm.toString(ids[i])));
        }
        assertFalse(logZeroAmount, "a money event with amount zero");
        assertFalse(logZeroAccount, "a money event naming address zero");
        assertFalse(logNamesTheContract, "a credit or payment naming the contract");
        assertFalse(logTotalMismatch, "a newTotal other than the deposit");
        assertFalse(logPartialRelease, "a release of less or more than the deposit");
        assertFalse(logPartialWithdraw, "a withdrawal of less or more than the credit");
    }

    // the replayed trial money of every id, payer and amount, equals trialPaymentOf
    function _assertTrialMoney(PageNFT nft, uint256[] memory ids) internal view {
        for (uint256 i; i < ids.length; ++i) {
            (address p, uint96 a) = nft.trialPaymentOf(ids[i]);
            assertEq(logTrialPayer[ids[i]], p, string.concat("trial payer of ", vm.toString(ids[i])));
            assertEq(logTrialAmount[ids[i]], a, string.concat("trial money of ", vm.toString(ids[i])));
        }
        assertFalse(logRefundMismatch, "a refund that is not the money held for its payer");
        assertFalse(logTrialOverwrite, "a trial started over money still held");
    }

    // what the logs say came in, less what they say went out, plus ETH forced in, is the balance; and the
    // tracked credits, deposits and trial money hold all of it but the ETH forced in, so no account is owed
    // without a log
    function _assertBalance(PageNFT nft, uint256[] memory ids, uint256 forced) internal view {
        assertEq(address(nft).balance + logOut, logIn + forced, "the logs account for every wei");
        uint256 sum = forced;
        for (uint256 i; i < logAccounts.length; ++i) sum += nft.owed(logAccounts[i]);
        for (uint256 i; i < ids.length; ++i) {
            (, uint96 a) = nft.trialPaymentOf(ids[i]);
            sum += nft.depositOf(ids[i]) + a;
        }
        assertEq(address(nft).balance, sum, "the tracked ledgers hold the whole balance");
    }

    function _assertReplay(PageNFT nft, uint256[] memory ids, uint256 forced) internal view {
        _assertOwedAndDeposits(nft, ids);
        _assertTrialMoney(nft, ids);
        _assertBalance(nft, ids, forced);
    }
}

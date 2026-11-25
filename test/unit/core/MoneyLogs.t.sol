// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Vm} from "forge-std/Test.sol";
import {LibString} from "solady/utils/LibString.sol";
import {PageNFT} from "../../../src/PageNFT.sol";
import {RulesBase} from "../../utils/RulesBase.sol";

// The money events of every call that moves money, read from the logs: each credit is logged once, to the
// account that was credited, with the amount credited.
contract MoneyLogsTest is RulesBase {
    bytes32 constant T_WITHDRAWN = keccak256("Withdrawn(address,address,uint256)");

    function _isMoney(bytes32 t) internal pure returns (bool) {
        return t == T_DEPOSIT || t == T_BOUGHT || t == T_RELEASED || t == T_REF_PREMIUM || t == T_OWNER_PREMIUM
            || t == T_WITHDRAWN || t == T_STARTED || t == T_REFUNDED;
    }

    // the money events of a log, in order
    function _money(Vm.Log[] memory logs) internal view returns (Vm.Log[] memory out) {
        uint256 n;
        for (uint256 i; i < logs.length; ++i) if (logs[i].emitter == address(nft) && _isMoney(logs[i].topics[0])) ++n;
        out = new Vm.Log[](n);
        n = 0;
        for (uint256 i; i < logs.length; ++i) if (logs[i].emitter == address(nft) && _isMoney(logs[i].topics[0])) out[n++] = logs[i];
    }

    function _addr(bytes32 topic) internal pure returns (address) {
        return address(uint160(uint256(topic)));
    }

    function _assertCredit(Vm.Log memory l, bytes32 topic, uint256 id, address to, uint256 amount) internal pure {
        assertEq(l.topics[0], topic, "event");
        assertEq(uint256(l.topics[1]), id, "token id");
        assertEq(_addr(l.topics[2]), to, "the account credited");
        assertEq(abi.decode(l.data, (uint256)), amount, "the amount credited");
    }

    function _assertDepositAdded(Vm.Log memory l, uint256 id, address payer, uint256 amount, uint256 total)
        internal
        pure
    {
        assertEq(l.topics[0], T_DEPOSIT, "DepositAdded");
        assertEq(uint256(l.topics[1]), id);
        assertEq(_addr(l.topics[2]), payer, "the payer");
        (uint256 a, uint256 t) = abi.decode(l.data, (uint256, uint256));
        assertEq(a, amount, "the fee");
        assertEq(t, total, "the new deposit");
    }

    // registration, renewal, auction, release and withdrawal each log exactly their money events, every
    // credit naming the account whose ledger rose by exactly the amount logged
    function test_eventPerCreditExactlyOnce() public {
        // a registration with a referrer logs only its deposit
        uint256 ref = _buy(carol, "carolname");
        vm.prank(carol);
        nft.setAddr(ref, dave);
        string memory l = "alice";
        _commitPaid(bob, l, bob, ref);
        vm.warp(vm.getBlockTimestamp() + 61);
        (uint256 fee,,, uint256 total) = nft.quote(l);
        vm.recordLogs();
        vm.prank(bob);
        uint256 id = nft.reveal{value: total}(l, bob, ref, _s(l, bob, ref));
        Vm.Log[] memory m = _money(vm.getRecordedLogs());
        assertEq(m.length, 1, "a first registration credits nobody");
        _assertDepositAdded(m[0], id, bob, fee, fee);

        // a renewal by another account logs only its deposit
        vm.recordLogs();
        vm.prank(relayer);
        nft.renew{value: fee}(id);
        m = _money(vm.getRecordedLogs());
        assertEq(m.length, 1);
        _assertDepositAdded(m[0], id, relayer, fee, 2 * fee);
        uint256 refFee = nft.getFee(9);
        vm.prank(carol);
        nft.renew{value: refFee}(ref);

        // the holder points the name at user, which is now its payee
        vm.prank(bob);
        nft.setAddr(id, user);

        // an auction: the carried deposit and 75 percent of the premium to the payee, 25 percent to the
        // referrer's payee, then the buyer's deposit
        vm.warp(nft.expiresAt(id) + 90 days + 2 days - 61);
        _commitPaid(relayer, l, relayer, 0);
        vm.warp(vm.getBlockTimestamp() + 61);
        uint256 carried;
        uint256 premium;
        (fee, carried, premium, total) = nft.quote(l);
        assertGt(premium, 0);
        assertEq(nft.payee(id), user);
        assertEq(nft.payee(ref), dave);
        uint256 refShare = premium * 2500 / 10_000;
        uint256 userBefore = nft.owed(user);
        uint256 daveBefore = nft.owed(dave);
        vm.recordLogs();
        vm.prank(relayer);
        nft.reveal{value: total}(l, relayer, 0, _s(l, relayer, 0));
        m = _money(vm.getRecordedLogs());
        assertEq(m.length, 4, "three credits and the deposit");
        _assertCredit(m[0], T_BOUGHT, id, user, carried);
        assertEq(m[1].topics[0], T_REF_PREMIUM);
        assertEq(uint256(m[1].topics[1]), id);
        assertEq(uint256(m[1].topics[2]), ref, "the referrer");
        assertEq(_addr(m[1].topics[3]), dave, "the referrer's payee");
        assertEq(abi.decode(m[1].data, (uint256)), refShare);
        _assertCredit(m[2], T_OWNER_PREMIUM, id, user, premium - refShare);
        _assertDepositAdded(m[3], id, relayer, fee, carried + fee);
        assertEq(nft.owed(user) - userBefore, carried + premium - refShare, "the payee's ledger");
        assertEq(nft.owed(dave) - daveBefore, refShare, "the referrer payee's ledger");

        // a release after grace and the premium window credits the deposit to the payee
        vm.warp(nft.expiresAt(id) + 90 days + 21 days + 1);
        uint256 deposit = nft.depositOf(id);
        uint256 relayerBefore = nft.owed(relayer);
        vm.recordLogs();
        vm.prank(carol);
        nft.release(id);
        m = _money(vm.getRecordedLogs());
        assertEq(m.length, 1);
        _assertCredit(m[0], T_RELEASED, id, relayer, deposit);
        assertEq(nft.owed(relayer) - relayerBefore, deposit);
        assertEq(nft.depositOf(id), 0);

        // a withdrawal by a third party logs the account, the caller and the amount
        uint256 owed = nft.owed(user);
        uint256 balance = user.balance;
        vm.recordLogs();
        vm.prank(carol);
        nft.withdraw(user);
        m = _money(vm.getRecordedLogs());
        assertEq(m.length, 1);
        assertEq(m[0].topics[0], T_WITHDRAWN);
        assertEq(_addr(m[0].topics[1]), user, "the account paid");
        assertEq(_addr(m[0].topics[2]), carol, "the caller");
        assertEq(abi.decode(m[0].data, (uint256)), owed);
        assertEq(user.balance - balance, owed);
        assertEq(nft.owed(user), 0);
    }

    // a trial logs its held price when it starts and the same amount back to its payer when it is released
    function test_trialMoneyLogsTheHeldPrice() public {
        string memory l = "trialname";
        uint256 price = _price(l);
        vm.recordLogs();
        uint256 id = _trial(relayer, l, user, 0);
        Vm.Log[] memory m = _money(vm.getRecordedLogs());
        assertEq(m.length, 1);
        _assertCredit(m[0], T_STARTED, id, relayer, price);
        vm.warp(nft.expiresAt(id) + 1);
        vm.recordLogs();
        vm.prank(bob);
        nft.release(id);
        m = _money(vm.getRecordedLogs());
        assertEq(m.length, 1);
        _assertCredit(m[0], T_REFUNDED, id, relayer, price);
        assertEq(nft.owed(relayer), price);
    }

    // the payee is a codeless address nobody signs for, such as an exchange deposit address: a third party
    // withdraws for it, exactly its credit arrives there, the caller gets nothing and the event names both
    function test_exchangeStylePayee() public {
        address exchange = address(uint160(uint256(keccak256("exchange deposit address"))));
        assertEq(exchange.code.length, 0);
        uint256 id = _buy(bob, "deposit");
        vm.prank(bob);
        nft.setAddr(id, exchange);
        uint256 deposit = nft.depositOf(id);
        vm.warp(nft.expiresAt(id) + 90 days + 21 days + 1);
        vm.prank(carol);
        nft.release(id);
        assertEq(nft.owed(exchange), deposit, "the release credits the payee");
        uint256 exchangeBefore = exchange.balance;
        uint256 daveBefore = dave.balance;
        vm.expectEmit(true, true, false, true, address(nft));
        emit PageNFT.Withdrawn(exchange, dave, deposit);
        vm.prank(dave);
        uint256 paid = nft.withdraw(exchange);
        assertEq(paid, deposit);
        assertEq(exchange.balance - exchangeBefore, deposit, "exactly the credit arrives");
        assertEq(dave.balance, daveBefore, "nothing reaches the caller");
        assertEq(nft.owed(exchange), 0);
        assertEq(nft.owed(dave), 0);
    }

    // a paid release logs its credit and then one MetadataUpdate, its last event, since the Deposit attribute of the
    // metadata changes; a trial release logs only its refund
    function test_metadataUpdateOnRelease() public {
        uint256 id = _buy(bob, "released");
        vm.warp(nft.expiresAt(id) + 90 days + 21 days + 1);
        vm.recordLogs();
        nft.release(id);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 2);
        assertEq(logs[0].topics[0], T_RELEASED);
        assertEq(logs[1].topics[0], T_META);
        assertEq(abi.decode(logs[1].data, (uint256)), id, "MetadataUpdate names the released name");
        assertEq(_count(logs, T_META), 1);
        assertTrue(LibString.contains(_json(id), '"Deposit","display_type":"number","value":0}'), "the card shows no deposit");

        uint256 t = _trial(relayer, "trialrel", user, 0);
        vm.warp(nft.expiresAt(t) + 1);
        vm.recordLogs();
        nft.release(t);
        logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], T_REFUNDED);
        assertEq(_count(logs, T_META), 0, "a trial release changes nothing on the card");
    }
}

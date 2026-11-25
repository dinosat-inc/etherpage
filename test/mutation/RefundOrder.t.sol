// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Vm} from "forge-std/Test.sol";
import {PageNFT} from "../../src/PageNFT.sol";
import {RulesBase} from "../utils/RulesBase.sol";

// a payer that commits from its receive hook, so the refund leaves a log of its own
contract EchoPayer {
    PageNFT immutable nft;
    uint256 public received;

    constructor(PageNFT n) {
        nft = n;
    }

    function commit(bytes32 c) external {
        nft.commit(c);
    }

    function reveal(string calldata l, address owner, bytes32 s, uint256 v) external returns (uint256) {
        return nft.reveal{value: v}(l, owner, 0, s);
    }

    function renew(uint256 id, uint256 v) external {
        nft.renew{value: v}(id);
    }

    receive() external payable {
        received += msg.value;
        nft.commit(keccak256(abi.encode("refund", received)));
    }
}

// The change is sent back to the caller, and only after the registration or renewal has logged all its events.
contract RefundOrderTest is RulesBase {
    bytes32 constant T_COMMITTED = keccak256("Committed(bytes32,address)");
    bytes32 constant T_REGISTERED = keccak256("PageRegistered(uint256,string,address,uint256)");
    bytes32 constant T_TRANSFER = keccak256("Transfer(address,address,uint256)");

    function _topics(Vm.Log[] memory logs) internal view returns (bytes32[] memory t) {
        uint256 n;
        for (uint256 i; i < logs.length; ++i) if (logs[i].emitter == address(nft)) ++n;
        t = new bytes32[](n);
        n = 0;
        for (uint256 i; i < logs.length; ++i) if (logs[i].emitter == address(nft)) t[n++] = logs[i].topics[0];
    }

    function test_registrationRefundComesLast() public {
        EchoPayer p = new EchoPayer(nft);
        vm.deal(address(p), 1 ether);
        string memory l = "alice";
        bytes32 s = _s(l, bob, 0);
        p.commit(nft.makeCommitment(l, bob, 0, s));
        vm.warp(block.timestamp + 61);
        (,,, uint256 total) = nft.quote(l);
        uint256 before = address(p).balance;
        vm.recordLogs();
        p.reveal(l, bob, s, total + 7);
        bytes32[] memory t = _topics(vm.getRecordedLogs());
        // the payer got back exactly the excess and paid exactly the price
        assertEq(p.received(), 7, "refund");
        assertEq(address(p).balance, before - total, "paid the price");
        // the mint and its logs, PageRegistered, MetadataUpdate, then the payer's own log from the refund
        uint256 n = t.length;
        assertEq(t[n - 1], T_COMMITTED, "refund last");
        assertEq(t[n - 2], T_META, "metadata before the refund");
        assertEq(t[n - 3], T_REGISTERED, "registered before the refund");
        uint256 transfers;
        for (uint256 i; i < n - 3; ++i) if (t[i] == T_TRANSFER) ++transfers;
        assertEq(transfers, 1, "mint before the refund");
        assertEq(_countTopic(t, T_COMMITTED), 1, "one refund");
    }

    function _countTopic(bytes32[] memory t, bytes32 topic) internal pure returns (uint256 n) {
        for (uint256 i; i < t.length; ++i) if (t[i] == topic) ++n;
    }

    function test_renewRefundComesLast() public {
        uint256 id = _buy(bob, "alice");
        EchoPayer p = new EchoPayer(nft);
        vm.deal(address(p), 1 ether);
        uint256 fee = nft.getFee(5);
        vm.recordLogs();
        p.renew(id, fee + 3);
        bytes32[] memory t = _topics(vm.getRecordedLogs());
        assertEq(p.received(), 3, "refund");
        uint256 n = t.length;
        assertEq(t[n - 1], T_COMMITTED, "refund last");
        assertEq(t[n - 2], T_META);
        assertEq(t[n - 3], T_RENEWED);
        assertEq(t[n - 4], T_DEPOSIT);
    }

    // a payer that pays the exact price gets no ETH back
    function test_exactPriceSendsNothing() public {
        EchoPayer p = new EchoPayer(nft);
        vm.deal(address(p), 1 ether);
        string memory l = "carol";
        bytes32 s = _s(l, bob, 0);
        p.commit(nft.makeCommitment(l, bob, 0, s));
        vm.warp(block.timestamp + 61);
        (,,, uint256 total) = nft.quote(l);
        p.reveal(l, bob, s, total);
        assertEq(p.received(), 0);
    }
}

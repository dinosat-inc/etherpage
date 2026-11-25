// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Vm} from "forge-std/Test.sol";
import {PageNFT} from "../../src/PageNFT.sol";
import {RulesBase} from "../utils/RulesBase.sol";
import {NoHook} from "../utils/MinterMocks.sol";

// takes names, but its receive reverts
contract RevertingReceiver {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    receive() external payable {
        revert("no ETH");
    }
}

// burns every unit of gas it is given when ETH arrives
contract GasBurnerPayee {
    receive() external payable {
        while (true) {}
    }
}

// An auction never calls the accounts it credits, so no previous holder, payee or referrer payee can stop
// it: their credits wait in owed, and the share of a referrer with no record goes to DEAD.
contract AuctionPayeesTest is RulesBase {
    uint256 constant AUCTION_GAS = 1_000_000;

    // moves to two days into the premium window of id and buys label there for carol under an ordinary one
    // million gas limit, which a payee that burns all gas would use up if the auction sent it ETH; returns the
    // carried deposit, the premium and the logs of the purchase
    function _auction(uint256 id, string memory label)
        internal
        returns (uint256 carried, uint256 premium, Vm.Log[] memory logs)
    {
        vm.warp(nft.expiresAt(id) + 90 days + 2 days - 61);
        _commitPaid(carol, label, carol, 0);
        vm.warp(vm.getBlockTimestamp() + 61);
        uint256 total;
        (, carried, premium, total) = nft.quote(label);
        assertGt(carried, 0);
        assertGt(premium, 0);
        vm.recordLogs();
        vm.prank(carol);
        (bool ok,) = address(nft).call{value: total, gas: AUCTION_GAS}(
            abi.encodeCall(PageNFT.reveal, (label, carol, 0, _s(label, carol, 0)))
        );
        logs = vm.getRecordedLogs();
        assertTrue(ok, "the auction settles");
        assertEq(nft.ownerOf(id), carol);
    }

    function _refShare(uint256 premium) internal pure returns (uint256) {
        return premium * 2500 / 10_000;
    }

    // the previous holder saved a main address whose receive reverts: the auction settles, that address is
    // credited the carried deposit and 75 percent of the premium, and its credit can never be withdrawn
    function test_auctionSucceedsWithRevertingOldPayee() public {
        RevertingReceiver payee = new RevertingReceiver();
        uint256 id = _buy(bob, "alice");
        vm.prank(bob);
        nft.setAddr(id, address(payee));
        (uint256 carried, uint256 premium,) = _auction(id, "alice");
        assertEq(nft.owed(address(payee)), carried + premium - _refShare(premium));
        assertEq(nft.owed(bob), 0, "nothing to the holder that saved it");
        vm.prank(dave);
        vm.expectRevert(bytes4(keccak256("ETHTransferFailed()")));
        nft.withdraw(address(payee));
        assertEq(nft.owed(address(payee)), carried + premium - _refShare(premium), "the credit stays");
    }

    // the referrer's payee burns all gas when paid: the auction settles under an ordinary gas limit because
    // nothing is sent to it, and its 25 percent waits in owed
    function test_auctionSucceedsWithGasBurningReferrerPayee() public {
        GasBurnerPayee burner = new GasBurnerPayee();
        uint256 ref = _buy(dave, "daveref");
        vm.prank(dave);
        nft.setAddr(ref, address(burner));
        uint256 id = _buy(bob, "alice", bob, ref);
        assertEq(nft.payee(ref), address(burner));
        (uint256 carried, uint256 premium, Vm.Log[] memory logs) = _auction(id, "alice");
        assertEq(nft.owed(address(burner)), _refShare(premium));
        assertEq(nft.owed(bob), carried + premium - _refShare(premium));
        assertEq(_count(logs, T_REF_PREMIUM), 1);
    }

    // the previous holder is a contract with no receive and no hook, sent the name by a plain transfer, with
    // nothing saved: the auction settles, it is credited, and that credit can never be withdrawn
    function test_auctionSucceedsWithRevertingPreviousHolder() public {
        NoHook holder = new NoHook();
        uint256 id = _buy(bob, "alice");
        vm.prank(bob);
        nft.transferFrom(bob, address(holder), id);
        assertEq(nft.payee(id), address(holder));
        (uint256 carried, uint256 premium,) = _auction(id, "alice");
        assertEq(nft.owed(address(holder)), carried + premium - _refShare(premium));
        vm.expectRevert(bytes4(keccak256("ETHTransferFailed()")));
        nft.withdraw(address(holder));
    }

    // a referrer id with no record, any nonzero value but the name itself, is recorded as given, and at the
    // auction its 25 percent goes to DEAD, the event naming DEAD and that id
    function testFuzz_deadOnMissingReferrerRecord(uint256 ghost) public {
        uint256 id = uint256(keccak256(abi.encodePacked(nft.ROOT(), keccak256("alice"))));
        vm.assume(ghost != 0 && ghost != id);
        uint256 got = _buy(bob, "alice", bob, ghost);
        assertEq(got, id);
        assertEq(nft.referrerOf(id), ghost);
        (string memory label,,,,) = nft.records(ghost);
        assertEq(bytes(label).length, 0, "the referrer has no record");
        uint256 deadBefore = nft.owed(DEAD);
        (uint256 carried, uint256 premium, Vm.Log[] memory logs) = _auction(id, "alice");
        uint256 share = _refShare(premium);
        assertEq(nft.owed(DEAD) - deadBefore, share, "the referrer share goes to DEAD");
        assertEq(nft.owed(bob), carried + premium - share, "the rest to the previous payee");
        bool seen;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(nft) || logs[i].topics[0] != T_REF_PREMIUM) continue;
            seen = true;
            assertEq(uint256(logs[i].topics[1]), id);
            assertEq(uint256(logs[i].topics[2]), ghost, "the recorded referrer");
            assertEq(address(uint160(uint256(logs[i].topics[3]))), DEAD, "credited to DEAD");
            assertEq(abi.decode(logs[i].data, (uint256)), share);
        }
        assertTrue(seen);
    }
}

// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {IMulticall3} from "forge-std/interfaces/IMulticall3.sol";
import {PageNFT} from "../../../src/PageNFT.sol";
import {AcceptedBase} from "./AcceptedBase.sol";

// The account that calls revealTrial pays for the trial, and the money is credited back to it later, through owed
// and withdraw. Multicall3 cannot take a plain ETH transfer, so a sponsor that sends its trials through it leaves
// every refund frozen in owed for good. A paid reveal through Multicall3 has no such delay: any overpayment is
// sent back at once, and that failure reverts the reveal.
contract AcceptedTrialPayerTest is AcceptedBase {
    function setUp() public override {
        super.setUp();
        _etchMulticall3();
    }

    // a relayer batches three trials through Multicall3; one is converted and two end unpaid, each refund is
    // credited to Multicall3, and withdraw for it reverts whoever calls it
    function test_trialRefundsThroughMulticall3StayFrozen() public {
        vm.prank(relayer);
        (bool plain,) = MULTICALL3.call{value: 1}("");
        assertFalse(plain, "Multicall3 takes no plain ETH");

        string[3] memory labels = ["user-one", "user-two", "aa"];
        address[3] memory owners = [makeAddr("u1"), makeAddr("u2"), makeAddr("u3")];
        IMulticall3.Call3Value[] memory calls = new IMulticall3.Call3Value[](3);
        uint256 sum;
        for (uint256 i; i < 3; ++i) {
            _commitTrial(relayer, labels[i], owners[i], 0);
            uint256 price = _trialPrice(labels[i]);
            sum += price;
            calls[i] = IMulticall3.Call3Value(
                address(nft),
                false,
                price,
                abi.encodeCall(PageNFT.revealTrial, (labels[i], owners[i], 0, _secret(labels[i], owners[i])))
            );
        }
        vm.warp(vm.getBlockTimestamp() + 61);
        vm.prank(relayer);
        IMulticall3(MULTICALL3).aggregate3Value{value: sum}(calls);

        uint256[3] memory ids;
        for (uint256 i; i < 3; ++i) {
            ids[i] = nft.computeId(labels[i]);
            (address payer, uint96 held) = nft.trialPaymentOf(ids[i]);
            assertEq(payer, MULTICALL3, "Multicall3 is the recorded payer");
            assertEq(held, _trialPrice(labels[i]));
            assertEq(nft.ownerOf(ids[i]), owners[i]);
        }

        // the first owner pays its year, the other two trials end unpaid and anyone releases them
        uint256 fee = nft.getFee(bytes(labels[0]).length);
        vm.deal(owners[0], fee);
        vm.prank(owners[0]);
        nft.renew{value: fee}(ids[0]);
        vm.warp(nft.expiresAt(ids[2]) + 1);
        nft.release(ids[1]);
        nft.release(ids[2]);
        assertEq(nft.owed(MULTICALL3), sum, "every refund is credited to Multicall3");

        address[3] memory callers = [address(this), relayer, owners[0]];
        for (uint256 i; i < 3; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(ETH_TRANSFER_FAILED);
            nft.withdraw(MULTICALL3);
        }
        assertEq(nft.owed(MULTICALL3), sum, "still owed, never payable");
        assertEq(nft.owed(relayer), 0, "nothing reaches the relayer that paid");
    }

    // the same batcher with a paid reveal: one wei over the price is sent back to Multicall3 at once, which fails,
    // so the reveal reverts and nothing is registered; the exact price goes through
    function test_paidRevealThroughMulticall3RevertsOnOverpayment() public {
        address owner = makeAddr("u1");
        _commitPaid(relayer, "paid-name", owner, 0);
        vm.warp(vm.getBlockTimestamp() + 61);
        (,,, uint256 total) = nft.quote("paid-name");
        IMulticall3.Call3Value[] memory calls = new IMulticall3.Call3Value[](1);
        calls[0] = IMulticall3.Call3Value(
            address(nft), true, total + 1, abi.encodeCall(PageNFT.reveal, ("paid-name", owner, 0, _secret("paid-name", owner)))
        );

        // with the failure allowed, the reveal's own revert is the failed refund
        uint256 snap = vm.snapshotState();
        vm.prank(relayer);
        IMulticall3.Result[] memory res = IMulticall3(MULTICALL3).aggregate3Value{value: total + 1}(calls);
        assertFalse(res[0].success);
        assertEq(bytes4(res[0].returnData), ETH_TRANSFER_FAILED);
        assertTrue(nft.isAvailable("paid-name", 0), "nothing was registered");
        vm.revertToState(snap);

        calls[0].allowFailure = false;
        vm.prank(relayer);
        vm.expectRevert(bytes("Multicall3: call failed"));
        IMulticall3(MULTICALL3).aggregate3Value{value: total + 1}(calls);

        calls[0].value = total;
        vm.prank(relayer);
        IMulticall3(MULTICALL3).aggregate3Value{value: total}(calls);
        assertEq(nft.ownerOf(nft.computeId("paid-name")), owner);
        assertEq(nft.owed(MULTICALL3), 0, "a paid reveal credits its payer nothing");
    }
}

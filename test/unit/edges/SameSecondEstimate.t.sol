// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {MinterBase} from "../../utils/MinterBase.sol";

// A transfer stores the block time in holderSince. Estimated in the second of the mint, which stored the same time,
// that write changes nothing and costs less. Mined a block later it stores a new time and costs 2,800 gas more. So
// an estimate sent as it is runs out of gas, while the gas limit the website sends, 125 percent of the estimate
// (GAS_HEADROOM_PERCENT in src/lib/context.ts), is enough.
contract SameSecondEstimateTest is MinterBase {
    uint256 id;
    uint256 mintedAt;

    function setUp() public override {
        super.setUp();
        id = _reg(alice, "alice");
        mintedAt = vm.getBlockTimestamp();
        assertEq(nft.holderSince(id), mintedAt);
    }

    function _tryTransfer(uint256 g) internal returns (bool ok) {
        vm.prank(alice);
        (ok,) = address(nft).call{gas: g}(abi.encodeCall(nft.transferFrom, (alice, bob, id)));
    }

    // the smallest gas limit with which the transfer works, found by halving the range as an estimate does
    function _minGas() internal returns (uint256 hi) {
        uint256 lo;
        hi = 1_000_000;
        while (lo + 1 < hi) {
            uint256 mid = (lo + hi) / 2;
            uint256 snap = vm.snapshotState();
            bool ok = _tryTransfer(mid);
            vm.revertToState(snap);
            if (ok) hi = mid;
            else lo = mid;
        }
    }

    function test_anEstimateInTheMintsSecondIsShortABlockLater() public {
        uint256 sameSecond = _minGas();
        vm.warp(mintedAt + 2);
        uint256 later = _minGas();
        emit log_named_uint("smallest gas limit in the mint's second", sameSecond);
        emit log_named_uint("smallest gas limit 2 seconds later", later);
        assertEq(later - sameSecond, 2800, "storing a new time costs 2,800 gas more than storing the same time");
        uint256 snap = vm.snapshotState();
        assertFalse(_tryTransfer(sameSecond), "the estimate sent as it is fails a block later");
        vm.revertToState(snap);
        assertTrue(_tryTransfer(sameSecond * 125 / 100), "125 percent of the estimate is enough");
        assertEq(nft.ownerOf(id), bob);
        assertEq(nft.holderSince(id), mintedAt + 2);
    }
}

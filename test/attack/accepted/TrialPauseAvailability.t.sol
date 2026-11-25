// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {PageNFT} from "../../../src/PageNFT.sol";
import {AcceptedBase} from "./AcceptedBase.sol";

// For 14 days after an unpaid trial ends, isAvailable answers true, but revealTrial reverts TrialNotAllowed. No view
// answers differently on the last second of that pause and on the first second after it, so an app works the
// trial rule out from depositOf, expiresAt and the clock.
contract AcceptedTrialPauseTest is AcceptedBase {
    string constant L = "alice-smith";

    // the revert selector of carol's trial of L for herself at time t, with a commitment made an hour before,
    // or zero when it starts; the state is restored afterwards
    function _trialAt(uint256 t) internal returns (bytes4 err) {
        uint256 snap = vm.snapshotState();
        vm.warp(t - 1 hours);
        _commitTrial(carol, L, carol, 0);
        vm.warp(t);
        uint256 price = _trialPrice(L);
        bytes memory data = abi.encodeCall(PageNFT.revealTrial, (L, carol, 0, _secret(L, carol)));
        vm.prank(carol);
        (bool ok, bytes memory ret) = address(nft).call{value: price}(data);
        if (!ok) err = ret.length >= 4 ? bytes4(ret) : bytes4(0xffffffff);
        vm.revertToState(snap);
    }

    // the first second after the trial, a week in, the last second of the pause, and the second after it
    function test_isAvailableTrueThroughThePauseWhileTrialsAreRefused() public {
        uint256 id = _trial(relayer, L, user, 0);
        uint256 e = nft.expiresAt(id);
        uint256[3] memory times = [e + 1, e + 7 days, e + 14 days];
        for (uint256 i; i < 3; ++i) {
            vm.warp(times[i]);
            assertTrue(nft.isAvailable(L, 0), "isAvailable answers true in the pause");
            assertEq(_trialAt(times[i]), PageNFT.TrialNotAllowed.selector, "a trial is refused in the pause");
        }
        vm.warp(e + 14 days + 1);
        assertTrue(nft.isAvailable(L, 0));
        assertEq(_trialAt(e + 14 days + 1), bytes4(0), "a trial starts after the pause");
    }

    struct Views {
        bool available;
        uint256 fee;
        uint256 carried;
        uint256 premium;
        uint256 total;
        bool expired;
        bool grace;
        bool releasable;
        uint256 status;
        uint256 deposit;
        uint256 expiry;
        address holder;
        address payer;
        uint96 held;
        bytes32 uri;
    }

    function _views(uint256 id) internal view returns (Views memory v) {
        v.available = nft.isAvailable(L, 0);
        (v.fee, v.carried, v.premium, v.total) = nft.quote(L);
        v.expired = nft.isExpired(id);
        v.grace = nft.inGracePeriod(id);
        v.releasable = nft.isReleasable(id);
        v.status = uint256(nft.status(id));
        v.deposit = nft.depositOf(id);
        v.expiry = nft.expiresAt(id);
        v.holder = nft.ownerOf(id);
        (v.payer, v.held) = nft.trialPaymentOf(id);
        v.uri = keccak256(bytes(nft.tokenURI(id)));
    }

    // every view of the name answers the same on the last second of the pause and the next one, while the trial
    // goes from refused to allowed
    function test_noViewTellsTheLastPauseSecondFromTheNext() public {
        uint256 id = _trial(relayer, L, user, 0);
        uint256 last = nft.expiresAt(id) + 14 days;
        vm.warp(last);
        Views memory a = _views(id);
        vm.warp(last + 1);
        Views memory b = _views(id);
        assertEq(keccak256(abi.encode(a)), keccak256(abi.encode(b)), "the views agree");
        assertTrue(a.available);
        assertEq(_trialAt(last), PageNFT.TrialNotAllowed.selector);
        assertEq(_trialAt(last + 1), bytes4(0));
    }
}

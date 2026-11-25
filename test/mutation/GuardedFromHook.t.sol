// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {trialCommitment} from "../utils/TrialCommitment.sol";

import {PageNFT} from "../../src/PageNFT.sol";
import {RulesBase} from "../utils/RulesBase.sol";

// makes each call it was given from its receiver hook or its receive function, once, and keeps the revert data
contract ReentryProbe {
    PageNFT immutable nft;
    bytes[] calls;
    bytes[] public rets;
    bool fired;

    constructor(PageNFT n) {
        nft = n;
    }

    function arm(bytes[] calldata c) external {
        delete calls;
        delete rets;
        fired = false;
        for (uint256 i; i < c.length; ++i) calls.push(c[i]);
    }

    function retAt(uint256 i) external view returns (bytes memory) {
        return rets[i];
    }

    function count() external view returns (uint256) {
        return rets.length;
    }

    function _fire() internal {
        if (fired) return;
        fired = true;
        for (uint256 i; i < calls.length; ++i) {
            (bool s, bytes memory r) = address(nft).call(calls[i]);
            rets.push(s ? bytes("ok") : r);
        }
    }

    function commit(bytes32 c) external {
        nft.commit(c);
    }

    function renew(uint256 id, uint256 v) external {
        nft.renew{value: v}(id);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        _fire();
        return this.onERC721Received.selector;
    }

    receive() external payable {
        _fire();
    }
}

// Each guarded entry point refuses to run while another one is running, and each sets the lock for the calls it
// hands control to.
contract GuardedFromHookTest is RulesBase {
    bytes4 constant REENTRANCY = 0xab143c06;

    function _expectAllRefused(ReentryProbe p, uint256 n) internal view {
        assertEq(p.count(), n, "every call was made");
        for (uint256 i; i < n; ++i) {
            assertEq(p.retAt(i), abi.encodeWithSelector(REENTRANCY), string.concat("call ", vm.toString(i)));
        }
    }

    // all seven guarded entry points, the running one included, for a hook to call while one of them holds the lock
    function _guardedCalls(uint256 parent, uint256 other) internal view returns (bytes[] memory c) {
        c = new bytes[](7);
        c[0] = abi.encodeCall(nft.renew, (other));
        c[1] = abi.encodeCall(nft.registerSubpage, ("sub", parent));
        c[2] = abi.encodeCall(nft.registerSubpageFor, ("sub2", parent, dave));
        c[3] = abi.encodeCall(nft.release, (other));
        c[4] = abi.encodeCall(nft.withdraw, (dave));
        c[5] = abi.encodeCall(nft.reveal, ("zzzzz", dave, 0, bytes32(0)));
        c[6] = abi.encodeCall(nft.revealTrial, ("zzzzz", dave, 0, bytes32(0)));
    }

    function test_revealHookCannotEnterAnyGuardedCall() public {
        ReentryProbe p = new ReentryProbe(nft);
        uint256 parent = _buy(bob, "parent", address(p), 0);
        uint256 other = _buy(bob, "other");
        p.arm(_guardedCalls(parent, other));
        // a second name to the probe fires the hook while reveal holds the lock
        _buy(bob, "second", address(p), 0);
        _expectAllRefused(p, 7);
    }

    function test_revealTrialHookCannotEnterAnyGuardedCall() public {
        ReentryProbe p = new ReentryProbe(nft);
        uint256 parent = _buy(bob, "parent", address(p), 0);
        uint256 other = _buy(bob, "other");
        p.arm(_guardedCalls(parent, other));
        _trial(relayer, "second", address(p), 0);
        _expectAllRefused(p, 7);
    }

    // the refund of renew and the payout of withdraw call back into reveal and the other guarded entry points
    function test_renewRefundAndWithdrawPayoutCannotEnter() public {
        ReentryProbe p = new ReentryProbe(nft);
        vm.deal(address(p), 1 ether);
        uint256 parent = _buy(bob, "parent", address(p), 0);
        uint256 other = _buy(bob, "other");
        p.arm(_guardedCalls(parent, other));
        p.renew(other, FEE5 + 1);
        _expectAllRefused(p, 7);
        // a trial paid by the probe is credited back to it, and withdraw sends that money to it
        p.arm(_guardedCalls(parent, other));
        string memory l = "triala";
        bytes32 commitment = trialCommitment(address(nft), l, bob, 0, _s(l, bob, 0));
        vm.prank(address(p));
        nft.commit(commitment);
        vm.warp(block.timestamp + 61);
        vm.prank(address(p));
        uint256 t = nft.revealTrial{value: PRICE5}(l, bob, 0, _s(l, bob, 0));
        vm.prank(carol);
        nft.renew{value: FEE5}(t);
        assertEq(nft.owed(address(p)), PRICE5);
        nft.withdraw(address(p));
        _expectAllRefused(p, 7);
    }

    // a subpage minted to a contract by registerSubpageFor fires its hook while the lock is held
    function test_registerSubpageForHookCannotEnter() public {
        ReentryProbe p = new ReentryProbe(nft);
        uint256 parent = _buy(bob, "parent");
        uint256 other = _buy(carol, "other");
        bytes[] memory c = new bytes[](3);
        c[0] = abi.encodeCall(nft.renew, (other));
        c[1] = abi.encodeCall(nft.withdraw, (dave));
        c[2] = abi.encodeCall(nft.release, (other));
        p.arm(c);
        vm.prank(bob);
        nft.registerSubpageFor("kid", parent, address(p));
        _expectAllRefused(p, 3);
    }
}

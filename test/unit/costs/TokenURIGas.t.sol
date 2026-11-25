// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {PageCard} from "../../../src/PageCard.sol";
import {EdgesBase} from "../edges/EdgesBase.sol";

// tokenURI is read through eth_call, where providers often cap the gas at 30 million, and a name that cannot render
// shows nowhere. The largest real tokens, a 63 character name, a 63 character trial and a 63 character subpage of a
// 63 character parent in every state of its card, stale and deleted included, each render inside that cap. The bound
// is the cap itself, so it holds for the unoptimised build forge coverage makes as well as for the deploy build; the
// test logs each figure.
contract TokenURIGasTest is EdgesBase {
    uint256 constant PROVIDER_CAP = 30_000_000;

    uint256 parent;
    uint256 sub;
    uint256 trial;

    function _rep(string memory c, uint256 n) internal pure returns (string memory s) {
        for (uint256 i; i < n; ++i) s = string.concat(s, c);
    }

    function setUp() public override {
        super.setUp();
        parent = _buy(bob, _rep("p", 63), bob, 0);
        vm.prank(bob);
        sub = nft.registerSubpage(_rep("s", 63), parent);
        trial = _trial(relayer, _rep("t", 63), carol, 0);
    }

    // the gas of one tokenURI call, with its result read so the call cannot be skipped
    function _uriGas(uint256 id) internal view returns (uint256 used) {
        uint256 g = gasleft();
        string memory uri = nft.tokenURI(id);
        used = g - gasleft();
        assertGt(bytes(uri).length, 1000, "a full tokenURI came back");
    }

    function _check(uint256 id, PageCard.Status want, string memory which) internal {
        assertEq(uint256(nft.status(id)), uint256(want), which);
        uint256 used = _uriGas(id);
        emit log_named_uint(which, used);
        assertLt(used, PROVIDER_CAP, which);
    }

    function test_largestTokenURIsRenderInsideTheProviderCap() public {
        _check(parent, PageCard.Status.Active, "63 character name");
        _check(trial, PageCard.Status.Trial, "63 character trial");
        _check(sub, PageCard.Status.Active, "63 by 63 subpage, active");
        // a second subpage its holder sends to DEAD is deleted
        vm.startPrank(bob);
        uint256 gone = nft.registerSubpage(_rep("d", 63), parent);
        nft.transferFrom(bob, DEAD, gone);
        vm.stopPrank();
        _check(gone, PageCard.Status.Invalid, "63 by 63 subpage, deleted");
        vm.warp(nft.expiresAt(parent) + 1);
        _check(sub, PageCard.Status.Grace, "63 by 63 subpage, grace");
        vm.warp(nft.expiresAt(parent) + GRACE + 1);
        _check(sub, PageCard.Status.Expired, "63 by 63 subpage, expired");
        _check(parent, PageCard.Status.Expired, "63 character name, expired");
        // the parent registered again leaves the subpage stale, the largest tokenURI there is
        vm.warp(nft.expiresAt(parent) + GRACE + DECAY + 1);
        _buy(dave, _rep("p", 63), dave, 0);
        _check(sub, PageCard.Status.Invalid, "63 by 63 subpage, stale");
    }
}

// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {PageNFT} from "../../../src/PageNFT.sol";
import {EdgesBase} from "./EdgesBase.sol";

// The one second edges of expiry and grace, each call made directly from the same state. A paid name is written
// and moved at its expiry second T and not one second later, and renewed at the end of its grace G and not one
// second later. A trial is written at its last second E and not one second later. clearRecords of an inactive name,
// at G and past the premium window, reverts Expired for the holder, an operator and a stranger alike.
contract BoundarySecondsTest is EdgesBase {
    uint256 constant ETH = 60;

    // the five record writers and keepProfile
    function _writers(uint256 id) internal view returns (bytes[] memory c) {
        c = new bytes[](7);
        c[0] = abi.encodeCall(PageNFT.setAddr, (id, hot));
        c[1] = abi.encodeCall(PageNFT.setAddrForCoin, (id, ETH, abi.encodePacked(hot)));
        c[2] = abi.encodeCall(PageNFT.setAddrForCoin, (id, 0, hex"0014aa"));
        c[3] = abi.encodeCall(PageNFT.setText, (id, "url", "https://example.org"));
        c[4] = abi.encodeCall(PageNFT.setContenthash, (id, hex"e301017012201234"));
        c[5] = abi.encodeCall(PageNFT.clearRecords, (id));
        c[6] = abi.encodeCall(PageNFT.keepProfile, (id));
    }

    // the three transfers of the name from holder to an account with no code
    function _transfers(uint256 id, address holder) internal pure returns (bytes[] memory c) {
        c = new bytes[](3);
        c[0] = abi.encodeWithSignature("transferFrom(address,address,uint256)", holder, address(0xb0b), id);
        c[1] = abi.encodeWithSignature("safeTransferFrom(address,address,uint256)", holder, address(0xb0b), id);
        c[2] = abi.encodeWithSignature(
            "safeTransferFrom(address,address,uint256,bytes)", holder, address(0xb0b), id, bytes("x")
        );
    }

    // each call by holder at time t from the same state: it succeeds when live, else it reverts Expired
    function _eachCall(bytes[] memory c, address holder, uint256 t, bool live, string memory when) internal {
        for (uint256 i; i < c.length; ++i) {
            string memory which = string.concat(when, ", call ", vm.toString(i));
            uint256 snap = vm.snapshotState();
            vm.warp(t);
            vm.prank(holder);
            (bool ok, bytes memory ret) = address(nft).call(c[i]);
            if (live) {
                assertTrue(ok, which);
            } else {
                assertFalse(ok, which);
                assertEq(ret, abi.encodeWithSelector(PageNFT.Expired.selector), which);
            }
            vm.revertToState(snap);
        }
    }

    function test_paidNameIsWrittenAndMovedAtItsExpirySecondOnly() public {
        uint256 id = _buy(alice, "alpha", alice, 0);
        uint256 t = nft.expiresAt(id);
        _eachCall(_writers(id), alice, t, true, "write at T");
        _eachCall(_transfers(id, alice), alice, t, true, "move at T");
        _eachCall(_writers(id), alice, t + 1, false, "write at T + 1");
        _eachCall(_transfers(id, alice), alice, t + 1, false, "move at T + 1");
    }

    function test_paidNameIsRenewedAtItsGraceEndOnly() public {
        uint256 id = _buy(alice, "alpha", alice, 0);
        uint256 t = nft.expiresAt(id);
        uint256 fee = nft.getFee(5);
        uint256 snap = vm.snapshotState();
        vm.warp(t + GRACE);
        vm.prank(stranger);
        nft.renew{value: fee}(id);
        assertEq(nft.expiresAt(id), t + YEAR, "renewed at G");
        assertEq(nft.depositOf(id), 2 * fee);
        vm.revertToState(snap);
        vm.warp(t + GRACE + 1);
        vm.prank(stranger);
        vm.expectRevert(PageNFT.Expired.selector);
        nft.renew{value: fee}(id);
        assertEq(nft.expiresAt(id), t, "not renewed at G + 1");
        assertEq(nft.depositOf(id), fee);
    }

    function test_trialIsWrittenAtItsLastSecondOnly() public {
        uint256 id = _trial(relayer, "alpha", alice, 0);
        uint256 e = nft.expiresAt(id);
        _eachCall(_writers(id), alice, e, true, "trial write at E");
        _eachCall(_writers(id), alice, e + 1, false, "trial write at E + 1");
    }

    function test_clearOfAnInactiveNameRevertsExpiredForEveryCaller() public {
        uint256 id = _buy(alice, "alpha", alice, 0);
        vm.prank(alice);
        nft.setApprovalForAll(dave, true);
        uint256 g = nft.expiresAt(id) + GRACE;
        uint256[4] memory instants = [g, g + DECAY, g + DECAY + 1, g + DECAY + 365 days];
        address[3] memory callers = [alice, dave, stranger];
        for (uint256 i; i < instants.length; ++i) {
            vm.warp(instants[i]);
            for (uint256 j; j < callers.length; ++j) {
                vm.prank(callers[j]);
                vm.expectRevert(PageNFT.Expired.selector);
                nft.clearRecords(id);
            }
        }
        assertEq(nft.recordVersion(id), 0, "no clear went through");
        assertEq(nft.ownerOf(id), alice);
    }
}

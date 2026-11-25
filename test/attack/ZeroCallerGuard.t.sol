// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {MinterBase} from "../utils/MinterBase.sol";
import {PageNFT} from "../../src/PageNFT.sol";

// The zero address as the caller. The ERC721 library skips its approval checks for a caller of address(0), so
// without the guard it could move any name that has no approval for the token, approve anyone for any name, and
// mint subpages wherever no minter counts. A call from address(0) comes only from a protocol fixed transaction, such
// as an OP network upgrade transaction. PageNFT refuses that caller in transfers, approvals and subpage mints, on
// every path, a bundle included, and leaves every other call as it was.
contract ZeroCallerGuardTest is MinterBase {
    address constant ZERO = address(0);
    address op = makeAddr("op");
    address appr = makeAddr("appr");

    // every way to move a name, whatever approval the name has: none, one for the token, an operator, or both
    function test_zeroCallerMovesNoName() public {
        for (uint256 kind; kind < 4; ++kind) {
            uint256 id = _reg(alice, string.concat("gold", vm.toString(kind)));
            if (kind == 1 || kind == 3) {
                vm.prank(alice);
                nft.approve(appr, id);
            }
            if (kind == 2 || kind == 3) {
                vm.prank(alice);
                nft.setApprovalForAll(op, true);
            }
            address approvedBefore = nft.getApproved(id);
            vm.startPrank(ZERO);
            vm.expectRevert(NOT_OWNER_NOR_APPROVED);
            nft.transferFrom(alice, stranger, id);
            vm.expectRevert(NOT_OWNER_NOR_APPROVED);
            nft.safeTransferFrom(alice, stranger, id);
            vm.expectRevert(NOT_OWNER_NOR_APPROVED);
            nft.safeTransferFrom(alice, stranger, id, "");
            vm.expectRevert(NOT_OWNER_NOR_APPROVED);
            nft.transferFrom(alice, DEAD, id);
            vm.expectRevert(NOT_OWNER_NOR_APPROVED);
            nft.approve(stranger, id);
            vm.expectRevert(NOT_OWNER_NOR_APPROVED);
            nft.approve(ZERO, id);
            vm.stopPrank();
            assertEq(nft.ownerOf(id), alice, "the name stays");
            assertEq(nft.getApproved(id), approvedBefore, "the approval stays");
        }
    }

    // a value sent with the call is refused first, as for any caller
    function test_zeroCallerWithValueGetsTheValueErrorFirst() public {
        uint256 id = _reg(alice, "gold");
        vm.deal(ZERO, 1 ether);
        vm.prank(ZERO);
        vm.expectRevert(PageNFT.UnexpectedValue.selector);
        nft.transferFrom{value: 1}(alice, stranger, id);
        vm.prank(ZERO);
        vm.expectRevert(PageNFT.UnexpectedValue.selector);
        nft.approve{value: 1}(stranger, id);
    }

    // the holder of a token, or zero when it has none
    function _holderOf(uint256 id) internal view returns (address h) {
        (bool ok, bytes memory ret) = address(nft).staticcall(abi.encodeWithSignature("ownerOf(uint256)", id));
        if (ok) h = abi.decode(ret, (address));
    }

    // no subpage mint, whatever the minter record: none, a counted pick, a pick that no longer counts after the
    // parent moved, a cleared pick, and over a free, a live and a deleted subpage
    function test_zeroCallerMintsNoSubpage() public {
        uint256 p = _reg(alice, "club");
        vm.prank(alice);
        nft.registerSubpageFor("live", p, carol);
        vm.prank(alice);
        uint256 gone = nft.registerSubpageFor("gone", p, carol);
        vm.prank(carol);
        nft.transferFrom(carol, DEAD, gone);
        string[3] memory labels = ["free", "live", "gone"];
        for (uint256 pick; pick < 4; ++pick) {
            uint256 snap = vm.snapshotState();
            if (pick == 1) _setMinter(p, hot);
            if (pick == 2) {
                _setMinter(p, hot);
                vm.prank(alice);
                nft.transferFrom(alice, bob, p);
                assertEq(_minter(p), address(0), "the pick of the last holder counts for no one");
            }
            if (pick == 3) {
                _setMinter(p, hot);
                _setMinter(p, address(0));
            }
            for (uint256 j; j < 3; ++j) {
                uint256 sid = _subId(labels[j], p);
                address before = _holderOf(sid);
                vm.prank(ZERO);
                vm.expectRevert(PageNFT.NotParentOwner.selector);
                nft.registerSubpageFor(labels[j], p, stranger);
                vm.prank(ZERO);
                vm.expectRevert(PageNFT.NotParentOwner.selector);
                nft.registerSubpage(labels[j], p);
                assertEq(_holderOf(sid), before, "nothing moved");
            }
            vm.revertToState(snap);
        }
    }

    // bundled calls keep the caller, so the zero caller gets the same refusal inside multicall
    function test_zeroCallerRefusedInsideABundle() public {
        uint256 id = _reg(alice, "gold");
        uint256 p = _reg(alice, "club");
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeWithSignature("transferFrom(address,address,uint256)", alice, stranger, id);
        vm.prank(ZERO);
        vm.expectRevert(NOT_OWNER_NOR_APPROVED);
        nft.multicall(calls);
        calls[0] = abi.encodeCall(PageNFT.approve, (stranger, id));
        vm.prank(ZERO);
        vm.expectRevert(NOT_OWNER_NOR_APPROVED);
        nft.multicall(calls);
        calls[0] = abi.encodeCall(PageNFT.registerSubpageFor, ("free", p, stranger));
        vm.prank(ZERO);
        vm.expectRevert(PageNFT.NotParentOwner.selector);
        nft.multicall(calls);
        assertEq(nft.ownerOf(id), alice);
        assertTrue(nft.isAvailable("free", p));
    }

    // the zero caller writes no record of a name, as before: it never holds one
    function test_zeroCallerWritesNoRecord() public {
        uint256 id = _reg(alice, "iron");
        vm.startPrank(ZERO);
        vm.expectRevert(PageNFT.Unauthorized.selector);
        nft.setText(id, "url", "x");
        vm.expectRevert(PageNFT.Unauthorized.selector);
        nft.setAddr(id, stranger);
        vm.expectRevert(PageNFT.Unauthorized.selector);
        nft.setAddrForCoin(id, 0x80000000, abi.encodePacked(stranger));
        vm.expectRevert(PageNFT.Unauthorized.selector);
        nft.setAddrForCoin(id, 60, abi.encodePacked(stranger));
        vm.expectRevert(PageNFT.Unauthorized.selector);
        nft.setContenthash(id, hex"01");
        vm.expectRevert(PageNFT.Unauthorized.selector);
        nft.keepProfile(id);
        vm.expectRevert(PageNFT.Unauthorized.selector);
        nft.clearRecords(id);
        vm.expectRevert(PageNFT.Unauthorized.selector);
        nft.setPrimaryPage(id);
        vm.expectRevert(PageNFT.Unauthorized.selector);
        nft.setSubpageMinter(id, stranger);
        vm.stopPrank();
    }

    // the guard changes nothing for any other caller: the holder, an approved account and an operator still move
    // names, an operator still approves for the holder and an approved account does not, and the holder and its
    // minter still mint subpages
    function test_otherCallersUnchanged() public {
        uint256 a = _reg(alice, "aaa1");
        uint256 b = _reg(alice, "bbb1");
        uint256 c = _reg(alice, "ccc1");
        uint256 d = _reg(alice, "ddd1");
        vm.prank(alice);
        nft.approve(appr, b);
        vm.prank(alice);
        nft.setApprovalForAll(op, true);
        vm.prank(op);
        nft.approve(dave, d);
        assertEq(nft.getApproved(d), dave, "an operator approves for the holder");
        vm.prank(appr);
        vm.expectRevert(NOT_OWNER_NOR_APPROVED);
        nft.approve(stranger, b);
        vm.prank(dave);
        nft.transferFrom(alice, carol, d);
        assertEq(nft.ownerOf(d), carol);
        vm.prank(alice);
        nft.transferFrom(alice, bob, a);
        vm.prank(appr);
        nft.transferFrom(alice, bob, b);
        vm.prank(op);
        nft.safeTransferFrom(alice, bob, c);
        assertEq(nft.ownerOf(a), bob);
        assertEq(nft.ownerOf(b), bob);
        assertEq(nft.ownerOf(c), bob);
        vm.prank(bob);
        uint256 s = nft.registerSubpageFor("sub", a, carol);
        assertEq(nft.ownerOf(s), carol);
        _setMinter(a, hot);
        vm.prank(hot);
        uint256 s2 = nft.registerSubpageFor("sub2", a, carol);
        assertEq(nft.ownerOf(s2), carol);
    }
}

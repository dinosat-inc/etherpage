// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {PageNFT} from "../../src/PageNFT.sol";
import {MinterBase} from "../utils/MinterBase.sol";

// approve, transferFrom and both safeTransferFrom forms are payable in the ERC721 interface but refuse any
// ETH, whoever calls them, and change nothing; multicall is not payable at all. Without ETH they work.
contract ValueRefusalTest is MinterBase {
    function _call(address who, uint256 value, bytes memory data) internal returns (bool ok, bytes memory ret) {
        vm.deal(who, who.balance + value);
        uint256 before = who.balance;
        uint256 held = address(nft).balance;
        vm.prank(who);
        (ok, ret) = address(nft).call{value: value}(data);
        if (!ok) {
            assertEq(who.balance, before, "the caller keeps its ETH");
            assertEq(address(nft).balance, held, "PageNFT takes none");
        }
    }

    function _assertRefused(address who, uint256 value, bytes memory data, string memory what) internal {
        (bool ok, bytes memory ret) = _call(who, value, data);
        assertFalse(ok, what);
        assertEq(ret, abi.encodeWithSelector(PageNFT.UnexpectedValue.selector), what);
    }

    function _checkRefusals(uint256 value) internal {
        uint256 id = _reg(alice, "valued");
        vm.startPrank(alice);
        nft.approve(carol, id);
        nft.setApprovalForAll(dave, true);
        vm.stopPrank();
        address[3] memory movers = [alice, carol, dave];
        for (uint256 i; i < 3; ++i) {
            _assertRefused(movers[i], value, abi.encodeWithSignature("transferFrom(address,address,uint256)", alice, bob, id), "transferFrom");
            _assertRefused(
                movers[i], value, abi.encodeWithSignature("safeTransferFrom(address,address,uint256)", alice, bob, id),
                "safeTransferFrom"
            );
            _assertRefused(
                movers[i], value,
                abi.encodeWithSignature("safeTransferFrom(address,address,uint256,bytes)", alice, bob, id, "data"),
                "safeTransferFrom with data"
            );
        }
        _assertRefused(alice, value, abi.encodeCall(PageNFT.approve, (stranger, id)), "approve by the holder");
        _assertRefused(dave, value, abi.encodeCall(PageNFT.approve, (stranger, id)), "approve by the operator");
        assertEq(nft.ownerOf(id), alice, "the name did not move");
        assertEq(nft.getApproved(id), carol, "the approval did not change");
        // multicall has no payable entry, so value fails it before any inner call
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeCall(PageNFT.approve, (stranger, id));
        (bool ok, bytes memory ret) = _call(alice, value, abi.encodeCall(PageNFT.multicall, (calls)));
        assertFalse(ok, "multicall refuses value");
        assertEq(ret.length, 0);
        assertEq(nft.getApproved(id), carol);
        // without ETH the same calls follow the usual rules, so dave's approve replaces carol's approval, her transfer
        // fails and his safe transfer works
        (ok,) = _call(dave, 0, abi.encodeCall(PageNFT.approve, (stranger, id)));
        assertTrue(ok);
        assertEq(nft.getApproved(id), stranger);
        (ok,) = _call(carol, 0, abi.encodeWithSignature("transferFrom(address,address,uint256)", alice, bob, id));
        assertFalse(ok, "carol's approval was replaced");
        (ok,) = _call(dave, 0, abi.encodeWithSignature("safeTransferFrom(address,address,uint256)", alice, bob, id));
        assertTrue(ok);
        assertEq(nft.ownerOf(id), bob);
        assertEq(address(nft).balance, nft.depositOf(id), "PageNFT holds only the deposit");
    }

    function test_inheritedPayableFunctionsRejectValue() public {
        _checkRefusals(1);
    }

    function testFuzz_inheritedPayableFunctionsRejectValue(uint256 value) public {
        _checkRefusals(bound(value, 1, 1000 ether));
    }
}

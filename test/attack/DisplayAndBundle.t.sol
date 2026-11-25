// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {PageNFT} from "../../src/PageNFT.sol";
import {MinterBase} from "../utils/MinterBase.sol";

// a smart account that can hold names and forward calls, standing in for any contract account
contract ForwardingWallet {
    function exec(address t, bytes calldata d) external payable returns (bytes memory r) {
        bool ok;
        (ok, r) = t.call{value: msg.value}(d);
        if (!ok) assembly { revert(add(r, 0x20), mload(r)) }
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    receive() external payable {}
}

// a contract account with no token hook
contract BareContract {
    function exec(address t, bytes calldata d) external returns (bytes memory r) {
        bool ok;
        (ok, r) = t.call(d);
        if (!ok) assembly { revert(add(r, 0x20), mload(r)) }
    }
}

// Checks of display names, bundles and contract accounts.
contract DisplayAndBundleTest is MinterBase {
    bytes4 constant UNAUTHORIZED = 0x82b42900;
    bytes4 constant INSUFFICIENT_FEE = 0x025dbdd4;

    function _b(bytes memory x) internal pure returns (bytes[] memory d) {
        d = new bytes[](1);
        d[0] = x;
    }

    // multicall with any value is refused before its body runs
    function testFuzz_J1_valueRefused(uint96 v) public {
        vm.assume(v != 0);
        uint256 id = _reg(alice, "alice");
        uint256 before = address(nft).balance;
        vm.deal(alice, uint256(v));
        vm.prank(alice);
        (bool ok, bytes memory r) = address(nft).call{value: v}(
            abi.encodeCall(PageNFT.multicall, (_b(abi.encodeCall(PageNFT.renew, (id)))))
        );
        assertFalse(ok);
        assertEq(r.length, 0);
        assertEq(address(nft).balance, before);
    }

    // a paid call inside a bundle sees zero value and fails, since multicall takes no ETH
    function test_J2_paidCallInsideBundleFails() public {
        uint256 id = _reg(alice, "alice");
        uint256 exp = nft.expiresAt(id);
        vm.prank(alice);
        (bool ok, bytes memory r) =
            address(nft).call(abi.encodeCall(PageNFT.multicall, (_b(abi.encodeCall(PageNFT.renew, (id))))));
        assertFalse(ok);
        assertEq(bytes4(r), INSUFFICIENT_FEE);
        assertEq(nft.expiresAt(id), exp);
    }

    // each entry runs as the original caller, never as the contract
    function test_J3_callerKept() public {
        uint256 id = _reg(alice, "alice");
        bytes[] memory d = new bytes[](3);
        d[0] = abi.encodeCall(PageNFT.setText, (id, "url", "https://a.example"));
        d[1] = abi.encodeCall(PageNFT.setPrimaryPage, (id));
        d[2] = abi.encodeWithSignature("setAddr(uint256,address)", id, hot);
        vm.prank(alice);
        nft.multicall(d);
        assertEq(nft.primaryPage(alice), id);
        assertEq(nft.primaryPage(address(nft)), 0);
        assertEq(nft.text(id, "url"), "https://a.example");
        assertEq(nft.resolve(id), hot);
    }

    // a stranger's bundle fails with the single call's error and changes nothing
    function test_J4_strangerBundleUndone() public {
        uint256 id = _reg(alice, "alice");
        uint256 mine = _reg(stranger, "strange");
        bytes[] memory d = new bytes[](2);
        d[0] = abi.encodeCall(PageNFT.setText, (mine, "k", "v"));
        d[1] = abi.encodeCall(PageNFT.setText, (id, "k", "evil"));
        vm.prank(stranger);
        (bool ok, bytes memory r) = address(nft).call(abi.encodeCall(PageNFT.multicall, (d)));
        assertFalse(ok);
        assertEq(r, abi.encodeWithSelector(UNAUTHORIZED));
        assertEq(nft.text(mine, "k"), "");
        assertEq(nft.text(id, "k"), "");
    }

    // a sale by any route clears the seller's display name
    function test_J5_everyRouteClearsSeller() public {
        for (uint256 route; route < 4; ++route) {
            string memory label = string.concat("name", vm.toString(route));
            uint256 id = _reg(alice, label);
            vm.prank(alice);
            nft.setPrimaryPage(id);
            assertEq(nft.reverseResolve(alice), label);
            if (route == 0) {
                vm.prank(alice);
                nft.transferFrom(alice, buyer, id);
            } else if (route == 1) {
                vm.prank(alice);
                nft.setApprovalForAll(carol, true);
                vm.prank(carol);
                nft.safeTransferFrom(alice, buyer, id);
                vm.prank(alice);
                nft.setApprovalForAll(carol, false);
            } else if (route == 2) {
                vm.prank(alice);
                nft.approve(dave, id);
                vm.prank(dave);
                nft.safeTransferFrom(alice, buyer, id, hex"01");
            } else {
                bytes[] memory d = new bytes[](1);
                d[0] = abi.encodeWithSignature("transferFrom(address,address,uint256)", alice, buyer, id);
                vm.prank(alice);
                nft.multicall(d);
            }
            assertEq(nft.primaryPage(alice), 0);
            assertEq(nft.reverseResolve(alice), "");
            // the buyer points the name back at the seller and still cannot revive it
            vm.prank(buyer);
            nft.setAddr(id, alice);
            assertEq(nft.reverseResolve(alice), "");
        }
    }

    // an address the name pointed at keeps its own setting, but the buyer cannot revive it
    function test_J6_pointeeKeepsItsSettingButStaysHidden() public {
        uint256 id = _reg(alice, "alice");
        vm.prank(alice);
        nft.setAddr(id, hot);
        vm.prank(hot);
        nft.setPrimaryPage(id);
        vm.prank(alice);
        nft.transferFrom(alice, buyer, id);
        assertEq(nft.primaryPage(hot), id);
        assertEq(nft.reverseResolve(hot), "");
        vm.prank(buyer);
        nft.setAddr(id, hot);
        assertEq(nft.reverseResolve(hot), "");
    }

    // a self transfer and a failed transfer keep the setting
    function test_J7_selfAndFailedKeep() public {
        uint256 id = _reg(alice, "alice");
        vm.prank(alice);
        nft.setPrimaryPage(id);
        vm.prank(alice);
        nft.transferFrom(alice, alice, id);
        assertEq(nft.primaryPage(alice), id);
        vm.prank(stranger);
        vm.expectRevert();
        nft.transferFrom(alice, buyer, id);
        assertEq(nft.primaryPage(alice), id);
    }

    // a transfer clears the sender's display name and leaves the stored pointer of any account other than
    // the sender and the receiver as it was
    function testFuzz_J8_othersUntouched(address x, uint256 v) public {
        vm.assume(x != alice && x != address(0));
        uint256 id = _reg(alice, "alice");
        vm.store(address(nft), keccak256(abi.encode(x, uint256(3))), bytes32(v));
        vm.prank(alice);
        nft.setPrimaryPage(id);
        vm.prank(alice);
        nft.transferFrom(alice, buyer, id);
        if (x != buyer) assertEq(nft.primaryPage(x), v);
        assertEq(nft.primaryPage(alice), 0);
    }

    // no holder answers for another EVM chain by default: a key wallet and a contract account both answer only on the
    // home chain until they save an entry or a default, and the code at an address never changes an answer
    function test_J9_noHolderAnswersElsewhereUntilItSaves() public {
        uint256 a1 = _reg(alice, "eoa");
        ForwardingWallet w = new ForwardingWallet();
        uint256 a2 = _regTo(alice, "smart", address(w));
        // a key wallet answers on the home chain only
        assertEq(nft.addr(a1, 0x8000000a), abi.encodePacked(alice));
        assertEq(nft.addr(a1, 60).length, 0);
        assertEq(nft.addr(a1, 0x80000000 | 8453).length, 0);
        // a contract account the same
        assertEq(nft.addr(a2, 0x8000000a), abi.encodePacked(address(w)));
        assertEq(nft.addr(a2, 60).length, 0);
        assertEq(nft.addr(a2, 0x80000000 | 8453).length, 0);
        // an entry for coin type 60 answers there and nowhere else
        w.exec(address(nft), abi.encodeCall(PageNFT.setAddrForCoin, (a2, 60, abi.encodePacked(address(w)))));
        assertEq(nft.addr(a2, 60), abi.encodePacked(address(w)));
        assertEq(nft.addr(a2, 0x80000000 | 8453).length, 0);
        // a saved default answers on every EVM chain without an entry of its own
        vm.prank(alice);
        nft.setAddrForCoin(a1, 0x80000000, abi.encodePacked(alice));
        assertEq(nft.addr(a1, 60), abi.encodePacked(alice));
        assertEq(nft.addr(a1, 0x80000000 | 8453), abi.encodePacked(alice));
        // a delegation (EIP7702 designator) or contract code at the holder changes nothing
        vm.etch(alice, abi.encodePacked(hex"ef0100", address(w)));
        assertEq(nft.addr(a1, 60), abi.encodePacked(alice));
        assertEq(nft.addr(a1, 0x80000000 | 8453), abi.encodePacked(alice));
        vm.etch(alice, address(w).code);
        assertEq(nft.addr(a1, 60), abi.encodePacked(alice));
        assertEq(nft.addr(a1, 0x80000000 | 8453), abi.encodePacked(alice));
        // and code removed from the contract account adds nothing
        vm.etch(address(w), "");
        assertEq(nft.addr(a2, 60), abi.encodePacked(address(w)));
        assertEq(nft.addr(a2, 0x80000000 | 8453).length, 0);
    }

    // a contract account uses every function through msg.sender alone, bundles included
    function test_J10_contractAccountWorks() public {
        ForwardingWallet w = new ForwardingWallet();
        uint256 id = _regTo(alice, "vault", address(w));
        bytes[] memory d = new bytes[](2);
        d[0] = abi.encodeCall(PageNFT.setText, (id, "url", "x"));
        d[1] = abi.encodeCall(PageNFT.setPrimaryPage, (id));
        w.exec(address(nft), abi.encodeCall(PageNFT.multicall, (d)));
        assertEq(nft.reverseResolve(address(w)), "vault");
        w.exec(address(nft), abi.encodeWithSignature("transferFrom(address,address,uint256)", address(w), buyer, id));
        assertEq(nft.ownerOf(id), buyer);
        assertEq(nft.primaryPage(address(w)), 0);
    }

    // a mint that another account sends to a contract account with no token hook is refused
    function test_J11_noHookNoMint() public {
        BareContract bare = new BareContract();
        bytes32 secret = bytes32(uint256(7));
        bytes32 commitment = nft.makeCommitment("bare", address(bare), 0, secret);
        vm.prank(alice);
        nft.commit(commitment);
        vm.warp(vm.getBlockTimestamp() + 61);
        (,,, uint256 total) = nft.quote("bare");
        vm.prank(alice);
        vm.expectRevert(NON_RECEIVER);
        nft.reveal{value: total}("bare", address(bare), 0, secret);
        // a plain transfer still works
        uint256 id = _reg(alice, "plain");
        vm.prank(alice);
        nft.transferFrom(alice, address(bare), id);
        assertEq(nft.ownerOf(id), address(bare));
    }

    // the two inherited safeTransferFrom are payable in the ABI but refuse value through transferFrom
    function test_J12_safeTransferRefusesValue() public {
        uint256 id = _reg(alice, "alice");
        vm.prank(alice);
        vm.expectRevert(PageNFT.UnexpectedValue.selector);
        nft.safeTransferFrom{value: 1}(alice, buyer, id);
        vm.prank(alice);
        vm.expectRevert(PageNFT.UnexpectedValue.selector);
        nft.safeTransferFrom{value: 1}(alice, buyer, id, "");
        assertEq(nft.ownerOf(id), alice);
    }
}

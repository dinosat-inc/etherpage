// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {ProfileBase} from "../../utils/ProfileBase.sol";

contract SafeLike {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}

// The OP side of the avatar rules an app applies after reading the avatar record. nftHolder stands for
// the holder of the NFT read fresh on Ethereum.
// A: the NFT holder equals the main address (resolve), which the metadata description shows and which
//    money for the name is credited to.
// B: the NFT holder equals the name's holder (ownerOf).
// C: B, or the NFT holder is the name's Ethereum address addr(node, 60) and has chosen this name as its
//    display name.
// _shown: what an app shows, the record from text and then rule C.
contract ProfileAvatarTest is ProfileBase {
    address whale = makeAddr("whale");
    address hot = makeAddr("hot");

    function _a(uint256 id, address h) internal view returns (bool) {
        return h == nft.resolve(id);
    }

    function _b(uint256 id, address h) internal view returns (bool) {
        return h == nft.ownerOf(id);
    }

    function _c(uint256 id, address h) internal view returns (bool) {
        if (h == nft.ownerOf(id)) return true;
        bytes memory e = nft.addr(id, 60);
        if (e.length != 20 || address(bytes20(e)) != h) return false;
        return _eqs(nft.reverseResolve(h), nft.getPageName(id));
    }

    // the avatar an app shows under rule C, or "" for the placeholder
    function _shown(uint256 id, address nftHolder) internal view returns (string memory) {
        string memory rec = nft.text(id, "avatar");
        if (bytes(rec).length == 0) return "";
        return _c(id, nftHolder) ? rec : "";
    }

    function test_R1_plainWallet() public {
        uint256 id = _profiled(user, "alice");
        assertTrue(_a(id, user) && _b(id, user) && _c(id, user));
        assertEq(_shown(id, user), PUNK);
    }

    // the holder points the name at a whale and names the whale's punk
    function test_R2_pointAtWhale() public {
        uint256 id = _paid(bob, "bob");
        vm.startPrank(bob);
        nft.setAddr(id, whale);
        nft.setText(id, "avatar", PUNK);
        vm.stopPrank();
        assertTrue(_a(id, whale), "A would show the whale's punk on bob's name");
        assertFalse(_b(id, whale));
        assertFalse(_c(id, whale));
        assertEq(_shown(id, whale), "");
    }

    // the name sits in a cold wallet and points at a hot wallet that holds the NFT; the main address alone gives no
    // coin 60 answer, so the cold wallet saves the hot wallet as its default too
    function test_R3_hotWallet() public {
        uint256 id = _profiled(user, "alice");
        vm.prank(user);
        nft.setAddr(id, hot);
        assertEq(nft.addr(id, 60), "", "the main address does not answer coin 60");
        assertFalse(_c(id, hot), "no coin 60 answer yet");
        vm.prank(user);
        nft.setAddrForCoin(id, 0x80000000, abi.encodePacked(hot));
        assertEq(nft.addr(id, 60), abi.encodePacked(hot), "the saved default answers coin 60");
        assertFalse(_c(id, hot), "no display name yet");
        vm.prank(hot);
        nft.setPrimaryPage(id);
        assertTrue(_c(id, hot));
        assertEq(_shown(id, hot), PUNK);
    }

    // a sale: the record is hidden on chain, and the rule refuses too
    function test_R4_afterSale() public {
        uint256 id = _profiled(user, "alice");
        vm.prank(user);
        nft.setAddr(id, hot);
        vm.prank(hot);
        nft.setPrimaryPage(id);
        _move(user, bob, id);
        assertEq(nft.text(id, "avatar"), "", "the record itself is hidden after the sale");
        assertFalse(_c(id, user) || _c(id, hot));
        // the buyer points the name back at the seller's hot wallet, on coin 60 too, and adopts the profile
        vm.startPrank(bob);
        nft.setAddr(id, hot);
        nft.setAddrForCoin(id, 60, abi.encodePacked(hot));
        nft.keepProfile(id);
        vm.stopPrank();
        assertEq(nft.text(id, "avatar"), PUNK, "the buyer adopted the seller's avatar record");
        assertEq(nft.addr(id, 60), abi.encodePacked(hot), "coin 60 answers the hot wallet");
        assertTrue(_a(id, hot), "A would show the seller's NFT on the buyer's name");
        assertFalse(_c(id, hot), "C refuses: the seller's display name is hidden by the holder rule");
        assertEq(_shown(id, hot), "");
        assertEq(_shown(id, user), "");
    }

    // a contract account holds the name on OP
    function test_R5_contractHolder() public {
        SafeLike s = new SafeLike();
        vm.deal(user, 10 ether);
        uint256 id = _buy(user, "safe", address(s), 0);
        assertTrue(_a(id, address(s)) && _b(id, address(s)) && _c(id, address(s)), "same address taken as same owner");
        assertEq(nft.text(id, "avatar"), "", "a contract that never writes shows no profile");
    }

    // the NFT stays in the cold wallet that holds the name, which points at a hot wallet
    function test_R6_nftInColdWallet() public {
        uint256 id = _profiled(user, "alice");
        vm.prank(user);
        nft.setAddr(id, hot);
        assertFalse(_a(id, user), "A hides the owner's own NFT");
        assertTrue(_b(id, user) && _c(id, user));
        assertEq(_shown(id, user), PUNK);
    }

    // the seller sells the punk but keeps the name: the record still shows, only the NFT check hides it
    function test_R7_nftSoldNameKept() public {
        uint256 id = _profiled(user, "alice");
        address punkBuyer = makeAddr("punkBuyer");
        assertEq(nft.text(id, "avatar"), PUNK);
        assertEq(_shown(id, punkBuyer), "", "the NFT check is still needed in every profile option");
    }

    // the avatar record in each move, without any NFT check: empty after every move away from its writer
    function test_R8_recordAcrossMoves() public {
        uint256 id = _profiled(user, "alice");
        _move(user, bob, id);
        assertEq(nft.text(id, "avatar"), "");
        _move(bob, user2, id);
        assertEq(nft.text(id, "avatar"), "");
        _move(user2, user, id);
        assertEq(nft.text(id, "avatar"), PUNK, "back at its writer with no write in between");
    }
}

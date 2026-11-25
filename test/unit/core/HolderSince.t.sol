// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {PageNFT} from "../../../src/PageNFT.sol";
import {MinterBase} from "../../utils/MinterBase.sol";

// Takes the page during the mint callback and passes it straight on.
contract PassOn {
    address immutable next;

    constructor(address n) {
        next = n;
    }

    function onERC721Received(address, address, uint256 id, bytes calldata) external returns (bytes4) {
        PageNFT(msg.sender).transferFrom(address(this), next, id);
        return this.onERC721Received.selector;
    }
}

// Takes every page sent to it.
contract HolderSinceReceiver {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}

// holderSince is the time of the latest mint, or of the latest transfer to another account, and nothing else moves it.
contract HolderSinceTest is MinterBase {
    function _trialFor(address who, string memory label) internal returns (uint256 id) {
        bytes32 secret = keccak256(abi.encode(label));
        vm.prank(who);
        nft.commit(keccak256(abi.encode(bytes(label), who, uint256(0), secret, true)));
        vm.warp(vm.getBlockTimestamp() + 61);
        vm.prank(who);
        id = nft.revealTrial{value: nft.getFee(bytes(label).length) / 10}(label, who, 0, secret);
    }

    function test_zeroForAPageNeverMinted() public view {
        assertEq(nft.holderSince(_id("nobody")), 0);
        assertEq(nft.holderSince(0), 0);
    }

    function test_everyMintPathSetsIt() public {
        uint256 trial = _trialFor(alice, "trial");
        assertEq(nft.holderSince(trial), vm.getBlockTimestamp(), "revealTrial");
        uint256 shop = _reg(bob, "shop");
        assertEq(nft.holderSince(shop), vm.getBlockTimestamp(), "reveal");

        vm.warp(vm.getBlockTimestamp() + 5);
        vm.prank(bob);
        uint256 own = nft.registerSubpage("own", shop);
        assertEq(nft.holderSince(own), vm.getBlockTimestamp(), "registerSubpage");

        vm.warp(vm.getBlockTimestamp() + 5);
        vm.prank(bob);
        uint256 given = nft.registerSubpageFor("given", shop, carol);
        assertEq(nft.holderSince(given), vm.getBlockTimestamp(), "registerSubpageFor");

        _sellSetup(shop, 0);
        vm.warp(vm.getBlockTimestamp() + 5);
        vm.prank(buyer);
        uint256 sold = reg.registerSubpage(shop, "sold", 0, address(0));
        assertEq(nft.holderSince(sold), vm.getBlockTimestamp(), "registrar sale");
    }

    function test_transfersToAnotherAccountSetIt() public {
        uint256 id = _reg(alice, "alice");
        uint256 t0 = vm.getBlockTimestamp();

        vm.warp(t0 + 10);
        vm.prank(alice);
        nft.transferFrom(alice, alice, id);
        assertEq(nft.holderSince(id), t0, "a transfer to the same account");

        vm.prank(alice);
        nft.transferFrom(alice, bob, id);
        assertEq(nft.holderSince(id), t0 + 10, "transferFrom");

        vm.warp(t0 + 20);
        vm.prank(bob);
        nft.safeTransferFrom(bob, carol, id);
        assertEq(nft.holderSince(id), t0 + 20, "safeTransferFrom");

        vm.warp(t0 + 30);
        vm.prank(carol);
        nft.safeTransferFrom(carol, alice, id, "data");
        assertEq(nft.holderSince(id), t0 + 30, "safeTransferFrom with data");

        // any other account, address(1) included
        vm.warp(t0 + 40);
        vm.prank(alice);
        nft.transferFrom(alice, address(1), id);
        assertEq(nft.holderSince(id), t0 + 40, "a transfer to address(1)");
    }

    // an approved account, an operator, a safe transfer to a contract and a transfer in a batch all set it; a page
    // the dead address holds cannot move again, so its value stays
    function test_everyWayOfMovingItSetsIt() public {
        uint256 id = _reg(alice, "alice");
        uint256 t0 = vm.getBlockTimestamp();
        vm.warp(t0 + 10);
        vm.prank(alice);
        nft.approve(stranger, id);
        vm.prank(stranger);
        nft.transferFrom(alice, bob, id);
        assertEq(nft.holderSince(id), t0 + 10, "an approved account moves it");

        vm.warp(t0 + 20);
        HolderSinceReceiver r = new HolderSinceReceiver();
        vm.prank(bob);
        nft.setApprovalForAll(stranger, true);
        vm.prank(stranger);
        nft.safeTransferFrom(bob, address(r), id, "x");
        assertEq(nft.holderSince(id), t0 + 20, "an operator moves it safely to a contract");

        vm.warp(t0 + 30);
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeWithSignature("transferFrom(address,address,uint256)", address(r), carol, id);
        vm.prank(address(r));
        nft.multicall(calls);
        assertEq(nft.holderSince(id), t0 + 30, "a transfer in a batch");

        vm.warp(t0 + 40);
        vm.prank(carol);
        nft.transferFrom(carol, DEAD, id);
        assertEq(nft.holderSince(id), t0 + 40, "to the dead address");
        vm.warp(t0 + 50);
        vm.prank(DEAD);
        vm.expectRevert(PageNFT.Expired.selector);
        nft.transferFrom(DEAD, alice, id);
        assertEq(nft.holderSince(id), t0 + 40, "it cannot move again");
    }

    function test_nothingElseMovesIt() public {
        uint256 id = _reg(alice, "alice");
        uint256 t0 = vm.getBlockTimestamp();
        vm.warp(t0 + 100);
        vm.startPrank(alice);
        nft.setAddr(id, hot);
        nft.setAddrForCoin(id, 0x80002105, abi.encodePacked(hot2));
        nft.setText(id, "url", "x");
        nft.setContenthash(id, hex"e301");
        nft.setData(id, "k", hex"01");
        nft.setPrimaryPage(id);
        nft.approve(bob, id);
        nft.setApprovalForAll(carol, true);
        nft.setSubpageMinter(id, dave);
        nft.clearRecords(id);
        vm.stopPrank();
        vm.prank(stranger);
        nft.renew{value: 0.0001 ether}(id);
        assertEq(nft.holderSince(id), t0);
    }

    function test_registeringAgainSetsItForTheSameHolderToo() public {
        uint256 id = _reg(alice, "alice");
        _lapseAndRegister(id, alice);
        assertEq(nft.ownerOf(id), alice);
        assertEq(nft.holderSince(id), vm.getBlockTimestamp());
    }

    function test_aTrialGivenUpToTheDeadAddress() public {
        uint256 id = _trialFor(alice, "gone");
        vm.warp(vm.getBlockTimestamp() + 5);
        vm.prank(alice);
        nft.transferFrom(alice, DEAD, id);
        assertEq(nft.holderSince(id), vm.getBlockTimestamp());
    }

    function test_aPagePassedOnInsideTheMintCallback() public {
        PassOn p = new PassOn(carol);
        uint256 id = _regTo(alice, "alice", address(p));
        assertEq(nft.ownerOf(id), carol);
        assertEq(nft.holderSince(id), vm.getBlockTimestamp());
    }

    function test_subpages() public {
        uint256 shop = _reg(alice, "shop");
        vm.prank(alice);
        uint256 pay = nft.registerSubpageFor("pay", shop, bob);
        uint256 t0 = vm.getBlockTimestamp();

        vm.warp(t0 + 50);
        vm.prank(alice);
        nft.registerSubpageFor("pay", shop, carol);
        assertEq(nft.holderSince(pay), t0 + 50, "minted again for another account");

        vm.warp(t0 + 80);
        vm.prank(alice);
        nft.transferFrom(alice, dave, shop);
        assertEq(nft.holderSince(pay), t0 + 50, "a sale of the parent leaves the subpage's value");

        // the parent registered again: the subpage is Invalid and keeps its old value
        _lapseAndRegister(shop, stranger);
        assertEq(nft.holderSince(pay), t0 + 50);
    }

    // every new mint of a subpage sets it: for the same account, over the dead address by the minter or by the
    // holder of the parent, and under a new registration of the parent
    function test_subpagesMintedAgain() public {
        uint256 shop = _reg(alice, "shop");
        vm.prank(alice);
        uint256 pay = nft.registerSubpageFor("pay", shop, bob);
        _setMinter(shop, dave);
        uint256 t0 = vm.getBlockTimestamp();

        vm.warp(t0 + 10);
        vm.prank(alice);
        nft.registerSubpageFor("pay", shop, bob);
        assertEq(nft.holderSince(pay), t0 + 10, "minted again for the same account");

        vm.prank(bob);
        nft.transferFrom(bob, DEAD, pay);
        vm.warp(t0 + 20);
        vm.prank(dave);
        nft.registerSubpageFor("pay", shop, carol);
        assertEq(nft.holderSince(pay), t0 + 20, "the minter mints it again over the dead address");

        vm.prank(carol);
        nft.transferFrom(carol, DEAD, pay);
        vm.warp(t0 + 30);
        vm.prank(alice);
        nft.registerSubpage("pay", shop);
        assertEq(nft.holderSince(pay), t0 + 30, "the holder of the parent mints it again over the dead address");

        _lapseAndRegister(shop, carol);
        _setMinter(shop, dave);
        vm.warp(vm.getBlockTimestamp() + 10);
        vm.prank(dave);
        nft.registerSubpageFor("pay", shop, stranger);
        assertEq(nft.holderSince(pay), vm.getBlockTimestamp(), "the minter mints it under the new registration");
    }
}

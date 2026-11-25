// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {ERC721} from "solady/tokens/ERC721.sol";
import {PageNFT} from "../../../src/PageNFT.sol";
import {PageCard} from "../../../src/PageCard.sol";
import {SubpageRegistrar, IPageNFT} from "../../../src/SubpageRegistrar.sol";
import {AcceptedBase} from "./AcceptedBase.sol";

// Before its deploy transaction the registrar's address has no code, so a name minted or sent to it goes through,
// and once the registrar exists it can never move that name. A commit sent before PageNFT exists records nothing,
// and a commitment ripens twenty seconds after its block, so only a deployment that stops or stalls between
// PageNFT and the registrar leaves time for a name to get there. G-20 then finds a balance at the block that
// created the registrar.
contract AcceptedRegistrarBeforeItExistsTest is AcceptedBase {
    // a commit sent to the future PageNFT address before the contract exists calls an account with no code, so it
    // succeeds and records nothing
    function test_commitBeforeDeploymentRecordsNothing() public {
        address deployer = makeAddr("deployer");
        uint64 n = vm.getNonce(deployer);
        address cardAt = vm.computeCreateAddress(deployer, n);
        address nftAt = vm.computeCreateAddress(deployer, n + 1);
        bytes32 c = nft.makeCommitment("early", alice, 0, _secret("early", alice));
        (bool ok,) = nftAt.call(abi.encodeCall(PageNFT.commit, (c)));
        assertTrue(ok, "a call to an address with no code succeeds");
        vm.startPrank(deployer);
        PageCard card = new PageCard();
        PageNFT deployed = new PageNFT(card);
        vm.stopPrank();
        assertEq(address(card), cardAt);
        assertEq(address(deployed), nftAt);
        assertEq(deployed.commitments(c), 0, "nothing was recorded");
    }

    // while the deployment waits after PageNFT, a stranger starts a trial for the registrar's address, another pays
    // a year for it, a parent's holder mints it a subpage and a holder sends it a name with a safe transfer
    function test_mintToTheFutureRegistrarBeforeItExists() public {
        address deployer = makeAddr("deployer");
        uint64 n = vm.getNonce(deployer);
        address regAt = vm.computeCreateAddress(deployer, n + 2);
        vm.startPrank(deployer);
        nft = new PageNFT(new PageCard());
        vm.stopPrank();
        uint256 trial = _trial(stranger, "stuck", regAt, 0);
        uint256 paid = _buy(carol, "bought", regAt, 0);
        uint256 parent = _buy(dave, "parent", dave, 0);
        vm.prank(dave);
        uint256 sub = nft.registerSubpageFor("sub", parent, regAt);
        uint256 sent = _buy(alice, "moved", alice, 0);
        vm.prank(alice);
        nft.safeTransferFrom(alice, regAt, sent);

        vm.prank(deployer);
        reg = new SubpageRegistrar(IPageNFT(address(nft)));
        assertEq(address(reg), regAt);
        assertEq(nft.ownerOf(trial), regAt);
        assertEq(nft.ownerOf(paid), regAt);
        assertEq(nft.ownerOf(sub), regAt);
        assertEq(nft.ownerOf(sent), regAt);
        assertEq(nft.balanceOf(regAt), 4, "names that did not arrive by a plain transfer");

        // once the registrar has code, a safe transfer into it reverts
        uint256 other = _buy(bob, "other", bob, 0);
        vm.prank(bob);
        vm.expectRevert(ERC721.TransferToNonERC721ReceiverImplementer.selector);
        nft.safeTransferFrom(bob, regAt, other);
        assertEq(nft.ownerOf(other), bob);
    }
}

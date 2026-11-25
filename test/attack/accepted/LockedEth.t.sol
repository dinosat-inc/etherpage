// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {PageNFT} from "../../../src/PageNFT.sol";
import {PageCard} from "../../../src/PageCard.sol";
import {SubpageRegistrar, IPageNFT} from "../../../src/SubpageRegistrar.sol";
import {ForceSend} from "../../utils/TokenMocks.sol";
import {AcceptedBase} from "./AcceptedBase.sol";

// ETH sent to the contract addresses before they are deployed, or forced in with SELFDESTRUCT, is owed to nobody
// and stays for good. Neither contract reads its own balance, so the surplus changes nothing: every ledger pays out
// exactly and the balance falls to the surplus, never below it. Solvency on chain is therefore PageNFT's balance at
// least its deposits, its owed credits and the trial money it holds, and the registrar's balance at least its
// proceeds.
contract AcceptedLockedEthTest is AcceptedBase {
    uint256 constant SHOP_PRICE = 0.05 ether;
    uint256 surplusNft;
    uint256 surplusReg;
    uint256 paid;
    uint256 trial;
    address deployer = makeAddr("deployer");

    // the contracts' balances equal the surplus plus every ledger and the held trial money
    function _checkBooks() internal view {
        (, uint96 held) = nft.trialPaymentOf(trial);
        uint256 books = nft.depositOf(paid) + nft.depositOf(trial) + held + nft.owed(alice) + nft.owed(relayer)
            + nft.owed(DEAD) + nft.owed(deployer);
        assertEq(address(nft).balance, surplusNft + books, "PageNFT holds the surplus and its books");
        assertEq(address(reg).balance, surplusReg + reg.proceedsOf(payout), "the registrar holds the surplus and its proceeds");
    }

    function test_prefundedAndForcedEthIsLockedAndHarmless() public {
        uint64 n = vm.getNonce(deployer);
        address cardAt = vm.computeCreateAddress(deployer, n);
        address nftAt = vm.computeCreateAddress(deployer, n + 1);
        address regAt = vm.computeCreateAddress(deployer, n + 2);
        vm.deal(address(this), 10 ether);
        (bool s1,) = nftAt.call{value: 1 ether}("");
        (bool s2,) = regAt.call{value: 1 ether}("");
        assertTrue(s1 && s2, "an address with no code takes plain ETH");
        vm.startPrank(deployer);
        PageCard c = new PageCard();
        nft = new PageNFT(c);
        reg = new SubpageRegistrar(IPageNFT(address(nft)));
        vm.stopPrank();
        assertEq(address(c), cardAt);
        assertEq(address(nft), nftAt);
        assertEq(address(reg), regAt);
        new ForceSend{value: 1 ether}(payable(address(nft)));
        new ForceSend{value: 0.5 ether}(payable(address(reg)));
        surplusNft = 2 ether;
        surplusReg = 1.5 ether;
        assertEq(address(nft).balance, surplusNft);
        assertEq(address(reg).balance, surplusReg);

        // with the code in place a plain send is refused, and nobody is owed any of the surplus
        (bool s3,) = address(nft).call{value: 1}("");
        (bool s4,) = address(reg).call{value: 1}("");
        assertFalse(s3);
        assertFalse(s4);
        vm.expectRevert(PageNFT.NothingToWithdraw.selector);
        nft.withdraw(DEAD);
        vm.expectRevert(PageNFT.NothingToWithdraw.selector);
        nft.withdraw(deployer);
        vm.expectRevert(SubpageRegistrar.NothingToClaim.selector);
        reg.claimProceedsFor(deployer);
        _checkBooks();

        // a paid name, a trial, a shop sale and a renewal
        paid = _buy(alice, "money", alice, 0);
        _checkBooks();
        trial = _trial(relayer, "trialname", user, 0);
        _checkBooks();
        _openShop(paid, SHOP_PRICE, false);
        vm.prank(bob);
        reg.registerSubpage{value: SHOP_PRICE}(paid, "x", SHOP_PRICE, address(0));
        _checkBooks();
        uint256 fee = nft.getFee(bytes("money").length);
        vm.prank(carol);
        nft.renew{value: fee}(paid);
        _checkBooks();

        // the trial ends unpaid and the paid name lapses, both are released, and every ledger pays out
        vm.warp(nft.expiresAt(trial) + 1);
        nft.release(trial);
        _checkBooks();
        vm.warp(nft.expiresAt(paid) + 90 days + 21 days + 1);
        nft.release(paid);
        _checkBooks();
        assertEq(nft.owed(alice), 2 * fee, "the deposit goes to the payee");
        assertEq(nft.owed(relayer), _trialPrice("trialname"), "the trial money goes to its payer");
        nft.withdraw(alice);
        nft.withdraw(relayer);
        reg.claimProceedsFor(payout);
        _checkBooks();
        assertEq(address(nft).balance, surplusNft, "PageNFT falls to the surplus exactly");
        assertEq(address(reg).balance, surplusReg, "the registrar falls to the surplus exactly");
    }
}

// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Vm} from "forge-std/Test.sol";
import {PageNFT} from "../../../src/PageNFT.sol";
import {MinterBase} from "../../utils/MinterBase.sol";

// a custody contract that takes names and, when built with a nonzero address, saves that address as the main
// address of each name it receives
contract SavingCustody {
    address public saveAs;

    constructor(address a) {
        saveAs = a;
    }

    function onERC721Received(address, address, uint256 id, bytes calldata) external returns (bytes4) {
        if (saveAs != address(0)) PageNFT(msg.sender).setAddr(id, saveAs);
        return this.onERC721Received.selector;
    }
}

// The money of an auction goes to the payees of the moment: the last holder's answer for the deposit and 75 percent
// of the premium, the referrer name's current answer for the other 25 percent, whoever saved addresses before.
contract ReferrerLegsTest is MinterBase {
    bytes32 constant T_REF_PREMIUM = keccak256("ReferrerPremiumCredited(uint256,uint256,address,uint256)");
    bytes32 constant T_OWNER_PREMIUM = keccak256("OwnerPremiumCredited(uint256,address,uint256)");
    bytes32 constant T_BOUGHT = keccak256("DepositBoughtOut(uint256,address,uint256)");

    address bobMain = makeAddr("bobMain");
    address carolMain = makeAddr("carolMain");
    address aliceMain = makeAddr("aliceMain");

    // registers label for to with a referrer, paid by payer at the exact price
    function _regRef(address payer, string memory label, address to, uint256 ref) internal returns (uint256 id) {
        bytes32 secret = keccak256(abi.encode(payer, label, to, ref));
        bytes32 c = nft.makeCommitment(label, to, ref, secret);
        vm.prank(payer);
        nft.commit(c);
        vm.warp(vm.getBlockTimestamp() + 61);
        (,,, uint256 total) = nft.quote(label);
        vm.deal(payer, payer.balance + total);
        vm.prank(payer);
        id = nft.reveal{value: total}(label, to, ref, secret);
    }

    struct Sale {
        uint256 carried;
        uint256 premium;
        uint256 refShare;
        Vm.Log[] logs;
    }

    // dave commits one second into the premium window of label and buys it 61 seconds later
    function _auction(string memory label) internal returns (Sale memory s) {
        uint256 id = uint256(keccak256(abi.encodePacked(ROOT, keccak256(bytes(label)))));
        vm.warp(nft.expiresAt(id) + 90 days + 1);
        bytes32 secret = keccak256(abi.encode("auction", label));
        bytes32 c = nft.makeCommitment(label, dave, 0, secret);
        vm.prank(dave);
        nft.commit(c);
        vm.warp(vm.getBlockTimestamp() + 61);
        uint256 total;
        (, s.carried, s.premium, total) = nft.quote(label);
        assertGt(s.premium, 0, "inside the premium window");
        s.refShare = s.premium * 2500 / 10000;
        vm.deal(dave, dave.balance + total);
        vm.recordLogs();
        vm.prank(dave);
        nft.reveal{value: total}(label, dave, 0, secret);
        s.logs = vm.getRecordedLogs();
    }

    // the address a money event of the auction names, by its topic
    function _paidTo(Vm.Log[] memory logs, bytes32 topic) internal view returns (address to) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(nft) || logs[i].topics[0] != topic) continue;
            to = address(uint160(uint256(logs[i].topics[topic == T_REF_PREMIUM ? 3 : 2])));
        }
    }

    // the referrer name lapsed and was registered again before the auction: its new holder, or the address that
    // holder saved, gets the referrer share, and nothing goes to the earlier holder or the address it saved
    function test_referrerReRegisteredPaysNewHolder() public {
        uint256 ref = _reg(bob, "refname");
        vm.prank(bob);
        nft.setAddr(ref, bobMain);
        uint256 prize = _regRef(alice, "prize", alice, ref);
        // the prize is kept a year longer, so the referrer name can lapse and be registered again first
        uint256 fee = nft.getFee(5);
        vm.prank(alice);
        nft.renew{value: fee}(prize);
        vm.warp(nft.expiresAt(ref) + 111 days + 1);
        _reg(carol, "refname");
        assertEq(nft.ownerOf(ref), carol);
        // the registration of the referrer name paid its carried deposit to bob's saved address
        uint256 earlier = nft.owed(bob) + nft.owed(bobMain);
        uint256 snap = vm.snapshotState();

        Sale memory s = _auction("prize");
        assertEq(nft.owed(carol), s.refShare, "the new holder of the referrer name");
        assertEq(_paidTo(s.logs, T_REF_PREMIUM), carol);
        assertEq(nft.owed(bob) + nft.owed(bobMain), earlier, "nothing more to the earlier holder or its saved address");
        assertEq(nft.owed(alice), s.carried + s.premium - s.refShare);

        vm.revertToState(snap);
        vm.prank(carol);
        nft.setAddr(ref, carolMain);
        s = _auction("prize");
        assertEq(nft.owed(carolMain), s.refShare, "the address the new holder saved");
        assertEq(nft.owed(carol), 0);
        assertEq(nft.owed(bob) + nft.owed(bobMain), earlier);
        assertEq(_paidTo(s.logs, T_REF_PREMIUM), carolMain);
    }

    // the referrer name was sold before the auction: the buyer, or the address the buyer saved, gets the referrer
    // share; the seller's saved address never counts for the buyer
    function test_referrerSoldPaysBuyer() public {
        uint256 ref = _reg(bob, "refname");
        vm.prank(bob);
        nft.setAddr(ref, bobMain);
        _regRef(alice, "prize", alice, ref);
        vm.prank(bob);
        nft.transferFrom(bob, carol, ref);
        assertEq(nft.payee(ref), carol);
        uint256 snap = vm.snapshotState();

        Sale memory s = _auction("prize");
        assertEq(nft.owed(carol), s.refShare, "the buyer");
        assertEq(nft.owed(bob) + nft.owed(bobMain), 0, "never the seller or its saved address");

        vm.revertToState(snap);
        vm.prank(carol);
        nft.setAddr(ref, carolMain);
        s = _auction("prize");
        assertEq(nft.owed(carolMain), s.refShare, "the address the buyer saved");
        assertEq(nft.owed(carol) + nft.owed(bob) + nft.owed(bobMain), 0);
    }

    // the referrer share follows the referrer name's current answer: its holder's saved address, a buyer, a
    // custody contract and the address that contract saved while it holds the name
    function test_referralFollowsTheCurrentOwner() public {
        uint256 ref = _reg(bob, "refname");
        vm.prank(bob);
        nft.setAddr(ref, bobMain);
        _regRef(alice, "prize", alice, ref);
        uint256 snap = vm.snapshotState();

        Sale memory s = _auction("prize");
        assertEq(nft.owed(bobMain), s.refShare, "the address the holder saved");
        assertEq(nft.owed(bob), 0);

        // sold to carol, who saves nothing
        vm.revertToState(snap);
        vm.prank(bob);
        nft.transferFrom(bob, carol, ref);
        s = _auction("prize");
        assertEq(nft.owed(carol), s.refShare, "the buyer");
        assertEq(nft.owed(bobMain), 0);

        // carol moves it into a custody contract that saves an address for it on arrival
        vm.revertToState(snap);
        vm.prank(bob);
        nft.transferFrom(bob, carol, ref);
        address vaultSaved = makeAddr("vaultSaved");
        SavingCustody v = new SavingCustody(vaultSaved);
        vm.prank(carol);
        nft.safeTransferFrom(carol, address(v), ref);
        assertEq(nft.payee(ref), vaultSaved);
        s = _auction("prize");
        assertEq(nft.owed(vaultSaved), s.refShare, "the address the custody contract saved");
        assertEq(nft.owed(carol) + nft.owed(address(v)) + nft.owed(bobMain), 0);

        // a custody contract that saves nothing is the payee itself
        vm.revertToState(snap);
        SavingCustody plain = new SavingCustody(address(0));
        vm.prank(bob);
        nft.safeTransferFrom(bob, address(plain), ref);
        s = _auction("prize");
        assertEq(nft.owed(address(plain)), s.refShare, "the custody contract");
        assertEq(nft.owed(bobMain) + nft.owed(bob), 0);
    }

    // the seller saved a main address and sold the name, the buyer saved nothing and let it lapse: the carried
    // deposit and the owner share go to the buyer, and with no referrer the referrer share goes to DEAD
    function test_soldNameAuctionPaysBuyer() public {
        uint256 id = _reg(alice, "sold");
        vm.prank(alice);
        nft.setAddr(id, aliceMain);
        vm.prank(alice);
        nft.transferFrom(alice, bob, id);
        assertEq(nft.payee(id), bob);
        vm.warp(nft.expiresAt(id) + 1);
        assertEq(nft.payee(id), bob, "the payee answers while the name is inactive");
        Sale memory s = _auction("sold");
        assertEq(_paidTo(s.logs, T_BOUGHT), bob, "the carried deposit");
        assertEq(_paidTo(s.logs, T_OWNER_PREMIUM), bob, "the owner share");
        assertEq(_paidTo(s.logs, T_REF_PREMIUM), DEAD, "no referrer, so the referrer share goes to DEAD");
        assertEq(nft.owed(bob), s.carried + s.premium - s.refShare);
        assertEq(nft.owed(aliceMain) + nft.owed(alice), 0, "nothing to the seller or its saved address");
    }

    // a referrer name moved into the registrar with a plain transfer is the registrar's: its referrer shares are
    // credited to the registrar, which cannot take ETH, so they stay there
    function test_strandedReferrerSwallowsShares() public {
        uint256 ref = _reg(bob, "refname");
        _regRef(alice, "prizeone", alice, ref);
        _regRef(alice, "prizetwo", alice, ref);
        vm.prank(bob);
        nft.transferFrom(bob, address(reg), ref);
        assertEq(nft.ownerOf(ref), address(reg));
        assertEq(nft.payee(ref), address(reg));
        Sale memory s1 = _auction("prizeone");
        assertEq(nft.owed(address(reg)), s1.refShare);
        Sale memory s2 = _auction("prizetwo");
        assertEq(nft.owed(address(reg)), s1.refShare + s2.refShare, "each referrer share is credited to the registrar");
        assertEq(nft.owed(bob), 0, "the old holder gets nothing");
        // and they stay there, since the registrar has no way to take ETH
        vm.expectRevert(ETH_TRANSFER_FAILED);
        nft.withdraw(address(reg));
    }
}

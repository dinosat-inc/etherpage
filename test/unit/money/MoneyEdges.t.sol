// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {Base64} from "solady/utils/Base64.sol";
import {LibString} from "solady/utils/LibString.sol";
import {PageNFT} from "../../../src/PageNFT.sol";
import {PageCard} from "../../../src/PageCard.sol";
import {LedgerRefuser} from "../../utils/MoneyLogReplay.sol";
import {CardReader} from "../../utils/CardReader.sol";

// Edges of the money rules: a payee that is the PageNFT itself, a release and a registration of the same
// name in one block, a name renewed four hundred times, and the premium of a subpage.
contract MoneyEdgesTest is Test {
    PageNFT nft;
    CardReader reader;
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address dave = makeAddr("dave");
    address erin = makeAddr("erin");
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    bytes4 constant ETH_TRANSFER_FAILED = 0xb12d13eb;
    // the storage slots of _resolvedAddress and _addrSaver in PageNFT
    uint256 constant RESOLVED_ADDRESS_SLOT = 7;
    uint256 constant ADDR_SAVER_SLOT = 11;

    function setUp() public {
        vm.warp(1_800_000_000);
        nft = new PageNFT(new PageCard());
        vm.deal(bob, 1000 ether);
        vm.deal(carol, 1000 ether);
        vm.deal(dave, 1000 ether);
        vm.deal(erin, 1000 ether);
        reader = new CardReader();
    }

    function _secret(string memory l, address owner) internal pure returns (bytes32) {
        return keccak256(abi.encode("edges", l, owner));
    }

    // payer commits, 61 seconds pass, and payer registers l for owner at the quote
    function _buy(address payer, string memory l, address owner, uint256 ref) internal returns (uint256 id) {
        bytes32 c = nft.makeCommitment(l, owner, ref, _secret(l, owner));
        vm.prank(payer);
        nft.commit(c);
        vm.warp(vm.getBlockTimestamp() + 61);
        (,,, uint256 total) = nft.quote(l);
        vm.prank(payer);
        id = nft.reveal{value: total}(l, owner, ref, _secret(l, owner));
    }

    // writes a main address and its saver at the name's current record version, which no call can do when
    // the address is the PageNFT itself
    function _forceMain(uint256 id, address a, address saver) internal {
        uint256 v = nft.recordVersion(id);
        bytes32 r = keccak256(abi.encode(v, keccak256(abi.encode(id, RESOLVED_ADDRESS_SLOT))));
        bytes32 s = keccak256(abi.encode(v, keccak256(abi.encode(id, ADDR_SAVER_SLOT))));
        vm.store(address(nft), r, bytes32(uint256(uint160(a))));
        vm.store(address(nft), s, bytes32(uint256(uint160(saver))));
    }

    function _json(uint256 id) internal view returns (string memory) {
        return string(Base64.decode(LibString.slice(nft.tokenURI(id), 29)));
    }

    function _svg(uint256 id) internal view returns (string memory) {
        string memory json = _json(id);
        uint256 a = LibString.indexOf(json, "base64,") + 7;
        uint256 b = LibString.indexOf(json, '","attributes');
        return string(Base64.decode(LibString.slice(json, a, b)));
    }

    // dead address paths

    // A referrer name whose main address is the PageNFT, saved by its holder so that it counts, has DEAD as
    // payee. Its 25 percent of a later premium is credited to DEAD, never to the PageNFT, where no withdrawal
    // could ever pay it, and anyone sends it out of the contract to DEAD.
    function test_deadOnRegistryPayee() public {
        uint256 ref = _buy(carol, "referrer", carol, 0);
        uint256 id = _buy(bob, "alpha", bob, ref);
        _forceMain(ref, address(nft), carol);
        assertEq(nft.resolve(ref), address(nft), "the saved main address counts while its saver holds the name");
        assertEq(nft.payee(ref), DEAD, "a main address that is the PageNFT gives DEAD as payee");

        vm.warp(nft.expiresAt(id) + 90 days + 2 days);
        bytes32 c = nft.makeCommitment("alpha", dave, 0, _secret("alpha", dave));
        vm.prank(dave);
        nft.commit(c);
        vm.warp(vm.getBlockTimestamp() + 61);
        (, uint256 carried, uint256 premium, uint256 total) = nft.quote("alpha");
        uint256 refShare = premium * 2500 / 10_000;
        assertGt(refShare, 0);
        assertEq(nft.payee(ref), DEAD, "the referrer name's payee once it has expired");
        vm.expectEmit(true, true, true, true, address(nft));
        emit PageNFT.ReferrerPremiumCredited(id, ref, DEAD, refShare);
        vm.prank(dave);
        nft.reveal{value: total}("alpha", dave, 0, _secret("alpha", dave));
        assertEq(nft.owed(DEAD), refShare, "the referrer's share is credited to DEAD");
        assertEq(nft.owed(address(nft)), 0, "nothing is owed to the PageNFT");
        assertEq(nft.owed(carol), 0, "nor to the referrer name's holder");
        assertEq(nft.owed(bob), carried + premium - refShare, "the last payee gets the deposit and 75 percent");

        uint256 before = DEAD.balance;
        vm.expectEmit(true, true, true, true, address(nft));
        emit PageNFT.Withdrawn(DEAD, erin, refShare);
        vm.prank(erin);
        nft.withdraw(DEAD);
        assertEq(DEAD.balance, before + refShare, "the credit left the contract to DEAD");
        assertEq(nft.owed(DEAD), 0);
        vm.expectRevert(PageNFT.NothingToWithdraw.selector);
        nft.withdraw(address(nft));
    }

    // The last holder's main address is the PageNFT: at an auction the deposit taken over, the 75 percent
    // share and, with no referrer named, the 25 percent share are all credited to DEAD, and so is the deposit
    // of a release of a name in the same state. Nothing is owed to the holder or to the PageNFT.
    function test_addrRecordPointingAtRegistrySanitizesToDead() public {
        uint256 id = _buy(bob, "alpha", bob, 0);
        _forceMain(id, address(nft), bob);
        assertEq(nft.resolve(id), address(nft));
        assertEq(nft.payee(id), DEAD);

        vm.warp(nft.expiresAt(id) + 90 days + 1 days);
        bytes32 c = nft.makeCommitment("alpha", dave, 0, _secret("alpha", dave));
        vm.prank(dave);
        nft.commit(c);
        vm.warp(vm.getBlockTimestamp() + 61);
        (, uint256 carried, uint256 premium, uint256 total) = nft.quote("alpha");
        uint256 refShare = premium * 2500 / 10_000;
        vm.expectEmit(true, true, true, true, address(nft));
        emit PageNFT.DepositBoughtOut(id, DEAD, carried);
        vm.expectEmit(true, true, true, true, address(nft));
        emit PageNFT.ReferrerPremiumCredited(id, 0, DEAD, refShare);
        vm.expectEmit(true, true, true, true, address(nft));
        emit PageNFT.OwnerPremiumCredited(id, DEAD, premium - refShare);
        vm.prank(dave);
        nft.reveal{value: total}("alpha", dave, 0, _secret("alpha", dave));
        assertEq(nft.owed(DEAD), carried + premium);
        assertEq(nft.owed(bob), 0);
        assertEq(nft.owed(address(nft)), 0);

        uint256 id2 = _buy(carol, "bravo", carol, 0);
        _forceMain(id2, address(nft), carol);
        uint256 dep = nft.depositOf(id2);
        vm.warp(nft.expiresAt(id2) + 111 days + 1);
        uint256 deadBefore = nft.owed(DEAD);
        vm.expectEmit(true, true, true, true, address(nft));
        emit PageNFT.DepositReleased(id2, DEAD, dep);
        nft.release(id2);
        assertEq(nft.owed(DEAD), deadBefore + dep);
        assertEq(nft.owed(carol), 0);
        assertEq(nft.owed(address(nft)), 0);
    }

    // release and registration in one block

    // every wei the contract holds is the name's deposit or a credit
    function _assertBacked(uint256 id, address[3] memory credited) internal view {
        uint256 sum = nft.depositOf(id);
        for (uint256 i; i < 3; ++i) sum += nft.owed(credited[i]);
        assertEq(address(nft).balance, sum, "every wei is a deposit or a credit");
    }

    // One second after the auction a zero premium registration and a release of the same name are both valid, and
    // they race in one block. Registration first: it releases the deposit to the old payee by itself, the buyer pays
    // only the fee and the release then reverts. Release first: the old payee is credited the deposit and the buyer
    // pays only the fee. A buyer who sends the price it quoted at the last second of the auction, the fee and the old
    // deposit, gets the rest back in the same call; a buyer that takes no ETH reverts its own reveal, which releases
    // nothing, keeps its commitment and succeeds sending exactly the fee. Either way the old payee is credited once
    // and every wei stays backed.
    function test_releaseRaceWithRegistration() public {
        uint256 id = _buy(bob, "alpha", bob, 0);
        uint256 fee = nft.getFee(5);
        vm.prank(carol);
        nft.renew{value: fee}(id);
        uint256 carried = nft.depositOf(id);
        assertEq(carried, 2 * fee);
        LedgerRefuser refuser = new LedgerRefuser();
        address[3] memory credited = [bob, DEAD, dave];

        // both buyers commit within the day before the race
        uint256 p = nft.expiresAt(id) + 90 days + 21 days;
        vm.warp(p + 1 - 1 hours);
        bytes32 cd = nft.makeCommitment("alpha", dave, 0, _secret("alpha", dave));
        vm.prank(dave);
        nft.commit(cd);
        bytes32 cr = nft.makeCommitment("alpha", dave, 7, _secret("alpha", dave));
        refuser.commit(nft, cr);
        // the last second of the auction still prices in the deposit
        vm.warp(p);
        assertFalse(nft.isReleasable(id));
        (, uint256 lastCarried,, uint256 total) = nft.quote("alpha");
        assertEq(lastCarried, carried);
        assertEq(total, fee + carried);
        vm.warp(p + 1);
        assertEq(nft.getPremium(id), 0);
        assertTrue(nft.isReleasable(id));
        (uint256 qFee, uint256 qCarried,, uint256 qTotal) = nft.quote("alpha");
        assertEq(qFee, fee);
        assertEq(qCarried, 0, "one second later the deposit goes back instead");
        assertEq(qTotal, fee);
        uint256 snap = vm.snapshotState();

        // registration first
        uint256 daveBefore = dave.balance;
        vm.prank(dave);
        nft.reveal{value: total}("alpha", dave, 0, _secret("alpha", dave));
        assertEq(daveBefore - dave.balance, fee, "the buyer pays only the fee");
        assertEq(nft.owed(bob), carried, "the old payee is credited the deposit");
        assertEq(nft.depositOf(id), fee);
        assertEq(nft.owed(dave), 0, "the excess came back at once, not as a credit");
        _assertBacked(id, credited);
        vm.prank(erin);
        vm.expectRevert(PageNFT.NotReleasable.selector);
        nft.release(id);
        assertEq(nft.owed(bob), carried, "credited once");
        assertEq(nft.depositOf(id), fee);
        _assertBacked(id, credited);

        // release first, then the same buyer
        vm.revertToState(snap);
        vm.prank(erin);
        nft.release(id);
        assertEq(nft.owed(bob), carried, "the old payee is credited the deposit");
        assertEq(nft.depositOf(id), 0);
        _assertBacked(id, credited);
        daveBefore = dave.balance;
        vm.prank(dave);
        nft.reveal{value: total}("alpha", dave, 0, _secret("alpha", dave));
        assertEq(daveBefore - dave.balance, fee, "the buyer pays only the fee");
        assertEq(nft.depositOf(id), fee);
        assertEq(nft.owed(bob), carried, "credited once");
        assertEq(nft.owed(dave), 0, "the excess came back at once, not as a credit");
        _assertBacked(id, credited);

        // a buyer that takes no ETH
        vm.revertToState(snap);
        vm.expectRevert(ETH_TRANSFER_FAILED);
        refuser.reveal{value: total}(nft, "alpha", dave, 7, _secret("alpha", dave));
        assertEq(nft.commitments(cr), p + 1 - 1 hours, "the commitment survives the failed reveal");
        assertEq(nft.depositOf(id), carried, "the failed reveal released nothing");
        assertEq(nft.owed(bob), 0);
        assertEq(nft.ownerOf(id), bob);
        _assertBacked(id, credited);
        refuser.reveal{value: fee}(nft, "alpha", dave, 7, _secret("alpha", dave));
        assertEq(nft.ownerOf(id), dave);
        assertEq(nft.depositOf(id), fee);
        assertEq(nft.owed(bob), carried, "credited once");
        _assertBacked(id, credited);
    }

    // long life

    // Starting on 1 January 2026, a name renewed 400 times, each a year after the last, never meets the ten
    // year cap. Its expiry is exactly 401 years of 365 days after its registration, its deposit is 401 yearly
    // fees, its card shows the expiry date in 2426, its metadata shows the expiry and the deposit, and past its
    // grace the premium starts just under 10 ether and is gone 21 days later.
    function test_renew400Times() public {
        vm.warp(1_767_225_600);
        uint256 id = _buy(bob, "alpha", bob, 0);
        uint256 t0 = vm.getBlockTimestamp();
        uint256 fee = nft.getFee(5);
        for (uint256 i; i < 400; ++i) {
            vm.warp(vm.getBlockTimestamp() + 365 days);
            vm.prank(carol);
            nft.renew{value: fee}(id);
        }
        uint256 e = nft.expiresAt(id);
        assertEq(e, t0 + 401 * 365 days, "no expiry was cut or capped");
        assertEq(e, 14_413_161_661);
        assertEq(nft.depositOf(id), 401 * fee);
        assertEq(nft.depositOf(id), 0.0401 ether);
        assertEq(uint256(nft.status(id)), uint256(PageCard.Status.Active));
        assertEq(reader.read(_svg(id)).left, "Until 26 Sep 2426", "the card shows the expiry date");
        string memory json = _json(id);
        assertTrue(LibString.contains(json, '"Expires","display_type":"date","value":14413161661}'));
        assertTrue(LibString.contains(json, '"Deposit","display_type":"number","value":0.0401}'));

        vm.warp(e + 90 days);
        assertEq(nft.getPremium(id), 0, "no premium in grace");
        vm.warp(e + 90 days + 1);
        assertEq(nft.getPremium(id), 9999994488536155202, "the first second of the auction");
        vm.warp(e + 111 days);
        assertEq(nft.getPremium(id), 0, "none at the end of the window");
        assertFalse(nft.isReleasable(id));
        vm.warp(e + 111 days + 1);
        nft.release(id);
        assertEq(nft.owed(bob), 401 * fee, "the release pays the whole deposit to the payee");
        assertEq(uint256(nft.status(id)), uint256(PageCard.Status.Expired));
        assertTrue(LibString.contains(_json(id), '"Status","value":"Expired"'));
    }

    // subpages

    // A subpage never has a premium: getPremium answers zero for it at every edge of its parent's life and
    // on every day of the parent's auction, while the parent's own premium is not zero, and after the parent
    // is bought by someone else.
    function test_subpageNoPremium() public {
        uint256 parent = _buy(bob, "alpha", bob, 0);
        vm.prank(bob);
        uint256 sub = nft.registerSubpageFor("x", parent, carol);
        uint256 e = nft.expiresAt(parent);
        assertEq(nft.getPremium(sub), 0, "live");
        uint256[6] memory edges = [e, e + 1, e + 90 days, e + 111 days, e + 111 days + 1, e + 400 days];
        uint256 snap = vm.snapshotState();
        for (uint256 i; i < 6; ++i) {
            vm.warp(edges[i]);
            assertEq(nft.getPremium(sub), 0, "an edge of the parent's life");
        }
        vm.revertToState(snap);
        for (uint256 d; d < 21; ++d) {
            vm.warp(e + 90 days + 1 + d * 1 days);
            assertGt(nft.getPremium(parent), 0, "the parent is in its auction");
            assertEq(nft.getPremium(sub), 0, "a day of the parent's auction");
        }
        // dave buys the parent at auction; the old subpage stays and still has no premium
        bytes32 c = nft.makeCommitment("alpha", dave, 0, _secret("alpha", dave));
        vm.prank(dave);
        nft.commit(c);
        vm.warp(vm.getBlockTimestamp() + 61);
        (,,, uint256 total) = nft.quote("alpha");
        vm.prank(dave);
        nft.reveal{value: total}("alpha", dave, 0, _secret("alpha", dave));
        assertEq(nft.parentOf(sub), parent);
        assertEq(nft.getPremium(sub), 0, "after the parent is registered again");
        assertEq(nft.depositOf(sub), 0);
    }
}

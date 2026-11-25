// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Vm} from "forge-std/Test.sol";
import {Base64} from "solady/utils/Base64.sol";
import {ERC721} from "solady/tokens/ERC721.sol";
import {PageCard} from "../../../src/PageCard.sol";
import {PageNFT} from "../../../src/PageNFT.sol";
import {SubpageRegistrar, IPageNFT} from "../../../src/SubpageRegistrar.sol";
import {MinterBase} from "../../utils/MinterBase.sol";
import {Holder721} from "../../utils/MinterMocks.sol";
import {PageNFTNoRecycle} from "../../differential/harness/PageNFTNoRecycle.sol";

// The recycle bin: a live subpage held by DEAD counts as free. Top level names held by DEAD do not.
contract RecycleBinTest is MinterBase {
    bytes32 constant T_VERSION = keccak256("VersionChanged(bytes32,uint64)");
    bytes32 constant T_PRIMARY = keccak256("PrimaryPageSet(address,uint256)");
    bytes32 constant T_SUBREG = keccak256("SubpageRegistered(uint256,uint256,string)");
    bytes32 constant T_SOLD =
        keccak256("SubpageSold(uint256,uint256,address,address,address,address,uint256,string)");

    uint256 club;

    function setUp() public override {
        super.setUp();
        club = _reg(alice, "club");
    }

    // helpers

    function _sub(string memory label, address to) internal returns (uint256 id) {
        vm.prank(nft.ownerOf(club));
        id = nft.registerSubpageFor(label, club, to);
    }

    function _toDead(uint256 id) internal {
        address o = nft.ownerOf(id);
        vm.prank(o);
        nft.transferFrom(o, DEAD, id);
    }

    function _epoch(uint256 id) internal view returns (uint64 e) {
        (,,, e,) = nft.records(id);
    }

    function _pe(uint256 id) internal view returns (uint64 pe) {
        (,,,, pe) = nft.records(id);
    }

    function _json(uint256 id) internal view returns (string memory) {
        bytes memory uri = bytes(nft.tokenURI(id));
        bytes memory b64 = new bytes(uri.length - 29);
        for (uint256 i; i < b64.length; ++i) b64[i] = uri[29 + i];
        return string(Base64.decode(string(b64)));
    }

    function _contains(string memory hay, string memory needle) internal pure returns (bool) {
        return vm.indexOf(hay, needle) != type(uint256).max;
    }

    function _buy(uint256 parentId, string memory label, address who, address to, uint256 value)
        internal
        returns (uint256)
    {
        vm.prank(who);
        return reg.registerSubpageFor{value: value}(parentId, label, to, value, address(0));
    }

    function _countTransfers(Vm.Log[] memory logs, address from, address to, uint256 id)
        internal
        view
        returns (uint256 n)
    {
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory l = logs[i];
            if (l.emitter != address(nft) || l.topics.length != 4 || l.topics[0] != T_TRANSFER) continue;
            if (address(uint160(uint256(l.topics[1]))) == from && address(uint160(uint256(l.topics[2]))) == to
                && uint256(l.topics[3]) == id) ++n;
        }
    }

    // 1. delete by sending to DEAD, then a sale

    function test_holderSendsToDead_thenShopSellsFreshToken() public {
        uint256 id = _sub("bob", bob);
        vm.prank(bob);
        nft.setPrimaryPage(id);
        assertEq(nft.reverseResolve(bob), "bob.club");
        vm.startPrank(bob);
        nft.setText(id, "url", "https://bob.example");
        nft.setContenthash(id, hex"e301");
        nft.setAddr(id, carol);
        nft.setAddrForCoin(id, 60, abi.encodePacked(carol));
        vm.stopPrank();
        assertEq(nft.primaryPage(bob), id);
        assertFalse(nft.isAvailable("bob", club));

        _toDead(id);
        assertEq(nft.ownerOf(id), DEAD);
        assertTrue(nft.isAvailable("bob", club), "a live subpage held by DEAD is free");
        assertTrue(nft.isAvailable("BOB", club), "normalized the same way");
        // a deleted subpage answers nothing
        assertEq(nft.resolve(id), address(0));
        assertEq(nft.reverseResolve(bob), "");

        _sellSetup(club, 0.01 ether);
        uint256 v0 = nft.recordVersion(id);
        uint64 e0 = _epoch(id);
        uint256 nftEth = address(nft).balance;
        uint256 buyerEth = buyer.balance;

        vm.recordLogs();
        uint256 got = _buy(club, "bob", buyer, buyer, 0.01 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(got, id);
        assertEq(nft.ownerOf(id), buyer);
        assertEq(nft.recordVersion(id), v0 + 1, "record version bumped");
        assertEq(_epoch(id), e0 + 1, "subpage epoch bumped");
        assertEq(_pe(id), nft.epochOf(club));
        assertEq(nft.text(id, "url"), "", "old text gone");
        assertEq(nft.contenthash(id), "", "old contenthash gone");
        assertEq(nft.resolve(id), buyer, "old address gone");
        assertEq(nft.addr(id, COIN_OP), abi.encodePacked(buyer));
        assertEq(nft.addr(id, 60), "", "old coin type 60 entry gone, and the buyer saved none");
        assertEq(buyerEth - buyer.balance, 0.01 ether, "charged the configured price");
        assertEq(reg.proceedsOf(payout), 0.01 ether);
        assertEq(address(nft).balance, nftEth, "PageNFT ETH unchanged");
        assertFalse(nft.isAvailable("bob", club), "taken again");
        assertEq(nft.reverseResolve(bob), "", "bob's old pointer stays dead");
        assertEq(nft.primaryPage(bob), 0, "the move to DEAD cleared bob's pointer");
        assertEq(_countTransfers(logs, DEAD, address(0), id), 1, "burn from DEAD");
        assertEq(_countTransfers(logs, address(0), buyer, id), 1, "mint to the buyer");
        assertTrue(_has(logs, T_VERSION));
        assertTrue(_has(logs, T_SOLD));
        assertFalse(_has(logs, T_PRIMARY), "DEAD had no primary pointer");
    }

    // 2. the parent holder mints it again to DEAD

    function test_parentRemintsToDead_isFreeAtOnce() public {
        uint256 id = _sub("x", bob);
        vm.prank(bob);
        nft.setText(id, "k", "v");
        uint256 v0 = nft.recordVersion(id);
        vm.prank(alice);
        nft.registerSubpageFor("x", club, DEAD);
        assertEq(nft.ownerOf(id), DEAD);
        assertEq(nft.recordVersion(id), v0 + 1);
        assertEq(nft.text(id, "k"), "");
        assertTrue(nft.isAvailable("x", club));

        // a minter, which only creates, may now mint it
        _setMinter(club, hot);
        vm.prank(hot);
        nft.registerSubpageFor("x", club, carol);
        assertEq(nft.ownerOf(id), carol);
        assertFalse(nft.isAvailable("x", club));
    }

    function test_parentMintsFreshLabelToDead_staysFree() public {
        uint256 id = _sub("fresh", DEAD);
        assertEq(nft.ownerOf(id), DEAD);
        assertTrue(nft.isAvailable("fresh", club));
        _setMinter(club, hot);
        vm.prank(hot);
        nft.registerSubpageFor("fresh", club, hot);
        assertEq(nft.ownerOf(id), hot);
        assertEq(_epoch(id), 2);
    }

    // 3. the parent holder sends a subpage it holds

    function test_parentSendsHeldSubToDead() public {
        uint256 id = _sub("own", alice);
        assertFalse(nft.isAvailable("own", club));
        _toDead(id);
        assertTrue(nft.isAvailable("own", club));
        _sellSetup(club, 0);
        _buy(club, "own", buyer, carol, 0);
        assertEq(nft.ownerOf(id), carol);
    }

    // 4. a minter over DEAD and over anyone else

    function test_minterMintsOverDead_butNotOverAnyOtherHolder() public {
        Holder721 h = new Holder721();
        uint256 dead = _sub("d", bob);
        _toDead(dead);
        uint256 byBob = _sub("b", bob);
        uint256 byAlice = _sub("a", alice);
        uint256 byHot = _sub("h", hot);
        uint256 byContract = _sub("c", address(h));
        uint256 nearDead = _sub("n", address(0xdEaE));
        uint256 dead2 = _sub("z", address(uint160(0xdead) << 144));
        _setMinter(club, hot);

        vm.prank(hot);
        nft.registerSubpageFor("d", club, carol);
        assertEq(nft.ownerOf(dead), carol);

        string[6] memory labels = ["b", "a", "h", "c", "n", "z"];
        uint256[6] memory idsL = [byBob, byAlice, byHot, byContract, nearDead, dead2];
        for (uint256 i; i < 6; ++i) {
            assertFalse(nft.isAvailable(labels[i], club));
            address before = nft.ownerOf(idsL[i]);
            vm.prank(hot);
            vm.expectRevert(PageNFT.AlreadyRegistered.selector);
            nft.registerSubpageFor(labels[i], club, carol);
            assertEq(nft.ownerOf(idsL[i]), before);
        }
        // carol's fresh token is live again, so the minter is refused over it now
        vm.prank(hot);
        vm.expectRevert(PageNFT.AlreadyRegistered.selector);
        nft.registerSubpageFor("d", club, hot);
    }

    function test_minterAsRecipientOfDeadLabel_andSelfMint() public {
        uint256 id = _sub("d", DEAD);
        _setMinter(club, hot);
        vm.prank(hot);
        nft.registerSubpage("d", club);
        assertEq(nft.ownerOf(id), hot);
    }

    // 5. strangers

    function test_strangerCannotMintOverDead() public {
        uint256 id = _sub("d", DEAD);
        _setMinter(club, hot);
        uint256 gold = _reg(bob, "gold");
        vm.prank(bob);
        nft.setSubpageMinter(gold, stranger);

        address[4] memory who = [stranger, bob, hot2, address(reg)];
        for (uint256 i; i < 4; ++i) {
            vm.prank(who[i]);
            vm.expectRevert(PageNFT.NotParentOwner.selector);
            nft.registerSubpageFor("d", club, who[i]);
        }
        // the shop without being the minter
        vm.prank(alice);
        reg.configure(club, payout, address(0), 0, true, address(0), 0, false);
        vm.prank(buyer);
        vm.expectRevert(SubpageRegistrar.NotMinter.selector);
        reg.registerSubpageFor(club, "d", buyer, 0, address(0));
        assertEq(nft.ownerOf(id), DEAD);
    }

    // 6. burned top level names stay locked

    function _burnName(string memory label) internal returns (uint256 id) {
        id = _reg(alice, label);
        _toDead(id);
        assertEq(nft.ownerOf(id), DEAD);
    }

    function _tryRegister(string memory label, address who) internal returns (bool ok, bytes memory ret) {
        bytes32 secret = keccak256(abi.encode(label, who, vm.getBlockTimestamp()));
        bytes32 commitment = nft.makeCommitment(label, who, 0, secret);
        vm.prank(who);
        nft.commit(commitment);
        vm.warp(vm.getBlockTimestamp() + 61);
        (,,, uint256 total) = nft.quote(label);
        vm.prank(who);
        (ok, ret) = address(nft).call{value: total + 1 ether}(
            abi.encodeCall(PageNFT.reveal, (label, who, 0, secret))
        );
    }

    function test_burnedNamesStayLocked() public {
        string[3] memory words = ["maple", "cedar", "birch"];
        uint256[3] memory idsW;
        for (uint256 i; i < 3; ++i) idsW[i] = _burnName(words[i]);
        uint256 exp = nft.expiresAt(idsW[0]);
        // right after, near expiry, at expiry, in grace and a few minutes before grace ends, which leaves room for
        // the three reveals
        uint256[5] memory at = [vm.getBlockTimestamp(), exp - 1 days, exp, exp + 45 days, exp + 90 days - 400];
        for (uint256 t; t < 5; ++t) {
            if (at[t] > vm.getBlockTimestamp()) vm.warp(at[t]);
            for (uint256 i; i < 3; ++i) {
                assertFalse(nft.isAvailable(words[i], 0), "a top-level name held by DEAD is never free by the rule");
                (bool ok, bytes memory ret) = _tryRegister(words[i], stranger);
                assertFalse(ok);
                assertEq(bytes4(ret), PageNFT.AlreadyRegistered.selector);
                assertEq(nft.ownerOf(idsW[i]), DEAD);
            }
        }
    }

    function test_burnedPageRenewedByAnyone_staysLocked() public {
        uint256 id = _burnName("maple");
        vm.warp(nft.expiresAt(id) + 80 days);
        vm.prank(stranger);
        nft.renew{value: 0.0001 ether}(id);
        vm.warp(vm.getBlockTimestamp() + 200 days);
        assertFalse(nft.isAvailable("maple", 0));
        (bool ok, bytes memory ret) = _tryRegister("maple", bob);
        assertFalse(ok);
        assertEq(bytes4(ret), PageNFT.AlreadyRegistered.selector);
        // nobody can mint under it or pick a minter for it
        vm.prank(alice);
        vm.expectRevert(PageNFT.NotParentOwner.selector);
        nft.registerSubpageFor("x", id, alice);
        vm.prank(alice);
        vm.expectRevert(PageNFT.Unauthorized.selector);
        nft.setSubpageMinter(id, alice);
    }

    function test_minterPickedBeforeBurn_countsNoMore() public {
        uint256 id = _reg(alice, "maple");
        vm.prank(alice);
        nft.setSubpageMinter(id, hot);
        vm.prank(alice);
        reg.configure(id, payout, address(0), 0, true, address(0), 0, false);
        _toDead(id);
        assertEq(nft.subpageMinterOf(id), address(0));
        vm.prank(hot);
        vm.expectRevert(PageNFT.NotParentOwner.selector);
        nft.registerSubpageFor("x", id, hot);
        vm.prank(buyer);
        vm.expectRevert(SubpageRegistrar.StaleController.selector);
        reg.registerSubpageFor(id, "x", buyer, 0, address(0));
    }

    // 7. a lapsed burned name follows the ordinary rules

    function _regBoth(PageNFTNoRecycle base, string memory label, address who, bytes32 s) internal returns (uint256 id) {
        bytes32 commitment = nft.makeCommitment(label, who, 0, s);
        vm.prank(who);
        nft.commit(commitment);
        bytes32 baseCommitment = base.makeCommitment(label, who, 0, s);
        vm.prank(who);
        base.commit(baseCommitment);
        vm.warp(vm.getBlockTimestamp() + 61);
        (,,, uint256 t) = nft.quote(label);
        (,,, uint256 bt) = base.quote(label);
        assertEq(t, bt, "same total");
        vm.prank(who);
        id = nft.reveal{value: t}(label, who, 0, s);
        vm.prank(who);
        assertEq(base.reveal{value: t}(label, who, 0, s), id);
    }

    function test_burnedNameLapsed_ordinaryExpiryRules() public {
        PageNFTNoRecycle base = new PageNFTNoRecycle(card);
        uint256 id = _regBoth(base, "maple", alice, keccak256("s0"));
        vm.prank(alice);
        nft.transferFrom(alice, DEAD, id);
        vm.prank(alice);
        base.transferFrom(alice, DEAD, id);

        uint256 graceEnd = nft.expiresAt(id) + 90 days;
        assertEq(base.expiresAt(id), nft.expiresAt(id));
        vm.warp(graceEnd);
        assertFalse(nft.isAvailable("maple", 0));
        assertFalse(base.isAvailable("maple", 0));
        vm.warp(graceEnd + 1);
        assertTrue(nft.isAvailable("maple", 0));
        assertTrue(base.isAvailable("maple", 0));
        (uint256 f, uint256 c, uint256 p, uint256 t) = nft.quote("maple");
        (uint256 bf, uint256 bc, uint256 bp, uint256 bt) = base.quote("maple");
        assertEq(abi.encode(f, c, p, t), abi.encode(bf, bc, bp, bt), "quote identical");

        uint256 owedDead = nft.owed(DEAD);
        _regBoth(base, "maple", bob, keccak256("s1"));
        assertEq(nft.ownerOf(id), bob);
        assertEq(base.ownerOf(id), bob);
        assertEq(nft.epochOf(id), 2);
        // the carried deposit and the owner's premium share go to the payee, DEAD
        assertGt(nft.owed(DEAD), owedDead);
        assertEq(nft.owed(DEAD), base.owed(DEAD), "same credits as the reference build");
        assertEq(nft.depositOf(id), base.depositOf(id));
        assertEq(nft.recordVersion(id), base.recordVersion(id));
    }

    // 8. subpages under a parent held by DEAD

    function test_subpagesUnderDeadParent() public {
        PageNFTNoRecycle base = new PageNFTNoRecycle(card);
        uint256 live = _sub("live", bob);
        uint256 gone = _sub("gone", bob);
        _toDead(gone);
        _setMinter(club, hot);
        _sellSetup(club, 0);
        _toDead(club);

        // a parent DEAD holds is not active, so no label under it reads free, as nobody can mint it
        assertFalse(nft.isAvailable("fresh", club));
        assertFalse(nft.isAvailable("gone", club));
        assertFalse(nft.isAvailable("live", club));
        assertEq(nft.subpageMinterOf(club), address(0));
        // while the parent's registration runs, its live subpage still answers
        assertEq(nft.resolve(live), bob);

        address[3] memory who = [alice, hot, stranger];
        for (uint256 i; i < 3; ++i) {
            vm.prank(who[i]);
            vm.expectRevert(PageNFT.NotParentOwner.selector);
            nft.registerSubpageFor("gone", club, who[i]);
        }
        vm.prank(buyer);
        vm.expectRevert(SubpageRegistrar.StaleController.selector);
        reg.registerSubpageFor(club, "gone", buyer, 0, address(0));
        vm.prank(buyer);
        vm.expectRevert(SubpageRegistrar.StaleController.selector);
        reg.registerSubpageFor(club, "fresh", buyer, 0, address(0));
        assertEq(nft.ownerOf(gone), DEAD);
        assertEq(nft.ownerOf(live), bob);

        // the reference build agrees on the fresh label
        bytes32 s = keccak256("club");
        bytes32 baseCommitment = base.makeCommitment("club", alice, 0, s);
        vm.prank(alice);
        base.commit(baseCommitment);
        vm.warp(vm.getBlockTimestamp() + 61);
        (,,, uint256 total) = base.quote("club");
        vm.prank(alice);
        uint256 bclub = base.reveal{value: total}("club", alice, 0, s);
        vm.prank(alice);
        base.transferFrom(alice, DEAD, bclub);
        assertFalse(base.isAvailable("fresh", bclub));
        assertEq(base.isAvailable("fresh", bclub), nft.isAvailable("fresh", club));
    }

    // A shop under a parent sent to DEAD: every sale path is refused, and a subpage it sold keeps working while the
    // parent lasts. Once the parent is registered again the old terms are stale, and the new holder's shop sells the
    // old labels with nothing of their old records, also to the buyer who saved them.
    function test_shopUnderDeadParentThenRegisteredAgain() public {
        uint256 price = 0.01 ether;
        _sellSetup(club, price);
        uint256 sold = _buy(club, "sold", bob, bob, price);
        uint256 gone = _buy(club, "gone", buyer, buyer, price);
        vm.startPrank(buyer);
        nft.setData(gone, "k", hex"01");
        nft.setAddr(gone, hot);
        vm.stopPrank();
        uint256 savedAt = vm.getBlockTimestamp();
        vm.warp(savedAt + 10);
        _toDead(gone);
        assertEq(nft.holderSince(gone), savedAt + 10, "the move to DEAD sets holderSince");
        assertEq(nft.addressesUpdatedAt(gone), savedAt, "and leaves the address time");
        assertTrue(nft.isAvailable("gone", club));

        _toDead(club);
        assertFalse(nft.isAvailable("gone", club), "nothing is free under a parent DEAD holds");
        // every sale path is refused before any money moves
        vm.prank(carol);
        vm.expectRevert(SubpageRegistrar.StaleController.selector);
        reg.registerSubpage{value: price}(club, "gone", price, address(0));
        bytes32 s = keccak256("s");
        bytes32 c = reg.makeSubpageCommitment(club, "new", carol, s);
        vm.prank(carol);
        reg.commitSubpage(c);
        vm.warp(vm.getBlockTimestamp() + 61);
        vm.prank(carol);
        vm.expectRevert(SubpageRegistrar.StaleController.selector);
        reg.revealSubpage{value: price}(club, "new", s, price, address(0));
        // the old holder can neither change the shop nor stop it, and the registrar cannot mint by itself
        vm.startPrank(alice);
        vm.expectRevert(SubpageRegistrar.NotAuthorized.selector);
        reg.configure(club, payout, address(0), 0, true, address(0), 0, false);
        vm.expectRevert(SubpageRegistrar.NotAuthorized.selector);
        reg.disable(club);
        vm.stopPrank();
        vm.prank(address(reg));
        vm.expectRevert(PageNFT.NotParentOwner.selector);
        nft.registerSubpageFor("new", club, carol);
        assertEq(reg.proceedsOf(payout), 2 * price, "only the two sales were paid");

        // the subpage it sold keeps working, also past the old expiry once anyone renews the parent
        vm.prank(bob);
        nft.setData(sold, "k", hex"02");
        assertEq(nft.data(bytes32(sold), "k"), hex"02");
        uint256 e0 = nft.expiresAt(club);
        vm.prank(stranger);
        nft.renew{value: nft.getFee(4)}(club);
        vm.warp(e0 + 1);
        assertEq(nft.resolve(sold), bob);

        // registered again: both subpages are Invalid and free, and the old minter and terms are stale
        _lapseAndRegister(club, carol);
        uint256 again = vm.getBlockTimestamp();
        assertEq(uint256(nft.status(sold)), uint256(PageCard.Status.Invalid));
        assertTrue(nft.isAvailable("sold", club));
        assertTrue(nft.isAvailable("gone", club));
        assertEq(nft.subpageMinterOf(club), address(0), "the old minter does not carry over");
        vm.prank(dave);
        vm.expectRevert(SubpageRegistrar.StaleConfig.selector);
        reg.registerSubpage{value: price}(club, "gone", price, address(0));

        // the new holder sets up its own shop, which sells the old labels with empty records
        vm.warp(again + 5);
        _sellSetup(club, price);
        uint256 v = nft.recordVersion(gone);
        assertEq(_buy(club, "gone", buyer, buyer, price), gone, "the same buyer, over the token DEAD holds");
        assertEq(_buy(club, "sold", dave, dave, price), sold, "another buyer, over bob's token");
        assertEq(nft.recordVersion(gone), v + 1);
        assertEq(nft.holderSince(gone), again + 5, "the sale sets holderSince");
        assertEq(nft.addressesUpdatedAt(gone), savedAt, "and leaves the address time, older than the holder");
        assertEq(nft.resolve(gone), buyer, "the buyer's old main address does not come back");
        assertEq(nft.data(bytes32(gone), "k").length, 0, "nor the buyer's old data record");
        assertEq(nft.data(bytes32(sold), "k").length, 0, "bob's record never reaches dave");
        assertEq(nft.resolve(sold), dave);
        assertEq(uint256(nft.status(gone)), uint256(PageCard.Status.Active));
    }

    // 9. a parent in grace or registered again

    function test_deadSubWhileParentInGrace() public {
        uint256 id = _sub("d", DEAD);
        _setMinter(club, hot);
        vm.warp(nft.expiresAt(club) + 1);
        assertFalse(nft.isAvailable("d", club), "parent in grace, nothing is free");
        vm.prank(hot);
        vm.expectRevert(PageNFT.Expired.selector);
        nft.registerSubpageFor("d", club, hot);
        vm.prank(alice);
        vm.expectRevert(PageNFT.Expired.selector);
        nft.registerSubpageFor("d", club, alice);
        // renewed in grace, the same registration: free again, the minter still counts
        vm.prank(stranger);
        nft.renew{value: 0.001 ether}(club);
        assertTrue(nft.isAvailable("d", club));
        vm.prank(hot);
        nft.registerSubpageFor("d", club, hot);
        assertEq(nft.ownerOf(id), hot);
    }

    function test_deadSubAfterParentReRegistered() public {
        uint256 id = _sub("d", DEAD);
        uint256 kept = _sub("k", bob);
        uint64 pe0 = _pe(id);
        _lapseAndRegister(club, carol);
        assertEq(nft.ownerOf(club), carol);
        assertTrue(nft.isAvailable("d", club), "stale, free as before");
        assertTrue(nft.isAvailable("k", club), "stale, free as before");
        assertEq(_pe(id), pe0);
        vm.prank(carol);
        nft.setSubpageMinter(club, hot2);
        vm.prank(hot2);
        nft.registerSubpageFor("d", club, hot2);
        vm.prank(hot2);
        nft.registerSubpageFor("k", club, hot2);
        assertEq(nft.ownerOf(id), hot2);
        assertEq(nft.ownerOf(kept), hot2);
    }

    // 10. primary names

    function test_primaryPointerOfDeadIsCleared() public {
        uint256 id = _sub("d", bob);
        vm.prank(bob);
        nft.setAddr(id, DEAD);
        // DEAD has no known key; a prank shows what happens if it ever acted
        vm.prank(DEAD);
        nft.setPrimaryPage(id);
        assertEq(nft.primaryPage(DEAD), id);
        assertEq(nft.reverseResolve(DEAD), "d.club");
        _toDead(id);
        assertEq(nft.reverseResolve(DEAD), "", "a deleted subpage answers nothing");
        vm.prank(DEAD);
        vm.expectRevert(PageNFT.Expired.selector);
        nft.setPrimaryPage(id);
        _setMinter(club, hot);
        vm.expectEmit(true, true, false, true, address(nft));
        emit PageNFT.PrimaryPageSet(DEAD, 0);
        vm.prank(hot);
        nft.registerSubpageFor("d", club, carol);
        assertEq(nft.primaryPage(DEAD), 0);
        assertEq(nft.reverseResolve(DEAD), "");
    }

    function test_oldHolderPrimaryDoesNotFollowTheName() public {
        uint256 id = _sub("d", bob);
        vm.prank(bob);
        nft.setPrimaryPage(id);
        _toDead(id);
        assertEq(nft.reverseResolve(bob), "");
        _setMinter(club, hot);
        vm.prank(hot);
        nft.registerSubpageFor("d", club, carol);
        assertEq(nft.reverseResolve(bob), "");
        assertEq(nft.reverseResolve(carol), "");
        vm.prank(carol);
        nft.setPrimaryPage(id);
        assertEq(nft.reverseResolve(carol), "d.club");
    }

    // 11. the events of a recycle mint and of a delete

    function test_eventsOfARecycleMint() public {
        uint256 id = _sub("d", bob);
        _toDead(id);
        _setMinter(club, hot);
        uint256 v = nft.recordVersion(id);

        vm.expectEmit(true, true, true, true, address(nft));
        emit ERC721.Transfer(DEAD, address(0), id);
        vm.expectEmit(true, false, false, true, address(nft));
        emit PageNFT.VersionChanged(bytes32(id), uint64(v + 1));
        vm.expectEmit(true, true, true, true, address(nft));
        emit ERC721.Transfer(address(0), carol, id);
        vm.expectEmit(true, true, false, true, address(nft));
        emit PageNFT.SubpageRegistered(id, club, "d");
        vm.recordLogs();
        vm.prank(hot);
        nft.registerSubpageFor("d", club, carol);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 transfers;
        uint256 versions;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == T_TRANSFER) ++transfers;
            if (logs[i].topics[0] == T_VERSION) ++versions;
            assertTrue(logs[i].topics[0] != T_MINTER_SET, "no minter change");
            assertTrue(logs[i].topics[0] != T_PRIMARY, "no primary pointer to clear");
        }
        assertEq(transfers, 2);
        assertEq(versions, 1);
    }

    function test_sendingToDeadEmitsOnlyATransfer() public {
        uint256 id = _sub("d", bob);
        vm.recordLogs();
        _toDead(id);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_countTransfers(logs, bob, DEAD, id), 1);
        assertFalse(_has(logs, T_VERSION));
        assertFalse(_has(logs, T_SUBREG));
    }

    // 12. the card of a subpage held by DEAD

    function test_cardAndTokenURIOfDeadHeldSubpage() public {
        uint256 id = _sub("d", bob);
        vm.prank(bob);
        nft.setAddr(id, carol);
        vm.prank(bob);
        nft.setText(id, "url", "kept");
        _toDead(id);
        assertEq(nft.payee(id), DEAD);
        // a deleted subpage answers nothing and its card says Invalid
        assertEq(nft.resolve(id), address(0));
        assertEq(nft.text(id, "url"), "");
        string memory j = _json(id);
        assertTrue(_contains(j, '"name":"d.club"'));
        assertTrue(_contains(j, '"value":"Subpage"'));
        assertTrue(_contains(j, '"value":"Invalid"'));
        assertTrue(_contains(j, card.shortAddress(DEAD)));
        string memory svg = card.render("d", "club", bytes32(id), PageCard.Status.Invalid, 0);
        assertTrue(_contains(j, Base64.encode(bytes(svg))), "image is the Invalid card of d.club");

        _setMinter(club, hot);
        vm.prank(hot);
        nft.registerSubpageFor("d", club, carol);
        j = _json(id);
        assertTrue(_contains(j, card.shortAddress(carol)));
        assertEq(nft.text(id, "url"), "");
    }

    // 13. commit and reveal sales

    function test_commitRevealSaleOfDeadLabel() public {
        uint256 id = _sub("d", bob);
        _setMinter(club, address(reg));
        _configure(club, payout, address(0), 0.02 ether, true);
        bytes32 secret = keccak256("secret");
        // committed while bob still holds it
        bytes32 c = reg.makeSubpageCommitment(club, "d", buyer, secret);
        vm.prank(buyer);
        reg.commitSubpage(c);
        vm.warp(vm.getBlockTimestamp() + 61);
        vm.prank(buyer);
        vm.expectRevert(SubpageRegistrar.NotAvailable.selector);
        reg.revealSubpage{value: 0.02 ether}(club, "d", secret, 0.02 ether, address(0));
        // the reveal removes its commitment before it checks that the label is free, so its revert kept the
        // commitment for the next try
        _toDead(id);
        vm.prank(buyer);
        reg.revealSubpage{value: 0.02 ether}(club, "d", secret, 0.02 ether, address(0));
        assertEq(nft.ownerOf(id), buyer);
        assertEq(reg.proceedsOf(payout), 0.02 ether);
        // a direct buy is refused on a commit and reveal parent
        _toDead(id);
        vm.prank(stranger);
        vm.expectRevert(SubpageRegistrar.CommitRequired.selector);
        reg.registerSubpage{value: 0.02 ether}(club, "d", 0.02 ether, address(0));
    }

    function test_twoBuyersRaceForADeadLabel() public {
        uint256 id = _sub("d", DEAD);
        _sellSetup(club, 0.01 ether);
        _buy(club, "d", buyer, buyer, 0.01 ether);
        vm.prank(stranger);
        vm.expectRevert(SubpageRegistrar.NotAvailable.selector);
        reg.registerSubpageFor{value: 0.01 ether}(club, "d", stranger, 0.01 ether, address(0));
        assertEq(nft.ownerOf(id), buyer);
    }

    function test_erc20SaleOfDeadLabel() public {
        uint256 id = _sub("d", DEAD);
        _setMinter(club, address(reg));
        _configure(club, payout, address(usd), 5 ether, false);
        usd.mint(buyer, 5 ether);
        vm.prank(buyer);
        usd.approve(address(reg), 5 ether);
        vm.prank(buyer);
        reg.registerSubpage(club, "d", 5 ether, address(usd));
        assertEq(nft.ownerOf(id), buyer);
        assertEq(usd.balanceOf(payout), 5 ether);
    }

    // isAvailable for a fresh, held, deleted or invalid label, under a subpage or a missing parent, for a top level
    // name held by alice or by DEAD, and under a parent DEAD holds

    function test_isAvailableTable() public {
        uint256 held = _sub("held", bob);
        _sub("dead", DEAD);
        assertTrue(nft.isAvailable("none", club));
        assertFalse(nft.isAvailable("held", club));
        assertTrue(nft.isAvailable("dead", club));
        assertFalse(nft.isAvailable("-bad", club));
        assertFalse(nft.isAvailable("dead", held), "a subpage is never a parent");
        assertFalse(nft.isAvailable("dead", 12345), "missing parent");
        assertFalse(nft.isAvailable("club", 0), "top-level held by alice");
        _toDead(club);
        assertFalse(nft.isAvailable("club", 0), "top-level held by DEAD");
        // nothing is free under a parent DEAD holds: not a label whose subpage DEAD holds, nor one with no record
        assertFalse(nft.isAvailable("dead", club));
        assertFalse(nft.isAvailable("none", club));
        assertFalse(nft.isAvailable("held", club));
    }

    // the DEAD rule reads only DEAD, not the zero address or another burn address
    function test_onlyDeadCounts() public {
        _sub("a", address(0xdEaE));
        _sub("b", address(uint160(0xdead) << 144));
        _sub("c", address(0xdEaD));
        assertFalse(nft.isAvailable("a", club));
        assertFalse(nft.isAvailable("b", club));
        assertTrue(nft.isAvailable("c", club));
        vm.expectRevert(ERC721.TransferToZeroAddress.selector);
        vm.prank(alice);
        nft.registerSubpageFor("z", club, address(0));
    }
}

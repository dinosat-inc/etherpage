// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Vm} from "forge-std/Test.sol";
import {PageNFT} from "../../../src/PageNFT.sol";
import {PageCard} from "../../../src/PageCard.sol";
import {ProfileBase, Vault, Lending} from "../../utils/ProfileBase.sol";

// The profile (text records and the website) counts only while its writer, the account that last wrote
// or kept it, holds the name. Each story below is what a user or an app sees, and every story but the
// last checks the avatar record.
contract ProfileScenariosTest is ProfileBase {
    // sales and sends

    // OpenSea style: an approved conduit moves the name with safeTransferFrom and data
    function test_S01_openSeaSaleByOperator() public {
        uint256 id = _profiled(user, "alice");
        _assertFull(id);
        assertEq(nft.addr(id, BTC), bytes("bc1qalice"));
        vm.prank(user);
        nft.setApprovalForAll(seaport, true);
        vm.recordLogs();
        vm.prank(seaport);
        nft.safeTransferFrom(user, bob, id, hex"1234");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_profileLogs(logs), 0, "a transfer emits no profile event");
        _assertEmpty(id);
        assertEq(nft.addr(id, BTC).length, 0, "addresses reset as before");
        assertEq(nft.profileWriter(id), user, "the writer is still the seller");
        assertEq(nft.resolve(id), bob);
        // the buyer writes one field: only that field shows, the seller's avatar does not come back
        vm.recordLogs();
        vm.prank(bob);
        nft.setText(id, "url", "https://bob.example");
        logs = vm.getRecordedLogs();
        assertEq(logs.length, 2);
        _assertPwc(logs[0], id, bob, true);
        assertEq(logs[1].topics[0], T_TEXT);
        assertEq(nft.text(id, "url"), "https://bob.example");
        assertEq(nft.text(id, "avatar"), "", "no seller avatar next to the buyer's link");
        assertEq(nft.contenthash(id).length, 0, "no seller website");
        // the seller can neither write nor keep, and the conduit cannot keep
        vm.prank(user);
        vm.expectRevert(PageNFT.Unauthorized.selector);
        nft.setText(id, "avatar", PUNK);
        vm.prank(user);
        vm.expectRevert(PageNFT.Unauthorized.selector);
        nft.keepProfile(id);
        vm.prank(seaport);
        vm.expectRevert(PageNFT.Unauthorized.selector);
        nft.keepProfile(id);
    }

    // the sale goes through transferFrom, as a Seaport conduit does for ERC721
    function test_S01b_openSeaSaleByTransferFrom() public {
        uint256 id = _profiled(user, "alice");
        vm.prank(user);
        nft.setApprovalForAll(seaport, true);
        vm.prank(seaport);
        nft.transferFrom(user, bob, id);
        _assertEmpty(id);
    }

    // the name comes back to the seller before the buyer wrote anything: the seller's profile shows again
    function test_S01c_boughtBackBeforeTheBuyerWrote() public {
        uint256 id = _profiled(user, "alice");
        _move(user, bob, id);
        _assertEmpty(id);
        _move(bob, user, id);
        _assertFull(id);
    }

    // a wallet send (MetaMask) to another person, with both transfer forms
    function test_S02_walletSend() public {
        uint256 id = _profiled(user, "alice");
        _move(user, bob, id);
        _assertEmpty(id);
        uint256 id2 = _profiled(carol, "carol");
        vm.prank(carol);
        nft.safeTransferFrom(carol, dave, id2);
        _assertEmpty(id2);
        assertEq(nft.text(id2, "avatar"), "");
    }

    // the recipient may adopt what it found, avatar included, with one call
    function test_S02b_recipientCanAdopt() public {
        uint256 id = _profiled(user, "alice");
        _move(user, bob, id);
        vm.recordLogs();
        _keep(bob, id);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        _assertPwc(logs[0], id, bob, false);
        _assertFull(id);
        assertEq(nft.text(id, "avatar"), PUNK, "the seller's avatar record, now shown by the buyer's choice");
    }

    // own wallets and custody

    // moving to one's own other wallet hides the profile until that wallet keeps it
    function test_S03_ownWalletMoveAndKeep() public {
        uint256 id = _profiled(user, "alice");
        _move(user, user2, id);
        _assertEmpty(id);
        vm.recordLogs();
        _keep(user2, id);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "keep logs one event");
        _assertPwc(logs[0], id, user2, false);
        _assertFull(id);
        assertEq(nft.profileWriter(id), user2);
        assertEq(nft.addr(id, BTC).length, 0, "chain entries still need saving again");
        vm.prank(user2);
        vm.expectRevert(PageNFT.AlreadyKept.selector);
        nft.keepProfile(id);
        // later writes by the keeper add to the same profile, with no ProfileWriterChanged event
        vm.recordLogs();
        vm.prank(user2);
        nft.setText(id, "description", "moved");
        assertEq(_profileLogs(vm.getRecordedLogs()), 0);
        _assertFull(id);
        assertEq(nft.text(id, "description"), "moved");
    }

    // the keep bundled with the first edit, in one transaction
    function test_S03b_ownWalletMoveKeepAndEditInOneBundle() public {
        uint256 id = _profiled(user, "alice");
        _move(user, user2, id);
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(PageNFT.keepProfile, (id));
        calls[1] = abi.encodeWithSignature("setText(uint256,string,string)", id, "url", "https://new.example");
        vm.recordLogs();
        vm.prank(user2);
        nft.multicall(calls);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_profileLogs(logs), 1);
        _assertPwc(logs[0], id, user2, false);
        assertEq(nft.text(id, "avatar"), PUNK);
        assertEq(nft.text(id, "url"), "https://new.example");
        assertEq(nft.contenthash(id), SITE);
    }

    // a vault that never writes: hidden while it holds the name, back with no action after
    function test_S04_vaultRoundTrip() public {
        uint256 id = _profiled(user, "alice");
        Vault v = new Vault();
        vm.prank(user);
        nft.safeTransferFrom(user, address(v), id);
        _assertEmpty(id);
        assertEq(nft.addr(id, BTC).length, 0);
        vm.recordLogs();
        v.give(nft, user, id);
        assertEq(_profileLogs(vm.getRecordedLogs()), 0);
        _assertFull(id);
        assertEq(nft.addr(id, BTC), bytes("bc1qalice"), "chain entry back as before");
        assertEq(nft.text(id, "avatar"), PUNK);
    }

    // a loan: back on repay with no action; the lender who seizes it sees an empty profile
    function test_S04b_lendingRepayAndDefault() public {
        uint256 id = _profiled(user, "alice");
        Lending lend = new Lending(nft);
        vm.prank(user);
        nft.safeTransferFrom(user, address(lend), id, abi.encode(dave));
        _assertEmpty(id);
        vm.prank(user);
        lend.repay(id);
        _assertFull(id);
        vm.prank(user);
        nft.safeTransferFrom(user, address(lend), id, abi.encode(dave));
        vm.prank(dave);
        lend.seize(id);
        _assertEmpty(id);
        assertEq(nft.ownerOf(id), dave);
    }

    // the gift back

    // a middle holder plants a scam link and gives the name back: hidden
    function test_S05_giftBackPlantHidden() public {
        uint256 id = _profiled(user, "alice");
        _move(user, bob, id);
        vm.prank(bob);
        nft.setText(id, "url", SCAM);
        vm.prank(bob);
        nft.setText(id, "avatar", MILADY);
        _move(bob, user, id);
        _assertEmpty(id);
        assertEq(nft.text(id, "avatar"), "", "the planted avatar does not show");
        // keeping shows what the holder adopts, the plant included; the old profile is gone for good
        _keep(user, id);
        assertEq(nft.text(id, "url"), SCAM);
        assertEq(nft.text(id, "avatar"), MILADY);
        assertEq(nft.text(id, "com.twitter"), "", "the original profile was discarded by bob's write");
        assertEq(nft.contenthash(id).length, 0);
    }

    // after a gift back the holder writes instead of keeping: a new empty profile with only that field
    function test_S05b_giftBackThenWrite() public {
        uint256 id = _profiled(user, "alice");
        _move(user, bob, id);
        vm.prank(bob);
        nft.setText(id, "url", SCAM);
        _move(bob, user, id);
        vm.recordLogs();
        vm.prank(user);
        nft.setText(id, "avatar", PUNK);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        _assertPwc(logs[0], id, user, true);
        assertEq(nft.text(id, "avatar"), PUNK);
        assertEq(nft.text(id, "url"), "", "the plant is discarded");
        vm.prank(user);
        vm.expectRevert(PageNFT.AlreadyKept.selector);
        nft.keepProfile(id);
        assertEq(nft.text(id, "url"), "");
    }

    // the middle holder keeps, plants and gives back: hidden until the holder chooses to keep
    function test_S05c_giftBackAfterKeep() public {
        uint256 id = _profiled(user, "alice");
        _move(user, bob, id);
        _keep(bob, id);
        vm.prank(bob);
        nft.setText(id, "url", SCAM);
        _move(bob, user, id);
        _assertEmpty(id);
        _keep(user, id);
        assertEq(nft.text(id, "url"), SCAM, "keeping adopts the plant too");
        assertEq(nft.text(id, "avatar"), PUNK);
    }

    // subpages

    // the parent's holder takes a subpage back by minting over it: empty, and keep brings nothing
    function test_S06_subpageTakeBack() public {
        uint256 p = _paid(user, "parent");
        vm.prank(user);
        uint256 s = nft.registerSubpageFor("sub", p, bob);
        _write(bob, s);
        _assertFull(s);
        vm.recordLogs();
        vm.prank(user);
        nft.registerSubpage("sub", p);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_count(logs, T_VERSION), 1, "re-mint bumps the record version");
        assertEq(_profileLogs(logs), 0);
        _assertEmpty(s);
        _keep(user, s);
        _assertEmpty(s);
        assertEq(nft.text(s, "avatar"), "");
    }

    // a subpage sent to another account, then deleted and minted again for its first holder: empty each
    // time, and that holder's keepProfile reverts AlreadyKept
    function test_S06b_subpageSendAndDelete() public {
        uint256 p = _paid(user, "parent");
        vm.prank(user);
        uint256 s = nft.registerSubpageFor("sub", p, bob);
        _write(bob, s);
        _move(bob, carol, s);
        _assertEmpty(s);
        _move(carol, DEAD, s);
        _assertEmpty(s);
        vm.prank(user);
        nft.registerSubpageFor("sub", p, bob);
        _assertEmpty(s);
        vm.prank(bob);
        vm.expectRevert(PageNFT.AlreadyKept.selector);
        nft.keepProfile(s);
        _assertEmpty(s);
    }

    // the shop sells a subpage as the parent's minter; the parent never moves
    function test_S07_shopSale() public {
        uint256 p = _profiled(user, "alice");
        vm.startPrank(user);
        nft.setSubpageMinter(p, address(shop));
        shop.configure(p, user, address(0), 0.001 ether, true, address(0), 0, false);
        vm.stopPrank();
        vm.prank(carol);
        uint256 s = shop.registerSubpage{value: 0.001 ether}(p, "shop", 0.001 ether, address(0));
        assertEq(nft.ownerOf(s), carol);
        vm.prank(carol);
        nft.setText(s, "avatar", MILADY);
        assertEq(nft.text(s, "avatar"), MILADY, "the buyer's profile shows");
        _assertFull(p);
        assertEq(nft.ownerOf(p), user);
    }

    // a key wallet minter mints for a buyer and cannot touch the buyer's profile
    function test_S07b_walletMinter() public {
        uint256 p = _paid(user, "alice");
        vm.prank(user);
        nft.setSubpageMinter(p, dave);
        vm.prank(dave);
        uint256 s = nft.registerSubpageFor("m", p, carol);
        vm.prank(carol);
        nft.setText(s, "avatar", MILADY);
        assertEq(nft.text(s, "avatar"), MILADY);
        vm.prank(dave);
        vm.expectRevert(PageNFT.Unauthorized.selector);
        nft.setText(s, "avatar", PUNK);
        vm.prank(dave);
        vm.expectRevert(PageNFT.Unauthorized.selector);
        nft.keepProfile(s);
        assertEq(nft.text(s, "avatar"), MILADY);
    }

    // trials

    // a trial paid by a relayer, written during the trial and converted by the relayer: the profile stays
    function test_S08_trialAndConversion() public {
        uint256 id = _trial("trialname", user);
        _assertStatus(id, PageCard.Status.Trial);
        vm.prank(user);
        nft.setText(id, "avatar", PUNK);
        assertEq(nft.text(id, "avatar"), PUNK);
        assertEq(nft.profileWriter(id), user);
        vm.prank(user);
        vm.expectRevert(PageNFT.Unpaid.selector);
        nft.transferFrom(user, bob, id);
        vm.prank(relayer);
        nft.renew{value: FEE5}(id);
        _assertStatus(id, PageCard.Status.Active);
        assertEq(nft.text(id, "avatar"), PUNK, "conversion moves nothing, the profile stays");
        // the relayer, having paid, still cannot keep
        vm.prank(relayer);
        vm.expectRevert(PageNFT.Unauthorized.selector);
        nft.keepProfile(id);
    }

    // a trial thrown to DEAD shows nothing, and a trial taken over after it ended starts empty
    function test_S08b_trialToDeadAndTakeover() public {
        uint256 id = _trial("trialname", user);
        vm.prank(user);
        nft.setText(id, "avatar", PUNK);
        _move(user, DEAD, id);
        assertEq(nft.text(id, "avatar"), "", "a name at DEAD shows no profile");
        vm.warp(nft.expiresAt(id) + 1);
        vm.deal(bob, 10 ether);
        _buy(bob, "trialname");
        assertEq(nft.text(id, "avatar"), "");
        vm.prank(bob);
        nft.setText(id, "url", "https://bob.example");
        assertEq(nft.text(id, "avatar"), "");
        assertEq(nft.text(id, "url"), "https://bob.example");
    }

    // a paid name sent to DEAD shows no profile
    function test_S08c_paidNameAtDead() public {
        uint256 id = _profiled(user, "alice");
        _move(user, DEAD, id);
        _assertEmpty(id);
    }

    // multicall

    // the wrong order reverts the whole bundle and nothing is lost
    function test_S09_bundleWrongOrderReverts() public {
        uint256 id = _profiled(user, "alice");
        _move(user, user2, id);
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSignature("setText(uint256,string,string)", id, "url", "https://new.example");
        calls[1] = abi.encodeCall(PageNFT.keepProfile, (id));
        vm.prank(user2);
        vm.expectRevert(PageNFT.AlreadyKept.selector);
        nft.multicall(calls);
        assertEq(nft.profileWriter(id), user, "writer unchanged");
        _keep(user2, id);
        _assertFull(id);
    }

    // keep, text and website in one bundle; a bundle by someone else fails; a write then a move hides
    function test_S09b_bundles() public {
        uint256 id = _profiled(user, "alice");
        _move(user, user2, id);
        bytes[] memory calls = new bytes[](3);
        calls[0] = abi.encodeCall(PageNFT.keepProfile, (id));
        calls[1] = abi.encodeWithSignature("setText(uint256,string,string)", id, "avatar", MILADY);
        calls[2] = abi.encodeWithSignature("setContenthash(uint256,bytes)", id, hex"e301");
        vm.prank(bob);
        vm.expectRevert(PageNFT.Unauthorized.selector);
        nft.multicall(calls);
        vm.prank(user2);
        nft.multicall(calls);
        assertEq(nft.text(id, "avatar"), MILADY);
        assertEq(nft.text(id, "url"), "https://alice.example");
        assertEq(nft.contenthash(id), hex"e301");
        // write then move in one bundle: the write is hidden at the new holder
        bytes[] memory c2 = new bytes[](2);
        c2[0] = abi.encodeWithSignature("setText(uint256,string,string)", id, "url", "https://last.example");
        c2[1] = abi.encodeWithSignature("transferFrom(address,address,uint256)", user2, bob, id);
        vm.prank(user2);
        nft.multicall(c2);
        _assertEmpty(id);
        // a move then a keep by the old holder fails as a whole
        bytes[] memory c3 = new bytes[](2);
        c3[0] = abi.encodeWithSignature("transferFrom(address,address,uint256)", bob, carol, id);
        c3[1] = abi.encodeCall(PageNFT.keepProfile, (id));
        vm.prank(bob);
        vm.expectRevert(PageNFT.Unauthorized.selector);
        nft.multicall(c3);
        assertEq(nft.ownerOf(id), bob);
    }

    // clear and a new registration

    function test_S10_clearRecords() public {
        uint256 id = _profiled(user, "alice");
        vm.recordLogs();
        vm.prank(user);
        nft.clearRecords(id);
        assertEq(_profileLogs(vm.getRecordedLogs()), 0);
        _assertEmpty(id);
        assertEq(nft.profileWriter(id), user, "clear keeps the writer");
        vm.prank(user);
        vm.expectRevert(PageNFT.AlreadyKept.selector);
        nft.keepProfile(id);
        vm.prank(user);
        nft.setText(id, "avatar", MILADY);
        assertEq(nft.text(id, "avatar"), MILADY);
        assertEq(nft.text(id, "url"), "");
    }

    // the buyer clears and gives back: nothing returns, and keepProfile by the first holder, still the
    // writer, reverts AlreadyKept
    function test_S10b_clearThenGiveBack() public {
        uint256 id = _profiled(user, "alice");
        _move(user, bob, id);
        vm.prank(bob);
        nft.clearRecords(id);
        _move(bob, user, id);
        _assertEmpty(id);
        vm.prank(user);
        vm.expectRevert(PageNFT.AlreadyKept.selector);
        nft.keepProfile(id);
        _assertEmpty(id);
    }

    // a lapse and a registration by someone else: empty, also after the new holder keeps
    function test_S11_reRegistration() public {
        uint256 id = _profiled(user, "alice");
        _lapseAndBuy(id, bob, "alice");
        _assertEmpty(id);
        assertEq(nft.profileWriter(id), user, "the stale writer stays stored and counts for nobody");
        _keep(bob, id);
        _assertEmpty(id);
        // the old writer gets it back through a sale: still empty, as the new holder kept it and the
        // registration erased the old profile
        _move(bob, user, id);
        _assertEmpty(id);
    }

    // the old writer registering again after a lapse: empty, and its keepProfile reverts AlreadyKept
    function test_S11b_sameAccountRegistersAgain() public {
        uint256 id = _profiled(user, "alice");
        _lapseAndBuy(id, user, "alice");
        _assertEmpty(id);
        vm.prank(user);
        vm.expectRevert(PageNFT.AlreadyKept.selector);
        nft.keepProfile(id);
        _assertEmpty(id);
    }

    // the name moved before grace: in grace the holder can neither keep nor write, and after a renewal
    // in grace the profile shows only once the holder keeps it
    function test_S11c_graceAndRenew() public {
        uint256 id = _profiled(user, "alice");
        _move(user, bob, id);
        vm.warp(nft.expiresAt(id) + 1);
        _assertEmpty(id);
        vm.prank(bob);
        vm.expectRevert(PageNFT.Expired.selector);
        nft.keepProfile(id);
        vm.prank(bob);
        vm.expectRevert(PageNFT.Expired.selector);
        nft.setText(id, "avatar", PUNK);
        vm.prank(bob);
        nft.renew{value: FEE5}(id);
        _assertEmpty(id);
        _keep(bob, id);
        _assertFull(id);
    }

    // the writer still holds it: grace hides the profile and a renewal shows it again with no action
    function test_S11d_graceHidesTheHoldersOwnProfile() public {
        uint256 id = _profiled(user, "alice");
        vm.warp(nft.expiresAt(id) + 1);
        _assertEmpty(id);
        vm.warp(nft.expiresAt(id) + 90 days + 1);
        _assertEmpty(id);
        uint256 id2 = _profiled(bob, "bobby");
        vm.warp(nft.expiresAt(id2) + 1);
        _assertEmpty(id2);
        vm.prank(bob);
        nft.renew{value: FEE5}(id2);
        _assertFull(id2);
    }

    // who can keep

    function test_S12_onlyTheHolderKeeps() public {
        uint256 id = _profiled(user, "alice");
        _move(user, bob, id);
        vm.startPrank(bob);
        nft.setApprovalForAll(carol, true);
        nft.approve(dave, id);
        vm.stopPrank();
        address[4] memory who = [user, carol, dave, makeAddr("stranger")];
        for (uint256 i; i < 4; ++i) {
            vm.prank(who[i]);
            vm.expectRevert(PageNFT.Unauthorized.selector);
            nft.keepProfile(id);
            vm.prank(who[i]);
            vm.expectRevert(PageNFT.Unauthorized.selector);
            nft.setText(id, "avatar", PUNK);
        }
        _assertEmpty(id);
        uint256 nobody = nft.computeId("nobody");
        vm.expectRevert(PageNFT.Expired.selector);
        nft.keepProfile(nobody);
    }

    // events for indexers

    // the exact logs of each profile call, in order
    function test_S13_eventsForIndexers() public {
        uint256 id = _paid(user, "alice");
        vm.recordLogs();
        vm.prank(user);
        nft.setText(id, "avatar", PUNK);
        Vm.Log[] memory l = vm.getRecordedLogs();
        assertEq(l.length, 2, "first write ever: writer event, then the text event");
        _assertPwc(l[0], id, user, true);
        assertEq(l[1].topics[0], T_TEXT);
        assertEq(l[1].topics[1], bytes32(id));
        assertEq(l[1].topics[2], keccak256("avatar"));
        (string memory k, string memory v) = abi.decode(l[1].data, (string, string));
        assertEq(k, "avatar");
        assertEq(v, PUNK);
        vm.recordLogs();
        vm.prank(user);
        nft.setContenthash(id, SITE);
        l = vm.getRecordedLogs();
        assertEq(l.length, 1, "later writes by the writer: no writer event");
        assertEq(l[0].topics[0], T_SITE);
        // a transfer: no profile event, the usual ones only
        vm.recordLogs();
        _move(user, bob, id);
        l = vm.getRecordedLogs();
        assertEq(_profileLogs(l), 0);
        assertEq(_count(l, T_TRANSFER), 1);
        // the new holder's first write is a fresh start, logged before the website event
        vm.recordLogs();
        vm.prank(bob);
        nft.setContenthash(id, hex"e301");
        l = vm.getRecordedLogs();
        assertEq(l.length, 2);
        _assertPwc(l[0], id, bob, true);
        assertEq(l[1].topics[0], T_SITE);
        // a keep by the next holder is fresh false
        _move(bob, carol, id);
        vm.recordLogs();
        _keep(carol, id);
        l = vm.getRecordedLogs();
        assertEq(l.length, 1);
        _assertPwc(l[0], id, carol, false);
        assertEq(nft.contenthash(id), hex"e301");
        assertEq(nft.text(id, "avatar"), "");
    }

    // an event only replay: the profile counts iff the last writer event names the current holder,
    // and holds the writes since the last fresh event or version change
    function test_S13b_replayMatchesViews() public {
        uint256 id = _paid(user, "alice");
        vm.recordLogs();
        _write(user, id);
        _move(user, bob, id);
        vm.prank(bob);
        nft.setText(id, "url", SCAM);
        _move(bob, user, id);
        _keep(user, id);
        vm.prank(user);
        nft.setText(id, "com.twitter", "back");
        Vm.Log[] memory l = vm.getRecordedLogs();
        address owner;
        address writer;
        string memory url;
        string memory avatar;
        string memory tw;
        for (uint256 i; i < l.length; ++i) {
            if (l[i].emitter != address(nft)) continue;
            bytes32 t = l[i].topics[0];
            if (t == T_TRANSFER) owner = address(uint160(uint256(l[i].topics[2])));
            else if (t == T_PWC) {
                (address w, bool fresh) = abi.decode(l[i].data, (address, bool));
                writer = w;
                if (fresh) (url, avatar, tw) = ("", "", "");
            } else if (t == T_VERSION) {
                (url, avatar, tw) = ("", "", "");
            } else if (t == T_TEXT) {
                (string memory k, string memory v) = abi.decode(l[i].data, (string, string));
                if (_eqs(k, "url")) url = v;
                else if (_eqs(k, "avatar")) avatar = v;
                else if (_eqs(k, "com.twitter")) tw = v;
            }
        }
        bool counts = writer == owner;
        assertEq(owner, nft.ownerOf(id));
        assertEq(counts ? url : "", nft.text(id, "url"));
        assertEq(counts ? avatar : "", nft.text(id, "avatar"));
        assertEq(counts ? tw : "", nft.text(id, "com.twitter"));
        assertEq(nft.text(id, "url"), SCAM);
        assertEq(nft.text(id, "avatar"), "");
    }

    // what the profile does not touch

    // the card never reads the profile, and through a sale and a keep the addresses, payee and
    // display name follow their usual rules
    function test_S14_profileTouchesNothingElse() public {
        uint256 id = _profiled(user, "alice");
        vm.prank(user);
        nft.setPrimaryPage(id);
        string memory uriBefore = nft.tokenURI(id);
        vm.prank(user);
        nft.setText(id, "description", "changes nothing on the card");
        assertEq(nft.tokenURI(id), uriBefore, "the card does not read the profile");
        _move(user, bob, id);
        assertEq(nft.reverseResolve(user), "");
        assertEq(nft.payee(id), bob);
        string memory uriSold = nft.tokenURI(id);
        _keep(bob, id);
        assertEq(nft.tokenURI(id), uriSold, "keep changes nothing on the card");
        assertEq(nft.resolve(id), bob);
        assertEq(nft.addr(id, BTC).length, 0);
    }
}

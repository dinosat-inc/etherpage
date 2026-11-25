// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {trialCommitment, trialCommitmentRaw} from "../utils/TrialCommitment.sol";

import {Vm} from "forge-std/Test.sol";
import {PageNFT} from "../../src/PageNFT.sol";
import {SubpageRegistrar} from "../../src/SubpageRegistrar.sol";
import {TrialBase} from "../utils/TrialBase.sol";

// chooses the name it receives as its display name from inside the receiver hook
contract ChoosingReceiver {
    string public seen;

    function onERC721Received(address, address, uint256 id, bytes calldata) external returns (bytes4) {
        PageNFT(msg.sender).setPrimaryPage(id);
        seen = PageNFT(msg.sender).reverseResolve(address(this));
        return this.onERC721Received.selector;
    }
}

// The sponsored trial next to multicall, the display name clear on transfer and the holder check on
// display names.
contract TrialDisplayInterplayTest is TrialBase {
    address hot = makeAddr("hot");
    address bot = makeAddr("bot");
    uint256 constant HOLDER_SLOT = 13;

    function setUp() public override {
        super.setUp();
        vm.deal(user, 10 ether);
        vm.deal(bot, 10 ether);
    }

    // the account stored with a's display name, read from its storage slot
    function _holderOf(address a) internal view returns (address) {
        return address(uint160(uint256(vm.load(address(nft), keccak256(abi.encode(a, HOLDER_SLOT))))));
    }

    // the holder points the name at hot, and hot chooses it
    function _hotChooses(uint256 id, address holder) internal {
        vm.prank(holder);
        nft.setAddr(id, hot);
        vm.prank(hot);
        nft.setPrimaryPage(id);
    }

    function _one(bytes memory call) internal pure returns (bytes[] memory calls) {
        calls = new bytes[](1);
        calls[0] = call;
    }

    function _primarySetFor(Vm.Log[] memory logs, address a, uint256 id) internal pure returns (uint256 n) {
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].topics.length == 3 && logs[i].topics[0] == PRIMARY_SET
                    && logs[i].topics[1] == bytes32(uint256(uint160(a))) && logs[i].topics[2] == bytes32(id)
            ) ++n;
        }
    }

    // a trial name as a display name
    function test_trialNameShownByItsHolder() public {
        uint256 id = _trial("alice", user);
        vm.prank(user);
        nft.setPrimaryPage(id);
        assertEq(nft.reverseResolve(user), "alice");
        assertEq(nft.primaryPage(user), id);
        assertEq(_holderOf(user), user, "the holder stores itself");
    }

    function test_trialNameShownByTheAddressItPointsAt() public {
        uint256 id = _trial("alice", user);
        vm.prank(user);
        nft.setPrimaryPage(id);
        _hotChooses(id, user);
        assertEq(nft.reverseResolve(hot), "alice");
        assertEq(_holderOf(hot), user, "hot stores the trial holder");
        assertEq(nft.reverseResolve(user), "", "the name no longer points at its holder");
        assertEq(nft.primaryPage(user), id, "the holder's own pointer stays, hidden");
    }

    // a contract that receives a trial can choose it inside the mint callback
    function test_trialChosenInsideTheMintCallback() public {
        ChoosingReceiver r = new ChoosingReceiver();
        uint256 id = _trial("alice", address(r));
        assertEq(r.seen(), "alice", "seen inside the hook");
        assertEq(nft.reverseResolve(address(r)), "alice");
        assertEq(_holderOf(address(r)), address(r));
        assertEq(nft.ownerOf(id), address(r));
    }

    // a trial that its holder and hot both chose as their display name lapses unpaid, with no grace period after it
    function _lapsedTrialWithBothRoutes() internal returns (uint256 id) {
        id = _trial("alice", user);
        vm.prank(user);
        nft.setPrimaryPage(id);
        _hotChooses(id, user);
        vm.warp(nft.expiresAt(id) + 1);
        assertEq(nft.reverseResolve(hot), "", "a lapsed trial shows nothing");
        assertTrue(nft.isAvailable("alice", 0), "no grace after a trial");
    }

    function test_lapsedTrialTrialledBySomeoneElseKeepsOldSettingsHidden() public {
        uint256 id = _lapsedTrialWithBothRoutes();
        // a new trial waits out the fourteen day pause
        vm.warp(nft.expiresAt(id) + 14 days - 1 hours);
        _commitTrial(relayer, "alice", bob);
        vm.warp(nft.expiresAt(id) + 14 days + 1);
        vm.recordLogs();
        vm.prank(relayer);
        nft.revealTrial{value: PRICE5}("alice", bob, 0, _secret("alice", bob));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_primarySetFor(logs, user, 0), 1, "the old holder's own pointer is cleared");
        assertEq(nft.primaryPage(user), 0);
        assertEq(nft.primaryPage(hot), id, "hot's pointer stays");
        assertEq(nft.reverseResolve(hot), "");
        // the new trial holder points the name back at hot with its own records
        vm.startPrank(bob);
        nft.setAddr(id, hot);
        nft.setText(id, "url", "https://scam.example");
        vm.stopPrank();
        assertEq(nft.resolve(id), hot);
        assertEq(nft.reverseResolve(hot), "", "the new holder cannot revive hot's display name");
        // only hot itself can choose the name again, under the new holder
        vm.prank(hot);
        nft.setPrimaryPage(id);
        assertEq(_holderOf(hot), bob);
        assertEq(nft.reverseResolve(hot), "alice");
    }

    function test_lapsedTrialBoughtBySomeoneElseKeepsOldSettingsHidden() public {
        uint256 id = _lapsedTrialWithBothRoutes();
        (,, uint256 premium, uint256 total) = nft.quote("alice");
        assertEq(premium, 0, "no auction after a trial");
        assertEq(total, FEE5);
        _buy(bob, "alice");
        assertEq(nft.ownerOf(id), bob);
        assertEq(nft.depositOf(id), FEE5);
        assertEq(nft.primaryPage(user), 0);
        vm.startPrank(bob);
        nft.setAddr(id, hot);
        nft.setText(id, "avatar", "ipfs://bob");
        vm.stopPrank();
        assertEq(nft.reverseResolve(hot), "");
        assertEq(nft.reverseResolve(user), "");
    }

    // a sponsor gives the lapsed name back to the same holder as a new trial: the version bump means the
    // name points at the holder again, so hot shows nothing until the holder points it at hot
    function test_lapsedTrialTrialledAgainForTheSameHolder() public {
        uint256 id = _lapsedTrialWithBothRoutes();
        // a new trial waits out the fourteen day pause
        vm.warp(nft.expiresAt(id) + 14 days - 1 hours);
        _commitTrial(bob, "alice", user);
        vm.warp(nft.expiresAt(id) + 14 days + 1);
        vm.prank(bob);
        nft.revealTrial{value: PRICE5}("alice", user, 0, _secret("alice", user));
        assertEq(nft.ownerOf(id), user);
        assertEq(_holderOf(hot), user, "the stored holder holds the name again");
        assertEq(nft.resolve(id), user);
        assertEq(nft.reverseResolve(hot), "");
        assertEq(nft.primaryPage(user), 0, "re-registration cleared the holder's pointer");
        // the sponsor cannot point it anywhere
        vm.prank(bob);
        vm.expectRevert(PageNFT.Unauthorized.selector);
        nft.setAddr(id, hot);
        // the holder's own act brings hot back
        vm.prank(user);
        nft.setAddr(id, hot);
        assertEq(nft.reverseResolve(hot), "alice");
    }

    // thrown to DEAD
    function test_trialThrownToDeadClearsAndHides() public {
        uint256 id = _trial("alice", user);
        vm.prank(user);
        nft.setPrimaryPage(id);
        assertEq(nft.reverseResolve(user), "alice");
        vm.prank(user);
        nft.setAddr(id, hot);
        vm.prank(hot);
        nft.setPrimaryPage(id);
        vm.prank(user);
        nft.setAddr(id, address(0));
        assertEq(nft.reverseResolve(user), "alice");
        assertEq(nft.reverseResolve(hot), "", "hot no longer resolved");
        vm.prank(user);
        nft.setAddr(id, hot);
        assertEq(nft.reverseResolve(hot), "alice");
        vm.recordLogs();
        vm.prank(user);
        nft.transferFrom(user, DEAD, id);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_primarySetFor(logs, user, 0), 1, "the sender's display name is cleared");
        assertEq(nft.primaryPage(user), 0);
        assertEq(nft.primaryPage(hot), id, "hot keeps its pointer");
        assertEq(nft.reverseResolve(hot), "", "and it stays hidden");
        assertEq(nft.resolve(id), address(0), "a top-level name held by DEAD is deleted and resolves to nothing");
        // the name comes back only through a new registration, which retires every saved address
        vm.warp(nft.expiresAt(id) + 1);
        _buy(bob, "alice");
        vm.prank(bob);
        nft.setAddr(id, hot);
        assertEq(nft.reverseResolve(hot), "");
    }

    // the same throw away inside a bundle
    function test_trialThrownToDeadInsideABundle() public {
        uint256 id = _trial("alice", user);
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSignature("setPrimaryPage(uint256)", id);
        calls[1] = abi.encodeCall(PageNFT.transferFrom, (user, DEAD, id));
        vm.prank(user);
        nft.multicall(calls);
        assertEq(nft.ownerOf(id), DEAD);
        assertEq(nft.primaryPage(user), 0, "chosen and cleared in one bundle");
        assertEq(_holderOf(user), user, "the stored holder stays, unread");
        assertEq(nft.reverseResolve(user), "");
    }

    // conversion by renew
    function test_conversionByRenewKeepsTheDisplayName() public {
        uint256 a = _trial("alice", user);
        uint256 b = _trial("bravo", user);
        vm.prank(user);
        nft.setPrimaryPage(a);
        _hotChooses(b, user);
        assertEq(nft.reverseResolve(user), "alice");
        assertEq(nft.reverseResolve(hot), "bravo");
        uint256 trialEnd = nft.expiresAt(a);
        // anyone may convert
        vm.prank(relayer);
        nft.renew{value: FEE5}(a);
        vm.prank(carol);
        nft.renew{value: FEE5}(b);
        assertEq(nft.expiresAt(a), trialEnd + 365 days);
        assertEq(nft.depositOf(a), FEE5);
        vm.warp(trialEnd + 1);
        assertEq(nft.reverseResolve(user), "alice", "kept past the trial end");
        assertEq(nft.reverseResolve(hot), "bravo");
        vm.warp(trialEnd + 300 days);
        assertEq(nft.reverseResolve(user), "alice");
        assertEq(nft.reverseResolve(hot), "bravo");
        // once paid, both move like any name: the sender is cleared, and hot is hidden
        vm.startPrank(user);
        nft.transferFrom(user, bob, a);
        nft.transferFrom(user, bob, b);
        vm.stopPrank();
        assertEq(nft.primaryPage(user), 0);
        assertEq(nft.reverseResolve(hot), "");
        vm.prank(bob);
        nft.setAddr(b, hot);
        assertEq(nft.reverseResolve(hot), "", "the buyer cannot revive it");
    }

    // paid calls and bundles
    function test_revealTrialCannotRunInABundle() public {
        _commitTrial(relayer, "alice", user);
        vm.warp(vm.getBlockTimestamp() + 61);
        bytes[] memory calls = _one(abi.encodeCall(PageNFT.revealTrial, ("alice", user, 0, _secret("alice", user))));
        vm.prank(relayer);
        vm.expectRevert(PageNFT.InsufficientFee.selector);
        nft.multicall(calls);
        vm.prank(relayer);
        (bool ok,) = address(nft).call{value: PRICE5}(abi.encodeCall(PageNFT.multicall, (calls)));
        assertFalse(ok, "multicall refuses ETH");
        // the failed bundles left the commitment in place, and the sponsor flow works directly
        assertGt(nft.commitments(trialCommitment(address(nft), "alice", user, 0, _secret("alice", user))), 0);
        vm.prank(relayer);
        uint256 id = nft.revealTrial{value: PRICE5}("alice", user, 0, _secret("alice", user));
        assertEq(nft.ownerOf(id), user);
        assertEq(nft.owed(DEAD), 0);
        (, uint256 held) = nft.trialPaymentOf(id);
        assertEq(held, PRICE5);
        assertEq(address(nft).balance, PRICE5);
    }

    function test_renewCannotRunInABundle() public {
        uint256 id = _trial("alice", user);
        uint256 exp = nft.expiresAt(id);
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(PageNFT.setText, (id, "k", "v"));
        calls[1] = abi.encodeCall(PageNFT.renew, (id));
        vm.prank(user);
        vm.expectRevert(PageNFT.InsufficientFee.selector);
        nft.multicall(calls);
        assertEq(nft.text(id, "k"), "", "the whole bundle reverted");
        vm.prank(relayer);
        (bool ok,) = address(nft).call{value: FEE5}(abi.encodeCall(PageNFT.multicall, (_one(calls[1]))));
        assertFalse(ok, "multicall refuses ETH");
        assertEq(nft.expiresAt(id), exp);
        assertEq(nft.depositOf(id), 0);
        vm.prank(relayer);
        nft.renew{value: FEE5}(id);
        assertEq(nft.depositOf(id), FEE5);
        assertEq(nft.expiresAt(id), exp + 365 days);
    }

    // a sponsor may batch its commitments, then reveals each trial directly
    function test_sponsorBatchesCommitmentsThenRevealsDirectly() public {
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(PageNFT.commit, (trialCommitment(address(nft), "alice", user, 0, _secret("alice", user))));
        calls[1] = abi.encodeCall(PageNFT.commit, (trialCommitment(address(nft), "bravo", carol, 0, _secret("bravo", carol))));
        vm.prank(relayer);
        nft.multicall(calls);
        vm.warp(vm.getBlockTimestamp() + 61);
        vm.startPrank(relayer);
        uint256 a = nft.revealTrial{value: PRICE5}("alice", user, 0, _secret("alice", user));
        uint256 b = nft.revealTrial{value: PRICE5}("bravo", carol, 0, _secret("bravo", carol));
        vm.stopPrank();
        assertEq(nft.ownerOf(a), user);
        assertEq(nft.ownerOf(b), carol);
        assertEq(nft.owed(DEAD), 0);
        (address pa, uint256 ha) = nft.trialPaymentOf(a);
        (address pb, uint256 hb) = nft.trialPaymentOf(b);
        assertEq(pa, relayer);
        assertEq(pb, relayer);
        assertEq(ha + hb, 2 * PRICE5);
    }

    // the trial commitment form with multicall
    // A leaked paid reveal: the bot cannot turn the user's ripe paid commitment into a trial, directly or
    // in a bundle, and a trial form it commits in a bundle is as new as one it commits directly.
    function test_trialCommitmentFormHoldsWithMulticall() public {
        string memory L = "alice-smith";
        _commit(user, L, user);
        uint256 t0 = vm.getBlockTimestamp();
        vm.warp(t0 + 19);
        vm.prank(user);
        vm.expectRevert(PageNFT.CommitmentTooNew.selector);
        nft.reveal{value: FEE5}(L, user, 0, _secret(L, user));
        // the bot bundles its own trial form right after the leak
        vm.prank(bot);
        nft.multicall(_one(abi.encodeCall(PageNFT.commit, (trialCommitmentRaw(L, user, 0, _secret(L, user))))));
        vm.warp(t0 + 20);
        vm.prank(bot);
        vm.expectRevert(PageNFT.CommitmentTooNew.selector);
        nft.revealTrial{value: PRICE5}(L, user, 0, _secret(L, user));
        vm.prank(bot);
        vm.expectRevert(PageNFT.InsufficientFee.selector);
        nft.multicall(_one(abi.encodeCall(PageNFT.revealTrial, (L, user, 0, _secret(L, user)))));
        // the user's retry wins a paid year
        vm.prank(user);
        uint256 id = nft.reveal{value: FEE5}(L, user, 0, _secret(L, user));
        assertEq(nft.depositOf(id), FEE5);
        // once the bot's trial form has ripened, the name is taken and holds a deposit
        vm.warp(t0 + 19 + 20);
        vm.prank(bot);
        vm.expectRevert(PageNFT.TrialNotAllowed.selector);
        nft.revealTrial{value: PRICE5}(L, user, 0, _secret(L, user));
    }

    // a plain form committed in a bundle never serves a trial, and still serves its paid reveal
    function test_plainFormCommittedInABundleNeverServesATrial() public {
        string memory M = "other-name";
        bytes32 commitment = nft.makeCommitment(M, bot, 0, _secret(M, bot));
        vm.prank(bot);
        nft.multicall(_one(abi.encodeCall(PageNFT.commit, (commitment))));
        vm.warp(vm.getBlockTimestamp() + 61);
        vm.prank(bot);
        vm.expectRevert(PageNFT.CommitmentNotFound.selector);
        nft.revealTrial{value: PRICE5}(M, bot, 0, _secret(M, bot));
        vm.prank(bot);
        uint256 id = nft.reveal{value: FEE5}(M, bot, 0, _secret(M, bot));
        assertEq(nft.depositOf(id), FEE5);
    }

    // a trial form cannot serve a paid reveal, whether the sponsor that committed it or the owner it names sends it
    function test_trialFormNeverServesAPaidReveal() public {
        _commitTrial(relayer, "alice", user);
        vm.warp(vm.getBlockTimestamp() + 61);
        vm.prank(relayer);
        vm.expectRevert(PageNFT.CommitmentNotFound.selector);
        nft.reveal{value: FEE5}("alice", user, 0, _secret("alice", user));
        vm.prank(user);
        vm.expectRevert(PageNFT.CommitmentNotFound.selector);
        nft.reveal{value: FEE5}("alice", user, 0, _secret("alice", user));
    }

    // a trial cannot revive a display name
    // A paid name lapses fully and someone trials it, which first releases its deposit: the address the old
    // holder pointed at stays hidden whatever the trial holder writes.
    function test_trialOfALapsedPaidNameCannotRevive() public {
        uint256 id = _buy(user, "alice");
        _hotChooses(id, user);
        assertEq(nft.reverseResolve(hot), "alice");
        vm.warp(nft.expiresAt(id) + 90 days + 21 days + 1);
        _commitTrial(relayer, "alice", bot);
        vm.warp(vm.getBlockTimestamp() + 61);
        vm.prank(relayer);
        nft.revealTrial{value: PRICE5}("alice", bot, 0, _secret("alice", bot));
        assertEq(nft.depositOf(id), 0);
        assertEq(nft.owed(hot), nft.getFee(5), "the deposit went to the main address the old holder saved");
        vm.startPrank(bot);
        nft.setAddr(id, hot);
        nft.setText(id, "url", "https://scam.example");
        nft.setContenthash(id, hex"e301");
        vm.stopPrank();
        assertEq(nft.resolve(id), hot);
        assertEq(nft.reverseResolve(hot), "");
    }

    // a lapsed trial is taken over one second after it ends by a paid registration (a new trial must
    // wait out the pause); the old pointee stays hidden
    function test_snipedTrialCannotRevive() public {
        uint256 id = _trial("alice", user);
        _hotChooses(id, user);
        uint256 e = nft.expiresAt(id);
        vm.warp(e - 1 hours);
        _commit(bot, "alice", bot);
        vm.warp(e + 1);
        vm.prank(bot);
        nft.reveal{value: FEE5}("alice", bot, 0, _secret("alice", bot));
        vm.prank(bot);
        nft.setAddr(id, hot);
        assertEq(nft.reverseResolve(hot), "");
    }

    // a trial name pointed at an account that never chose it shows nothing there, and leaves that account's
    // own display name alone
    function test_trialPointedAtAStrangerShowsNothing() public {
        uint256 c = _buy(carol, "carol");
        vm.prank(carol);
        nft.setPrimaryPage(c);
        uint256 id = _trial("bravo", bot);
        vm.prank(bot);
        nft.setAddr(id, carol);
        assertEq(nft.reverseResolve(carol), "carol");
        assertEq(nft.primaryPage(carol), c);
        vm.prank(bot);
        nft.setPrimaryPage(id);
        assertEq(nft.reverseResolve(bot), "", "the trial holder's own setting needs the name to point at it");
        assertEq(nft.reverseResolve(carol), "carol");
    }

    // an unpaid trial cannot stage the gift back: it moves only to DEAD, and DEAD never gives it back
    function test_unpaidTrialCannotStageAGiftBack() public {
        uint256 id = _trial("alice", user);
        _hotChooses(id, user);
        vm.prank(user);
        vm.expectRevert(PageNFT.Unpaid.selector);
        nft.transferFrom(user, bob, id);
        vm.prank(user);
        vm.expectRevert(PageNFT.Unpaid.selector);
        nft.multicall(_one(abi.encodeCall(PageNFT.transferFrom, (user, bob, id))));
        vm.prank(user);
        nft.transferFrom(user, DEAD, id);
        assertEq(nft.reverseResolve(hot), "");
    }

    // the subpage routes that could hand a pointee's name to someone else need a paid parent
    function test_subpageRoutesNeedAPaidParent() public {
        uint256 pid = _trial("alice", user);
        vm.prank(user);
        vm.expectRevert(PageNFT.Unpaid.selector);
        nft.registerSubpageFor("x", pid, hot);
        vm.prank(user);
        nft.setSubpageMinter(pid, address(shop));
        assertEq(nft.subpageMinterOf(pid), address(shop));
        vm.prank(user);
        vm.expectRevert(PageNFT.Unpaid.selector);
        nft.multicall(_one(abi.encodeCall(PageNFT.registerSubpageFor, ("x", pid, hot))));
        assertFalse(nft.isAvailable("x", pid));
    }
}

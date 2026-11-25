// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {trialCommitment} from "../utils/TrialCommitment.sol";

import {console} from "forge-std/Test.sol";
import {SafeMintBase} from "../differential/SafeMintBase.sol";
import {PageNFT} from "../../src/PageNFT.sol";
import {SimpleDelegateLike, PQAccountLike} from "../utils/WalletMocks.sol";

// a helper contract anyone can drive, like a public batching tool, with no receiver hook
contract PublicHelper {
    function run(address target, bytes calldata data) external payable returns (bytes memory ret) {
        bool ok;
        (ok, ret) = target.call{value: msg.value}(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }
}

contract HybridMintTest is SafeMintBase {
    // S: a refused reveal costs the buyer nothing and the commitment survives, but the commitment
    // names the owner, so buying for another address needs a new commit and a new 20 second wait
    function test_S_refusedRevealKeepsMoneyAndCommitment() public {
        PageNFT nft = nfts[S];
        string memory l = "refusedname";
        bytes32 secret = _s(l, vaultNoHook);
        bytes32 c = nft.makeCommitment(l, vaultNoHook, 0, secret);
        vm.prank(bob);
        nft.commit(c);
        vm.warp(vm.getBlockTimestamp() + 61);
        uint256 before = bob.balance;
        vm.prank(bob);
        (bool ok, bytes memory ret) =
            address(nft).call{value: FEE5}(abi.encodeCall(PageNFT.reveal, (l, vaultNoHook, 0, secret)));
        assertEq(_sel(ok, ret), NOT_RECEIVER);
        assertEq(bob.balance, before, "buyer keeps its ETH");
        assertTrue(nft.commitments(c) != 0, "commitment survives");
        assertTrue(nft.isAvailable(l, 0), "name still free");

        vm.prank(bob);
        vm.expectRevert(PageNFT.CommitmentNotFound.selector);
        nft.reveal{value: FEE5}(l, keyWallet, 0, secret);

        bytes32 s2 = _s(l, keyWallet);
        bytes32 commitment = nft.makeCommitment(l, keyWallet, 0, s2);
        vm.prank(bob);
        nft.commit(commitment);
        vm.prank(bob);
        vm.expectRevert(PageNFT.CommitmentTooNew.selector);
        nft.reveal{value: FEE5}(l, keyWallet, 0, s2);
        vm.warp(vm.getBlockTimestamp() + 61);
        vm.prank(bob);
        uint256 id = nft.reveal{value: FEE5}(l, keyWallet, 0, s2);
        assertEq(nft.ownerOf(id), keyWallet);
    }

    // H2 is the code of record. A reveal or a trial naming a contract that is neither the caller nor a key wallet
    // and has no hook reverts, the payer keeps its ETH and the commitment stays as it was. A second try by the payer
    // with the same commitment meets the same refusal, and the contract then registers for itself with it.
    function test_H2_refusedRevealKeepsMoneyAndCommitment() public {
        _refusedThenForItself(false, "refusedyear");
        _refusedThenForItself(true, "refusedtrial");
    }

    // bob reveals twice for pq, an account contract with no hook, and pq then reveals the same commitment for itself
    function _refusedThenForItself(bool trial, string memory l) internal {
        PageNFT nft = nfts[H2];
        bytes32 c = trial
            ? trialCommitment(address(nft), l, address(pq), 0, _s(l, address(pq)))
            : nft.makeCommitment(l, address(pq), 0, _s(l, address(pq)));
        vm.prank(bob);
        nft.commit(c);
        uint256 committedAt = vm.getBlockTimestamp();
        vm.warp(committedAt + 61);
        bytes memory data = trial
            ? abi.encodeCall(PageNFT.revealTrial, (l, address(pq), 0, _s(l, address(pq))))
            : abi.encodeCall(PageNFT.reveal, (l, address(pq), 0, _s(l, address(pq))));
        uint256 price = trial ? PRICE5 : FEE5;
        uint256 payerBefore = bob.balance;
        for (uint256 k; k < 2; ++k) {
            vm.prank(bob);
            (bool ok, bytes memory ret) = address(nft).call{value: price}(data);
            assertEq(_sel(ok, ret), NOT_RECEIVER);
            assertEq(bob.balance, payerBefore, "the payer keeps its ETH");
            assertEq(nft.commitments(c), committedAt, "the commitment is untouched");
            assertTrue(nft.isAvailable(l, 0), "the name is still free");
        }
        uint256 ownBefore = address(pq).balance;
        vm.prank(entryPoint);
        pq.execute(address(nft), price, data);
        uint256 id = nft.computeId(l);
        assertEq(nft.ownerOf(id), address(pq), "the same commitment registers the name for the contract itself");
        assertEq(ownBefore - address(pq).balance, price, "which pays for it");
        assertEq(nft.commitments(c), 0, "and uses the commitment");
        if (trial) {
            (address payer, uint96 amount) = nft.trialPaymentOf(id);
            assertEq(payer, address(pq));
            assertEq(amount, PRICE5);
        } else {
            assertEq(nft.depositOf(id), FEE5);
        }
    }

    // H2 trusts any contract that calls for itself. A public helper named as owner by mistake then
    // holds the name and anyone can take it through the helper. S refuses the same mint.
    function test_H2_publicHelperNamedAsOwner() public {
        address mallory = makeAddr("mallory");
        for (uint256 v; v < 4; v += 3) {
            PageNFT nft = nfts[v];
            PublicHelper helper = new PublicHelper();
            address to = address(helper);
            string memory l = v == S ? "helpers" : "helperh";
            bytes32 commitment = nft.makeCommitment(l, to, 0, _s(l, to));
            vm.prank(bob);
            nft.commit(commitment);
            vm.warp(vm.getBlockTimestamp() + 61);
            bytes memory inner = abi.encodeCall(PageNFT.reveal, (l, to, 0, _s(l, to)));
            vm.prank(bob);
            (bool ok, bytes memory ret) =
                address(helper).call{value: FEE5}(abi.encodeCall(PublicHelper.run, (address(nft), inner)));
            if (v == S) {
                assertEq(_sel(ok, ret), NOT_RECEIVER);
                continue;
            }
            assertTrue(ok, "H2 lets the helper mint for itself");
            uint256 id = nft.computeId(l);
            assertEq(nft.ownerOf(id), to);
            vm.prank(mallory);
            helper.run(address(nft), abi.encodeCall(PageNFT.transferFrom, (to, mallory, id)));
            assertEq(nft.ownerOf(id), mallory);
        }
    }

    // H1 and H2 trust a 7702 marker because a key stands behind it. A marker made without a known
    // key leaves a name nobody can move when its delegate has no hook and no open call. S refuses it.
    // A plain address nobody controls is accepted by every build, so this widens an existing gap.
    function test_H_keylessMarker() public {
        SimpleDelegateLike sd = new SimpleDelegateLike();
        address keyless = address(uint160(uint256(keccak256("keyless 7702 account"))));
        vm.etch(keyless, abi.encodePacked(hex"ef0100", address(sd)));
        assertEq(keyless.code.length, 23);
        (bool live,) = keyless.call("");
        assertTrue(live, "the marker runs the delegate");
        address nobody = address(uint160(uint256(keccak256("plain address nobody controls"))));
        string[4] memory tag = ["s", "p", "a", "b"];
        for (uint256 v; v < 4; ++v) {
            PageNFT nft = nfts[v];
            string memory l = string.concat("keyless", tag[v]);
            bytes32 commitment = nft.makeCommitment(l, keyless, 0, _s(l, keyless));
            vm.prank(bob);
            nft.commit(commitment);
            vm.warp(vm.getBlockTimestamp() + 61);
            vm.prank(bob);
            (bool ok, bytes memory ret) =
                address(nft).call{value: FEE5}(abi.encodeCall(PageNFT.reveal, (l, keyless, 0, _s(l, keyless))));
            if (v == S) {
                assertEq(_sel(ok, ret), NOT_RECEIVER);
            } else {
                assertTrue(ok);
                uint256 id = nft.computeId(l);
                assertEq(nft.ownerOf(id), keyless);
                vm.prank(bob);
                vm.expectRevert(bytes("self only"));
                SimpleDelegateLike(payable(keyless)).executeBatch(
                    address(nft), 0, abi.encodeCall(PageNFT.transferFrom, (keyless, bob, id))
                );
            }
            string memory l2 = string.concat("nobody", tag[v]);
            bytes32 commitment2 = nft.makeCommitment(l2, nobody, 0, _s(l2, nobody));
            vm.prank(bob);
            nft.commit(commitment2);
            vm.warp(vm.getBlockTimestamp() + 61);
            vm.prank(bob);
            nft.reveal{value: FEE5}(l2, nobody, 0, _s(l2, nobody));
            assertEq(nft.ownerOf(nft.computeId(l2)), nobody);
        }
    }

    // H2 end to end for a deployed account with no hook: it commits, takes a trial for itself,
    // sets a text record, pays the year and moves the name. In S the same trial is refused.
    function test_H2_hooklessAccountTrialToOwnership() public {
        for (uint256 v; v < 4; v += 3) {
            PageNFT nft = nfts[v];
            string memory l = v == S ? "pqtrials" : "pqtrialh";
            address me = address(pq);
            bytes32 c = trialCommitment(address(nft), l, me, 0, _s(l, me));
            vm.prank(entryPoint);
            pq.execute(address(nft), 0, abi.encodeCall(PageNFT.commit, (c)));
            vm.warp(vm.getBlockTimestamp() + 61);
            bytes memory trial = abi.encodeCall(PageNFT.revealTrial, (l, me, 0, _s(l, me)));
            vm.prank(entryPoint);
            (bool ok, bytes memory ret) =
                address(pq).call(abi.encodeCall(PQAccountLike.execute, (address(nft), PRICE5, trial)));
            if (v == S) {
                assertEq(_sel(ok, ret), NOT_RECEIVER);
                continue;
            }
            assertTrue(ok);
            uint256 id = nft.computeId(l);
            assertEq(nft.ownerOf(id), me);
            vm.startPrank(entryPoint);
            pq.execute(address(nft), 0, abi.encodeCall(PageNFT.setText, (id, "url", "https://example.org")));
            pq.execute(address(nft), FEE5, abi.encodeCall(PageNFT.renew, (id)));
            pq.execute(address(nft), 0, abi.encodeCall(PageNFT.transferFrom, (me, alice, id)));
            vm.stopPrank();
            assertEq(nft.ownerOf(id), alice);
            assertEq(nft.owed(me), PRICE5, "trial price credited back to the account that paid it");
        }
    }
}

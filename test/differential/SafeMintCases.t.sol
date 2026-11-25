// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {trialCommitment} from "../utils/TrialCommitment.sol";

import {console} from "forge-std/Test.sol";
import {SafeMintBase} from "./SafeMintBase.sol";
import {PageNFT} from "../../src/PageNFT.sol";
import {SubpageRegistrar} from "../../src/SubpageRegistrar.sol";
import {PQAccountLike, CountingReceiver, PQFactory} from "../utils/WalletMocks.sol";

contract SafeMintCasesTest is SafeMintBase {
    bytes4 constant NOT_OWNER_NOR_APPROVED = 0x4b6e7f18; // solady NotOwnerNorApproved()
    bytes4 constant ETH_TRANSFER_FAILED = 0xb12d13eb; // solady ETHTransferFailed()
    address payout = makeAddr("payout");

    function _buy(uint256 v, string memory l, address to) internal returns (uint256 id) {
        PageNFT nft = nfts[v];
        bytes32 commitment = nft.makeCommitment(l, to, 0, _s(l, to));
        vm.prank(bob);
        nft.commit(commitment);
        vm.warp(vm.getBlockTimestamp() + 61);
        vm.prank(bob);
        id = nft.reveal{value: FEE5}(l, to, 0, _s(l, to));
    }

    function _trial(uint256 v, string memory l, address to) internal returns (uint256 id) {
        PageNFT nft = nfts[v];
        bytes32 commitment = trialCommitment(address(nft), l, to, 0, _s(l, to));
        vm.prank(bob);
        nft.commit(commitment);
        vm.warp(vm.getBlockTimestamp() + 61);
        vm.prank(bob);
        id = nft.revealTrial{value: PRICE5}(l, to, 0, _s(l, to));
    }

    function _pqDo(address target, uint256 value, bytes memory data) internal {
        vm.prank(entryPoint);
        pq.execute(target, value, data);
    }

    // S: the ways around the check when every contract recipient is asked

    // buy to a key wallet, then a plain transferFrom; the account then uses the name fully
    function test_S_workaround_buyToKeyThenTransferFrom() public {
        PageNFT nft = nfts[S];
        uint256 id = _buy(S, "pqname", bob);
        vm.prank(bob);
        vm.expectRevert(NOT_RECEIVER);
        nft.safeTransferFrom(bob, address(pq), id);
        vm.prank(bob);
        nft.transferFrom(bob, address(pq), id);
        assertEq(nft.ownerOf(id), address(pq));
        _pqDo(address(nft), 0, abi.encodeCall(PageNFT.setAddr, (id, payout)));
        _pqDo(address(nft), 0, abi.encodeCall(PageNFT.setText, (id, "k", "v")));
        assertEq(nft.resolve(id), payout);
        _pqDo(address(nft), 0, abi.encodeCall(PageNFT.transferFrom, (address(pq), alice, id)));
        assertEq(nft.ownerOf(id), alice);

        uint256 id2 = _buy(S, "vaultname", bob);
        vm.prank(bob);
        nft.transferFrom(bob, vaultNoHook, id2);
        vm.prank(vaultNoHook, vaultNoHook);
        nft.setPrimaryPage(id2);
        assertEq(nft.reverseResolve(vaultNoHook), "vaultname");
    }

    // in S a trial cannot be minted to an account with code and no hook, and cannot move to one until paid,
    // so such an account holds a trial only if it got it while it had no code or still had a hook
    function test_S_trialForNoHookAccountImpossible() public {
        PageNFT nft = nfts[S];
        assertEq(_attempt(S, 1, PQ, false), NOT_RECEIVER);
        assertEq(_attempt(S, 1, PQ, true), NOT_RECEIVER);
        assertEq(_attempt(S, 1, D7702_NOHOOK, true), NOT_RECEIVER);
        uint256 id = _trial(S, "trialname", bob);
        vm.prank(bob);
        vm.expectRevert(PageNFT.Unpaid.selector);
        nft.transferFrom(bob, address(pq), id);
        vm.prank(bob);
        vm.expectRevert(PageNFT.Unpaid.selector);
        nft.transferFrom(bob, vaultNoHook, id);
        // paying the year makes it movable, and it is then a normal name, not a trial
        vm.prank(bob);
        nft.renew{value: FEE5}(id);
        vm.prank(bob);
        nft.transferFrom(bob, address(pq), id);
        assertEq(nft.ownerOf(id), address(pq));
    }

    // an account that is not deployed yet has no code, so it receives in every build, trials included
    function test_S_counterfactualAccountReceivesBeforeDeploy() public {
        PageNFT nft = nfts[S];
        PQFactory f = new PQFactory();
        address predicted = f.predict(entryPoint, bytes32("salt"));
        assertEq(predicted.code.length, 0);
        uint256 id = _buy(S, "earlybird", predicted);
        uint256 t = _trial(S, "earlytrial", predicted);
        assertEq(nft.ownerOf(id), predicted);
        assertEq(nft.ownerOf(t), predicted);
        address deployed = f.deploy(entryPoint, bytes32("salt"));
        assertEq(deployed, predicted);
        vm.prank(entryPoint);
        PQAccountLike(payable(deployed)).execute(address(nft), 0, abi.encodeCall(PageNFT.setAddr, (id, payout)));
        assertEq(nft.resolve(id), payout);
        // once deployed it can no longer receive a mint in S
        string memory l = "latebird";
        bytes32 commitment = nft.makeCommitment(l, deployed, 0, _s(l, deployed));
        vm.prank(bob);
        nft.commit(commitment);
        vm.warp(vm.getBlockTimestamp() + 61);
        vm.prank(bob);
        vm.expectRevert(NOT_RECEIVER);
        nft.reveal{value: FEE5}(l, deployed, 0, _s(l, deployed));
    }

    // subpages and registrar sales: mint to a key wallet, then transferFrom
    function test_S_workaround_subpages() public {
        PageNFT nft = nfts[S];
        uint256 parent = _registrarParent(S);
        vm.prank(alice);
        uint256 sub = nft.registerSubpageFor("club", parent, alice);
        vm.prank(alice);
        nft.transferFrom(alice, address(pq), sub);
        assertEq(nft.ownerOf(sub), address(pq));
        vm.prank(bob);
        uint256 sold = regs[S].registerSubpageFor(parent, "shop", bob, 0, address(0));
        vm.prank(bob);
        nft.transferFrom(bob, address(pq), sold);
        assertEq(nft.ownerOf(sold), address(pq));
    }

    // P: what plain minting lets through

    // a contract with no way to call anything holds the name until it lapses; its money is stuck for good
    function test_P_tokenHoldsNameAndMoneyForever() public {
        PageNFT nft = nfts[P];
        uint256 id = _buy(P, "stuckname", address(token));
        assertEq(nft.ownerOf(id), address(token));
        vm.prank(bob);
        vm.expectRevert(NOT_OWNER_NOR_APPROVED);
        nft.transferFrom(address(token), bob, id);
        vm.prank(bob);
        vm.expectRevert(PageNFT.Unauthorized.selector);
        nft.setAddr(id, bob);
        vm.prank(bob);
        vm.expectRevert(PageNFT.Unauthorized.selector);
        nft.setPrimaryPage(id);
        // the name pays the token contract on OP and answers nothing on other chains
        assertEq(nft.resolve(id), address(token));
        assertEq(nft.addr(id, 60).length, 0);
        assertEq(nft.payee(id), address(token));
        assertEq(nft.reverseResolve(address(token)), "");
        assertTrue(bytes(nft.tokenURI(id)).length > 0);

        // committed one second into the auction and revealed 61 seconds later: the carried deposit and
        // three quarters of the premium go to the token
        vm.warp(uint256(nft.expiresAt(id)) + 90 days + 1);
        uint256 premium = nft.getPremium(id);
        (,,, uint256 total) = nft.quote("stuckname");
        string memory l = "stuckname";
        bytes32 commitment = nft.makeCommitment(l, bob, 0, _s(l, bob));
        vm.prank(bob);
        nft.commit(commitment);
        vm.warp(vm.getBlockTimestamp() + 61);
        premium = nft.getPremium(id);
        (,,, total) = nft.quote(l);
        vm.deal(bob, total + 1 ether);
        vm.prank(bob);
        nft.reveal{value: total}(l, bob, 0, _s(l, bob));
        uint256 owedToToken = nft.owed(address(token));
        assertEq(owedToToken, FEE5 + premium - premium * 2500 / 10_000);
        console.log("owed to the token contract after the auction buyout (wei)", owedToToken);
        vm.expectRevert(ETH_TRANSFER_FAILED);
        nft.withdraw(address(token));
        assertEq(nft.owed(address(token)), owedToToken);

        // S refuses the same registration, so nothing is stranded there
        assertEq(_attempt(S, 0, TOKEN, false), NOT_RECEIVER);
    }

    // a contract shaped like WETH accepts the withdrawal; the ETH becomes WETH credited to the PageNFT, gone for good
    function test_P_wethLikeSwallowsTheMoney() public {
        PageNFT nft = nfts[P];
        uint256 id = _buy(P, "wethname", address(weth));
        vm.warp(uint256(nft.expiresAt(id)) + 90 days + 21 days + 1);
        string memory l = "wethname";
        bytes32 commitment = nft.makeCommitment(l, bob, 0, _s(l, bob));
        vm.prank(bob);
        nft.commit(commitment);
        vm.warp(vm.getBlockTimestamp() + 61);
        (,,, uint256 total) = nft.quote(l);
        vm.prank(bob);
        nft.reveal{value: total}(l, bob, 0, _s(l, bob));
        assertEq(nft.owed(address(weth)), FEE5);
        nft.withdraw(address(weth));
        assertEq(nft.owed(address(weth)), 0);
        assertEq(weth.balanceOf(address(nft)), FEE5);
        assertEq(weth.balanceOf(address(weth)), 0);
    }

    // an unsolicited trial on a contract: the payer gets the money back, the contract holds a dead trial 14 days
    function test_P_trialOnAContract() public {
        PageNFT nft = nfts[P];
        uint256 t = _trial(P, "spamtrial", address(token));
        assertEq(nft.ownerOf(t), address(token));
        (address payer, uint96 amount) = nft.trialPaymentOf(t);
        assertEq(payer, bob);
        assertEq(amount, PRICE5);
        vm.warp(uint256(nft.expiresAt(t)) + 1);
        nft.release(t);
        assertEq(nft.owed(bob), PRICE5);
        // no grace for a trial: free again right away
        assertTrue(nft.isAvailable("spamtrial", 0));
        // S refuses it outright
        assertEq(_attempt(S, 1, TOKEN, false), NOT_RECEIVER);
    }

    // an account that bought its own trial gets its refund and can withdraw it
    function test_P_H2_selfTrialRefundReachesTheAccount() public {
        for (uint256 v = P; v <= H2; v += 2) {
            PageNFT nft = nfts[v];
            string memory l = v == P ? "selftrialp" : "selftrialh";
            address to = address(pq);
            bytes32 commitment = trialCommitment(address(nft), l, to, 0, _s(l, to));
            vm.prank(bob);
            nft.commit(commitment);
            vm.warp(vm.getBlockTimestamp() + 61);
            _pqDo(address(nft), PRICE5, abi.encodeCall(PageNFT.revealTrial, (l, to, 0, _s(l, to))));
            uint256 t = nft.computeId(l);
            assertEq(nft.ownerOf(t), to);
            vm.warp(uint256(nft.expiresAt(t)) + 1);
            nft.release(t);
            assertEq(nft.owed(to), PRICE5);
            uint256 before = to.balance;
            nft.withdraw(to);
            assertEq(to.balance, before + PRICE5);
        }
    }

    // plain minting lets a name land in the registrar, which the other builds refuse
    function test_P_nameStrandsInTheRegistrar() public {
        PageNFT nft = nfts[P];
        address reg = address(regs[P]);
        uint256 id = _buy(P, "intoreg", reg);
        assertEq(nft.ownerOf(id), reg);
        assertEq(nft.payee(id), reg);
        uint256 parent = _aliceParent(P);
        vm.prank(alice);
        uint256 sub = nft.registerSubpageFor("lost", parent, reg);
        assertEq(nft.ownerOf(sub), reg);
    }

    // a 7702 account without the hook receives in P, H1 and H2, and its key moves the name: nothing is stuck
    function test_P_H1_H2_7702WithoutHookIsNeverStuck() public {
        for (uint256 v = P; v <= H2; ++v) {
            PageNFT nft = nfts[v];
            string memory l = v == P ? "vaultp" : v == H1 ? "vaulthone" : "vaulthtwo";
            uint256 id = _buy(v, l, vaultNoHook);
            vm.startPrank(vaultNoHook, vaultNoHook);
            nft.setAddr(id, payout);
            nft.setText(id, "k", "v");
            nft.transferFrom(vaultNoHook, alice, id);
            vm.stopPrank();
            assertEq(nft.ownerOf(id), alice);
        }
    }

    // the receiver hook during mint

    function _counting() internal returns (CountingReceiver c) {
        c = new CountingReceiver{value: 1 ether}(safeOwner);
    }

    // who gets called back during a mint, and a later safe transfer, in each build
    function test_hookCallsAtMint() public {
        uint256[4] memory third;
        uint256[4] memory self;
        uint256[4] memory safeMove;
        for (uint256 v; v < 4; ++v) {
            PageNFT nft = nfts[v];
            CountingReceiver c = _counting();
            string memory l = string.concat("hookthird", vname[v]);
            l = _lower(l);
            _buy(v, l, address(c));
            third[v] = c.hookCalls();

            CountingReceiver d = _counting();
            string memory m = _lower(string.concat("hookself", vname[v]));
            bytes32 commitment = nft.makeCommitment(m, address(d), 0, _s(m, address(d)));
            vm.prank(bob);
            nft.commit(commitment);
            vm.warp(vm.getBlockTimestamp() + 61);
            vm.prank(safeOwner);
            d.exec(address(nft), FEE5, abi.encodeCall(PageNFT.reveal, (m, address(d), 0, _s(m, address(d)))));
            self[v] = d.hookCalls();

            uint256 id = _buy(v, _lower(string.concat("hookmove", vname[v])), bob);
            vm.prank(bob);
            nft.safeTransferFrom(bob, address(c), id);
            safeMove[v] = c.hookCalls() - third[v];
            console.log(string.concat(vname[v], ": hook calls at a third-party mint, a self mint, a later safe transfer"));
            console.log(third[v], self[v], safeMove[v]);
        }
        assertEq(third[S], 1); assertEq(self[S], 1); assertEq(safeMove[S], 1);
        assertEq(third[P], 0); assertEq(self[P], 0); assertEq(safeMove[P], 1);
        assertEq(third[H1], 1); assertEq(self[H1], 1); assertEq(safeMove[H1], 1);
        assertEq(third[H2], 1); assertEq(self[H2], 0); assertEq(safeMove[H2], 1);
    }

    // the push custody route at mint (save a main address inside the hook) exists only where the hook runs;
    // where it does not, as in P here or for a contract that mints for itself in H2, the contract saves in
    // its own call after the mint, which leaves the same end state
    function test_custodyRouteAtMint() public {
        for (uint256 v; v < 4; ++v) {
            PageNFT nft = nfts[v];
            CountingReceiver c = _counting();
            c.arm(address(nft), payout);
            uint256 id = _buy(v, _lower(string.concat("custody", vname[v])), address(c));
            address r = nft.resolve(id);
            console.log(string.concat(vname[v], ": main address right after a third-party mint to a custody contract"), r);
            if (v == P) {
                assertEq(r, address(c));
                // the contract saves in its own call; at mint nothing counted before, so nothing was lost
                vm.prank(safeOwner);
                c.exec(address(nft), 0, abi.encodeCall(PageNFT.setAddr, (id, payout)));
            }
            assertEq(nft.resolve(id), payout);
        }
    }

    function _lower(string memory s) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        for (uint256 i; i < b.length; ++i) {
            if (b[i] >= 0x41 && b[i] <= 0x5a) b[i] = bytes1(uint8(b[i]) + 32);
        }
        return string(b);
    }
}

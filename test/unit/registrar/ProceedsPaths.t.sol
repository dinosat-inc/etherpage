// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Test, Vm} from "forge-std/Test.sol";
import {PageNFT} from "../../../src/PageNFT.sol";
import {PageCard} from "../../../src/PageCard.sol";
import {SubpageRegistrar, IPageNFT} from "../../../src/SubpageRegistrar.sol";
import {MockERC20, Delegate7702, RejectETH} from "../../utils/MinterMocks.sol";
import {PlainPayout, HeavyPayoutLogic, HeavyPayout} from "../../utils/ProceedsMocks.sol";
import {LedgerForce} from "../../utils/MoneyLogReplay.sol";
import {
    ArmedPayout, LedgerWatchPayout, SaleHookAccount, SaleHookToken, SelfBurnToken
} from "../../utils/ClaimMocks.sol";

// How registrar proceeds are paid: which accounts a claim can pay, what a payout sees and can do while it is
// paid, what a hook inside a sale can claim, how the two claim functions share one balance, and which payouts a
// holder may pick.
contract ProceedsPathsTest is Test {
    bytes4 constant REENTRANCY = 0xab143c06; // Reentrancy()
    bytes4 constant ETH_TRANSFER_FAILED = 0xb12d13eb; // ETHTransferFailed()
    bytes4 constant TRANSFER_FROM_FAILED = 0x7939f424; // TransferFromFailed()
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    PageCard card;
    PageNFT nft;
    SubpageRegistrar reg;
    MockERC20 usd;

    address alice = makeAddr("paths-alice");
    address bob = makeAddr("paths-bob");
    address carol = makeAddr("paths-carol");
    address dave = makeAddr("paths-dave");
    address buyer = makeAddr("paths-buyer");
    address stranger = makeAddr("paths-stranger");

    function setUp() public {
        vm.warp(1_800_000_000);
        card = new PageCard();
        nft = new PageNFT(card);
        reg = new SubpageRegistrar(IPageNFT(address(nft)));
        usd = new MockERC20();
        vm.deal(buyer, 1000 ether);
    }

    // payer commits and reveals a year of label for to
    function _register(address payer, string memory label, address to) internal returns (uint256 id) {
        bytes32 secret = keccak256(abi.encode("paths", label, to));
        bytes32 c = nft.makeCommitment(label, to, 0, secret);
        vm.prank(payer);
        nft.commit(c);
        vm.warp(vm.getBlockTimestamp() + 61);
        (,,, uint256 total) = nft.quote(label);
        vm.deal(payer, payer.balance + total);
        vm.prank(payer);
        id = nft.reveal{value: total}(label, to, 0, secret);
    }

    // the holder picks the registrar and sells for ETH at price, paid to payout
    function _openShop(address holder, uint256 parentId, address payout, uint256 price) internal {
        vm.prank(holder);
        nft.setSubpageMinter(parentId, address(reg));
        _terms(holder, parentId, payout, address(0), price);
    }

    function _terms(address holder, uint256 parentId, address payout, address feeToken, uint256 price) internal {
        vm.prank(holder);
        reg.configure(parentId, payout, feeToken, price, true, address(0), 0, false);
    }

    // the buyer pays exactly price for a subpage of parentId
    function _buy(uint256 parentId, string memory label, uint256 price) internal {
        vm.prank(buyer);
        reg.registerSubpage{value: price}(parentId, label, price, address(0));
    }

    function _subId(string memory label, uint256 parentId) internal pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(bytes32(parentId), keccak256(bytes(label)))));
    }

    function _who(bytes32 topic) internal pure returns (address) {
        return address(uint160(uint256(topic)));
    }

    // the logs of one emitter in a recording
    function _logsOf(Vm.Log[] memory logs, address emitter) internal pure returns (Vm.Log[] memory out) {
        uint256 n;
        for (uint256 i; i < logs.length; ++i) if (logs[i].emitter == emitter) ++n;
        out = new Vm.Log[](n);
        n = 0;
        for (uint256 i; i < logs.length; ++i) if (logs[i].emitter == emitter) out[n++] = logs[i];
    }

    // the recording holds exactly one registrar log, a ProceedsClaimed with these values, and nothing from PageNFT
    function _assertOnlyTheClaimLogged(Vm.Log[] memory logs, address account, address to, uint256 amount)
        internal
        view
    {
        Vm.Log[] memory r = _logsOf(logs, address(reg));
        assertEq(r.length, 1, "one registrar log");
        assertEq(r[0].topics[0], SubpageRegistrar.ProceedsClaimed.selector);
        assertEq(_who(r[0].topics[1]), account);
        assertEq(_who(r[0].topics[2]), to);
        assertEq(abi.decode(r[0].data, (uint256)), amount);
        assertEq(_logsOf(logs, address(nft)).length, 0, "no PageNFT log, so nothing was minted");
    }

    // every guarded entry point of the registrar, as the armed payout calls them from inside a payment:
    // claimProceedsFor for itself and for bob, claimProceeds, configure and disable of its own name, a free
    // registerSubpage and registerSubpageFor, a paid sale and a reveal
    function _guardedCalls(address r, uint256 shop, uint256 club, bytes32 secret)
        internal
        view
        returns (address[] memory t, uint256[] memory v, bytes[] memory d)
    {
        t = new address[](9);
        v = new uint256[](9);
        d = new bytes[](9);
        for (uint256 i; i < 9; ++i) t[i] = address(reg);
        d[0] = abi.encodeCall(SubpageRegistrar.claimProceedsFor, (r));
        d[1] = abi.encodeCall(SubpageRegistrar.claimProceedsFor, (bob));
        d[2] = abi.encodeCall(SubpageRegistrar.claimProceeds, (address(0)));
        d[3] = abi.encodeCall(
            SubpageRegistrar.configure, (shop, address(0), address(0), 0.5 ether, true, address(0), 0, false)
        );
        d[4] = abi.encodeCall(SubpageRegistrar.disable, (shop));
        d[5] = abi.encodeCall(SubpageRegistrar.registerSubpage, (shop, "ina", 0, address(0)));
        d[6] = abi.encodeCall(SubpageRegistrar.registerSubpageFor, (shop, "inb", carol, 0, address(0)));
        d[7] = abi.encodeCall(SubpageRegistrar.registerSubpageFor, (club, "inc", r, 0.01 ether, address(0)));
        v[7] = 0.01 ether;
        d[8] = abi.encodeCall(SubpageRegistrar.revealSubpageFor, (shop, "ind", r, secret, 0, address(0)));
    }

    // each armed call of the last payment to r got Reentrancy
    function _assertEveryCallBlocked(ArmedPayout r) internal view {
        (bool[] memory oks, bytes[] memory rets) = r.results();
        assertEq(oks.length, 9, "every armed call was made");
        for (uint256 i; i < 9; ++i) {
            assertFalse(oks[i], string.concat("armed call ", vm.toString(i), " went through"));
            assertEq(rets[i], abi.encodeWithSelector(REENTRANCY), string.concat("armed call ", vm.toString(i)));
        }
    }

    // none of the armed calls left a trace: the four labels are free, the commitment is unused and the terms of
    // shop are the ones r set
    function _assertNoTrace(address r, uint256 shop, uint256 club, bytes32 commitment) internal view {
        assertTrue(nft.isAvailable("ina", shop), "ina");
        assertTrue(nft.isAvailable("inb", shop), "inb");
        assertTrue(nft.isAvailable("inc", club), "inc");
        assertTrue(nft.isAvailable("ind", shop), "ind");
        assertGt(reg.subCommitments(commitment), 0, "the commitment is still there");
        (address controller, bool enabled,,, uint96 price,,, address payout,) = reg.config(shop);
        assertEq(controller, r);
        assertTrue(enabled, "shop still sells");
        assertEq(price, 0, "shop still sells for free");
        assertEq(payout, r);
    }

    // A payout whose receive calls every guarded entry point of the registrar while it is paid gets Reentrancy
    // each time: claimProceedsFor for itself and for another funded account, claimProceeds, configure, disable,
    // registerSubpage, registerSubpageFor, a paid sale and a reveal. The same calls go through outside a claim.
    // A third party's claimProceedsFor pays it once and in full, logs only that claim, and leaves the other
    // credit, the terms and the labels as they were. When another account sends its own credit there with
    // claimProceeds, the payout, owed again, still cannot take its own credit from inside that payment.
    function test_claimForReentryGetsNoSecondPayment() public {
        ArmedPayout r = new ArmedPayout();
        vm.deal(address(r), 1 ether);
        // club sells to r's benefit; r holds shop and sells its subpages for free; zoo pays bob and gold pays dave
        uint256 club = _register(alice, "club", alice);
        _openShop(alice, club, address(r), 0.01 ether);
        uint256 shop = _register(alice, "shop", address(r));
        r.exec(address(nft), 0, abi.encodeCall(PageNFT.setSubpageMinter, (shop, address(reg))));
        r.exec(
            address(reg),
            0,
            abi.encodeCall(SubpageRegistrar.configure, (shop, address(0), address(0), 0, true, address(0), 0, false))
        );
        uint256 zoo = _register(bob, "zoo", bob);
        _openShop(bob, zoo, bob, 0.02 ether);
        uint256 gold = _register(alice, "gold", alice);
        _openShop(alice, gold, dave, 0.03 ether);
        _buy(club, "c1", 0.01 ether);
        _buy(zoo, "z1", 0.02 ether);
        _buy(gold, "g1", 0.03 ether);
        bytes32 secret = keccak256("inside");
        bytes32 commitment = reg.makeSubpageCommitment(shop, "ind", address(r), secret);
        vm.prank(buyer);
        reg.commitSubpage(commitment);
        vm.warp(vm.getBlockTimestamp() + 61);
        (address[] memory t, uint256[] memory v, bytes[] memory d) = _guardedCalls(address(r), shop, club, secret);

        // outside a claim every one of the calls goes through
        for (uint256 i; i < 9; ++i) {
            uint256 snap = vm.snapshotState();
            bytes memory ret = r.exec(t[i], v[i], d[i]);
            if (i == 0 || i == 2) assertEq(abi.decode(ret, (uint256)), 0.01 ether, "r collects outside a claim");
            if (i == 1) assertEq(abi.decode(ret, (uint256)), 0.02 ether, "bob is paid outside a claim");
            if (i >= 5) assertEq(nft.ownerOf(abi.decode(ret, (uint256))), i == 6 ? carol : address(r));
            vm.revertToState(snap);
        }

        // a third party pushes r's proceeds
        r.arm(t, v, d);
        uint256 rBefore = address(r).balance;
        uint256 bobBefore = bob.balance;
        uint256 regBefore = address(reg).balance;
        vm.recordLogs();
        vm.prank(stranger);
        uint256 paid = reg.claimProceedsFor(address(r));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(paid, 0.01 ether);
        _assertEveryCallBlocked(r);
        assertEq(r.payments(), 1, "one payment reached r");
        assertEq(r.nested(), 0);
        assertEq(address(r).balance, rBefore + 0.01 ether, "r is paid once, in full");
        assertEq(reg.proceedsOf(address(r)), 0);
        assertEq(reg.proceedsOf(bob), 0.02 ether, "the other credit is intact");
        assertEq(bob.balance, bobBefore);
        assertEq(reg.proceedsOf(dave), 0.03 ether);
        assertEq(address(reg).balance, regBefore - 0.01 ether);
        _assertOnlyTheClaimLogged(logs, address(r), address(r), 0.01 ether);
        _assertNoTrace(address(r), shop, club, commitment);

        // r is owed again, and dave sends his own credit to r
        _buy(club, "c2", 0.01 ether);
        rBefore = address(r).balance;
        regBefore = address(reg).balance;
        vm.recordLogs();
        vm.prank(dave);
        paid = reg.claimProceeds(address(r));
        logs = vm.getRecordedLogs();
        assertEq(paid, 0.03 ether);
        _assertEveryCallBlocked(r);
        assertEq(r.payments(), 2);
        assertEq(r.nested(), 0, "no second payment reached r inside the first");
        assertEq(address(r).balance, rBefore + 0.03 ether, "r receives dave's credit once and none of its own");
        assertEq(reg.proceedsOf(address(r)), 0.01 ether, "r's own credit stays");
        assertEq(reg.proceedsOf(dave), 0);
        assertEq(reg.proceedsOf(bob), 0.02 ether);
        assertEq(address(reg).balance, regBefore - 0.03 ether);
        _assertOnlyTheClaimLogged(logs, dave, address(r), 0.03 ether);
        _assertNoTrace(address(r), shop, club, commitment);

        // once the claims are over r collects its own credit
        r.disarm();
        bytes memory own = r.exec(address(reg), 0, abi.encodeCall(SubpageRegistrar.claimProceeds, (address(0))));
        assertEq(abi.decode(own, (uint256)), 0.01 ether);
        assertEq(address(reg).balance, 0.02 ether, "only bob's credit is left");
    }

    // the watcher's view from inside its last payment: the proceeds of w, bob, carol and dave, in that order, the
    // amount paid, and the registrar's balance, which is their sum plus extra
    function _assertSeen(LedgerWatchPayout w, uint256[4] memory want, uint256 value, uint256 extra) internal view {
        uint256[] memory s = w.seen();
        assertEq(s.length, 4);
        uint256 sum;
        for (uint256 i; i < 4; ++i) {
            assertEq(s[i], want[i], string.concat("proceeds seen of watched account ", vm.toString(i)));
            sum += s[i];
        }
        assertEq(w.seenValue(), value, "the amount paid");
        assertEq(w.seenBalance(), sum + extra, "the registrar's balance is what it still owes");
    }

    // Inside the receive of the account being paid, the claimed balance already reads zero and the registrar's
    // balance equals the sum of proceedsOf over every account still owed: when a third party pushes the claim,
    // when the account claims for itself, and when another account sends its own credit there. ETH forced in by
    // selfdestruct stays on top of that sum.
    function test_claimForLedgerConsistentDuringPayout() public {
        LedgerWatchPayout w = new LedgerWatchPayout(reg);
        uint256 club = _register(alice, "club", alice);
        _openShop(alice, club, address(w), 0.01 ether);
        uint256 zoo = _register(bob, "zoo", bob);
        _openShop(bob, zoo, bob, 0.02 ether);
        uint256 gold = _register(carol, "gold", carol);
        _openShop(carol, gold, carol, 0.05 ether);
        _buy(club, "a", 0.01 ether);
        _buy(club, "b", 0.01 ether);
        _buy(club, "c", 0.01 ether);
        _buy(zoo, "a", 0.02 ether);
        _buy(gold, "a", 0.05 ether);
        address[] memory watched = new address[](4);
        watched[0] = address(w);
        watched[1] = bob;
        watched[2] = carol;
        watched[3] = dave;
        w.watch(watched);
        assertEq(address(reg).balance, 0.1 ether);

        // a third party pushes w's proceeds
        vm.prank(stranger);
        reg.claimProceedsFor(address(w));
        assertEq(w.payments(), 1);
        _assertSeen(w, [uint256(0), 0.02 ether, 0.05 ether, 0], 0.03 ether, 0);

        // w claims for itself
        _buy(club, "d", 0.01 ether);
        w.claim(address(0));
        assertEq(w.payments(), 2);
        _assertSeen(w, [uint256(0), 0.02 ether, 0.05 ether, 0], 0.01 ether, 0);

        // carol sends her credit to w, which is owed again
        _buy(club, "e", 0.01 ether);
        vm.prank(carol);
        reg.claimProceeds(address(w));
        assertEq(w.payments(), 3);
        _assertSeen(w, [uint256(0.01 ether), 0.02 ether, 0, 0], 0.05 ether, 0);

        // with ETH forced in, bob sends his credit to w
        new LedgerForce{value: 1 ether}(payable(address(reg)));
        vm.prank(bob);
        reg.claimProceeds(address(w));
        assertEq(w.payments(), 4);
        _assertSeen(w, [uint256(0.01 ether), 0, 0, 0], 0.02 ether, 1 ether);
    }

    // claimProceedsFor pays every kind of account its whole balance: a key wallet, a contract whose only code is a
    // receive, a Safe shaped proxy whose receive cannot run on 46,000 gas or on a 2300 gas stipend, an EIP7702
    // account whose delegate has a receive, and DEAD, where the ETH is burned in plain sight. For a payout that
    // refuses ETH the claim reverts ETHTransferFailed and its balance stays whole until it sends it elsewhere with
    // claimProceeds.
    function test_claimForPaysEveryAccountKind() public {
        uint256 club = _register(alice, "club", alice);
        vm.prank(alice);
        nft.setSubpageMinter(club, address(reg));
        address key = makeAddr("paths-key");
        PlainPayout plain = new PlainPayout();
        HeavyPayout heavy = new HeavyPayout(address(new HeavyPayoutLogic()));
        (bool okAt46k,) = address(heavy).call{value: 1, gas: 46_000}("");
        assertFalse(okAt46k, "the proxy's receive needs more than 46,000 gas");
        // a value call given no gas gets only the 2300 gas stipend, as transfer and send do
        (bool okAtStipend,) = address(heavy).call{value: 1, gas: 0}("");
        assertFalse(okAtStipend, "the proxy's receive fails on the stipend");
        (address seven, uint256 pk) = makeAddrAndKey("paths-7702");
        Delegate7702 impl = new Delegate7702();
        vm.signAndAttachDelegation(address(impl), pk);
        vm.prank(stranger);
        (bool okDelegated,) = seven.call("");
        assertTrue(okDelegated);
        assertEq(seven.code, abi.encodePacked(hex"ef0100", address(impl)), "seven delegates to impl");

        address[5] memory kinds = [key, address(plain), address(heavy), seven, DEAD];
        for (uint256 i; i < 5; ++i) {
            address a = kinds[i];
            uint256 price = (i + 1) * 0.01 ether;
            _terms(alice, club, a, address(0), price);
            _buy(club, string.concat("k", vm.toString(i)), price);
            uint256 before = a.balance;
            uint256 regBefore = address(reg).balance;
            vm.expectEmit(true, true, false, true, address(reg));
            emit SubpageRegistrar.ProceedsClaimed(a, a, price);
            vm.prank(stranger);
            uint256 paid = reg.claimProceedsFor(a);
            assertEq(paid, price, string.concat("kind ", vm.toString(i)));
            assertEq(a.balance, before + price, string.concat("kind ", vm.toString(i), " is paid in full"));
            assertEq(reg.proceedsOf(a), 0);
            assertEq(address(reg).balance, regBefore - price);
        }
        assertEq(HeavyPayoutLogic(payable(address(heavy))).received(), 0.03 ether, "the proxy's receive ran");

        RejectETH refuser = new RejectETH();
        _terms(alice, club, address(refuser), address(0), 0.06 ether);
        _buy(club, "k5", 0.06 ether);
        vm.prank(stranger);
        vm.expectRevert(ETH_TRANSFER_FAILED);
        reg.claimProceedsFor(address(refuser));
        assertEq(reg.proceedsOf(address(refuser)), 0.06 ether, "the refusing payout's balance stays whole");
        assertEq(address(reg).balance, 0.06 ether);
        uint256 daveBefore = dave.balance;
        refuser.claim(address(reg), dave);
        assertEq(dave.balance, daveBefore + 0.06 ether);
        assertEq(reg.proceedsOf(address(refuser)), 0);
        assertEq(address(reg).balance, 0);
    }

    struct HookSale {
        SaleHookAccount hk;
        SaleHookToken tk;
        address payout;
        address funded;
        uint256 club;
        uint256 mall;
    }

    // the balances and credits a hooked sale must leave alone, or change by exactly the price
    struct HookSnapshot {
        uint256 payoutOwed;
        uint256 fundedOwed;
        uint256 hkOwed;
        uint256 tkOwed;
        uint256 payer;
        uint256 regBalance;
        uint256 fundedBalance;
        uint256 daveBalance;
        uint256 payoutTokens;
        uint256 buyerTokens;
    }

    function _snapHook(HookSale memory x, address payer) internal view returns (HookSnapshot memory s) {
        s.payoutOwed = reg.proceedsOf(x.payout);
        s.fundedOwed = reg.proceedsOf(x.funded);
        s.hkOwed = reg.proceedsOf(address(x.hk));
        s.tkOwed = reg.proceedsOf(address(x.tk));
        s.payer = payer.balance;
        s.regBalance = address(reg).balance;
        s.fundedBalance = x.funded.balance;
        s.daveBalance = dave.balance;
        s.payoutTokens = x.tk.balanceOf(x.payout);
        s.buyerTokens = x.tk.balanceOf(buyer);
    }

    // one sale with a hook at site 0 (the recipient's receiver hook), 1 (the buyer's receive taking its excess
    // back) or 2 (the fee token's transferFrom), where the hook calls claimProceedsFor for a funded account (k 0)
    // or makes its own claimProceeds (k 1), and then carries on or reverts with what came back
    function _hookedSale(HookSale memory x, uint256 site, uint256 k, bool bubble) internal {
        string memory label = string.concat("s", vm.toString(site), vm.toString(k));
        bytes memory inner = k == 0
            ? abi.encodeCall(SubpageRegistrar.claimProceedsFor, (x.funded))
            : abi.encodeCall(SubpageRegistrar.claimProceeds, (site == 2 ? dave : address(0)));
        uint256 parent = site == 2 ? x.mall : x.club;
        address to = site == 0 ? address(x.hk) : carol;
        address payer = site == 1 ? address(x.hk) : buyer;
        string memory what = string.concat(label, bubble ? " reverting" : " carrying on");
        if (site == 0) x.hk.arm(x.hk.AT_RECEIVER(), address(reg), inner, bubble);
        else if (site == 1) x.hk.arm(x.hk.AT_REFUND(), address(reg), inner, bubble);
        else x.tk.arm(address(reg), inner, bubble);
        bytes memory buyHk =
            abi.encodeCall(SubpageRegistrar.registerSubpageFor, (x.club, label, to, 0.01 ether, address(0)));
        HookSnapshot memory s = _snapHook(x, payer);

        if (bubble) {
            bytes4 err = site == 0 ? REENTRANCY : site == 1 ? ETH_TRANSFER_FAILED : TRANSFER_FROM_FAILED;
            if (site == 1) {
                vm.expectRevert(err);
                x.hk.buy(address(reg), buyHk, 0.015 ether);
            } else if (site == 0) {
                vm.prank(buyer);
                vm.expectRevert(err);
                reg.registerSubpageFor{value: 0.015 ether}(parent, label, to, 0.01 ether, address(0));
            } else {
                vm.prank(buyer);
                vm.expectRevert(err);
                reg.registerSubpageFor(parent, label, to, 5, address(x.tk));
            }
            assertTrue(nft.isAvailable(label, parent), string.concat(what, ": nothing was sold"));
            assertEq(payer.balance, s.payer, string.concat(what, ": the payer keeps its ETH"));
            assertEq(address(reg).balance, s.regBalance, what);
            assertEq(reg.proceedsOf(x.payout), s.payoutOwed, what);
            assertEq(x.tk.balanceOf(x.payout), s.payoutTokens, what);
            assertEq(x.tk.balanceOf(buyer), s.buyerTokens, what);
        } else {
            if (site == 1) {
                x.hk.buy(address(reg), buyHk, 0.015 ether);
            } else if (site == 0) {
                vm.prank(buyer);
                reg.registerSubpageFor{value: 0.015 ether}(parent, label, to, 0.01 ether, address(0));
            } else {
                vm.prank(buyer);
                reg.registerSubpageFor(parent, label, to, 5, address(x.tk));
            }
            bool called = site == 2 ? x.tk.called() : x.hk.called();
            bool ok = site == 2 ? x.tk.ok() : x.hk.ok();
            bytes memory ret = site == 2 ? x.tk.ret() : x.hk.ret();
            assertTrue(called, string.concat(what, ": the hook ran"));
            assertFalse(ok, string.concat(what, ": the claim went through"));
            assertEq(ret, abi.encodeWithSelector(REENTRANCY), what);
            // the sale completed as a sale with no hook does
            assertEq(nft.ownerOf(_subId(label, parent)), to, string.concat(what, ": the subpage is sold"));
            if (site == 2) {
                assertEq(x.tk.balanceOf(x.payout), s.payoutTokens + 5, what);
                assertEq(x.tk.balanceOf(buyer), s.buyerTokens - 5, what);
                assertEq(reg.proceedsOf(x.payout), s.payoutOwed, what);
                assertEq(address(reg).balance, s.regBalance, what);
                assertEq(payer.balance, s.payer, what);
            } else {
                assertEq(reg.proceedsOf(x.payout), s.payoutOwed + 0.01 ether, what);
                assertEq(address(reg).balance, s.regBalance + 0.01 ether, what);
                assertEq(payer.balance, s.payer - 0.01 ether, string.concat(what, ": the payer pays the price"));
            }
        }
        // the accounts the hook named are owed exactly what they were owed
        assertEq(reg.proceedsOf(x.funded), s.fundedOwed, string.concat(what, ": funded is still owed"));
        assertEq(reg.proceedsOf(address(x.hk)), s.hkOwed, string.concat(what, ": the hook account is still owed"));
        assertEq(reg.proceedsOf(address(x.tk)), s.tkOwed, string.concat(what, ": the token is still owed"));
        assertEq(x.funded.balance, s.fundedBalance, what);
        assertEq(dave.balance, s.daveBalance, what);
    }

    // claimProceedsFor and claimProceeds made during a sale, from the subpage recipient's receiver hook while
    // PageNFT mints, from the buyer's receive while its excess comes back, and from an ERC20 fee token's
    // transferFrom, each get Reentrancy while the accounts they name are owed. When the hook carries on, the sale
    // completes as one with no hook would; when it reverts with that error, the whole sale reverts and changes
    // nothing.
    function test_claimBlockedInsideASale() public {
        HookSale memory x;
        x.hk = new SaleHookAccount();
        x.tk = new SaleHookToken();
        x.payout = makeAddr("paths-payout");
        x.funded = makeAddr("paths-funded");
        x.club = _register(alice, "club", alice);
        _openShop(alice, x.club, x.payout, 0.01 ether);
        x.mall = _register(alice, "mall", alice);
        vm.prank(alice);
        nft.setSubpageMinter(x.mall, address(reg));
        _terms(alice, x.mall, x.payout, address(x.tk), 5);
        // zoo credits funded, the hook account and the token in turn, so each of them is owed
        uint256 zoo = _register(bob, "zoo", bob);
        _openShop(bob, zoo, x.funded, 0.02 ether);
        _buy(zoo, "f", 0.02 ether);
        _terms(bob, zoo, address(x.hk), address(0), 0.03 ether);
        _buy(zoo, "h", 0.03 ether);
        _terms(bob, zoo, address(x.tk), address(0), 0.04 ether);
        _buy(zoo, "t", 0.04 ether);
        x.tk.mint(buyer, 100);
        vm.prank(buyer);
        x.tk.approve(address(reg), type(uint256).max);
        vm.deal(address(x.hk), 1 ether);

        for (uint256 site; site < 3; ++site) {
            for (uint256 k; k < 2; ++k) {
                for (uint256 b; b < 2; ++b) {
                    uint256 snap = vm.snapshotState();
                    _hookedSale(x, site, k, b == 1);
                    vm.revertToState(snap);
                }
            }
        }
    }

    // Over ETH sales, claimProceeds and claimProceedsFor interleaved in both orders pay each account exactly once:
    // the second claim of the same balance reverts NothingToClaim, whoever makes it and wherever it sends. A sale
    // in a token never touches proceedsOf, and ETH forced in by selfdestruct is claimed by no one.
    function test_claimPathsInterleave() public {
        uint256 club = _register(alice, "club", alice);
        _openShop(alice, club, carol, 0.01 ether);
        uint256 zoo = _register(bob, "zoo", bob);
        _openShop(bob, zoo, dave, 0.02 ether);
        _buy(club, "a1", 0.01 ether);
        _buy(club, "a2", 0.01 ether);
        _buy(club, "a3", 0.01 ether);
        _buy(zoo, "b1", 0.02 ether);
        _buy(zoo, "b2", 0.02 ether);
        uint256 carol0 = carol.balance;
        uint256 dave0 = dave.balance;
        uint256 bob0 = bob.balance;

        // carol's own claim, then a pushed claim of the same balance
        vm.prank(carol);
        assertEq(reg.claimProceeds(address(0)), 0.03 ether);
        vm.prank(stranger);
        vm.expectRevert(SubpageRegistrar.NothingToClaim.selector);
        reg.claimProceedsFor(carol);
        // a pushed claim of dave's balance, then dave's own claims
        vm.prank(stranger);
        assertEq(reg.claimProceedsFor(dave), 0.04 ether);
        vm.prank(dave);
        vm.expectRevert(SubpageRegistrar.NothingToClaim.selector);
        reg.claimProceeds(address(0));
        vm.prank(dave);
        vm.expectRevert(SubpageRegistrar.NothingToClaim.selector);
        reg.claimProceeds(bob);
        assertEq(carol.balance, carol0 + 0.03 ether);
        assertEq(dave.balance, dave0 + 0.04 ether);

        // new sales between the claims, and a claim sent to another address
        _buy(club, "a4", 0.01 ether);
        vm.prank(stranger);
        assertEq(reg.claimProceedsFor(carol), 0.01 ether);
        vm.prank(carol);
        vm.expectRevert(SubpageRegistrar.NothingToClaim.selector);
        reg.claimProceeds(bob);
        _buy(club, "a5", 0.01 ether);
        vm.prank(carol);
        assertEq(reg.claimProceeds(bob), 0.01 ether);
        vm.prank(stranger);
        vm.expectRevert(SubpageRegistrar.NothingToClaim.selector);
        reg.claimProceedsFor(carol);
        assertEq(carol.balance, carol0 + 0.04 ether, "carol is paid each of her own claims once");
        assertEq(bob.balance, bob0 + 0.01 ether, "bob gets the credit carol sent him");
        assertEq(dave.balance, dave0 + 0.04 ether);
        assertEq(address(reg).balance, 0);

        // a sale in a token pays the payout straight away and leaves proceedsOf alone
        usd.mint(buyer, 50);
        vm.prank(buyer);
        usd.approve(address(reg), type(uint256).max);
        _terms(alice, club, carol, address(usd), 7);
        vm.prank(buyer);
        reg.registerSubpage(club, "t1", 7, address(usd));
        assertEq(usd.balanceOf(carol), 7);
        assertEq(usd.balanceOf(address(reg)), 0);
        assertEq(reg.proceedsOf(carol), 0, "a token sale credits no ETH");
        assertEq(address(reg).balance, 0);
        vm.prank(stranger);
        vm.expectRevert(SubpageRegistrar.NothingToClaim.selector);
        reg.claimProceedsFor(carol);

        // ETH forced in by selfdestruct belongs to no one
        new LedgerForce{value: 1 ether}(payable(address(reg)));
        address[10] memory anyone =
            [carol, dave, bob, alice, stranger, buyer, address(0), DEAD, address(reg), address(nft)];
        for (uint256 i; i < anyone.length; ++i) {
            vm.prank(stranger);
            vm.expectRevert(SubpageRegistrar.NothingToClaim.selector);
            reg.claimProceedsFor(anyone[i]);
        }
        for (uint256 i; i < 6; ++i) {
            vm.prank(anyone[i]);
            vm.expectRevert(SubpageRegistrar.NothingToClaim.selector);
            reg.claimProceeds(address(0));
            vm.prank(anyone[i]);
            vm.expectRevert(SubpageRegistrar.NothingToClaim.selector);
            reg.claimProceeds(stranger);
        }
        assertEq(address(reg).balance, 1 ether, "the forced ETH stays");

        // a later sale is paid out exactly, past the forced ETH
        _buy(zoo, "b3", 0.02 ether);
        vm.prank(stranger);
        assertEq(reg.claimProceedsFor(dave), 0.02 ether);
        assertEq(dave.balance, dave0 + 0.06 ether);
        assertEq(address(reg).balance, 1 ether);
    }

    // Apart from the registrar and PageNFT, which configure refuses, any payout is the holder's choice. The fee
    // token itself as payout keeps each token fee on the token contract, and a token that burns what reaches its
    // own address turns the same terms into a burn sale. PageCard as payout is credited ETH it can never take:
    // claimProceedsFor reverts ETHTransferFailed and the credit stays. A precompile or DEAD as payout is paid by a
    // claim, and the ETH is gone.
    function test_otherPayoutsAreTheControllersChoice() public {
        uint256 club = _register(alice, "club", alice);
        vm.prank(alice);
        nft.setSubpageMinter(club, address(reg));
        vm.prank(alice);
        vm.expectRevert(SubpageRegistrar.NotAuthorized.selector);
        reg.configure(club, address(reg), address(usd), 10, true, address(0), 0, false);
        vm.prank(alice);
        vm.expectRevert(SubpageRegistrar.NotAuthorized.selector);
        reg.configure(club, address(nft), address(usd), 10, true, address(0), 0, false);

        // the fee token itself as payout
        usd.mint(buyer, 100);
        vm.prank(buyer);
        usd.approve(address(reg), type(uint256).max);
        _terms(alice, club, address(usd), address(usd), 10);
        vm.prank(buyer);
        reg.registerSubpage(club, "t1", 10, address(usd));
        vm.prank(buyer);
        reg.registerSubpage(club, "t2", 10, address(usd));
        assertEq(usd.balanceOf(address(usd)), 20, "the fees rest on the token contract");
        assertEq(usd.balanceOf(buyer), 80);
        assertEq(usd.balanceOf(address(reg)), 0);
        assertEq(reg.proceedsOf(address(usd)), 0);

        // a token that burns what reaches its own address
        SelfBurnToken burn = new SelfBurnToken();
        burn.mint(buyer, 100);
        vm.prank(buyer);
        burn.approve(address(reg), type(uint256).max);
        _terms(alice, club, address(burn), address(burn), 10);
        vm.prank(buyer);
        uint256 burnSale = reg.registerSubpage(club, "b1", 10, address(burn));
        assertEq(nft.ownerOf(burnSale), buyer);
        assertEq(burn.totalSupply(), 90, "the fee is burned");
        assertEq(burn.balanceOf(buyer), 90);
        assertEq(burn.balanceOf(address(burn)), 0);

        // PageCard as payout
        _terms(alice, club, address(card), address(0), 0.01 ether);
        _buy(club, "c1", 0.01 ether);
        assertEq(reg.proceedsOf(address(card)), 0.01 ether);
        vm.prank(stranger);
        vm.expectRevert(ETH_TRANSFER_FAILED);
        reg.claimProceedsFor(address(card));
        assertEq(reg.proceedsOf(address(card)), 0.01 ether, "PageCard's credit is frozen");
        assertEq(address(card).balance, 0);
        assertEq(address(reg).balance, 0.01 ether);

        // a precompile and DEAD as payout
        address[2] memory gone = [address(4), DEAD];
        for (uint256 i; i < 2; ++i) {
            _terms(alice, club, gone[i], address(0), 0.02 ether);
            _buy(club, string.concat("g", vm.toString(i)), 0.02 ether);
            uint256 before = gone[i].balance;
            vm.prank(stranger);
            assertEq(reg.claimProceedsFor(gone[i]), 0.02 ether);
            assertEq(gone[i].balance, before + 0.02 ether, "the claim pays it");
            assertEq(reg.proceedsOf(gone[i]), 0);
        }
        assertEq(address(reg).balance, 0.01 ether, "only PageCard's frozen credit is left");
    }
}

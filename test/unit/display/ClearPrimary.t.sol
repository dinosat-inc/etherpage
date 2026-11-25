// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Vm} from "forge-std/Test.sol";
import {PageNFT} from "../../../src/PageNFT.sol";
import {MinterBase} from "../../utils/MinterBase.sol";
import {NoHook} from "../../utils/MinterMocks.sol";
import {PageNFTMulticall} from "../../differential/harness/PageNFTMulticall.sol";
import {Market, Probe} from "../../utils/ClearPrimaryMocks.sol";

// A transfer between two accounts clears the sender's primary name when it names the moved token.
// World N is PageNFT, world R is PageNFTMulticall, a reference without that clear and without the holder
// check of reverseResolve. Most tests run the same calls in both worlds and require the same outcome, except
// two expected differences: N emits PrimaryPageSet(from, 0) just before MetadataUpdate and stores 0 for the
// sender, and N shows a display name only while the holder it was chosen under still holds the name.
contract ClearPrimaryTest is MinterBase {
    PageNFTMulticall ref;
    address N;
    address R;
    Market market;
    address wallet2 = makeAddr("wallet2");

    bytes32 constant T_PRIMARY = keccak256("PrimaryPageSet(address,uint256)");
    bytes32 constant T_META = keccak256("MetadataUpdate(uint256)");
    bytes32 constant T_ADDRESS = keccak256("AddressChanged(bytes32,uint256,bytes)");
    bytes32 constant T_ADDR = keccak256("AddrChanged(bytes32,address)");
    bytes32 constant T_TEXT = keccak256("TextChanged(bytes32,string,string,string)");
    uint256 constant PRIMARY_SLOT = 3;
    uint256 constant HOLDER_SLOT = 13;

    struct Out {
        bool ok;
        bytes ret;
        Vm.Log[] logs;
    }

    function setUp() public override {
        super.setUp();
        ref = new PageNFTMulticall(card);
        N = address(nft);
        R = address(ref);
        market = new Market();
        vm.deal(wallet2, 10 ether);
    }

    // both worlds

    function _regBoth(address payer, string memory label, address to) internal returns (uint256 id) {
        bytes32 secret = keccak256(abi.encode(payer, label, to, block.timestamp));
        bytes32 c = nft.makeCommitment(label, to, 0, secret);
        vm.prank(payer);
        nft.commit(c);
        vm.prank(payer);
        ref.commit(c);
        vm.warp(vm.getBlockTimestamp() + 61);
        (,,, uint256 total) = nft.quote(label);
        vm.deal(payer, payer.balance + 2 * total);
        vm.prank(payer);
        id = nft.reveal{value: total}(label, to, 0, secret);
        vm.prank(payer);
        assertEq(ref.reveal{value: total}(label, to, 0, secret), id);
    }

    function _subBoth(address caller, string memory label, uint256 parent, address to) internal returns (uint256 id) {
        vm.prank(caller);
        id = nft.registerSubpageFor(label, parent, to);
        vm.prank(caller);
        ref.registerSubpageFor(label, parent, to);
    }

    function _one(address who, address target, bytes memory d) internal returns (Out memory o) {
        vm.recordLogs();
        vm.prank(who);
        (o.ok, o.ret) = target.call(d);
        o.logs = vm.getRecordedLogs();
    }

    // the same call by who, made directly on R and then on N
    function _both(address who, bytes memory d) internal returns (Out memory a, Out memory b) {
        a = _one(who, R, d);
        b = _one(who, N, d);
    }

    function _okBoth(address who, bytes memory d) internal {
        (Out memory a, Out memory b) = _both(who, d);
        assertTrue(a.ok && b.ok, "a setup call failed");
    }

    function _xfer(address from, address to, uint256 id) internal pure returns (bytes memory) {
        return abi.encodeWithSignature("transferFrom(address,address,uint256)", from, to, id);
    }

    function _safe(address from, address to, uint256 id) internal pure returns (bytes memory) {
        return abi.encodeWithSignature("safeTransferFrom(address,address,uint256)", from, to, id);
    }

    function _safeData(address from, address to, uint256 id) internal pure returns (bytes memory) {
        return abi.encodeWithSignature("safeTransferFrom(address,address,uint256,bytes)", from, to, id, hex"0a0b");
    }

    function _setPtr(address a, uint256 v) internal {
        bytes32 slot = keccak256(abi.encode(a, PRIMARY_SLOT));
        vm.store(N, slot, bytes32(v));
        vm.store(R, slot, bytes32(v));
    }

    // expected logs

    function _log(bytes32[] memory t, bytes memory d) internal pure returns (Vm.Log memory l) {
        l.topics = t;
        l.data = d;
    }

    function _lTransfer(address f, address t, uint256 id) internal pure returns (Vm.Log memory) {
        bytes32[] memory x = new bytes32[](4);
        x[0] = T_TRANSFER;
        x[1] = bytes32(uint256(uint160(f)));
        x[2] = bytes32(uint256(uint160(t)));
        x[3] = bytes32(id);
        return _log(x, "");
    }

    function _lAddress(uint256 id, uint256 coin, address a) internal pure returns (Vm.Log memory) {
        bytes32[] memory x = new bytes32[](2);
        x[0] = T_ADDRESS;
        x[1] = bytes32(id);
        return _log(x, abi.encode(coin, a == address(0) ? bytes("") : abi.encodePacked(a)));
    }

    function _lAddr(uint256 id, address a) internal pure returns (Vm.Log memory) {
        bytes32[] memory x = new bytes32[](2);
        x[0] = T_ADDR;
        x[1] = bytes32(id);
        return _log(x, abi.encode(a));
    }

    function _lPrimary(address a, uint256 id) internal pure returns (Vm.Log memory) {
        bytes32[] memory x = new bytes32[](3);
        x[0] = T_PRIMARY;
        x[1] = bytes32(uint256(uint160(a)));
        x[2] = bytes32(id);
        return _log(x, "");
    }

    function _lMeta(uint256 id) internal pure returns (Vm.Log memory) {
        bytes32[] memory x = new bytes32[](1);
        x[0] = T_META;
        return _log(x, abi.encode(id));
    }

    // the events of an ordinary transfer with nothing saved: the main address moves to the recipient, and coin
    // type 60 is announced empty, with AddrChanged, as the recipient saved no entry and no default
    function _plainTransfer(address f, address t, uint256 id, bool cleared) internal pure returns (Vm.Log[] memory e) {
        e = new Vm.Log[](cleared ? 6 : 5);
        e[0] = _lTransfer(f, t, id);
        e[1] = _lAddress(id, COIN_OP, t);
        e[2] = _lAddress(id, 60, address(0));
        e[3] = _lAddr(id, address(0));
        if (cleared) e[4] = _lPrimary(f, 0);
        e[e.length - 1] = _lMeta(id);
    }

    function _eqLogs(Vm.Log[] memory got, Vm.Log[] memory exp, address emitter) internal pure {
        assertEq(got.length, exp.length, "log count");
        for (uint256 i; i < got.length; ++i) {
            assertEq(got[i].emitter, emitter, "log emitter");
            assertEq(got[i].topics.length, exp[i].topics.length, "topic count");
            for (uint256 k; k < got[i].topics.length; ++k) assertEq(got[i].topics[k], exp[i].topics[k], "topic");
            assertEq(got[i].data, exp[i].data, "log data");
        }
    }

    // R's logs must equal N's logs with N's log at index at left out, compared by topics and data. The caller passes
    // the index of N's PrimaryPageSet(from, 0) as at, and this helper does not check that log
    function _refIsSrcWithout(Vm.Log[] memory a, Vm.Log[] memory b, uint256 at) internal pure {
        assertEq(a.length + 1, b.length, "src has exactly one more log");
        for (uint256 i; i < a.length; ++i) {
            Vm.Log memory x = b[i < at ? i : i + 1];
            assertEq(keccak256(abi.encode(a[i].topics, a[i].data)), keccak256(abi.encode(x.topics, x.data)), "log");
        }
    }

    function _sameLogs(Vm.Log[] memory a, Vm.Log[] memory b) internal pure {
        assertEq(a.length, b.length, "log count differs from the reference");
        for (uint256 i; i < a.length; ++i) {
            assertEq(keccak256(abi.encode(a[i].topics, a[i].data)), keccak256(abi.encode(b[i].topics, b[i].data)), "log");
        }
    }

    function _count(Vm.Log[] memory l, bytes32 t0) internal pure returns (uint256 n) {
        for (uint256 i; i < l.length; ++i) if (l[i].topics.length > 0 && l[i].topics[0] == t0) ++n;
    }

    // sales

    function _saleSetup() internal returns (uint256 id) {
        id = _regBoth(alice, "alice", alice);
        _okBoth(alice, abi.encodeCall(PageNFT.setPrimaryPage, (id)));
        assertEq(nft.reverseResolve(alice), "alice");
        assertEq(ref.reverseResolve(alice), "alice");
    }

    function _checkSold(uint256 id, Out memory a, Out memory b, address to) internal view {
        assertTrue(a.ok && b.ok, "sale failed");
        _eqLogs(b.logs, _plainTransfer(alice, to, id, true), N);
        _eqLogs(a.logs, _plainTransfer(alice, to, id, false), R);
        assertEq(nft.primaryPage(alice), 0);
        assertEq(ref.primaryPage(alice), id);
        assertEq(nft.reverseResolve(alice), "");
        assertEq(ref.reverseResolve(alice), "");
        assertEq(nft.ownerOf(id), to);
    }

    // MetaMask Send is a plain transferFrom by the holder
    function test_metamaskSend() public {
        uint256 id = _saleSetup();
        (Out memory a, Out memory b) = _both(alice, _xfer(alice, bob, id));
        _checkSold(id, a, b, bob);
    }

    function test_safeTransferFromByHolder() public {
        uint256 id = _saleSetup();
        uint256 snap = vm.snapshotState();
        (Out memory a, Out memory b) = _both(alice, _safe(alice, bob, id));
        _checkSold(id, a, b, bob);
        vm.revertToState(snap);
        (a, b) = _both(alice, _safeData(alice, bob, id));
        _checkSold(id, a, b, bob);
    }

    // a marketplace like OpenSea, approved by the seller for all its names, settles the sale once with
    // safeTransferFrom and once with transferFrom
    function test_openseaStyleSaleByOperator() public {
        uint256 id = _saleSetup();
        _okBoth(alice, abi.encodeWithSignature("setApprovalForAll(address,bool)", address(market), true));
        uint256 snap = vm.snapshotState();
        Out memory a = _one(address(this), address(market), abi.encodeCall(Market.settle, (R, alice, bob, id, true)));
        Out memory b = _one(address(this), address(market), abi.encodeCall(Market.settle, (N, alice, bob, id, true)));
        _checkSold(id, a, b, bob);
        vm.revertToState(snap);
        a = _one(address(this), address(market), abi.encodeCall(Market.settle, (R, alice, bob, id, false)));
        b = _one(address(this), address(market), abi.encodeCall(Market.settle, (N, alice, bob, id, false)));
        _checkSold(id, a, b, bob);
    }

    function test_saleByApprovedAccount() public {
        uint256 id = _saleSetup();
        _okBoth(alice, abi.encodeWithSignature("approve(address,uint256)", carol, id));
        (Out memory a, Out memory b) = _both(carol, _xfer(alice, bob, id));
        _checkSold(id, a, b, bob);
    }

    function test_saleToAContractBuyer() public {
        uint256 id = _saleSetup();
        Probe p = new Probe();
        p.arm(N, false);
        vm.prank(alice);
        nft.safeTransferFrom(alice, address(p), id);
        assertEq(nft.primaryPage(alice), 0);
        // the pointer is already clear when the buyer's code runs
        assertEq(p.seenPointer(), 0);
        assertEq(p.seenReverse(), "");
        Probe q = new Probe();
        q.arm(R, false);
        vm.prank(alice);
        ref.safeTransferFrom(alice, address(q), id);
        assertEq(q.seenPointer(), id);
    }

    // revival

    // the buyer points the name back at the seller and writes its own profile
    function test_revivalBlocked() public {
        uint256 id = _saleSetup();
        _okBoth(alice, _xfer(alice, bob, id));
        _okBoth(bob, abi.encodeCall(PageNFT.setAddr, (id, alice)));
        _okBoth(bob, abi.encodeCall(PageNFT.setText, (id, "description", "send me your seed phrase")));
        assertEq(nft.resolve(id), alice);
        assertEq(ref.resolve(id), alice);
        // the reference build shows the sold name, with the buyer's profile, on the seller's address
        assertEq(ref.reverseResolve(alice), "alice");
        assertEq(nft.reverseResolve(alice), "");
        assertEq(nft.primaryPage(alice), 0);
        // only the seller can show it again, by choosing it
        vm.prank(alice);
        nft.setPrimaryPage(id);
        assertEq(nft.reverseResolve(alice), "alice");
    }

    function test_revivalFromInsideTheBuyersHookIsBlocked() public {
        uint256 id = _saleSetup();
        Probe p = new Probe();
        p.arm(N, true);
        vm.prank(alice);
        nft.safeTransferFrom(alice, address(p), id);
        assertEq(nft.resolve(id), alice);
        assertEq(nft.reverseResolve(alice), "");
        Probe q = new Probe();
        q.arm(R, true);
        vm.prank(alice);
        ref.safeTransferFrom(alice, address(q), id);
        assertEq(ref.reverseResolve(alice), "alice");
    }

    function test_sellerCannotSetItAgainAlone() public {
        uint256 id = _saleSetup();
        _okBoth(alice, _xfer(alice, bob, id));
        vm.prank(alice);
        vm.expectRevert(PageNFT.Unauthorized.selector);
        nft.setPrimaryPage(id);
    }

    // a bundle cannot move the name and keep the display name either
    function test_bundleCannotKeepIt() public {
        uint256 id = _saleSetup();
        bytes[] memory d = new bytes[](2);
        d[0] = _xfer(alice, bob, id);
        d[1] = abi.encodeCall(PageNFT.setPrimaryPage, (id));
        vm.prank(alice);
        vm.expectRevert(PageNFT.Unauthorized.selector);
        nft.multicall(d);
        assertEq(nft.primaryPage(alice), id);
        assertEq(nft.ownerOf(id), alice);
    }

    // what stays

    function test_pointerToAnotherNameUntouched() public {
        uint256 id = _regBoth(alice, "alice", alice);
        uint256 other = _regBoth(alice, "alicetwo", alice);
        _okBoth(alice, abi.encodeCall(PageNFT.setPrimaryPage, (other)));
        (Out memory a, Out memory b) = _both(alice, _xfer(alice, bob, id));
        _eqLogs(b.logs, _plainTransfer(alice, bob, id, false), N);
        _sameLogs(a.logs, b.logs);
        assertEq(nft.primaryPage(alice), other);
        assertEq(nft.reverseResolve(alice), "alicetwo");
    }

    function test_receiversPointerUntouched() public {
        uint256 id = _saleSetup();
        // carol chose the name while it pointed at her
        _okBoth(alice, abi.encodeCall(PageNFT.setAddr, (id, carol)));
        _okBoth(carol, abi.encodeCall(PageNFT.setPrimaryPage, (id)));
        _okBoth(alice, abi.encodeCall(PageNFT.setAddr, (id, address(0))));
        (Out memory a, Out memory b) = _both(alice, _xfer(alice, carol, id));
        assertTrue(a.ok && b.ok);
        _refIsSrcWithout(a.logs, b.logs, b.logs.length - 2);
        assertEq(nft.primaryPage(carol), id);
        // carol chose the name while alice held it, so it shows again only once carol chooses it herself
        assertEq(nft.reverseResolve(carol), "");
        assertEq(ref.reverseResolve(carol), "alice");
        assertEq(nft.primaryPage(alice), 0);
        vm.prank(carol);
        nft.setPrimaryPage(id);
        assertEq(nft.reverseResolve(carol), "alice");
    }

    // an account the seller's name pointed at keeps its pointer, but the buyer cannot revive that
    // account's display name by pointing the name back at it: the seller no longer holds the name
    function test_limit_pointeeOfTheSellerKeepsItsPointerHidden() public {
        uint256 id = _saleSetup();
        _okBoth(alice, abi.encodeCall(PageNFT.setAddr, (id, hot)));
        _okBoth(hot, abi.encodeCall(PageNFT.setPrimaryPage, (id)));
        assertEq(nft.reverseResolve(hot), "alice");
        _okBoth(alice, _xfer(alice, bob, id));
        assertEq(nft.primaryPage(hot), id);
        assertEq(nft.reverseResolve(hot), "");
        _okBoth(bob, abi.encodeCall(PageNFT.setAddr, (id, hot)));
        assertEq(nft.reverseResolve(hot), "");
        assertEq(ref.reverseResolve(hot), "alice");
    }

    function test_selfTransferKeepsIt() public {
        uint256 id = _saleSetup();
        (Out memory a, Out memory b) = _both(alice, _xfer(alice, alice, id));
        assertTrue(a.ok && b.ok);
        Vm.Log[] memory e = new Vm.Log[](1);
        e[0] = _lTransfer(alice, alice, id);
        _eqLogs(b.logs, e, N);
        _sameLogs(a.logs, b.logs);
        assertEq(nft.primaryPage(alice), id);
        assertEq(nft.reverseResolve(alice), "alice");
    }

    // the known cost: moving a name to one's own other wallet and back drops the display name
    function test_ownWalletRoundTrip() public {
        uint256 id = _saleSetup();
        _okBoth(alice, _xfer(alice, wallet2, id));
        (Out memory a, Out memory b) = _both(wallet2, _xfer(wallet2, alice, id));
        _sameLogs(a.logs, b.logs);
        assertEq(_count(b.logs, T_PRIMARY), 0);
        assertEq(ref.reverseResolve(alice), "alice");
        assertEq(nft.reverseResolve(alice), "");
        vm.prank(alice);
        nft.setPrimaryPage(id);
        assertEq(nft.reverseResolve(alice), "alice");
    }

    function test_failedTransferKeepsIt() public {
        uint256 id = _saleSetup();
        NoHook nh = new NoHook();
        vm.prank(alice);
        vm.expectRevert(NON_RECEIVER);
        nft.safeTransferFrom(alice, address(nh), id);
        assertEq(nft.primaryPage(alice), id);
        // an expired name cannot move, so the pointer stays too
        vm.warp(nft.expiresAt(id) + 1);
        vm.prank(alice);
        vm.expectRevert(PageNFT.Expired.selector);
        nft.transferFrom(alice, bob, id);
        assertEq(nft.primaryPage(alice), id);
    }

    // DEAD and the recycle bin

    function test_subpageToDeadClears() public {
        uint256 P = _regBoth(alice, "alice", alice);
        uint256 s = _subBoth(alice, "b", P, bob);
        _okBoth(bob, abi.encodeCall(PageNFT.setPrimaryPage, (s)));
        (Out memory a, Out memory b) = _both(bob, _xfer(bob, DEAD, s));
        Vm.Log[] memory e = new Vm.Log[](6);
        e[0] = _lTransfer(bob, DEAD, s);
        e[1] = _lAddress(s, COIN_OP, address(0));
        e[2] = _lAddress(s, 60, address(0));
        e[3] = _lAddr(s, address(0));
        e[4] = _lPrimary(bob, 0);
        e[5] = _lMeta(s);
        _eqLogs(b.logs, e, N);
        _refIsSrcWithout(a.logs, b.logs, 4);
        assertEq(nft.primaryPage(bob), 0);
        assertEq(ref.primaryPage(bob), s);

        // whoever takes the freed label cannot revive bob's display name
        _subBoth(alice, "b", P, carol);
        _okBoth(carol, abi.encodeCall(PageNFT.setAddr, (s, bob)));
        assertEq(ref.reverseResolve(bob), "b.alice");
        assertEq(nft.reverseResolve(bob), "");
    }

    function test_subpageToDeadByMinterRecreation() public {
        uint256 P = _regBoth(alice, "alice", alice);
        uint256 s = _subBoth(alice, "b", P, bob);
        _okBoth(alice, abi.encodeCall(PageNFT.setSubpageMinter, (P, hot)));
        _okBoth(bob, abi.encodeCall(PageNFT.setPrimaryPage, (s)));
        _okBoth(bob, _safe(bob, DEAD, s));
        _subBoth(hot, "b", P, carol);
        _okBoth(carol, abi.encodeCall(PageNFT.setAddr, (s, bob)));
        assertEq(ref.reverseResolve(bob), "b.alice");
        assertEq(nft.reverseResolve(bob), "");
    }

    // minting the label again to the former holder does not bring its old display name back
    function test_remintToFormerHolderShowsNothing() public {
        uint256 P = _regBoth(alice, "alice", alice);
        uint256 s = _subBoth(alice, "b", P, bob);
        _okBoth(bob, abi.encodeCall(PageNFT.setPrimaryPage, (s)));
        _okBoth(bob, _xfer(bob, DEAD, s));
        _subBoth(alice, "b", P, bob);
        assertEq(ref.reverseResolve(bob), "b.alice");
        assertEq(nft.reverseResolve(bob), "");
        assertEq(nft.primaryPage(bob), 0);
    }

    // a top level page held by the dead address is deleted too, so the transfer announces empty addresses
    function test_topLevelToDeadClears() public {
        uint256 id = _saleSetup();
        (Out memory a, Out memory b) = _both(alice, _xfer(alice, DEAD, id));
        assertTrue(a.ok && b.ok);
        Vm.Log[] memory e = new Vm.Log[](6);
        e[0] = _lTransfer(alice, DEAD, id);
        e[1] = _lAddress(id, COIN_OP, address(0));
        e[2] = _lAddress(id, 60, address(0));
        e[3] = _lAddr(id, address(0));
        e[4] = _lPrimary(alice, 0);
        e[5] = _lMeta(id);
        _eqLogs(b.logs, e, N);
        _refIsSrcWithout(a.logs, b.logs, b.logs.length - 2);
        assertEq(nft.primaryPage(alice), 0);
        assertEq(nft.ownerOf(id), DEAD);
    }

    // mints and burns

    function test_mintLeavesPointersAlone() public {
        uint256 P = _regBoth(alice, "alice", alice);
        uint256 s = _subId("b", P);
        // a stale pointer at the id to be minted, on the minter, the recipient and a stranger
        _setPtr(alice, s);
        _setPtr(bob, s);
        _setPtr(carol, s);
        (Out memory a, Out memory b) = _both(alice, abi.encodeCall(PageNFT.registerSubpageFor, ("b", P, bob)));
        assertTrue(a.ok && b.ok);
        _sameLogs(a.logs, b.logs);
        assertEq(_count(b.logs, T_PRIMARY), 0);
        assertEq(nft.primaryPage(alice), s);
        assertEq(nft.primaryPage(bob), s);
        assertEq(nft.primaryPage(carol), s);
    }

    // taking a subpage back burns the old token; the mint's own clear runs once, the hook adds nothing
    function test_takeBackClearsOnceLikeTheReference() public {
        uint256 P = _regBoth(alice, "alice", alice);
        uint256 s = _subBoth(alice, "b", P, bob);
        _okBoth(bob, abi.encodeCall(PageNFT.setPrimaryPage, (s)));
        (Out memory a, Out memory b) = _both(alice, abi.encodeCall(PageNFT.registerSubpageFor, ("b", P, carol)));
        assertTrue(a.ok && b.ok);
        _sameLogs(a.logs, b.logs);
        assertEq(_count(b.logs, T_PRIMARY), 1);
        assertEq(b.logs[0].topics[0], T_PRIMARY);
        assertEq(nft.primaryPage(bob), 0);
    }

    function test_reRegistrationClearsOnceLikeTheReference() public {
        uint256 id = _saleSetup();
        vm.warp(nft.expiresAt(id) + 90 days + 21 days + 1);
        bytes32 secret = keccak256("re");
        bytes32 c = nft.makeCommitment("alice", bob, 0, secret);
        _okBoth(bob, abi.encodeCall(PageNFT.commit, (c)));
        vm.warp(vm.getBlockTimestamp() + 61);
        (,,, uint256 total) = nft.quote("alice");
        vm.deal(bob, 10 ether);
        vm.recordLogs();
        vm.prank(bob);
        ref.reveal{value: total}("alice", bob, 0, secret);
        Vm.Log[] memory la = vm.getRecordedLogs();
        vm.prank(bob);
        nft.reveal{value: total}("alice", bob, 0, secret);
        Vm.Log[] memory lb = vm.getRecordedLogs();
        _sameLogs(la, lb);
        assertEq(_count(lb, T_PRIMARY), 1);
        assertEq(nft.primaryPage(alice), 0);
    }

    // after a round trip the returning holder's pointer is already clear in PageNFT, so taking the
    // name back, which clears it in the reference build, clears nothing here and emits no PrimaryPageSet
    function test_takeBackAfterRoundTripClearsNothingMore() public {
        uint256 P = _regBoth(alice, "alice", alice);
        uint256 s = _subBoth(alice, "b", P, bob);
        _okBoth(bob, abi.encodeCall(PageNFT.setPrimaryPage, (s)));
        _okBoth(bob, _xfer(bob, wallet2, s));
        _okBoth(wallet2, _xfer(wallet2, bob, s));
        (Out memory a, Out memory b) = _both(alice, abi.encodeCall(PageNFT.registerSubpageFor, ("b", P, carol)));
        assertTrue(a.ok && b.ok);
        assertEq(_count(a.logs, T_PRIMARY), 1);
        assertEq(_count(b.logs, T_PRIMARY), 0);
        assertEq(b.logs.length + 1, a.logs.length);
        for (uint256 i; i < b.logs.length; ++i) {
            assertEq(keccak256(abi.encode(b.logs[i].topics, b.logs[i].data)), keccak256(abi.encode(a.logs[i + 1].topics, a.logs[i + 1].data)));
        }
        assertEq(nft.primaryPage(bob), 0);
        assertEq(ref.primaryPage(bob), 0);
    }

    // bundles

    // a delete bundle with or without a first step that clears the pointer: the event goes out once
    function test_deleteBundles() public {
        uint256 P = _regBoth(alice, "alice", alice);
        uint256 s = _subBoth(alice, "b", P, bob);
        _okBoth(bob, abi.encodeCall(PageNFT.setPrimaryPage, (s)));
        uint256 snap = vm.snapshotState();
        bytes[] memory two = new bytes[](2);
        two[0] = abi.encodeCall(PageNFT.clearRecords, (s));
        two[1] = _xfer(bob, DEAD, s);
        vm.recordLogs();
        vm.prank(bob);
        nft.multicall(two);
        Vm.Log[] memory l2 = vm.getRecordedLogs();
        assertEq(nft.primaryPage(bob), 0);
        assertEq(_count(l2, T_PRIMARY), 1);
        vm.revertToState(snap);
        bytes[] memory three = new bytes[](3);
        three[0] = abi.encodeCall(PageNFT.setPrimaryPage, (0));
        three[1] = two[0];
        three[2] = two[1];
        vm.recordLogs();
        vm.prank(bob);
        nft.multicall(three);
        Vm.Log[] memory l3 = vm.getRecordedLogs();
        assertEq(nft.primaryPage(bob), 0);
        assertEq(_count(l3, T_PRIMARY), 1);
    }

    // a bundle that moves two names clears the pointer exactly as the two calls would
    function test_bundleOfTransfersEqualsSingles() public {
        uint256 id = _regBoth(alice, "alice", alice);
        uint256 other = _regBoth(alice, "alicetwo", alice);
        vm.prank(alice);
        nft.setPrimaryPage(other);
        bytes[] memory d = new bytes[](2);
        d[0] = _xfer(alice, bob, id);
        d[1] = _safe(alice, carol, other);
        uint256 snap = vm.snapshotState();
        vm.recordLogs();
        for (uint256 i; i < 2; ++i) {
            vm.prank(alice);
            (bool ok,) = N.call(d[i]);
            assertTrue(ok);
        }
        Vm.Log[] memory singles = vm.getRecordedLogs();
        vm.revertToState(snap);
        vm.recordLogs();
        vm.prank(alice);
        nft.multicall(d);
        Vm.Log[] memory bundle = vm.getRecordedLogs();
        _sameLogs(singles, bundle);
        assertEq(nft.primaryPage(alice), 0);
        assertEq(_count(bundle, T_PRIMARY), 1);
    }

    // differential fuzz

    // any transfer route, any pointer state: the worlds agree on success, return data, the logs of a success, every
    // listed account's pointer and display name, and the name's holder, address and payee, except the one predicted
    // pointer and event, and the display names PageNFT hides because their name is no longer held by the holder they
    // were chosen under
    function testFuzz_transferDifferential(
        uint256 ptrSeed, uint8 idK, uint8 fromK, uint8 toK, uint8 callerK, uint8 how, uint32 dt
    ) public {
        _diff(ptrSeed, idK, fromK, toK, callerK, how, dt);
    }

    uint256 sweepOk;
    uint256 sweepFail;
    uint256 sweepCleared;
    uint256 sweepToDead;
    uint256 holderHidden;

    // the same body over fixed seeds. It logs how often each case occurs and requires failures, cleared pointers,
    // other successes and hidden display names to occur
    function test_sweepDifferential() public {
        for (uint256 i; i < 400; ++i) {
            uint256 r = uint256(keccak256(abi.encode("sweep", i)));
            uint256 snap = vm.snapshotState();
            (bool ok, bool cleared, bool dead) =
                _diff(r, uint8(r >> 8), uint8(r >> 16), uint8(r >> 24), uint8(r >> 32), uint8(r >> 40), uint32(r >> 48) % 400 days);
            // the snapshot also rolls back this contract, so the count is carried over by hand
            uint256 hidden = holderHidden;
            vm.revertToStateAndDelete(snap);
            holderHidden = hidden;
            if (ok) ++sweepOk;
            else ++sweepFail;
            if (cleared) ++sweepCleared;
            if (cleared && dead) ++sweepToDead;
        }
        emit log_named_uint("transfers that succeeded", sweepOk);
        emit log_named_uint("transfers that failed", sweepFail);
        emit log_named_uint("of the successes, sender pointer cleared", sweepCleared);
        emit log_named_uint("of those, sent to DEAD", sweepToDead);
        emit log_named_uint("display names hidden because the holder changed", holderHidden);
        assertGt(holderHidden, 0);
        assertGt(sweepCleared, 20);
        assertGt(sweepOk - sweepCleared, 20);
        assertGt(sweepFail, 20);
    }

    function _diff(uint256 ptrSeed, uint8 idK, uint8 fromK, uint8 toK, uint8 callerK, uint8 how, uint32 dt)
        internal
        returns (bool, bool, bool)
    {
        uint256 A = _regBoth(alice, "alice", alice);
        uint256 A2 = _regBoth(alice, "alicetwo", alice);
        uint256 S = _subBoth(alice, "s", A, bob);
        _okBoth(alice, abi.encodeWithSignature("approve(address,uint256)", carol, A));
        _okBoth(alice, abi.encodeWithSignature("setApprovalForAll(address,bool)", address(market), true));
        _okBoth(bob, abi.encodeWithSignature("setApprovalForAll(address,bool)", address(market), true));
        if (ptrSeed % 3 == 0) _okBoth(alice, abi.encodeCall(PageNFT.setAddr, (A, hot)));

        address[7] memory acc = [alice, bob, carol, hot, DEAD, address(market), stranger];
        uint256[5] memory vals = [uint256(0), A, A2, S, uint256(keccak256(abi.encode(ptrSeed)))];
        // each pointer is stored with the holder of its name at that moment, as setPrimaryPage stores it
        address[] memory chosenUnder = new address[](acc.length);
        for (uint256 i; i < acc.length; ++i) {
            uint256 v = vals[(ptrSeed >> (8 * i + 8)) % 5];
            _setPtr(acc[i], v);
            chosenUnder[i] = _ownerOrZero(v);
            vm.store(N, keccak256(abi.encode(acc[i], HOLDER_SLOT)), bytes32(uint256(uint160(chosenUnder[i]))));
        }
        vm.warp(vm.getBlockTimestamp() + uint256(dt) % 500 days);

        uint256 id = [A, A2, S][idK % 3];
        address owner = nft.ownerOf(id);
        address from = fromK % 7 == 0 ? acc[fromK % 7 + 1] : owner;
        address to = acc[toK % 7];
        uint256[] memory pre = new uint256[](acc.length);
        string[] memory rrA = new string[](acc.length);
        for (uint256 i; i < acc.length; ++i) pre[i] = nft.primaryPage(acc[i]);

        Out memory a;
        Out memory b;
        uint256 k = how % 4;
        if (k == 3) {
            a = _one(stranger, address(market), abi.encodeCall(Market.settle, (R, from, to, id, callerK % 2 == 0)));
            b = _one(stranger, address(market), abi.encodeCall(Market.settle, (N, from, to, id, callerK % 2 == 0)));
        } else {
            address[4] memory callers = [owner, carol, stranger, from];
            address caller = callers[callerK % 4];
            bytes memory d = k == 0 ? _xfer(from, to, id) : k == 1 ? _safe(from, to, id) : _safeData(from, to, id);
            (a, b) = _both(caller, d);
        }
        assertEq(a.ok, b.ok, "success differs");
        assertEq(a.ret, b.ret, "return data differs");
        bool cleared = b.ok && from != to && pre[_ix(acc, from)] == id;
        // the recorder keeps the logs of a reverted call, which no indexer sees, so only successes compare logs
        if (!b.ok) {
            assertEq(nft.ownerOf(id), owner);
        } else if (cleared) {
            _refIsSrcWithout(a.logs, b.logs, b.logs.length - 2);
            Vm.Log memory c = b.logs[b.logs.length - 2];
            assertEq(c.topics[0], T_PRIMARY);
            assertEq(c.topics[1], bytes32(uint256(uint160(from))));
            assertEq(c.topics[2], bytes32(0));
        } else {
            _sameLogs(a.logs, b.logs);
        }
        for (uint256 i; i < acc.length; ++i) {
            rrA[i] = ref.reverseResolve(acc[i]);
            assertEq(ref.primaryPage(acc[i]), pre[i], "the reference moved a pointer");
            bool mine = cleared && acc[i] == from;
            // PageNFT shows a display name only while the holder it was chosen under still holds the name
            bool moved = _ownerOrZero(pre[i]) != chosenUnder[i];
            if (moved && !mine && bytes(rrA[i]).length != 0) ++holderHidden;
            assertEq(nft.primaryPage(acc[i]), mine ? 0 : pre[i], "src pointer");
            assertEq(nft.reverseResolve(acc[i]), mine || moved ? "" : rrA[i], "src reverseResolve");
        }
        assertEq(nft.ownerOf(id), ref.ownerOf(id));
        assertEq(nft.resolve(id), ref.resolve(id));
        assertEq(nft.payee(id), ref.payee(id));
        return (b.ok, cleared, to == DEAD);
    }

    function _ownerOrZero(uint256 id) internal view returns (address o) {
        try nft.ownerOf(id) returns (address x) {
            o = x;
        } catch {}
    }

    function _ix(address[7] memory acc, address x) internal pure returns (uint256) {
        for (uint256 i; i < 7; ++i) if (acc[i] == x) return i;
        revert("not in the account list");
    }

    // gas

    function test_gas_transfers() public {
        uint256 id = _regBoth(alice, "alice", alice);
        uint256 other = _regBoth(alice, "alicetwo", alice);
        uint256 s = _subBoth(alice, "b", id, bob);

        _gasBoth("transferFrom, sender has no display name", alice, _xfer(alice, bob, id), address(0), 0);
        _gasBoth("transferFrom, display name is another name", alice, _xfer(alice, bob, id), alice, other);
        _gasBoth("transferFrom, display name is this name", alice, _xfer(alice, bob, id), alice, id);
        _gasBoth("safeTransferFrom, display name is this name", alice, _safe(alice, bob, id), alice, id);
        _gasBoth("subpage to DEAD, no display name", bob, _xfer(bob, DEAD, s), address(0), 0);
        _gasBoth("subpage to DEAD, display name is this name", bob, _xfer(bob, DEAD, s), bob, s);
    }

    // execution gas of the same transfer in both worlds, storage cooled as in its own transaction;
    // the refund for the cleared slot is paid at the end of a transaction and is not counted here
    function _gasBoth(string memory what, address who, bytes memory d, address ptrOf, uint256 ptr) internal {
        uint256 snap = vm.snapshotState();
        if (ptrOf != address(0)) _setPtr(ptrOf, ptr);
        vm.cool(R);
        vm.prank(who);
        uint256 g0 = gasleft();
        (bool okA,) = R.call(d);
        uint256 gA = g0 - gasleft();
        vm.cool(N);
        vm.prank(who);
        uint256 g1 = gasleft();
        (bool okB,) = N.call(d);
        uint256 gB = g1 - gasleft();
        assertTrue(okA && okB);
        vm.revertToStateAndDelete(snap);
        emit log_named_string("transfer", what);
        emit log_named_uint("  reference, execution gas", gA);
        emit log_named_uint("  src, execution gas", gB);
        emit log_named_int("  difference", int256(gB) - int256(gA));
    }
}

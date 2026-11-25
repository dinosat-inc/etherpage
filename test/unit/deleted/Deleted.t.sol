// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Vm} from "forge-std/Test.sol";
import {Base64} from "solady/utils/Base64.sol";
import {LibString} from "solady/utils/LibString.sol";
import {PageCard} from "../../../src/PageCard.sol";
import {PageNFT} from "../../../src/PageNFT.sol";
import {MinterBase} from "../../utils/MinterBase.sol";
import {Holder721} from "../../utils/MinterMocks.sol";
import {PageNFTRecycle} from "../../differential/harness/PageNFTRecycle.sol";
import {NameWallet, INameLookup} from "../../utils/DeletedMocks.sol";
import {CardReader} from "../../utils/CardReader.sol";

// A page held by DEAD is deleted: it answers nothing and it cannot be written or moved. A subpage
// stays free until the parent's holder, its counted minter or the shop creates it again, a top level
// page until it is registered again after its grace period.
// World a is PageNFTRecycle, a reference without this rule, used where a test shows the difference.
contract DeletedTest is MinterBase {
    bytes32 constant T_VERSION = keccak256("VersionChanged(bytes32,uint64)");
    bytes32 constant T_PRIMARY = keccak256("PrimaryPageSet(address,uint256)");
    bytes32 constant T_SUBREG = keccak256("SubpageRegistered(uint256,uint256,string)");
    bytes32 constant T_ADDRESS = keccak256("AddressChanged(bytes32,uint256,bytes)");
    bytes32 constant T_ADDR = keccak256("AddrChanged(bytes32,address)");
    bytes32 constant T_META = keccak256("MetadataUpdate(uint256)");
    bytes32 constant T_TEXT = keccak256("TextChanged(bytes32,string,string,string)");

    uint256 constant COIN_BASE = 0x80002105; // chain 8453
    uint256 constant COIN_BTC = 0;
    uint256 constant DEFAULT_EVM = 0x80000000;

    PageNFTRecycle a;
    NameWallet wallet;
    CardReader reader;
    uint256 club;

    function setUp() public override {
        super.setUp();
        a = new PageNFTRecycle(card);
        wallet = new NameWallet();
        club = _regBoth(alice, "club", alice);
        reader = new CardReader();
    }

    // helpers

    // the same registration in both worlds at the same second
    function _regBoth(address payer, string memory label, address to) internal returns (uint256 id) {
        bytes32 secret = keccak256(abi.encode(payer, label, to, block.timestamp));
        bytes32 commitment = nft.makeCommitment(label, to, 0, secret);
        vm.prank(payer);
        nft.commit(commitment);
        bytes32 aCommitment = a.makeCommitment(label, to, 0, secret);
        vm.prank(payer);
        a.commit(aCommitment);
        vm.warp(vm.getBlockTimestamp() + 61);
        (,,, uint256 total) = nft.quote(label);
        vm.deal(payer, payer.balance + 2 * total);
        vm.prank(payer);
        id = nft.reveal{value: total}(label, to, 0, secret);
        vm.prank(payer);
        assertEq(a.reveal{value: total}(label, to, 0, secret), id);
    }

    function _sub(string memory label, address to) internal returns (uint256 id) {
        vm.prank(nft.ownerOf(club));
        id = nft.registerSubpageFor(label, club, to);
    }

    function _subA(string memory label, address to) internal returns (uint256 id) {
        vm.prank(a.ownerOf(club));
        id = a.registerSubpageFor(label, club, to);
    }

    // bob.club with a full profile in both worlds
    function _bobWithProfile() internal returns (uint256 id) {
        id = _sub("bob", bob);
        assertEq(_subA("bob", bob), id);
        address[2] memory w = [address(nft), address(a)];
        for (uint256 i; i < 2; ++i) {
            PageNFT n = PageNFT(w[i]);
            vm.startPrank(bob);
            n.setText(id, "avatar", "ipfs://bob");
            n.setContenthash(id, hex"e3010170");
            n.setAddr(id, carol);
            n.setAddrForCoin(id, 60, abi.encodePacked(carol));
            n.setAddrForCoin(id, COIN_BASE, abi.encodePacked(dave));
            n.setAddrForCoin(id, COIN_BTC, hex"0014deadbeef");
            n.setPrimaryPage(id);
            vm.stopPrank();
        }
    }

    function _toDead(address n, uint256 id) internal {
        address o = PageNFT(n).ownerOf(id);
        vm.prank(o);
        PageNFT(n).transferFrom(o, DEAD, id);
    }

    function _json(address n, uint256 id) internal view returns (string memory) {
        bytes memory uri = bytes(PageNFT(n).tokenURI(id));
        bytes memory b64 = new bytes(uri.length - 29);
        for (uint256 i; i < b64.length; ++i) b64[i] = uri[29 + i];
        return string(Base64.decode(string(b64)));
    }

    function _contains(string memory hay, string memory needle) internal pure returns (bool) {
        return vm.indexOf(hay, needle) != type(uint256).max;
    }

    function _image(uint256 id, string memory label, string memory parentLabel, PageCard.Status s, uint256 e)
        internal
        view
        returns (string memory)
    {
        return Base64.encode(bytes(card.render(label, parentLabel, bytes32(id), s, e)));
    }

    // the code of a page as its card shows it: the first 14 and the last 6 of the 64 hex digits of its id
    function _code(uint256 id) internal pure returns (string memory) {
        string memory h = vm.toString(bytes32(id));
        return string.concat(LibString.slice(h, 2, 16), unicode"…", LibString.slice(h, 60, 66));
    }

    function _epoch(uint256 id) internal view returns (uint64 e) {
        (,,, e,) = nft.records(id);
    }

    // exact log matching
    function _h(Vm.Log memory l) internal view returns (bytes32) {
        assertEq(l.emitter, address(nft), "emitter");
        return keccak256(abi.encode(l.topics, l.data));
    }

    function _t1(bytes32 t0) internal pure returns (bytes32[] memory t) {
        t = new bytes32[](1);
        t[0] = t0;
    }

    function _t2(bytes32 t0, bytes32 t1) internal pure returns (bytes32[] memory t) {
        t = new bytes32[](2);
        t[0] = t0;
        t[1] = t1;
    }

    function _lTransfer(address f, address to, uint256 id) internal pure returns (bytes32) {
        bytes32[] memory t = new bytes32[](4);
        t[0] = T_TRANSFER;
        t[1] = bytes32(uint256(uint160(f)));
        t[2] = bytes32(uint256(uint160(to)));
        t[3] = bytes32(id);
        return keccak256(abi.encode(t, bytes("")));
    }

    function _lCoin(uint256 id, uint256 coin, bytes memory v) internal pure returns (bytes32) {
        return keccak256(abi.encode(_t2(T_ADDRESS, bytes32(id)), abi.encode(coin, v)));
    }

    function _lAddr(uint256 id, address v) internal pure returns (bytes32) {
        return keccak256(abi.encode(_t2(T_ADDR, bytes32(id)), abi.encode(v)));
    }

    function _lMeta(uint256 id) internal pure returns (bytes32) {
        return keccak256(abi.encode(_t1(T_META), abi.encode(id)));
    }

    function _lVersion(uint256 id, uint256 v) internal pure returns (bytes32) {
        return keccak256(abi.encode(_t2(T_VERSION, bytes32(id)), abi.encode(uint64(v))));
    }

    function _lSubReg(uint256 id, uint256 parent, string memory label) internal pure returns (bytes32) {
        bytes32[] memory t = new bytes32[](3);
        t[0] = T_SUBREG;
        t[1] = bytes32(id);
        t[2] = bytes32(parent);
        return keccak256(abi.encode(t, abi.encode(label)));
    }

    function _enc(address x) internal pure returns (bytes memory) {
        return x == address(0) ? bytes("") : abi.encodePacked(x);
    }

    // the three address events for one main address and one coin type 60 answer, which AddrChanged carries
    function _trio(uint256 id, address main, address eth, bytes32[] memory out, uint256 at) internal pure {
        out[at] = _lCoin(id, COIN_OP, _enc(main));
        out[at + 1] = _lCoin(id, 60, _enc(eth));
        out[at + 2] = _lAddr(id, eth);
    }

    function _assertLogs(Vm.Log[] memory got, bytes32[] memory want) internal view {
        assertEq(got.length, want.length, "log count");
        for (uint256 i; i < got.length; ++i) assertEq(_h(got[i]), want[i], string.concat("log ", vm.toString(i)));
    }

    function _assertAnswersNothing(uint256 id) internal view {
        bytes32 node = bytes32(id);
        assertEq(nft.resolve(id), address(0), "resolve");
        assertEq(nft.addr(node), address(0), "addr(node)");
        assertEq(nft.addr(id, COIN_OP), "", "addr OP");
        assertEq(nft.addr(node, COIN_OP), "", "addr(node, OP)");
        assertEq(nft.addr(id, 60), "", "addr 60");
        assertEq(nft.addr(id, COIN_BASE), "", "addr other EVM chain");
        assertEq(nft.addr(id, DEFAULT_EVM), "", "addr default EVM");
        assertEq(nft.addr(id, COIN_BTC), "", "addr non-EVM");
        assertEq(nft.text(id, "avatar"), "", "text");
        assertEq(nft.text(node, "avatar"), "", "text(node)");
        assertEq(nft.contenthash(id), "", "contenthash");
        assertEq(nft.contenthash(node), "", "contenthash(node)");
        assertEq(nft.resolveAs(id, bob), address(0), "resolveAs former holder");
        assertEq(nft.resolveAs(id, DEAD), address(0), "resolveAs DEAD");
        assertEq(nft.resolveAs(id, carol), address(0), "resolveAs anyone");
    }

    // 1. what a deleted subpage answers

    function test_deletedSubpageAnswersNothing() public {
        uint256 id = _bobWithProfile();
        // before: a live name with a full profile
        assertEq(nft.resolve(id), carol);
        assertEq(nft.addr(id, 60), abi.encodePacked(carol));
        assertEq(nft.addr(id, COIN_BASE), abi.encodePacked(dave));
        assertEq(nft.addr(id, COIN_BTC), hex"0014deadbeef");
        assertEq(nft.text(id, "avatar"), "ipfs://bob");
        assertEq(nft.contenthash(id), hex"e3010170");
        uint256 v = nft.recordVersion(id);
        (string memory l0, uint256 p0, uint64 e0, uint64 ep0, uint64 pe0) = nft.records(id);

        _toDead(address(nft), id);
        _toDead(address(a), id);

        _assertAnswersNothing(id);
        assertEq(nft.reverseResolve(bob), "", "reverseResolve former holder");
        assertEq(nft.reverseResolve(carol), "", "reverseResolve saved address");
        assertEq(nft.reverseResolve(DEAD), "", "reverseResolve DEAD");
        // the views that do not follow activity still answer: DEAD holds it and is its payee, bob's display
        // name is cleared, the label is free again, and the full name, record, version and expiry views stay
        assertEq(nft.ownerOf(id), DEAD);
        assertEq(nft.getPageName(id), "bob.club", "getPageName keeps the name, like an expired one");
        assertEq(nft.payee(id), DEAD, "payee");
        assertEq(nft.primaryPage(bob), 0, "the move to DEAD cleared bob's pointer");
        assertTrue(nft.isAvailable("bob", club), "free for the recycle bin");
        assertEq(nft.recordVersion(id), v, "no version bump");
        (string memory l1, uint256 p1, uint64 e1, uint64 ep1, uint64 pe1) = nft.records(id);
        assertEq(keccak256(abi.encode(l0, p0, e0, ep0, pe0)), keccak256(abi.encode(l1, p1, e1, ep1, pe1)), "record");
        assertFalse(nft.isExpired(id));
        assertFalse(nft.inGracePeriod(id));
        assertEq(nft.expiresAt(id), 0);

        // the reference without the rule answers DEAD as the main address and the profile it had. Bob's entries
        // for other chains stopped counting when he gave the name away and DEAD saved none, so those answer empty
        assertEq(a.resolve(id), DEAD);
        assertEq(a.addr(id, COIN_OP), abi.encodePacked(DEAD));
        assertEq(a.addr(id, 60), "");
        assertEq(a.addr(id, COIN_BASE), "");
        assertEq(a.text(id, "avatar"), "ipfs://bob");
        assertEq(a.contenthash(id), hex"e3010170");
        // everything else agrees
        assertEq(a.getPageName(id), nft.getPageName(id));
        assertEq(a.payee(id), nft.payee(id));
        assertEq(a.isAvailable("bob", club), nft.isAvailable("bob", club));
        assertEq(a.addr(id, COIN_BTC), nft.addr(id, COIN_BTC));
        assertEq(a.reverseResolve(bob), nft.reverseResolve(bob));
    }

    // a wallet that pays a name finds no address instead of burning the payment
    function test_walletLookupFindsNoAddress() public {
        uint256 id = _bobWithProfile();
        vm.deal(dave, 10 ether);
        vm.prank(dave);
        assertEq(wallet.payOP{value: 1 ether}(INameLookup(address(nft)), "bob.club"), carol);
        _toDead(address(nft), id);
        _toDead(address(a), id);

        uint256 deadBefore = DEAD.balance;
        vm.prank(dave);
        vm.expectRevert(bytes("no address for this name"));
        wallet.payOP{value: 1 ether}(INameLookup(address(nft)), "bob.club");
        vm.prank(dave);
        vm.expectRevert(bytes("no address for this name"));
        wallet.payEth{value: 1 ether}(INameLookup(address(nft)), "BOB.club");
        assertEq(DEAD.balance, deadBefore);

        assertEq(nft.addr(bytes32(id), COIN_OP), "", "no main address either");

        // without the rule the main address is DEAD, so a wallet that pays the main address burns the money.
        // addr(node) and coin type 60 find nothing there, as they answer the same, DEAD saved no entry and bob's
        // entries stopped counting when he gave the name away
        bytes memory main = a.addr(bytes32(id), COIN_OP);
        assertEq(main, abi.encodePacked(DEAD));
        vm.prank(dave);
        (bool sent,) = address(bytes20(main)).call{value: 1 ether}("");
        assertTrue(sent);
        vm.prank(dave);
        vm.expectRevert(bytes("no address for this name"));
        wallet.payOP{value: 1 ether}(INameLookup(address(a)), "bob.club");
        vm.prank(dave);
        vm.expectRevert(bytes("no address for this name"));
        wallet.payEth{value: 1 ether}(INameLookup(address(a)), "bob.club");
        assertEq(DEAD.balance, deadBefore + 1 ether);
    }

    // 2. the events

    function test_eventsOfTransferToDead() public {
        uint256 id = _bobWithProfile();
        vm.recordLogs();
        vm.prank(bob);
        nft.transferFrom(bob, DEAD, id);
        bytes32[] memory want = new bytes32[](6);
        want[0] = _lTransfer(bob, DEAD, id);
        _trio(id, address(0), address(0), want, 1);
        // bob's display name was this subpage, so the move clears it
        bytes32[] memory tp = new bytes32[](3);
        tp[0] = T_PRIMARY;
        tp[1] = bytes32(uint256(uint160(bob)));
        want[4] = keccak256(abi.encode(tp, bytes("")));
        want[5] = _lMeta(id);
        _assertLogs(vm.getRecordedLogs(), want);

        // without the rule the trio names DEAD
        vm.recordLogs();
        vm.prank(bob);
        a.transferFrom(bob, DEAD, id);
        Vm.Log[] memory la = vm.getRecordedLogs();
        assertEq(la.length, 5);
        assertEq(keccak256(la[1].data), keccak256(abi.encode(COIN_OP, abi.encodePacked(DEAD))));
    }

    // the empty trio goes out whatever the holder had saved, a contract holder and a saved DEAD included
    function test_eventsOfTransferToDead_oddHolders() public {
        Holder721 h = new Holder721();
        uint256 id = _sub("h", address(h));
        vm.recordLogs();
        vm.prank(address(h));
        nft.safeTransferFrom(address(h), DEAD, id);
        bytes32[] memory want = new bytes32[](5);
        want[0] = _lTransfer(address(h), DEAD, id);
        _trio(id, address(0), address(0), want, 1);
        want[4] = _lMeta(id);
        _assertLogs(vm.getRecordedLogs(), want);

        uint256 id2 = _sub("s", bob);
        vm.prank(bob);
        nft.setAddr(id2, DEAD);
        assertEq(nft.resolve(id2), DEAD);
        vm.recordLogs();
        vm.prank(bob);
        nft.transferFrom(bob, DEAD, id2);
        want[0] = _lTransfer(bob, DEAD, id2);
        _trio(id2, address(0), address(0), want, 1);
        want[4] = _lMeta(id2);
        _assertLogs(vm.getRecordedLogs(), want);
    }

    function test_eventsOfRemintOverDeleted() public {
        uint256 id = _bobWithProfile();
        _toDead(address(nft), id);
        uint256 v = nft.recordVersion(id);
        vm.recordLogs();
        vm.prank(alice);
        nft.registerSubpageFor("bob", club, carol);
        // the burn from DEAD emits the empty trio of every burn. The mint makes carol the main address, and as
        // carol saved nothing in the fresh version the coin type 60 answer goes out empty
        bytes32[] memory want = new bytes32[](10);
        want[0] = _lTransfer(DEAD, address(0), id);
        _trio(id, address(0), address(0), want, 1);
        want[4] = _lVersion(id, v + 1);
        want[5] = _lTransfer(address(0), carol, id);
        _trio(id, carol, address(0), want, 6);
        want[9] = _lSubReg(id, club, "bob");
        _assertLogs(vm.getRecordedLogs(), want);
    }

    function test_eventsOfMintStraightToDead() public {
        uint256 id = _subId("fresh", club);
        vm.recordLogs();
        vm.prank(alice);
        nft.registerSubpageFor("fresh", club, DEAD);
        bytes32[] memory want = new bytes32[](2);
        want[0] = _lTransfer(address(0), DEAD, id);
        want[1] = _lSubReg(id, club, "fresh");
        _assertLogs(vm.getRecordedLogs(), want);
        _assertAnswersNothing(id);

        // a live subpage taken back and deleted in one call
        uint256 bid = _sub("bob", bob);
        uint256 v = nft.recordVersion(bid);
        vm.recordLogs();
        vm.prank(alice);
        nft.registerSubpageFor("bob", club, DEAD);
        want = new bytes32[](7);
        want[0] = _lTransfer(bob, address(0), bid);
        _trio(bid, address(0), address(0), want, 1);
        want[4] = _lVersion(bid, v + 1);
        want[5] = _lTransfer(address(0), DEAD, bid);
        want[6] = _lSubReg(bid, club, "bob");
        _assertLogs(vm.getRecordedLogs(), want);
        _assertAnswersNothing(bid);
    }

    // replaying every address event of a whole story ends on what the views answer
    function test_indexerReplayStaysRight() public {
        vm.recordLogs();
        uint256 id = _bobWithProfile();
        _replayAndCheck(id, bob, carol, carol);
        _toDead(address(nft), id);
        _replayAndCheck(id, DEAD, address(0), address(0));
        vm.prank(alice);
        nft.registerSubpageFor("bob", club, DEAD);
        _replayAndCheck(id, DEAD, address(0), address(0));
        _setMinter(club, hot);
        vm.prank(hot);
        nft.registerSubpageFor("bob", club, dave);
        // a fresh holder answers coin type 60 only once it saves an entry or a default
        _replayAndCheck(id, dave, dave, address(0));
        vm.prank(dave);
        nft.setAddrForCoin(id, DEFAULT_EVM, abi.encodePacked(dave));
        _replayAndCheck(id, dave, dave, dave);
        vm.prank(dave);
        nft.transferFrom(dave, DEAD, id);
        _replayAndCheck(id, DEAD, address(0), address(0));
        _sellSetup(club, 0.01 ether);
        vm.prank(buyer);
        reg.registerSubpageFor{value: 0.01 ether}(club, "bob", buyer, 0.01 ether, address(0));
        _replayAndCheck(id, buyer, buyer, address(0));
    }

    bytes idxOP;
    address idxAddr;
    bytes idx60;

    function _replayAndCheck(uint256 id, address holder, address wantMain, address wantEth) internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory l = logs[i];
            if (l.emitter != address(nft) || l.topics.length < 2 || l.topics[1] != bytes32(id)) continue;
            if (l.topics[0] == T_ADDR) {
                idxAddr = abi.decode(l.data, (address));
            } else if (l.topics[0] == T_ADDRESS) {
                (uint256 coin, bytes memory v) = abi.decode(l.data, (uint256, bytes));
                if (coin == COIN_OP) idxOP = v;
                if (coin == 60) idx60 = v;
            }
        }
        assertEq(nft.ownerOf(id), holder);
        assertEq(idxOP, nft.addr(id, COIN_OP), "indexer OP");
        assertEq(idxAddr, nft.addr(bytes32(id)), "indexer addr");
        assertEq(idx60, nft.addr(id, 60), "indexer 60");
        assertEq(_enc(nft.addr(bytes32(id))), nft.addr(id, 60), "addr(node) answers coin type 60");
        assertEq(nft.resolve(id), wantMain);
        assertEq(nft.addr(id, 60), _enc(wantEth));
        vm.recordLogs();
    }

    // 3. nothing can write or move it

    function test_deletedCannotBeWrittenOrMoved() public {
        uint256 id = _bobWithProfile();
        _toDead(address(nft), id);
        address[4] memory who = [bob, alice, stranger, DEAD];
        for (uint256 i; i < who.length; ++i) {
            vm.startPrank(who[i]);
            vm.expectRevert(PageNFT.Expired.selector);
            nft.setAddr(id, who[i]);
            vm.expectRevert(PageNFT.Expired.selector);
            nft.setAddrForCoin(id, 60, abi.encodePacked(who[i]));
            vm.expectRevert(PageNFT.Expired.selector);
            nft.setText(id, "avatar", "x");
            vm.expectRevert(PageNFT.Expired.selector);
            nft.setContenthash(id, hex"01");
            vm.expectRevert(PageNFT.Expired.selector);
            nft.clearRecords(id);
            vm.expectRevert(PageNFT.Expired.selector);
            nft.setPrimaryPage(id);
            vm.expectRevert(PageNFT.Expired.selector);
            nft.transferFrom(DEAD, who[i], id);
            vm.expectRevert(PageNFT.Expired.selector);
            nft.safeTransferFrom(DEAD, who[i], id);
            vm.stopPrank();
        }
        // even an approval given by DEAD's key, which nobody has, would not move it
        vm.prank(DEAD);
        nft.approve(stranger, id);
        vm.prank(DEAD);
        nft.setApprovalForAll(stranger, true);
        vm.prank(stranger);
        vm.expectRevert(PageNFT.Expired.selector);
        nft.transferFrom(DEAD, stranger, id);
        assertEq(nft.ownerOf(id), DEAD);
        _assertAnswersNothing(id);
        // clearing one's own pointer always works
        vm.prank(bob);
        nft.setPrimaryPage(0);
        assertEq(nft.primaryPage(bob), 0);
    }

    // the same calls without the rule fail too, only with other reasons
    function test_sameCallsFailWithoutTheRuleForOtherReasons() public {
        uint256 id = _bobWithProfile();
        _toDead(address(a), id);
        vm.startPrank(stranger);
        vm.expectRevert(PageNFTRecycle.Unauthorized.selector);
        a.setText(id, "avatar", "x");
        vm.expectRevert(PageNFTRecycle.Unauthorized.selector);
        a.setPrimaryPage(id);
        vm.expectRevert(NOT_OWNER_NOR_APPROVED);
        a.transferFrom(DEAD, stranger, id);
        vm.stopPrank();
    }

    // 4. the card and tokenURI

    function test_cardOfDeletedSubpage() public {
        uint256 id = _bobWithProfile();
        _toDead(address(nft), id);
        _toDead(address(a), id);
        string memory j = _json(address(nft), id);
        assertTrue(_contains(j, '"name":"bob.club"'), "full name kept");
        assertTrue(_contains(j, '"trait_type":"Status","value":"Invalid"'), "status Invalid");
        assertTrue(_contains(j, '"trait_type":"Type","value":"Subpage"'));
        assertTrue(_contains(j, string.concat("(", card.shortAddress(DEAD), ")")), "payee DEAD in the description");
        assertTrue(_contains(j, _image(id, "bob", "club", PageCard.Status.Invalid, 0)), "the card as told");
        CardReader.Card memory c = reader.read(card.render("bob", "club", bytes32(id), PageCard.Status.Invalid, 0));
        assertTrue(c.dead, "a dead card");
        assertEq(c.left, "Invalid");
        assertEq(c.dot, "#e5484d", "the red dot");
        assertEq(c.name, "bob.club", "the full name");
        assertEq(c.dimmed, ".club", "with the parent part dimmed");
        assertEq(c.right, _code(id), "the code of the page");
        // without the rule it is an Active card
        string memory ja = _json(address(a), id);
        assertTrue(_contains(ja, '"trait_type":"Status","value":"Active"'));
        assertFalse(_contains(ja, '"value":"Invalid"'));
    }

    // a deleted subpage whose parent is in grace or registered again
    function test_cardPrecedence() public {
        uint256 id = _sub("bob", bob);
        _toDead(address(nft), id);
        vm.warp(nft.expiresAt(club) + 1);
        assertTrue(_contains(_json(address(nft), id), '"value":"Invalid"'), "deleted wins over grace");
        assertTrue(_contains(_json(address(nft), id), _image(id, "bob", "club", PageCard.Status.Invalid, 0)));
        _lapseAndRegister(club, carol);
        // stale now: the same Invalid card, still with the full name
        assertTrue(_contains(_json(address(nft), id), _image(id, "bob", "club", PageCard.Status.Invalid, 0)));
        assertTrue(_contains(_json(address(nft), id), '"name":"bob.club"'));
    }

    // 5. creating it again restores a normal name

    function _assertFresh(uint256 id, address holder, uint256 v, uint64 e) internal {
        assertEq(nft.ownerOf(id), holder);
        assertEq(nft.recordVersion(id), v + 1, "fresh version");
        assertEq(_epoch(id), e + 1, "fresh epoch");
        assertEq(nft.resolve(id), holder);
        assertEq(nft.addr(id, COIN_OP), abi.encodePacked(holder));
        // the old entries are gone and the new holder saved none, so other chains answer empty
        assertEq(nft.addr(id, 60), "");
        assertEq(nft.addr(id, COIN_BASE), "");
        assertEq(nft.addr(id, COIN_BTC), "");
        assertEq(nft.text(id, "avatar"), "", "old text gone");
        assertEq(nft.contenthash(id), "", "old website gone");
        assertFalse(nft.isAvailable("bob", club));
        string memory j = _json(address(nft), id);
        assertTrue(_contains(j, '"value":"Active"'));
        assertTrue(_contains(j, _image(id, "bob", "club", PageCard.Status.Active, nft.expiresAt(club))));
        assertTrue(_contains(j, string.concat("(", card.shortAddress(holder), ")")), "paid to the new holder");
        vm.prank(holder);
        nft.setText(id, "avatar", "new");
        assertEq(nft.text(id, "avatar"), "new");
    }

    function test_recreateByHolder() public {
        uint256 id = _bobWithProfile();
        _toDead(address(nft), id);
        uint256 v = nft.recordVersion(id);
        uint64 e = _epoch(id);
        vm.prank(alice);
        nft.registerSubpageFor("bob", club, carol);
        _assertFresh(id, carol, v, e);
    }

    function test_recreateByMinter() public {
        uint256 id = _bobWithProfile();
        _toDead(address(nft), id);
        _setMinter(club, hot);
        uint256 v = nft.recordVersion(id);
        uint64 e = _epoch(id);
        vm.prank(hot);
        nft.registerSubpageFor("bob", club, dave);
        _assertFresh(id, dave, v, e);
    }

    function test_recreateByShop() public {
        uint256 id = _bobWithProfile();
        _toDead(address(nft), id);
        _sellSetup(club, 0.01 ether);
        uint256 v = nft.recordVersion(id);
        uint64 e = _epoch(id);
        vm.prank(buyer);
        assertEq(reg.registerSubpageFor{value: 0.01 ether}(club, "bob", buyer, 0.01 ether, address(0)), id);
        _assertFresh(id, buyer, v, e);
    }

    function test_holderRemintsStraightToDead() public {
        uint256 id = _bobWithProfile();
        uint256 v = nft.recordVersion(id);
        vm.prank(alice);
        nft.registerSubpageFor("bob", club, DEAD);
        assertEq(nft.ownerOf(id), DEAD);
        assertEq(nft.recordVersion(id), v + 1);
        _assertAnswersNothing(id);
        assertTrue(nft.isAvailable("bob", club));
        assertEq(nft.primaryPage(bob), 0, "the take-back clears bob's pointer at step 8");
        assertEq(nft.reverseResolve(bob), "");
        // and the holder can create it again
        vm.prank(alice);
        nft.registerSubpageFor("bob", club, bob);
        assertEq(nft.resolve(id), bob);
        assertEq(nft.recordVersion(id), v + 2);
    }

    // the move to DEAD cleared bob's pointer, so a later holder that points the name back at bob
    // does not bring back bob's display name
    function test_revivalAfterRecreationIsBlocked() public {
        uint256 id = _bobWithProfile();
        _toDead(address(nft), id);
        assertEq(nft.reverseResolve(bob), "");
        _setMinter(club, hot);
        vm.prank(hot);
        nft.registerSubpageFor("bob", club, stranger);
        vm.startPrank(stranger);
        nft.setAddr(id, bob);
        nft.setText(id, "avatar", "stranger");
        vm.stopPrank();
        assertEq(nft.resolve(id), bob);
        assertEq(nft.primaryPage(bob), 0);
        assertEq(nft.reverseResolve(bob), "", "no revival");
    }

    // 6. a top level page held by DEAD is deleted too

    // the views that do not follow activity agree with the reference
    function _sameStateViews(uint256 id, string memory label) internal view {
        assertEq(nft.ownerOf(id), a.ownerOf(id), "holder");
        assertEq(nft.payee(id), a.payee(id), "payee");
        assertEq(nft.getPageName(id), a.getPageName(id), "full name");
        assertEq(nft.expiresAt(id), a.expiresAt(id), "expiry");
        assertEq(nft.isExpired(id), a.isExpired(id), "isExpired");
        assertEq(nft.inGracePeriod(id), a.inGracePeriod(id), "inGracePeriod");
        assertEq(nft.isAvailable(label, 0), a.isAvailable(label, 0), "isAvailable of the label");
    }

    function test_topLevelHeldByDeadAnswersNothing() public {
        uint256 id = _regBoth(bob, "gold", bob);
        address[2] memory w = [address(nft), address(a)];
        for (uint256 i; i < 2; ++i) {
            vm.startPrank(bob);
            PageNFT(w[i]).setText(id, "avatar", "gold");
            PageNFT(w[i]).setContenthash(id, hex"e301");
            PageNFT(w[i]).setAddr(id, carol);
            PageNFT(w[i]).setData(id, "k", hex"01");
            vm.stopPrank();
        }
        // the move announces empty addresses
        vm.recordLogs();
        vm.prank(bob);
        nft.transferFrom(bob, DEAD, id);
        bytes32[] memory want = new bytes32[](5);
        want[0] = _lTransfer(bob, DEAD, id);
        _trio(id, address(0), address(0), want, 1);
        want[4] = _lMeta(id);
        _assertLogs(vm.getRecordedLogs(), want);
        // without the rule the main address goes out as DEAD
        vm.recordLogs();
        vm.prank(bob);
        a.transferFrom(bob, DEAD, id);
        Vm.Log[] memory la = vm.getRecordedLogs();
        assertEq(la.length, 5);
        assertEq(keccak256(la[1].data), keccak256(abi.encode(COIN_OP, abi.encodePacked(DEAD))));

        _assertAnswersNothing(id);
        assertEq(nft.data(bytes32(id), "k"), "", "data");
        assertEq(nft.reverseResolve(DEAD), "", "reverseResolve DEAD");
        assertEq(uint256(nft.status(id)), uint256(PageCard.Status.Invalid), "status");
        string memory j = _json(address(nft), id);
        assertTrue(_contains(j, '"trait_type":"Status","value":"Invalid"'), "card Invalid");
        assertTrue(_contains(j, _image(id, "gold", "", PageCard.Status.Invalid, 0)), "the card as told");
        assertTrue(_contains(j, string.concat("(", card.shortAddress(DEAD), ")")), "payee DEAD in the description");
        assertFalse(nft.isAvailable("x", id), "no subpage label is free under it");
        assertFalse(nft.isAvailable("gold", 0), "the label stays taken until grace ends");
        assertEq(nft.payee(id), DEAD, "payee");
        // the reference answers DEAD as the main address, the profile it had and an Active card
        assertEq(a.resolve(id), DEAD);
        assertEq(a.text(id, "avatar"), "gold");
        assertEq(a.contenthash(id), hex"e301");
        assertTrue(_contains(_json(address(a), id), '"trait_type":"Status","value":"Active"'));
        assertTrue(a.isAvailable("x", id));
        _sameStateViews(id, "gold");

        // anyone may renew it, and it stays deleted
        vm.deal(stranger, 1 ether);
        vm.startPrank(stranger);
        nft.renew{value: 0.001 ether}(id);
        a.renew{value: 0.001 ether}(id);
        vm.stopPrank();
        _assertAnswersNothing(id);
        assertEq(uint256(nft.status(id)), uint256(PageCard.Status.Invalid), "status after a renewal");
        _sameStateViews(id, "gold");

        // Invalid through grace and after it, and the label is free once grace ends
        vm.warp(nft.expiresAt(id) + 1);
        assertTrue(nft.inGracePeriod(id));
        _assertAnswersNothing(id);
        assertEq(uint256(nft.status(id)), uint256(PageCard.Status.Invalid), "status in grace");
        assertTrue(_contains(_json(address(nft), id), _image(id, "gold", "", PageCard.Status.Invalid, 0)));
        _sameStateViews(id, "gold");
        vm.warp(nft.expiresAt(id) + 90 days + 1);
        _assertAnswersNothing(id);
        assertEq(uint256(nft.status(id)), uint256(PageCard.Status.Invalid), "status after expiry");
        _sameStateViews(id, "gold");
        assertTrue(nft.isAvailable("gold", 0));
        assertEq(nft.isAvailable("x", id), a.isAvailable("x", id));

        // registered again, it is an ordinary page with nothing of the old profile
        assertEq(_regBoth(carol, "gold", carol), id);
        assertEq(nft.resolve(id), carol);
        assertEq(nft.addr(id, COIN_OP), abi.encodePacked(carol));
        assertEq(nft.text(id, "avatar"), "");
        assertEq(nft.data(bytes32(id), "k"), "");
        assertEq(uint256(nft.status(id)), uint256(PageCard.Status.Active), "status once registered again");
        assertTrue(nft.isAvailable("x", id));
    }

    function test_topLevelMintedToDeadAnswersNothing() public {
        vm.recordLogs();
        uint256 id = _regBoth(alice, "cedar", DEAD);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        // the mint announces no address, while the reference announces DEAD as the main address
        uint256 deadMainInA;
        for (uint256 i; i < logs.length; ++i) {
            bytes32 t0 = logs[i].topics[0];
            if (logs[i].emitter == address(nft)) {
                assertTrue(t0 != T_ADDRESS && t0 != T_ADDR, "no address event");
            } else if (logs[i].emitter == address(a) && t0 == T_ADDRESS) {
                if (keccak256(logs[i].data) == keccak256(abi.encode(COIN_OP, abi.encodePacked(DEAD)))) ++deadMainInA;
            }
        }
        assertEq(deadMainInA, 1);
        _assertAnswersNothing(id);
        assertEq(uint256(nft.status(id)), uint256(PageCard.Status.Invalid), "status");
        assertFalse(nft.isAvailable("x", id), "no subpage label is free under it");
        assertEq(nft.payee(id), DEAD, "payee");
        _sameStateViews(id, "cedar");
        // the reference answers DEAD as the main address. DEAD saves nothing, so coin type 60 answers empty there
        assertEq(a.resolve(id), DEAD);
        assertEq(a.addr(id, COIN_OP), abi.encodePacked(DEAD));
        assertEq(a.addr(id, 60), "");
        assertEq(a.addr(bytes32(id)), address(0));
    }

    // 7. grace, a new registration, stale

    function test_parentGraceAndRenewal() public {
        uint256 id = _bobWithProfile();
        _toDead(address(nft), id);
        vm.warp(nft.expiresAt(club) + 1);
        _assertAnswersNothing(id);
        assertFalse(nft.isAvailable("bob", club), "no subpage is free while the parent is in grace");
        vm.prank(alice);
        vm.expectRevert(PageNFT.Expired.selector);
        nft.registerSubpageFor("bob", club, carol);
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        nft.renew{value: 0.001 ether}(club);
        _assertAnswersNothing(id);
        assertTrue(nft.isAvailable("bob", club), "free again after the renewal");
        vm.prank(alice);
        nft.registerSubpageFor("bob", club, carol);
        assertEq(nft.resolve(id), carol);
    }

    function test_cannotDeleteWhileParentInGrace() public {
        uint256 id = _sub("bob", bob);
        vm.warp(nft.expiresAt(club) + 1);
        vm.prank(bob);
        vm.expectRevert(PageNFT.Expired.selector);
        nft.transferFrom(bob, DEAD, id);
    }

    function test_parentReRegistered_staleAndDeleted() public {
        uint256 id = _bobWithProfile();
        _toDead(address(nft), id);
        uint256 live = _sub("keep", dave);
        _lapseAndRegister(club, carol);
        // both are stale and answer nothing, the deleted one the same as the live one
        _assertAnswersNothing(id);
        assertEq(nft.resolve(live), address(0));
        assertEq(nft.getPageName(id), "", "stale drops the full name");
        assertTrue(nft.isAvailable("bob", club));
        // a stale subpage cannot be deleted, it is not active
        vm.prank(dave);
        vm.expectRevert(PageNFT.Expired.selector);
        nft.transferFrom(dave, DEAD, live);
        // the new holder creates it
        vm.prank(carol);
        nft.registerSubpageFor("bob", club, carol);
        assertEq(nft.resolve(id), carol);
        assertEq(nft.text(id, "avatar"), "");
        assertEq(nft.getPageName(id), "bob.club");
    }

    // a subpage under a top level name held by DEAD is an ordinary subpage
    function test_subpageOfADeadParentIsNotDeleted() public {
        uint256 id = _sub("bob", bob);
        vm.prank(alice);
        nft.transferFrom(alice, DEAD, club);
        assertEq(nft.resolve(id), bob, "only the subpage's own holder counts");
        vm.prank(bob);
        nft.setText(id, "avatar", "still mine");
        assertEq(nft.text(id, "avatar"), "still mine");
    }

    // only the exact DEAD address deletes: any other holder gets a live name it can write to
    function test_onlyDeadDeletes() public {
        address[3] memory others = [address(0xdEaE), address(uint160(0xdead) << 144), carol];
        for (uint256 i; i < others.length; ++i) {
            uint256 id = _sub(string.concat("o", vm.toString(i)), bob);
            vm.prank(bob);
            nft.transferFrom(bob, others[i], id);
            assertEq(nft.resolve(id), others[i]);
            assertEq(nft.addr(id, COIN_OP), abi.encodePacked(others[i]));
            assertEq(nft.addr(id, 60), "", "nothing saved yet");
            vm.prank(others[i]);
            nft.setAddrForCoin(id, DEFAULT_EVM, abi.encodePacked(others[i]));
            assertEq(nft.addr(id, 60), abi.encodePacked(others[i]));
        }
    }
}

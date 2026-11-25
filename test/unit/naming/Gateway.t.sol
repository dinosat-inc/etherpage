// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {console2} from "forge-std/Test.sol";
import {PageCard} from "../../../src/PageCard.sol";
import {NamingBase, ViewGateway, StorageReader, INameViews} from "../../utils/NamingBase.sol";

contract Vault {
    receive() external payable {}
}

contract GatewayTest is NamingBase {
    ViewGateway gwCom;
    ViewGateway gwEth;
    StorageReader reader;

    uint256 constant OP = 0x8000000a;
    uint256 constant BASE = 0x80002105;
    uint256 constant DEFAULT_EVM = 0x80000000;
    uint256 constant BTC = 0;

    uint256[] coins;
    string[] keys;

    function setUp() public override {
        super.setUp();
        gwCom = new ViewGateway(INameViews(address(nft)), "etherpage.com");
        gwEth = new ViewGateway(INameViews(address(nft)), "etherpage.eth");
        reader = new StorageReader(address(nft));
        coins.push(60);
        coins.push(OP);
        coins.push(DEFAULT_EVM);
        coins.push(BASE);
        coins.push(BTC);
        keys.push("avatar");
        keys.push("url");
        keys.push("missing");
    }

    function _q(ViewGateway gw, string memory full, bytes memory call) internal view returns (bytes memory) {
        return gw.resolve(_dns(full), call);
    }

    function _gwAddr(ViewGateway gw, string memory full) internal view returns (address) {
        return abi.decode(_q(gw, full, abi.encodeWithSelector(0x3b3b57de, bytes32(0))), (address));
    }

    function _gwCoin(ViewGateway gw, string memory full, uint256 c) internal view returns (bytes memory) {
        return abi.decode(_q(gw, full, abi.encodeWithSelector(0xf1cb7e06, bytes32(0), c)), (bytes));
    }

    function _gwText(ViewGateway gw, string memory full, string memory k) internal view returns (string memory) {
        return abi.decode(_q(gw, full, abi.encodeWithSelector(0x59d1d43c, bytes32(0), k)), (string));
    }

    function _gwHash(ViewGateway gw, string memory full) internal view returns (bytes memory) {
        return abi.decode(_q(gw, full, abi.encodeWithSelector(0xbc1c58d1, bytes32(0))), (bytes));
    }

    // views, raw storage and the etherpage.com gateway agree on every answer checked for this name, and the
    // etherpage.eth gateway agrees on every coin answer
    function _agree(uint256 id, string memory ours) internal view {
        string memory c = string.concat(ours, ".etherpage.com");
        string memory e = string.concat(ours, ".etherpage.eth");
        assertEq(nft.computeId(ours), id, "computeId");
        assertEq(reader.resolve(id), nft.resolve(id), "resolve");
        assertEq(reader.fullName(id), nft.getPageName(id), "fullName");
        for (uint256 i; i < coins.length; ++i) {
            bytes memory v = nft.addr(id, coins[i]);
            assertEq(reader.addr(id, coins[i]), v, "reader coin");
            assertEq(_gwCoin(gwCom, c, coins[i]), v, "gw com coin");
            assertEq(_gwCoin(gwEth, e, coins[i]), v, "gw eth coin");
        }
        bytes memory eth = nft.addr(id, 60);
        address ethAddr = eth.length == 20 ? address(bytes20(eth)) : address(0);
        assertEq(_gwAddr(gwCom, c), ethAddr, "gw addr(node) is coin 60");
        assertEq(nft.addr(bytes32(id)), ethAddr, "our addr(bytes32) is coin 60");
        for (uint256 i; i < keys.length; ++i) {
            string memory t = nft.text(id, keys[i]);
            assertEq(reader.text(id, keys[i]), t, "reader text");
            assertEq(_gwText(gwCom, c, keys[i]), t, "gw text");
        }
        assertEq(reader.contenthash(id), nft.contenthash(id), "reader contenthash");
        assertEq(_gwHash(gwCom, c), nft.contenthash(id), "gw contenthash");
    }

    function _empty(string memory ours) internal view {
        string memory c = string.concat(ours, ".etherpage.com");
        for (uint256 i; i < coins.length; ++i) assertEq(_gwCoin(gwCom, c, coins[i]).length, 0, "empty coin");
        assertEq(_gwAddr(gwCom, c), address(0), "empty addr");
        assertEq(bytes(_gwText(gwCom, c, "avatar")).length, 0, "empty text");
        assertEq(_gwHash(gwCom, c).length, 0, "empty hash");
    }

    function _profile(address who, uint256 id, string memory tag) internal {
        vm.startPrank(who);
        nft.setText(id, "avatar", string.concat("ipfs://", tag));
        nft.setText(id, "url", string.concat("https://", tag, ".example"));
        nft.setContenthash(id, abi.encodePacked(hex"e30101701220", keccak256(bytes(tag))));
        nft.setAddrForCoin(id, BASE, abi.encodePacked(carol));
        nft.setAddrForCoin(id, BTC, hex"0014751e76e8199196d454941c45d1b3a323f1433bd6");
        vm.stopPrank();
    }

    function test_idIsNotTheZeroRootNamehash() public view {
        uint256 ours = nft.computeId("alice");
        bytes32 zeroRoot = _zeroRootNamehash("alice");
        assertTrue(bytes32(ours) != zeroRoot, "ids live under ROOT, not under the zero root");
        assertEq(ours, uint256(keccak256(abi.encodePacked(nft.ROOT(), keccak256("alice")))));
        assertEq(nft.computeId("bob.alice"), uint256(keccak256(abi.encodePacked(bytes32(ours), keccak256("bob")))));
        console2.log("computeId(alice)            ", vm.toString(bytes32(ours)));
        console2.log("namehash(alice)             ", vm.toString(zeroRoot));
        console2.log("namehash(alice.etherpage.com)", vm.toString(_zeroRootNamehash("alice.etherpage.com")));
        console2.log("namehash(alice.etherpage.eth) ", vm.toString(_zeroRootNamehash("alice.etherpage.eth")));
    }

    function test_paidNameAndSubpage() public {
        uint256 a = _buy(alice, "alice");
        _profile(alice, a, "alice");
        vm.prank(alice);
        uint256 b = nft.registerSubpageFor("bob", a, bob);
        _profile(bob, b, "bob");
        _agree(a, "alice");
        _agree(b, "bob.alice");
        // neither holder saved a coin 60 address or a default, so addr(node) is empty, ours and through a gateway,
        // while resolve answers the main address, the holder
        assertEq(nft.resolve(a), alice, "resolve = main address");
        assertEq(nft.addr(bytes32(a)), address(0), "our addr(bytes32) is coin 60");
        assertEq(_gwAddr(gwCom, "alice.etherpage.com"), address(0), "no coin 60 answer before a save");
        assertEq(_gwAddr(gwEth, "bob.alice.etherpage.eth"), address(0), "no coin 60 answer before a save");
        // a saved default answers coin 60, so the gateway then gives exactly that
        vm.prank(bob);
        nft.setAddrForCoin(b, DEFAULT_EVM, abi.encodePacked(bob));
        assertEq(_gwAddr(gwEth, "bob.alice.etherpage.eth"), bob);
        _agree(b, "bob.alice");
        assertEq(_gwCoin(gwCom, "alice.etherpage.com", BASE), abi.encodePacked(carol));
        assertEq(_gwText(gwCom, "bob.alice.etherpage.com", "avatar"), "ipfs://bob");
        // case folding: normalized input is lower case, but upper case lands on the same id too
        assertEq(nft.computeId("ALICE"), a);
        assertEq(nft.computeId("Bob.Alice"), b);

        // a contract as the main address: resolve is the OP answer, addr(node) is coin 60, ours and a gateway's
        Vault v = new Vault();
        vm.prank(alice);
        nft.setAddr(a, address(v));
        assertEq(nft.resolve(a), address(v), "resolve = OP main address");
        assertEq(nft.addr(bytes32(a)), address(0), "our addr(bytes32) is coin 60");
        assertEq(nft.addr(a, 60), "", "the main address does not answer coin 60");
        assertEq(_gwAddr(gwCom, "alice.etherpage.com"), address(0), "gateway must map addr(node) to coin 60");
        _agree(a, "alice");
        // a 7702 delegated main address does not answer coin 60 either, the code at an address changes no answer
        address del = makeAddr("delegated");
        vm.etch(del, abi.encodePacked(hex"ef0100", address(v)));
        vm.prank(alice);
        nft.setAddr(a, del);
        assertEq(nft.resolve(a), del, "resolve = main address");
        assertEq(nft.addr(bytes32(a)), address(0), "our addr(bytes32) is coin 60");
        assertEq(nft.addr(a, 60), "", "no coin 60 answer before a save");
        assertEq(_gwAddr(gwCom, "alice.etherpage.com"), address(0));
        _agree(a, "alice");
        // a saved default answers coin 60 through the gateway, and the own BASE entry still wins on BASE
        vm.prank(alice);
        nft.setAddrForCoin(a, DEFAULT_EVM, abi.encodePacked(del));
        assertEq(nft.addr(a, 60), abi.encodePacked(del));
        assertEq(_gwAddr(gwCom, "alice.etherpage.com"), del);
        assertEq(_gwCoin(gwCom, "alice.etherpage.com", BASE), abi.encodePacked(carol));
        _agree(a, "alice");
        // a saved coin 60 address overrides the default
        vm.prank(alice);
        nft.setAddrForCoin(a, 60, abi.encodePacked(bob));
        assertEq(_gwAddr(gwCom, "alice.etherpage.com"), bob);
        _agree(a, "alice");
        // clearRecords empties everything through the version bump
        vm.prank(alice);
        nft.clearRecords(a);
        assertEq(nft.text(a, "avatar"), "");
        assertEq(_gwAddr(gwCom, "alice.etherpage.com"), address(0));
        _agree(a, "alice");
    }

    function test_trial() public {
        uint256 t = _trial("tryme", carol);
        assertEq(uint256(nft.status(t)), uint256(PageCard.Status.Trial));
        vm.prank(carol);
        nft.setText(t, "avatar", "ipfs://trial");
        _agree(t, "tryme");
        assertEq(_gwAddr(gwCom, "tryme.etherpage.com"), address(0), "nothing saved for coin 60 yet");
        vm.prank(carol);
        nft.setAddrForCoin(t, DEFAULT_EVM, abi.encodePacked(carol));
        _agree(t, "tryme");
        assertEq(_gwAddr(gwCom, "tryme.etherpage.com"), carol, "a live trial resolves");
        uint256 end = nft.expiresAt(t);
        vm.warp(end);
        _agree(t, "tryme");
        assertEq(_gwAddr(gwCom, "tryme.etherpage.com"), carol, "last second of the trial");
        vm.warp(end + 1);
        assertEq(uint256(nft.status(t)), uint256(PageCard.Status.Expired), "a trial has no grace");
        _agree(t, "tryme");
        _empty("tryme");
        assertEq(nft.getPageName(t), "tryme", "getPageName is not an activity check");
    }

    function test_expiredAndGrace() public {
        uint256 o = _buy(alice, "oldie");
        _profile(alice, o, "oldie");
        vm.prank(alice);
        uint256 s = nft.registerSubpageFor("shop", o, bob);
        uint256 end = nft.expiresAt(o);
        vm.warp(end + 1);
        assertEq(uint256(nft.status(o)), uint256(PageCard.Status.Grace));
        assertEq(uint256(nft.status(s)), uint256(PageCard.Status.Grace));
        _agree(o, "oldie");
        _agree(s, "shop.oldie");
        _empty("oldie");
        _empty("shop.oldie");
        vm.warp(end + 90 days + 1);
        assertEq(uint256(nft.status(o)), uint256(PageCard.Status.Expired));
        _agree(o, "oldie");
        _empty("oldie");
        // renewed in grace, everything comes back
        vm.warp(end + 10 days);
        vm.prank(bob);
        nft.renew{value: 0.0001 ether}(o);
        _agree(o, "oldie");
        _agree(s, "shop.oldie");
        assertEq(_gwText(gwCom, "oldie.etherpage.com", "avatar"), "ipfs://oldie");
    }

    function test_deletedSubpage() public {
        uint256 a = _buy(alice, "alice");
        vm.prank(alice);
        uint256 b = nft.registerSubpageFor("bob", a, bob);
        _profile(bob, b, "bob");
        vm.prank(bob);
        nft.setPrimaryPage(b);
        assertEq(gwCom.reverseName(bob), "bob.alice.etherpage.com");
        vm.prank(bob);
        nft.transferFrom(bob, DEAD, b);
        assertEq(uint256(nft.status(b)), uint256(PageCard.Status.Invalid));
        _agree(b, "bob.alice");
        _empty("bob.alice");
        assertEq(nft.reverseResolve(bob), "");
        assertEq(reader.reverseResolve(bob), "");
        assertEq(gwCom.reverseName(bob), "");
        assertEq(nft.getPageName(b), "bob.alice", "getPageName still spells a deleted subpage");
        // minted again, it starts clean: the main address is the new holder, and coin 60 answers only once she saves
        vm.prank(alice);
        nft.registerSubpageFor("bob", a, carol);
        _agree(b, "bob.alice");
        assertEq(nft.resolve(b), carol);
        assertEq(nft.addr(bytes32(b)), address(0));
        assertEq(_gwAddr(gwCom, "bob.alice.etherpage.com"), address(0));
        assertEq(_gwCoin(gwCom, "bob.alice.etherpage.com", BASE), "", "bob's BASE entry does not count");
        assertEq(_gwText(gwCom, "bob.alice.etherpage.com", "avatar"), "");
        vm.prank(carol);
        nft.setAddrForCoin(b, 60, abi.encodePacked(carol));
        _agree(b, "bob.alice");
        assertEq(_gwAddr(gwCom, "bob.alice.etherpage.com"), carol);
    }

    function test_staleSubpageAfterParentChangesHands() public {
        uint256 a = _buy(alice, "alice");
        vm.prank(alice);
        uint256 b = nft.registerSubpageFor("bob", a, bob);
        _profile(bob, b, "bob");
        vm.warp(nft.expiresAt(a) + 90 days + 21 days + 1);
        uint256 a2 = _buy(carol, "alice");
        assertEq(a2, a);
        assertEq(uint256(nft.status(b)), uint256(PageCard.Status.Invalid));
        assertEq(nft.getPageName(b), "", "a stale subpage has no full name");
        _agree(b, "bob.alice");
        _empty("bob.alice");
        _agree(a, "alice");
        assertEq(nft.resolve(a), carol);
        assertEq(nft.addr(bytes32(a)), address(0));
        assertEq(_gwAddr(gwCom, "alice.etherpage.com"), address(0), "nothing saved for coin 60 yet");
        vm.prank(carol);
        nft.setAddrForCoin(a, DEFAULT_EVM, abi.encodePacked(carol));
        _agree(a, "alice");
        assertEq(_gwAddr(gwCom, "alice.etherpage.com"), carol);
    }

    function test_reverse() public {
        uint256 a = _buy(alice, "alice");
        vm.prank(alice);
        nft.setPrimaryPage(a);
        assertEq(nft.reverseResolve(alice), "alice", "reverseResolve has no suffix");
        assertEq(reader.reverseResolve(alice), "alice");
        assertEq(gwCom.reverseName(alice), "alice.etherpage.com");
        assertEq(gwEth.reverseName(alice), "alice.etherpage.eth");
        // forward check a wallet does on a primary name: it reads coin 60, so it passes only once the holder saves a
        // coin 60 address or a default
        assertEq(_gwAddr(gwCom, gwCom.reverseName(alice)), address(0));
        vm.prank(alice);
        nft.setAddrForCoin(a, DEFAULT_EVM, abi.encodePacked(alice));
        assertEq(_gwAddr(gwCom, gwCom.reverseName(alice)), alice);
        // a sale ends it
        vm.prank(alice);
        nft.transferFrom(alice, bob, a);
        assertEq(nft.reverseResolve(alice), "");
        assertEq(reader.reverseResolve(alice), "");
    }

    function test_unknownAndMalformed() public {
        _buy(alice, "alice");
        _empty("nobody");
        // three labels of ours: computeId reverts, the gateway answers nothing
        vm.expectRevert();
        nft.computeId("a.b.alice");
        (bool found,) = gwCom.idOf(_dns("a.b.alice.etherpage.com"));
        assertFalse(found);
        _empty("a.b.alice");
        // wrong suffix or only the suffix
        (found,) = gwCom.idOf(_dns("alice.etherpage.org"));
        assertFalse(found);
        (found,) = gwCom.idOf(_dns("etherpage.com"));
        assertFalse(found);
        // a label with bytes outside ASCII can never exist, so it lands on an empty id
        (found,) = gwCom.idOf(_dns(unicode"alicé.etherpage.com"));
        assertTrue(found);
        _empty(unicode"alicé");
        // status reverts on an id with no record, a gateway must catch it
        uint256 none = nft.computeId("nobody");
        vm.expectRevert();
        nft.status(none);
    }
}

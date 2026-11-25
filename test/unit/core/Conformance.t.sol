// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Vm} from "forge-std/Test.sol";
import {Base64} from "solady/utils/Base64.sol";
import {PageCard} from "../../../src/PageCard.sol";
import {PageNFT} from "../../../src/PageNFT.sol";
import {SubpageRegistrar} from "../../../src/SubpageRegistrar.sol";
import {MinterBase} from "../../utils/MinterBase.sol";
import {HookCaller} from "../../utils/MinterMocks.sol";

contract EscapeHarness is PageNFT {
    constructor(PageCard c) PageNFT(c) {}

    function escape(string memory s) external pure returns (string memory) {
        return _escapeJSON(s);
    }
}

// The registry as a main address, the name and symbol, JSON escaping, the sale payout and pushed proceeds.
contract ConformanceTest is MinterBase {
    // the main address is never PageNFT; that check runs after the others and writes nothing
    function test_mainAddressRefusesTheRegistry() public {
        uint256 id = _reg(alice, "alice");
        vm.prank(alice);
        nft.setAddr(id, payout);
        vm.recordLogs();
        vm.prank(alice);
        vm.expectRevert(PageNFT.InvalidRecipient.selector);
        nft.setAddr(id, address(nft));
        vm.prank(alice);
        vm.expectRevert(PageNFT.InvalidRecipient.selector);
        nft.setAddrForCoin(id, COIN_OP, abi.encodePacked(address(nft)));
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(nft.resolve(id), payout);
        // Expired, Unauthorized and InvalidLength come first
        vm.prank(bob);
        vm.expectRevert(PageNFT.Unauthorized.selector);
        nft.setAddr(id, address(nft));
        vm.prank(alice);
        vm.expectRevert(PageNFT.InvalidLength.selector);
        nft.setAddrForCoin(id, COIN_OP, abi.encodePacked(address(nft), uint8(1)));
        // other coins store the bytes as given
        vm.prank(alice);
        nft.setAddrForCoin(id, 60, abi.encodePacked(address(nft)));
        assertEq(nft.addr(id, 60), abi.encodePacked(address(nft)));
        vm.warp(nft.expiresAt(id) + 1);
        vm.prank(alice);
        vm.expectRevert(PageNFT.Expired.selector);
        nft.setAddr(id, address(nft));
    }

    // a receiver that saves the registry from its hook reverts only its own mint
    function test_receiverSavingTheRegistryRevertsOnlyItself() public {
        uint256 club = _reg(alice, "club");
        HookCaller h = new HookCaller();
        uint256 sid = _subId("hook", club);
        h.arm(address(nft), abi.encodeCall(PageNFT.setAddr, (sid, address(nft))), true);
        vm.prank(alice);
        vm.expectRevert(PageNFT.InvalidRecipient.selector);
        nft.registerSubpageFor("hook", club, address(h));
    }

    // the name, the symbol and the start of the token JSON
    function test_nameAndSymbolExact() public {
        assertEq(nft.name(), "Etherpage");
        assertEq(nft.symbol(), "ETHERPAGE");
        uint256 id = _reg(alice, "alice");
        string memory uri = nft.tokenURI(id);
        bytes memory json = Base64.decode(_after(uri, 29));
        bytes memory want = bytes('{"name":"alice","description":"Etherpage: alice (');
        for (uint256 i; i < want.length; ++i) assertEq(json[i], want[i]);
    }

    function _after(string memory s, uint256 n) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        bytes memory o = new bytes(b.length - n);
        for (uint256 i; i < o.length; ++i) o[i] = b[i + n];
        return string(o);
    }

    // quote, backslash, tab, line feed and carriage return are escaped, other controls dropped
    function test_escapeJSON() public {
        EscapeHarness e = new EscapeHarness(card);
        assertEq(e.escape("bob.alice"), "bob.alice");
        assertEq(e.escape(unicode"a\"b\\c"), unicode"a\\\"b\\\\c");
        assertEq(e.escape(string(hex"610962")), "a\\tb");
        assertEq(e.escape(string(hex"610a62")), "a\\nb");
        assertEq(e.escape(string(hex"610d62")), "a\\rb");
        assertEq(e.escape(string(hex"61011f62")), "ab");
        // an escaped quote next to a dropped control keeps its escape
        assertEq(e.escape(string(hex"2201")), "\\\"");
        bytes memory hi = hex"7f80ff";
        assertEq(bytes(e.escape(string(hi))), hi);
    }

    function testFuzz_escapeJSONIsValidAndBounded(bytes memory b) public {
        EscapeHarness e = new EscapeHarness(card);
        bytes memory o = bytes(e.escape(string(b)));
        assertLe(o.length, 2 * b.length);
        for (uint256 i; i < o.length; ++i) {
            assertTrue(uint8(o[i]) >= 0x20, "no control byte");
            if (o[i] == 0x5c) {
                ++i;
                bytes1 c = o[i];
                assertTrue(c == 0x22 || c == 0x5c || c == "t" || c == "n" || c == "r", "escape");
            } else {
                assertTrue(o[i] != 0x22, "bare quote");
            }
        }
    }

    // PageNFT and the registrar are refused as sale payout
    function testFuzz_configurePayoutRule(address p) public {
        uint256 club = _reg(alice, "club");
        vm.prank(alice);
        (bool ok,) = address(reg).call(
            abi.encodeCall(SubpageRegistrar.configure, (club, p, address(0), 0, true, address(0), 0, false))
        );
        assertEq(ok, p != address(reg) && p != address(nft));
    }

    // anyone may push, only the account is paid, and the caller is never named
    function testFuzz_claimForPaysOnlyTheAccount(address caller, uint96 price) public {
        vm.assume(caller != payout && caller.code.length == 0 && uint160(caller) > 0x10000 && caller != address(vm));
        vm.assume(price > 0);
        uint256 club = _reg(alice, "club");
        _sellSetup(club, price);
        vm.deal(buyer, uint256(price));
        vm.prank(buyer);
        reg.registerSubpage{value: price}(club, "x", price, address(0));
        uint256 cb = caller.balance;
        vm.recordLogs();
        vm.prank(caller);
        uint256 paid = reg.claimProceedsFor(payout);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(paid, price);
        assertEq(payout.balance, price);
        assertEq(caller.balance, cb);
        assertEq(address(reg).balance, 0);
        assertEq(logs.length, 1);
        assertEq(abi.decode(logs[0].data, (uint256)), price);
        assertEq(logs[0].topics[1], bytes32(uint256(uint160(payout))));
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(payout))));
    }
}

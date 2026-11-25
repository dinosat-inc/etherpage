// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {PageCard} from "../../src/PageCard.sol";
import {PageNFT} from "../../src/PageNFT.sol";

// Opens the helpers that no call reaches with every input, so each of their branches can be tested. They are split
// over three harnesses so that each stays under the size limit.
contract CreditHarness is PageNFT {
    constructor(PageCard c) PageNFT(c) {}

    function credit(address account, uint256 amount) external returns (address) {
        return _credit(account, amount);
    }
}

contract MainHarness is PageNFT {
    constructor(PageCard c) PageNFT(c) {}

    // saves a main address without the refusal of this contract, which only a storage write can do
    function forceMain(uint256 tokenId, address a) external {
        uint256 v = recordVersion[tokenId];
        _resolvedAddress[tokenId][v] = a;
        _addrSaver[tokenId][v] = msg.sender;
    }
}

contract TextHarness is PageNFT {
    constructor(PageCard c) PageNFT(c) {}

    function formatEther(uint256 w) external pure returns (string memory) {
        return _formatEther(w);
    }

    function escape(string memory s) external pure returns (string memory) {
        return _escapeJSON(s);
    }
}

contract MutationHarnessTest is Test {
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    bytes32 constant ROOT = 0x62460c06d95b73747abf6ea4f28aefd78b4ad2abee112e7cf15fe6a924cca3c6;

    MainHarness h;
    CreditHarness c;
    TextHarness t;
    address alice = makeAddr("alice");

    function setUp() public {
        vm.warp(1_800_000_000);
        PageCard card = new PageCard();
        h = new MainHarness(card);
        c = new CreditHarness(card);
        t = new TextHarness(card);
        vm.deal(alice, 10 ether);
    }

    function _reg(address who, string memory label) internal returns (uint256 id) {
        bytes32 secret = keccak256(abi.encode(who, label));
        bytes32 hCommitment = h.makeCommitment(label, who, 0, secret);
        vm.prank(who);
        h.commit(hCommitment);
        vm.warp(block.timestamp + 61);
        (,,, uint256 total) = h.quote(label);
        vm.prank(who);
        id = h.reveal{value: total}(label, who, 0, secret);
    }

    // zero and this contract are credited to DEAD, any other account to itself, and nothing for no money
    function test_creditSanitizesHarness() public {
        assertEq(c.credit(address(c), 7), DEAD, "this contract");
        assertEq(c.owed(DEAD), 7);
        assertEq(c.owed(address(c)), 0);
        assertEq(c.credit(address(0), 5), DEAD, "zero");
        assertEq(c.owed(DEAD), 12);
        assertEq(c.owed(address(0)), 0);
        assertEq(c.credit(alice, 3), alice, "an account");
        assertEq(c.owed(alice), 3);
        assertEq(c.credit(alice, 0), address(0), "no money");
        assertEq(c.owed(alice), 3);
    }

    // a main address that is this contract makes DEAD the payee, while resolve still reads it
    function test_payeeOfThisContractIsDead() public {
        uint256 id = _reg(alice, "alice");
        vm.prank(alice);
        h.forceMain(id, address(h));
        assertEq(h.resolve(id), address(h));
        assertEq(h.payee(id), DEAD);
        vm.prank(alice);
        h.forceMain(id, alice);
        assertEq(h.payee(id), alice);
    }

    // every single byte: quote, backslash, tab, line feed and carriage return are escaped, other control bytes
    // dropped, and every byte from the space up kept as it is
    function test_escapeEveryByte() public view {
        for (uint256 b; b < 256; ++b) {
            bytes memory one = new bytes(1);
            one[0] = bytes1(uint8(b));
            bytes memory want;
            if (b == 0x22) want = bytes("\\\"");
            else if (b == 0x5c) want = bytes("\\\\");
            else if (b == 0x09) want = bytes("\\t");
            else if (b == 0x0a) want = bytes("\\n");
            else if (b == 0x0d) want = bytes("\\r");
            else if (b < 0x20) want = "";
            else want = one;
            assertEq(bytes(t.escape(string(one))), want, vm.toString(b));
        }
        assertEq(t.escape("a b"), "a b");
    }

    // ETH with up to four decimals, cut and not rounded, for amounts on either side of each unit
    function test_formatEtherEdges() public view {
        assertEq(t.formatEther(0), "0");
        assertEq(t.formatEther(1e14 - 1), "0");
        assertEq(t.formatEther(1e14), "0.0001");
        assertEq(t.formatEther(2e14 - 1), "0.0001");
        assertEq(t.formatEther(1e17), "0.1");
        assertEq(t.formatEther(1e18 - 1), "0.9999");
        assertEq(t.formatEther(1e18), "1");
        assertEq(t.formatEther(2e18 - 1), "1.9999");
        assertEq(t.formatEther(123456789e14), "12345.6789");
        assertEq(t.formatEther(5e18 + 1e15), "5.001");
    }
}

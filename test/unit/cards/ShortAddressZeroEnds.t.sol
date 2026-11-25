// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {Base64} from "solady/utils/Base64.sol";
import {LibString} from "solady/utils/LibString.sol";
import {PageNFT} from "../../../src/PageNFT.sol";
import {PageCard} from "../../../src/PageCard.sol";
import {CardReader} from "../../utils/CardReader.sol";

// An address whose first and last bytes are zero keeps every zero digit at both ends of its short form: 0x, its
// first 12 hex digits, the ellipsis and its last 6, in lower case, 23 bytes, which the metadata description prints.
// In the same way an id whose first and last bytes are zero keeps every zero digit at both ends of its code, the
// first 14 of its hex digits, the ellipsis and its last 6, which the right pill of the card shows.
contract ShortAddressZeroEndsTest is Test {
    PageCard card;
    PageNFT nft;
    CardReader reader;

    // one zero byte at each end, with letters next to both
    address constant ONE_ZERO = address(bytes20(hex"00abcdef0123456789abcdef0123456789abcd00"));
    // six zero bytes in front and three at the back, so both ends of the short form are all zero digits
    address constant ZERO_RUNS = address(bytes20(hex"000000000000abcdef0123456789abcdef000000"));
    // ids alike: one zero byte at each end, with letters next to both, and seven zero bytes in front and three at
    // the back, so both ends of the code are all zero digits
    bytes32 constant ID_ONE_ZERO = 0x00abcdef0123456789abcdef0123456789abcdef0123456789abcdef01abcd00;
    bytes32 constant ID_ZERO_RUNS = 0x00000000000000abcdef0123456789abcdef0123456789abcdef012345000000;

    address aliceW = makeAddr("alice wallet");

    function setUp() public {
        card = new PageCard();
        nft = new PageNFT(card);
        reader = new CardReader();
        vm.deal(aliceW, 10 ether);
    }

    function test_shortFormKeepsZeroBytesAtBothEnds() public view {
        string memory s = card.shortAddress(ONE_ZERO);
        assertEq(s, unicode"0x00abcdef0123…abcd00", "one zero byte at each end");
        assertEq(bytes(s).length, 23, "23 bytes");

        s = card.shortAddress(ZERO_RUNS);
        assertEq(s, unicode"0x000000000000…000000", "only zero digits at both ends");
        assertEq(bytes(s).length, 23, "23 bytes");
        // the digits between the two ends are not shown, so this address prints like the zero address
        assertEq(s, card.shortAddress(address(0)), "same short form as the zero address");
    }

    function test_codeKeepsZeroBytesAtBothEnds() public view {
        string memory svg = card.render("alice", "", ID_ONE_ZERO, PageCard.Status.Active, 0);
        assertEq(reader.read(svg).right, unicode"00abcdef012345…abcd00", "one zero byte at each end");
        svg = card.render("bob", "alice", ID_ZERO_RUNS, PageCard.Status.Expired, 0);
        CardReader.Card memory c = reader.read(svg);
        assertEq(c.right, unicode"00000000000000…000000", "only zero digits at both ends");
        // the digits between the two ends are not in the code, so it reads like the code of the zero id, while the
        // squares of digits 14 to 31 still tell the two apart
        CardReader.Card memory zero = reader.read(card.render("bob", "alice", bytes32(0), PageCard.Status.Expired, 0));
        assertEq(c.right, zero.right, "the code of the zero id");
        assertTrue(c.on[15] && !zero.on[15], "square 15, of the digit b");
    }

    function _secret(string memory label, address owner) internal pure returns (bytes32) {
        return keccak256(abi.encode(label, owner));
    }

    function _json(uint256 id) internal view returns (string memory) {
        return string(Base64.decode(LibString.slice(nft.tokenURI(id), 29)));
    }

    function _svg(string memory json) internal pure returns (string memory) {
        uint256 a = LibString.indexOf(json, "base64,") + 7;
        uint256 b = LibString.indexOf(json, '","attributes');
        return string(Base64.decode(LibString.slice(json, a, b)));
    }

    // saved as the main address of a name, each address is the payee the description prints, while the card keeps the
    // code of the id
    function test_zeroEndsInTheDescription() public {
        bytes32 c = nft.makeCommitment("alice", aliceW, 0, _secret("alice", aliceW));
        vm.prank(aliceW);
        nft.commit(c);
        vm.warp(vm.getBlockTimestamp() + 61);
        (,,, uint256 total) = nft.quote("alice");
        vm.prank(aliceW);
        uint256 id = nft.reveal{value: total}("alice", aliceW, 0, _secret("alice", aliceW));

        address[2] memory saved = [ONE_ZERO, ZERO_RUNS];
        string[2] memory short = [unicode"0x00abcdef0123…abcd00", unicode"0x000000000000…000000"];
        for (uint256 i; i < 2; ++i) {
            vm.prank(aliceW);
            nft.setAddr(id, saved[i]);
            assertEq(nft.payee(id), saved[i], "the saved address is the payee");
            string memory json = _json(id);
            assertTrue(
                LibString.contains(json, string.concat('"description":"Etherpage: alice (', short[i], ')"')),
                "the description"
            );
            assertEq(reader.read(_svg(json)).right, reader.code(bytes32(id)), "the right pill of the card");
        }
    }
}

// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {LibString} from "solady/utils/LibString.sol";
import {PageCard} from "../../../src/PageCard.sol";
import {RulesBase} from "../../utils/RulesBase.sol";
import {CardReader} from "../../utils/CardReader.sol";

// Three facts of the metadata read from real tokens. The Deposit attribute parses back to depositOf for any deposit
// a name can hold. A subpage's attributes are exactly Type and Status, in every state, while a top level name has its
// Length right before Expires. A name whose stored expiry is the largest uint64 still builds its tokenURI, with that
// expiry and its date on the card.
contract MetadataEdgesTest is RulesBase {
    string constant DEPOSIT_TRAIT = '{"trait_type":"Deposit","display_type":"number","value":';

    CardReader reader;

    function setUp() public override {
        super.setUp();
        reader = new CardReader();
    }

    // the text of the attributes array of id's JSON
    function _attributes(uint256 id) internal view returns (string memory) {
        string memory json = _json(id);
        uint256 a = LibString.indexOf(json, '"attributes":');
        assertTrue(a != LibString.NOT_FOUND, "the JSON has attributes");
        return LibString.slice(json, a + 13, bytes(json).length - 1);
    }

    // the Deposit value of id's metadata read back as wei: whole ether, then up to four decimals
    function _depositRead(uint256 id) internal view returns (uint256 amount) {
        string memory json = _json(id);
        uint256 a = LibString.indexOf(json, DEPOSIT_TRAIT);
        assertTrue(a != LibString.NOT_FOUND, "a top level name has a Deposit trait");
        bytes memory b = bytes(json);
        uint256 i = a + bytes(DEPOSIT_TRAIT).length;
        uint256 whole;
        for (; b[i] != "." && b[i] != "}"; ++i) whole = whole * 10 + (uint8(b[i]) - 48);
        uint256 frac;
        uint256 digits;
        if (b[i] == ".") {
            for (++i; b[i] != "}"; ++i) {
                frac = frac * 10 + (uint8(b[i]) - 48);
                ++digits;
            }
            assertGt(digits, 0, "a decimal point is followed by digits");
            assertLe(digits, 4, "at most four decimals");
            assertTrue(b[i - 1] != "0", "no trailing zero");
        }
        amount = whole * 1 ether + frac * 10 ** (18 - digits);
    }

    function testFuzz_depositAttributeReadsBackTheDeposit(uint8 lengthSeed, uint8 renewals, bool auction) public {
        string[6] memory labels = ["a", "ab", "abc", "abcd", "abcde", "abcdefgh"];
        string memory l = labels[lengthSeed % 6];
        uint256 id = _buy(bob, l);
        uint256 fee = nft.getFee(bytes(l).length);
        for (uint256 i; i < renewals % 10; ++i) {
            vm.prank(bob);
            nft.renew{value: fee}(id);
        }
        if (auction) {
            // at the last second of the auction a buyer takes over the deposit and adds its own fee
            vm.warp(nft.expiresAt(id) + 111 days - 61);
            _buy(carol, l);
        }
        uint256 deposit = nft.depositOf(id);
        assertEq(deposit % nft.getFee(5), 0, "every deposit is a whole number of the smallest fee");
        assertEq(deposit, (renewals % 10 + (auction ? 2 : 1)) * fee);
        assertEq(_depositRead(id), deposit, "the Deposit attribute is the deposit");

        // a release empties it, and the attribute reads 0
        vm.warp(nft.expiresAt(id) + 111 days + 1);
        nft.release(id);
        assertEq(_depositRead(id), 0);
    }

    // one second after the auction the old deposit goes back to its payee first, so the attribute is the new fee alone
    function test_depositAttributeAfterTheAuctionIsTheNewFee() public {
        uint256 id = _buy(bob, "abcde");
        uint256 fee = nft.getFee(5);
        vm.prank(bob);
        nft.renew{value: fee}(id);
        vm.warp(nft.expiresAt(id) + 111 days + 1 - 61);
        _buy(carol, "abcde");
        assertEq(nft.depositOf(id), fee);
        assertEq(nft.owed(bob), 2 * fee);
        assertEq(_depositRead(id), fee);
    }

    function test_subpageAttributesAreExactlyTypeAndStatus() public {
        uint256 parent = _buy(carol, "alpha");
        vm.prank(carol);
        uint256 sub = nft.registerSubpageFor("bob", parent, bob);
        string memory head = '[{"trait_type":"Type","value":"Subpage"},{"trait_type":"Status","value":"';
        string memory tail = '"}]';
        assertEq(_attributes(sub), string.concat(head, "Active", tail));
        // the parent has Length, Expires and Deposit, the subpage none of them
        assertTrue(
            LibString.contains(
                _attributes(parent),
                string.concat(
                    '[{"trait_type":"Type","value":"Page"},{"trait_type":"Status","value":"Active"},',
                    '{"trait_type":"Length","display_type":"number","value":5},{"trait_type":"Expires"'
                )
            ),
            "the parent has Length right before Expires"
        );
        uint256 t = nft.expiresAt(parent);
        vm.warp(t + 1);
        assertEq(_attributes(sub), string.concat(head, "Grace", tail));
        vm.warp(t + 90 days + 1);
        assertEq(_attributes(sub), string.concat(head, "Expired", tail));
        // the parent registered again leaves the subpage stale
        vm.warp(t + 111 days + 1);
        _buy(dave, "alpha");
        assertEq(_attributes(sub), string.concat(head, "Invalid", tail));
        // a deleted subpage of the new registration
        vm.prank(dave);
        uint256 again = nft.registerSubpageFor("bob", parent, dave);
        assertEq(again, sub);
        assertEq(_attributes(sub), string.concat(head, "Active", tail));
        vm.prank(dave);
        nft.transferFrom(dave, DEAD, sub);
        assertEq(_attributes(sub), string.concat(head, "Invalid", tail));
        // a 63 character subpage
        string memory long = "abcdefghijklmnopqrstuvwxyz0123456789abcdefghijklmnopqrstuvwxyz0";
        assertEq(bytes(long).length, 63);
        vm.prank(dave);
        uint256 longSub = nft.registerSubpage(long, parent);
        assertEq(_attributes(longSub), string.concat(head, "Active", tail), "no Length, whatever the label");
    }

    function test_tokenURIBuildsAtTheLargestStoredExpiry() public {
        vm.warp(uint256(type(uint64).max) - 365 days - 61);
        uint256 id = _buy(bob, "alpha");
        assertEq(nft.expiresAt(id), type(uint64).max, "the largest expiry a record can store");
        assertEq(uint256(nft.status(id)), uint256(PageCard.Status.Active));
        string memory json = _json(id);
        assertTrue(
            LibString.contains(json, '{"trait_type":"Expires","display_type":"date","value":18446744073709551615}'),
            "the Expires trait"
        );
        assertEq(reader.read(_svg(id)).left, "Until 9 Nov 584554051223", "the date on the card");
        assertEq(_metaStatus(id), "Active");
    }
}

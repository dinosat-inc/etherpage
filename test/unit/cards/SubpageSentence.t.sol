// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Base64} from "solady/utils/Base64.sol";
import {LibString} from "solady/utils/LibString.sol";
import {MinterBase} from "../../utils/MinterBase.sol";

// The description of every subpage ends with a sentence saying who it relies on. A top level page has no such sentence.
contract SubpageSentenceTest is MinterBase {
    function _description(uint256 id) internal view returns (string memory) {
        string memory json = string(Base64.decode(LibString.slice(nft.tokenURI(id), 29)));
        uint256 a = LibString.indexOf(json, '"description":"') + 15;
        uint256 b = LibString.indexOf(json, '","image"');
        return LibString.slice(json, a, b);
    }

    function _short(address a) internal view returns (string memory) {
        return card.shortAddress(a);
    }

    function test_topLevelPageHasNoSentence() public {
        uint256 shop = _reg(alice, "shop");
        assertEq(_description(shop), string.concat("Etherpage: shop (", _short(alice), ")"));
    }

    function test_subpageSaysWhoItReliesOn() public {
        uint256 shop = _reg(alice, "shop");
        vm.prank(alice);
        uint256 pay = nft.registerSubpageFor("pay", shop, bob);
        assertEq(
            _description(pay),
            string.concat("Etherpage: pay.shop (", _short(bob), "). This subpage relies on shop's holder, who can take it away.")
        );
    }

    // the sentence stays when the dead address holds the parent, and when the subpage is from an earlier registration
    function test_sentenceStaysInEveryState() public {
        uint256 shop = _reg(alice, "shop");
        vm.prank(alice);
        uint256 pay = nft.registerSubpageFor("pay", shop, bob);
        string memory tail = "). This subpage relies on shop's holder, who can take it away.";

        vm.prank(alice);
        nft.transferFrom(alice, DEAD, shop);
        assertTrue(LibString.endsWith(_description(pay), tail), "parent held by the dead address");

        _lapseAndRegister(shop, carol);
        assertTrue(LibString.endsWith(_description(pay), tail), "subpage from an earlier registration");
    }

    // a label of a to z, 0 to 9 and the hyphen that the contract accepts
    function _label(uint256 seed, uint256 len) internal pure returns (string memory) {
        bytes memory chars = "abcdefghijklmnopqrstuvwxyz0123456789-";
        bytes memory out = new bytes(len);
        for (uint256 i; i < len; ++i) {
            out[i] = chars[uint256(keccak256(abi.encode(seed, i))) % (i == 0 || i == len - 1 ? 36 : 37)];
        }
        if (len >= 4 && out[2] == "-" && out[3] == "-") out[3] = "a";
        if (len == 42 && out[0] == "0" && out[1] == "x") out[1] = "y";
        return string(out);
    }

    // for any pair of labels the metadata is valid JSON whose description ends with the sentence, also once the
    // subpage is Expired
    function testFuzz_metadataParsesWithTheSentence(uint256 seed, uint8 parentLength, uint8 subLength) public {
        string memory parentLabel = _label(seed, bound(parentLength, 5, 63));
        string memory subLabel = _label(uint256(keccak256(abi.encode(seed))), bound(subLength, 1, 63));
        uint256 parent = _reg(alice, parentLabel);
        vm.prank(alice);
        uint256 sub = nft.registerSubpageFor(subLabel, parent, bob);
        string memory want = string.concat(
            "Etherpage: ", subLabel, ".", parentLabel, " (", _short(bob), "). This subpage relies on ", parentLabel,
            "'s holder, who can take it away."
        );
        string memory json = string(Base64.decode(LibString.slice(nft.tokenURI(sub), 29)));
        assertEq(vm.parseJsonString(json, ".name"), string.concat(subLabel, ".", parentLabel));
        assertEq(vm.parseJsonString(json, ".description"), want);

        vm.warp(nft.expiresAt(parent) + 91 days);
        json = string(Base64.decode(LibString.slice(nft.tokenURI(sub), 29)));
        assertEq(vm.parseJsonString(json, ".attributes[1].value"), "Expired");
        assertEq(vm.parseJsonString(json, ".description"), want);
    }

    function test_labelsWithHyphensAndDigits() public {
        uint256 shop = _reg(alice, "my-shop-2");
        vm.prank(alice);
        uint256 pay = nft.registerSubpageFor("pay-1", shop, bob);
        assertTrue(
            LibString.endsWith(_description(pay), "). This subpage relies on my-shop-2's holder, who can take it away."),
            _description(pay)
        );
    }
}

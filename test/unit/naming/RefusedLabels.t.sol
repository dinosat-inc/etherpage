// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {PageNFT} from "../../../src/PageNFT.sol";
import {SubpageRegistrar} from "../../../src/SubpageRegistrar.sol";
import {MinterBase} from "../../utils/MinterBase.sol";
import {trialCommitmentRaw} from "../../utils/TrialCommitment.sol";

// A label the rule refuses is refused on every path a label can take, with the same error: InvalidLength outside 1
// to 63 bytes and InvalidLabel otherwise, NotAvailable on the registrar's direct path, zeros from quote and false from
// isAvailable. A commitment built by hand over its lowercased bytes does not help, as the label is checked first.
contract RefusedLabelsTest is MinterBase {
    uint256 club;
    uint256 shop;

    function setUp() public override {
        super.setUp();
        club = _reg(alice, "club");
        shop = _reg(bob, "shop");
        _sellSetup(shop, 0);
    }

    function _refused() internal pure returns (bytes[] memory l) {
        l = new bytes[](20);
        l[0] = "";
        l[1] = bytes("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
        l[2] = "a_b";
        l[3] = "$eth";
        l[4] = "my@eth";
        l[5] = "a.b";
        l[6] = "a b";
        l[7] = hex"09";
        l[8] = hex"7f";
        l[9] = hex"636166c3a9";
        l[10] = hex"f09f9a80";
        l[11] = hex"61e2808b62";
        l[12] = hex"616263e280ae";
        l[13] = "-ab";
        l[14] = "ab-";
        l[15] = "ci--ao";
        l[16] = "xn--abc";
        l[17] = "0xd8da6bf26964af9d7eed9e03e53415d37aa96045";
        l[18] = "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045";
        l[19] = "0XD8DA6BF26964AF9D7EED9E03E53415D37AA96045";
    }

    function _lower(bytes memory b) internal pure returns (bytes memory out) {
        out = new bytes(b.length);
        for (uint256 i; i < b.length; ++i) out[i] = (b[i] >= "A" && b[i] <= "Z") ? bytes1(uint8(b[i]) + 32) : b[i];
    }

    function test_refusedLabelsOnEveryPath() public {
        bytes[] memory labels = _refused();
        bytes32 secret = keccak256("by hand");
        // commitments over the lowercased bytes made without makeCommitment, for both reveal forms, aged past the
        // minimum
        // the three spellings of the address lowercase to the same bytes, so each commitment is made once
        for (uint256 i; i < labels.length; ++i) {
            bytes memory low = _lower(labels[i]);
            bytes32[2] memory paid = [
                keccak256(abi.encode(low, carol, uint256(0), secret)),
                trialCommitmentRaw(string(labels[i]), carol, 0, secret)
            ];
            for (uint256 k; k < 2; ++k) {
                if (nft.commitments(paid[k]) != 0) continue;
                vm.prank(carol);
                nft.commit(paid[k]);
            }
            bytes32[2] memory sub = [
                keccak256(abi.encode(shop, string(low), buyer, secret)),
                keccak256(abi.encode(shop, string(low), carol, secret))
            ];
            for (uint256 k; k < 2; ++k) {
                if (reg.subCommitments(sub[k]) == 0) reg.commitSubpage(sub[k]);
            }
        }
        vm.warp(vm.getBlockTimestamp() + 61);

        for (uint256 i; i < labels.length; ++i) {
            string memory s = string(labels[i]);
            bytes4 err = labels[i].length == 0 || labels[i].length > 63
                ? PageNFT.InvalidLength.selector
                : PageNFT.InvalidLabel.selector;
            string memory which = string.concat("label ", vm.toString(i));

            // the view paths
            vm.expectRevert(err);
            nft.normalize(s);
            (uint256 fee, uint256 carried, uint256 premium, uint256 total) = nft.quote(s);
            assertEq(fee + carried + premium + total, 0, which);
            assertFalse(nft.isAvailable(s, 0), which);
            assertFalse(nft.isAvailable(s, club), which);
            vm.expectRevert(err);
            nft.makeCommitment(s, carol, 0, secret);
            vm.expectRevert(err);
            reg.makeSubpageCommitment(shop, s, carol, secret);

            // the reveal paths of PageNFT, with the commitment in place and more than enough paid
            vm.prank(carol);
            vm.expectRevert(err);
            nft.reveal{value: 1 ether}(s, carol, 0, secret);
            vm.prank(carol);
            vm.expectRevert(err);
            nft.revealTrial{value: 1 ether}(s, carol, 0, secret);

            // the subpage mints of PageNFT
            vm.prank(alice);
            vm.expectRevert(err);
            nft.registerSubpage(s, club);
            vm.prank(alice);
            vm.expectRevert(err);
            nft.registerSubpageFor(s, club, carol);

            // the registrar: its direct paths find the label unavailable, its reveal paths normalize it first
            vm.prank(buyer);
            vm.expectRevert(SubpageRegistrar.NotAvailable.selector);
            reg.registerSubpage(shop, s, 0, address(0));
            vm.prank(buyer);
            vm.expectRevert(SubpageRegistrar.NotAvailable.selector);
            reg.registerSubpageFor(shop, s, carol, 0, address(0));
            vm.prank(buyer);
            vm.expectRevert(err);
            reg.revealSubpage(shop, s, secret, 0, address(0));
            vm.prank(buyer);
            vm.expectRevert(err);
            reg.revealSubpageFor(shop, s, carol, secret, 0, address(0));
        }
    }
}

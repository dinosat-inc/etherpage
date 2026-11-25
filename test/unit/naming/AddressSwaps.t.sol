// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {PageNFT} from "../../../src/PageNFT.sol";
import {SubpageRegistrar} from "../../../src/SubpageRegistrar.sol";
import {MinterBase} from "../../utils/MinterBase.sol";

// An address written with one character that is not a hex digit is no longer an address, so it is an ordinary label:
// each letter g to z, in either case, at any of the 40 places after 0x, in the lower, checksum and upper forms of an
// address, the near misses l for 1, o for 0 and s for 5, and a hyphen at any place after 0x but the last.
contract AddressSwapsTest is MinterBase {
    bytes constant LOWER = "0xd8da6bf26964af9d7eed9e03e53415d37aa96045";
    bytes constant CHECKSUM = "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045";
    bytes constant UPPER = "0XD8DA6BF26964AF9D7EED9E03E53415D37AA96045";
    uint256 constant FEE = 0.0001 ether;

    uint256 club;

    function setUp() public override {
        super.setUp();
        club = _reg(alice, "club");
    }

    function _forms() internal pure returns (bytes[3] memory) {
        return [LOWER, CHECKSUM, UPPER];
    }

    function _lower(bytes memory b) internal pure returns (bytes memory out) {
        out = new bytes(b.length);
        for (uint256 i; i < b.length; ++i) out[i] = (b[i] >= "A" && b[i] <= "Z") ? bytes1(uint8(b[i]) + 32) : b[i];
    }

    function _swap(bytes memory form, uint256 place, bytes1 c) internal pure returns (bytes memory b) {
        b = bytes.concat(form);
        b[place] = c;
    }

    // every view path takes the label and answers for the lowercased bytes
    function _viewAccepts(bytes memory l) internal view {
        string memory s = string(l);
        bytes memory low = _lower(l);
        assertEq(nft.normalize(s), string(low), s);
        (uint256 fee,,, uint256 total) = nft.quote(s);
        assertEq(fee, FEE, s);
        assertEq(total, FEE, s);
        assertTrue(nft.isAvailable(s, 0), s);
        assertTrue(nft.isAvailable(s, club), s);
        assertEq(nft.makeCommitment(s, alice, 0, bytes32(0)), keccak256(abi.encode(low, alice, uint256(0), bytes32(0))), s);
        assertEq(
            reg.makeSubpageCommitment(club, s, alice, bytes32(0)),
            keccak256(abi.encode(club, string(low), alice, bytes32(0))),
            s
        );
    }

    // each of the 20 letters g to z, lower and upper, at each of the 40 places: 1600 labels per form, all accepted on
    // every view path; the forms themselves, and a hex digit in place of a letter, are refused
    function test_oneLetterSwapAccepted() public view {
        bytes[3] memory forms = _forms();
        uint256 n;
        for (uint256 f; f < 3; ++f) {
            assertFalse(nft.isAvailable(string(forms[f]), 0), "the address itself is refused");
            for (uint256 place = 2; place < 42; ++place) {
                for (uint8 letter = 0; letter < 20; ++letter) {
                    _viewAccepts(_swap(forms[f], place, bytes1(0x67 + letter)));
                    _viewAccepts(_swap(forms[f], place, bytes1(0x47 + letter)));
                    n += 2;
                }
                // a hex digit in the same place keeps it an address
                assertFalse(nft.isAvailable(string(_swap(forms[f], place, "f")), 0));
            }
        }
        assertEq(n, 4800);
    }

    // l for 1, o for 0 and s for 5, and a hyphen at any one place after 0x but the last, are accepted on
    // every view path; a hyphen in the last place is refused
    function test_nearMissesAndHyphensAccepted() public {
        bytes[3] memory forms = _forms();
        bytes1[3] memory digit = [bytes1("1"), "0", "5"];
        bytes1[3] memory look = [bytes1("l"), "o", "s"];
        for (uint256 f; f < 3; ++f) {
            for (uint256 k; k < 3; ++k) {
                uint256 swaps;
                for (uint256 place = 2; place < 42; ++place) {
                    if (forms[f][place] != digit[k]) continue;
                    _viewAccepts(_swap(forms[f], place, look[k]));
                    ++swaps;
                }
                assertGt(swaps, 0, "the address has that digit");
            }
            for (uint256 place = 2; place < 41; ++place) _viewAccepts(_swap(forms[f], place, "-"));
            bytes memory last = _swap(forms[f], 41, "-");
            vm.expectRevert(PageNFT.InvalidLabel.selector);
            nft.normalize(string(last));
            assertFalse(nft.isAvailable(string(last), 0));
        }
    }

    // a label per letter, case and form, at places spread over the 40, goes through every write path but
    // revealTrial, and each one stores it in lower case under the id of the lowercased bytes; afterwards
    // neither the spelling used nor the lower case is free
    function test_oneLetterSwapAcceptedOnEveryWritePath() public {
        uint256[6] memory parents;
        string[6] memory names = ["pone", "ptwo", "pthree", "pfour", "pfive", "psix"];
        for (uint256 i; i < 6; ++i) parents[i] = _reg(alice, names[i]);
        for (uint256 i = 2; i < 6; ++i) {
            _setMinter(parents[i], address(reg));
            _configure(parents[i], payout, address(0), 0, false);
        }
        bytes[3] memory forms = _forms();
        bytes[] memory labels = new bytes[](120);
        for (uint256 f; f < 3; ++f) {
            for (uint256 letter; letter < 20; ++letter) {
                for (uint256 c; c < 2; ++c) {
                    uint256 place = 2 + (letter * 7 + f * 13 + c * 3) % 40;
                    labels[f * 40 + letter * 2 + c] = _swap(forms[f], place, bytes1(uint8((c == 0 ? 0x67 : 0x47) + letter)));
                }
            }
        }
        bytes32 secret = keccak256("swap");
        for (uint256 i; i < labels.length; ++i) {
            string memory s = string(labels[i]);
            bytes32 c = nft.makeCommitment(s, bob, 0, secret);
            vm.prank(bob);
            nft.commit(c);
            reg.commitSubpage(reg.makeSubpageCommitment(parents[4], s, buyer, secret));
            reg.commitSubpage(reg.makeSubpageCommitment(parents[5], s, carol, secret));
        }
        vm.warp(vm.getBlockTimestamp() + 61);
        for (uint256 i; i < labels.length; ++i) {
            string memory s = string(labels[i]);
            bytes memory low = _lower(labels[i]);
            uint256[7] memory ids;
            vm.prank(bob);
            ids[0] = nft.reveal{value: FEE}(s, bob, 0, secret);
            vm.prank(alice);
            ids[1] = nft.registerSubpage(s, parents[0]);
            vm.prank(alice);
            ids[2] = nft.registerSubpageFor(s, parents[1], carol);
            vm.prank(buyer);
            ids[3] = reg.registerSubpage(parents[2], s, 0, address(0));
            vm.prank(buyer);
            ids[4] = reg.registerSubpageFor(parents[3], s, carol, 0, address(0));
            vm.prank(buyer);
            ids[5] = reg.revealSubpage(parents[4], s, secret, 0, address(0));
            vm.prank(buyer);
            ids[6] = reg.revealSubpageFor(parents[5], s, carol, secret, 0, address(0));
            assertEq(ids[0], _id(string(low)), s);
            (string memory stored,,,,) = nft.records(ids[0]);
            assertEq(stored, string(low), s);
            assertEq(nft.getPageName(ids[0]), string(low));
            assertFalse(nft.isAvailable(s, 0));
            assertFalse(nft.isAvailable(string(low), 0));
            for (uint256 p; p < 6; ++p) {
                assertEq(ids[p + 1], _subId(string(low), parents[p]), s);
                (stored,,,,) = nft.records(ids[p + 1]);
                assertEq(stored, string(low), s);
                assertEq(nft.getPageName(ids[p + 1]), string.concat(string(low), ".", names[p]));
                assertFalse(nft.isAvailable(s, parents[p]));
                assertFalse(nft.isAvailable(string(low), parents[p]));
            }
        }
    }
}

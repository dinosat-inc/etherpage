// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {PageNFT} from "../../../src/PageNFT.sol";
import {LabelPathsBase} from "../../utils/LabelPathsBase.sol";

// The label rule on all fourteen paths a label can take: one byte labels, every length, the hyphen and
// address examples, accepted look alikes, and the case spellings of one name.
contract LabelPathsTest is LabelPathsBase {
    bytes constant HEX_LOWER = "0123456789abcdef";
    bytes constant HEX_UPPER = "0123456789ABCDEF";
    bytes constant HEX_MIXED = "0123456789aBcDeF";

    function _list(string[] memory ls) internal pure returns (bytes[] memory raws) {
        raws = new bytes[](ls.length);
        for (uint256 i; i < ls.length; ++i) raws[i] = bytes(ls[i]);
    }

    // n characters cycling through one of the hex alphabets
    function _hex(bytes memory alphabet, uint256 n) internal pure returns (bytes memory b) {
        b = new bytes(n);
        for (uint256 i; i < n; ++i) b[i] = alphabet[(i * 7 + 3) % 16];
    }

    // each of the 256 byte values as a one byte label: the 62 letters and digits are accepted, upper case
    // stored in lower case, and the other 194, the hyphen among them, are refused on every path, with
    // InvalidLabel, except NotAvailable on the registrar's direct paths, zeros from quote and false from
    // isAvailable
    function test_everyByteAlone() public {
        bytes[] memory raws = new bytes[](256);
        for (uint256 b; b < 256; ++b) raws[b] = abi.encodePacked(bytes1(uint8(b)));
        _prepare(raws);
        uint256 accepted;
        for (uint256 b; b < 256; ++b) {
            bool alnum = (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5a) || (b >= 0x61 && b <= 0x7a);
            uint8 want = alnum ? OK : BAD_NAME;
            (uint8 model,) = _model(raws[b]);
            assertEq(model, want, "the model agrees");
            if (alnum) ++accepted;
            _everyPath(raws[b], want);
        }
        assertEq(accepted, 62);
    }

    // a and A repeated 0 to 64, 255 and 256 times: accepted exactly from 1 to 63 and refused otherwise on
    // every path, with InvalidLength, except NotAvailable on the registrar's direct paths, zeros from quote
    // and false from isAvailable. On the view paths, dollar signs, 0xff bytes and hex digits after 0x are
    // refused the same way at those lengths before any byte is read, and with InvalidLabel at 1 to 63
    // wherever the rule refuses them. The lengths above 63 are priced as the default fee, and no path
    // charges them.
    function test_everyLength() public {
        uint256[] memory lens = new uint256[](67);
        for (uint256 i; i < 65; ++i) lens[i] = i;
        lens[65] = 255;
        lens[66] = 256;
        bytes[] memory raws = new bytes[](2 * lens.length);
        for (uint256 i; i < lens.length; ++i) {
            raws[2 * i] = _rep("a", lens[i]);
            raws[2 * i + 1] = _rep("A", lens[i]);
        }
        _prepare(raws);
        for (uint256 i; i < raws.length; ++i) {
            uint256 n = raws[i].length;
            uint8 want = n >= 1 && n <= 63 ? OK : BAD_LENGTH;
            (uint8 model,) = _model(raws[i]);
            assertEq(model, want, "the model agrees");
            _everyPath(raws[i], want);
        }
        for (uint256 i; i < lens.length; ++i) {
            uint256 n = lens[i];
            bool inRange = n >= 1 && n <= 63;
            bytes memory dollars = _rep("$", n);
            bytes memory high = _rep(0xff, n);
            bytes memory hexes = n < 2 ? _rep("0", n) : bytes.concat("0x", _hex(HEX_LOWER, n - 2));
            _viewPaths(dollars, inRange ? BAD_NAME : BAD_LENGTH);
            _viewPaths(high, inRange ? BAD_NAME : BAD_LENGTH);
            uint8 hexWant = !inRange ? BAD_LENGTH : n == 42 ? BAD_NAME : OK;
            (uint8 model,) = _model(hexes);
            assertEq(model, hexWant, "the model agrees on 0x and hex digits");
            _viewPaths(hexes, hexWant);
        }
        assertEq(nft.getFee(0), 0.0001 ether);
        assertEq(nft.getFee(64), 0.0001 ether);
        assertEq(nft.getFee(255), 0.0001 ether);
        assertEq(nft.getFee(0), nft.getFee(5), "the default tier");
    }

    // both the 3rd and 4th characters a hyphen, or a hyphen first or last, is refused; other hyphens are
    // kept as they are, as a top level name and as a subpage, on every path
    function test_hyphenExamples() public {
        string[10] memory bad = ["ci--ao", "ab--c", "a---b", "xn--abc", "XN--ABC", "xn--80ak6aa92e", "-ciao", "ciao-", "-", "--"];
        string[6] memory good = ["ciia--o", "a--b", "bob--alice", "ab-c", "abc-d", "a-b-c"];
        bytes[] memory raws = new bytes[](16);
        for (uint256 i; i < 10; ++i) raws[i] = bytes(bad[i]);
        for (uint256 i; i < 6; ++i) raws[10 + i] = bytes(good[i]);
        _prepare(raws);
        for (uint256 i; i < 16; ++i) {
            uint8 want = i < 10 ? BAD_NAME : OK;
            (uint8 model,) = _model(raws[i]);
            assertEq(model, want, "the model agrees");
            _everyPath(raws[i], want);
        }
    }

    // labels in lower, upper and mixed case are accepted on every path and stored in lower case under the id
    // of the lowered bytes, and the spellings as given, in lower case and in upper case give the same ids and
    // the same commitments
    function test_acceptedLabelsOnEveryPath() public {
        bytes memory a9 = new bytes(63);
        for (uint256 i; i < 63; ++i) a9[i] = i % 2 == 0 ? bytes1("A") : bytes1("9");
        bytes[] memory raws = new bytes[](8);
        raws[0] = "Bob-9";
        raws[1] = "a--b";
        raws[2] = "ciia--o";
        raws[3] = "0XDead";
        raws[4] = "0xalice";
        raws[5] = bytes.concat("0x", _hex(HEX_MIXED, 41));
        raws[6] = "0xd8da6bf26964af9d7eed9e03e53415d37aa9604g";
        raws[7] = a9;
        _prepare(raws);
        for (uint256 i; i < raws.length; ++i) {
            (uint8 model,) = _model(raws[i]);
            assertEq(model, OK, "the model accepts");
            _everyPath(raws[i], OK);
            bytes memory low = _lower(raws[i]);
            bytes[3] memory spellings = [raws[i], low, _upper(raws[i])];
            for (uint256 k; k < 3; ++k) {
                string memory s = string(spellings[k]);
                assertEq(nft.computeId(s), _topId(low), "one id for every spelling");
                assertEq(nft.computeId(string.concat(s, ".", CLUB)), _subId(club, low), "one subpage id for every spelling");
                assertEq(nft.makeCommitment(s, owner, 0, SECRET), _paidCommitment(low), "one commitment for every spelling");
                assertEq(
                    reg.makeSubpageCommitment(shop, s, owner, SECRET), _subCommitment(low, owner),
                    "one subpage commitment for every spelling"
                );
            }
        }
    }

    // plain look alikes and address look alikes are ordinary labels on every path
    function test_lookAlikesAccepted() public {
        string[] memory ls = new string[](8);
        ls[0] = "paypa1";
        ls[1] = "g00gle";
        ls[2] = "rnicrosoft";
        ls[3] = "paypal-support";
        ls[4] = "vitalik-eth";
        ls[5] = "d8da6bf26964af9d7eed9e03e53415d37aa96045";
        ls[6] = "bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq";
        ls[7] = "1234567890123456789012345678901234567890123";
        bytes[] memory raws = _list(ls);
        _prepare(raws);
        for (uint256 i; i < raws.length; ++i) {
            (uint8 model,) = _model(raws[i]);
            assertEq(model, OK, "the model accepts");
            _everyPath(raws[i], OK);
        }
    }

    // 0x or 0X and 0 to 62 hex digits in lower, upper and mixed case, on every path: refused with 40 digits
    // as an address and with 62 as too long, and accepted with every other count, 41 among them
    function test_addressLengthsAndPrefixes() public {
        bytes[3] memory alphabets = [HEX_LOWER, HEX_UPPER, HEX_MIXED];
        bytes[2] memory prefixes = [bytes("0x"), bytes("0X")];
        bytes[] memory raws = new bytes[](2 * 3 * 63);
        uint256 k;
        for (uint256 p; p < 2; ++p) {
            for (uint256 a; a < 3; ++a) {
                for (uint256 n; n <= 62; ++n) raws[k++] = bytes.concat(prefixes[p], _hex(alphabets[a], n));
            }
        }
        _prepare(raws);
        for (uint256 i; i < raws.length; ++i) {
            uint256 n = raws[i].length - 2;
            uint8 want = n == 40 ? BAD_NAME : n == 62 ? BAD_LENGTH : OK;
            (uint8 model,) = _model(raws[i]);
            assertEq(model, want, "the model agrees");
            _everyPath(raws[i], want);
        }
    }

    // short 0x labels, the 40 digits alone or after another prefix, and an address with one letter or digit
    // more before or after it are accepted; the digits after -x are refused for the leading hyphen
    function test_addressPrefixNeighbours() public {
        string memory digits = "d8da6bf26964af9d7eed9e03e53415d37aa96045";
        string[] memory ls = new string[](18);
        ls[0] = "0x";
        ls[1] = "0X";
        ls[2] = "0xalice";
        ls[3] = "0xdead";
        ls[4] = "0XDEAD";
        ls[5] = digits;
        ls[6] = string.concat("ox", digits);
        ls[7] = string.concat("Ox", digits);
        ls[8] = string.concat("OX", digits);
        ls[9] = string.concat("00", digits);
        ls[10] = string.concat("x0", digits);
        ls[11] = string.concat("0y", digits);
        ls[12] = string.concat("0-", digits);
        ls[13] = string.concat("a0x", digits);
        ls[14] = string.concat("70x", digits);
        ls[15] = string.concat("0x", digits, "a");
        ls[16] = string.concat("0x", digits, "1");
        ls[17] = string.concat("-x", digits);
        bytes[] memory raws = _list(ls);
        _prepare(raws);
        for (uint256 i; i < raws.length; ++i) {
            uint8 want = i == 17 ? BAD_NAME : OK;
            (uint8 model,) = _model(raws[i]);
            assertEq(model, want, "the model agrees");
            _everyPath(raws[i], want);
        }
        // 0XDEAD is the name 0xdead
        vm.revertToState(snap);
        _writePath(bytes("0XDEAD"), OK, 0);
        assertEq(nft.getPageName(_topId("0xdead")), "0xdead");
    }

    // after Mixed-Case9 is registered every spelling of it is taken, computeId of any spelling is its id,
    // and another account's reveal of MIXED-CASE9, paid in full, is refused as taken
    function test_caseSpellingsAreOneName() public {
        bytes32 first = nft.makeCommitment("Mixed-Case9", holder, 0, SECRET);
        vm.prank(holder);
        nft.commit(first);
        vm.warp(vm.getBlockTimestamp() + 61);
        (,,, uint256 total) = nft.quote("Mixed-Case9");
        vm.prank(holder);
        uint256 id = nft.reveal{value: total}("Mixed-Case9", holder, 0, SECRET);
        assertEq(id, _topId("mixed-case9"));
        assertEq(nft.getPageName(id), "mixed-case9");
        assertFalse(nft.isAvailable("mixed-case9", 0));
        assertFalse(nft.isAvailable("MIXED-case9", 0));
        assertFalse(nft.isAvailable("Mixed-Case9", 0));
        assertEq(nft.computeId("MIXED-CASE9"), id);
        bytes32 c = nft.makeCommitment("MIXED-CASE9", buyer, 0, SECRET);
        assertEq(c, nft.makeCommitment("mixed-case9", buyer, 0, SECRET));
        vm.prank(buyer);
        nft.commit(c);
        vm.warp(vm.getBlockTimestamp() + 61);
        // the reveal price includes the deposit of the live name, so paying fee and deposit passes the price
        // check, and the reveal then reverts AlreadyRegistered
        uint256 price = nft.getFee(11) + nft.depositOf(id);
        vm.prank(buyer);
        vm.expectRevert(PageNFT.AlreadyRegistered.selector);
        nft.reveal{value: price}("MIXED-CASE9", buyer, 0, SECRET);
        assertEq(nft.ownerOf(id), holder);
    }

    // computeNamehash and computeId give an id for labels the validator refuses, which normalize and
    // isAvailable refuse, so an id is no evidence that a label can be registered
    function test_computeNamehashIsPermissive() public view {
        bytes[3] memory raws = [bytes("a_b"), _rep("a", 64), bytes.concat("0x", _hex(HEX_LOWER, 40))];
        uint8[3] memory errs = [BAD_NAME, BAD_LENGTH, BAD_NAME];
        for (uint256 i; i < 3; ++i) {
            string memory s = string(raws[i]);
            bytes32 node = nft.computeNamehash(s);
            assertEq(node, keccak256(abi.encodePacked(ROOT, keccak256(_lower(raws[i])))), "the plain namehash");
            assertTrue(node != bytes32(0));
            assertEq(nft.computeId(s), uint256(node));
            assertEq(nft.computeId(string.concat(s, ".", CLUB)), _subId(club, _lower(raws[i])), "as a subpage too");
            (bool ok, bytes memory ret) = address(nft).staticcall(abi.encodeCall(PageNFT.normalize, (s)));
            _assertReverted(ok, ret, _err(errs[i]), "normalize refuses it");
            assertFalse(nft.isAvailable(s, 0));
            assertFalse(nft.isAvailable(s, club));
        }
    }
}

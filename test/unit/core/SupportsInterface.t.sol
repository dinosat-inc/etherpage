// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {PageNFT} from "../../../src/PageNFT.sol";
import {PageCard} from "../../../src/PageCard.sol";

// each resolver interface as its standard declares it, so its id is computed and not copied
interface IAddrById {
    function addr(bytes32 node) external view returns (address payable);
}

interface IAddrByCoin {
    function addr(bytes32 node, uint256 coinType) external view returns (bytes memory);
}

interface ITextRecord {
    function text(bytes32 node, string calldata key) external view returns (string memory);
}

interface IContenthashRecord {
    function contenthash(bytes32 node) external view returns (bytes memory);
}

interface IDataRecord {
    function data(bytes32 node, string calldata key) external view returns (bytes memory);
}

// supportsInterface is true for exactly nine ids, and each resolver id among them is a function that answers a
// plain static call with the return type its interface defines
contract SupportsInterfaceTest is Test {
    PageNFT nft;
    address holder = makeAddr("holder");

    bytes4[9] declared = [
        bytes4(0x01ffc9a7), // ERC165
        0x80ac58cd, // ERC721
        0x5b5e139f, // ERC721 metadata
        0x49064906, // ERC4906
        0x3b3b57de, // addr(bytes32)
        0xf1cb7e06, // addr(bytes32,uint256)
        0x59d1d43c, // text(bytes32,string)
        0xbc1c58d1, // contenthash(bytes32)
        0xecbfada3 // data(bytes32,string)
    ];

    function setUp() public {
        vm.warp(1_800_000_000);
        nft = new PageNFT(new PageCard());
        vm.deal(holder, 1 ether);
    }

    function _isDeclared(bytes4 id) internal view returns (bool) {
        for (uint256 i; i < 9; ++i) {
            if (declared[i] == id) return true;
        }
        return false;
    }

    function test_supportsInterfaceExactSet() public view {
        for (uint256 i; i < 9; ++i) assertTrue(nft.supportsInterface(declared[i]), "declared");
        bytes4[19] memory no = [
            bytes4(0xd700ff33), // recordVersions(bytes32), the versionable resolver
            0x9061b923, // resolve(bytes,bytes), the extended resolver
            0xffffffff, // never true under ERC165
            0x00000000,
            0x691f3431, // name(bytes32)
            0x2203ab56, // ABI(bytes32,uint256)
            0xc8690233, // pubkey(bytes32)
            0x124a319c, // interfaceImplementer(bytes32,bytes4)
            0xa8fa5682, // dnsRecord(bytes32,bytes32,uint16)
            0x5c98042b, // zonehash(bytes32)
            0x2dff6941, // content(bytes32)
            0x4fbf0433, // the resolver multicall interface
            0xac9650d8, // multicall(bytes[]), which PageNFT has but does not announce
            0x780e9d63, // ERC721 enumerable
            0xd9b67a26, // ERC1155
            0x2a55205a, // ERC2981
            0xb45a3c0e, // ERC5192
            0x150b7a02, // ERC721 receiver
            0x1626ba7e // ERC1271
        ];
        for (uint256 i; i < no.length; ++i) assertFalse(nft.supportsInterface(no[i]), "not declared");
    }

    function _check(uint256 c, bytes4[9] memory ids, bool[9] memory seen) internal view {
        bytes4 id = bytes4(uint32(c));
        bool want;
        for (uint256 k; k < 9; ++k) {
            if (ids[k] == id) {
                want = true;
                seen[k] = true;
            }
        }
        assertEq(nft.supportsInterface(id), want, "only the declared ids");
    }

    // An id the code compares against is in the code either as four bytes in a row, or as a shorter push that is
    // shifted left, which is how the compiler writes a constant that ends in zero bits. Every window of four bytes
    // of the deployed code is tried, and every push of up to four bytes at every shift that keeps it within four
    // bytes.
    function test_noOtherIdInTheCodeIsSupported() public view {
        bytes memory code = address(nft).code;
        bytes4[9] memory ids = declared;
        bool[9] memory seen;
        for (uint256 i; i + 4 <= code.length; ++i) {
            uint256 w;
            assembly ("memory-safe") {
                w := shr(224, mload(add(add(code, 0x20), i)))
            }
            _check(w, ids, seen);
        }
        // pushes of one or two bytes repeat, so each value is tried once
        uint256[] memory done = new uint256[](256);
        for (uint256 i; i < code.length;) {
            uint256 op = uint8(code[i]);
            if (op < 0x60 || op > 0x7f) {
                ++i;
                continue;
            }
            uint256 n = op - 0x5f;
            if (n <= 4 && i + n < code.length) {
                uint256 v;
                for (uint256 k; k < n; ++k) v = v << 8 | uint8(code[i + 1 + k]);
                bool fresh = true;
                if (n <= 2) {
                    fresh = ((done[v >> 8] >> (v & 0xff)) & 1) == 0;
                    done[v >> 8] |= 1 << (v & 0xff);
                }
                if (fresh && v != 0) {
                    for (uint256 c = v; c <= 0xffffffff; c <<= 1) _check(c, ids, seen);
                }
            }
            i += 1 + n;
        }
        // the scan meets every declared id
        for (uint256 k; k < 9; ++k) assertTrue(seen[k], "declared id found in the code");
    }

    // the five resolver ids are the ids of the interfaces their standards declare
    function test_resolverIdsAreComputedFromTheirInterfaces() public pure {
        assertEq(type(IAddrById).interfaceId, bytes4(0x3b3b57de));
        assertEq(type(IAddrByCoin).interfaceId, bytes4(0xf1cb7e06));
        assertEq(type(ITextRecord).interfaceId, bytes4(0x59d1d43c));
        assertEq(type(IContenthashRecord).interfaceId, bytes4(0xbc1c58d1));
        assertEq(type(IDataRecord).interfaceId, bytes4(0xecbfada3));
    }

    function testFuzz_supportsOnlyTheDeclaredIds(bytes4 id) public view {
        assertEq(nft.supportsInterface(id), _isDeclared(id));
    }

    function test_declaredResolverIdsAnswerStaticCalls() public {
        string memory label = "alice";
        bytes32 secret = keccak256("secret");
        bytes32 c = nft.makeCommitment(label, holder, 0, secret);
        vm.prank(holder);
        nft.commit(c);
        vm.warp(vm.getBlockTimestamp() + 61);
        (,,, uint256 total) = nft.quote(label);
        vm.prank(holder);
        uint256 id = nft.reveal{value: total}(label, holder, 0, secret);
        vm.startPrank(holder);
        nft.setText(id, "url", "https://example.org");
        nft.setContenthash(id, hex"e30101701220");
        nft.setData(id, "blob", hex"00ff10");
        vm.stopPrank();
        bytes32 node = bytes32(id);

        // each id is the selector of its one function, and the return data encodes the type its interface defines.
        // addr(bytes32) answers coin type 60, so with nothing saved for it the address is zero, and with nothing saved
        // addr(bytes32,uint256) answers empty bytes
        (bool ok, bytes memory ret) = address(nft).staticcall(abi.encodeWithSelector(0x3b3b57de, node));
        assertTrue(ok);
        assertEq(ret, abi.encode(address(0)), "addr(bytes32) returns an address, zero with nothing saved");
        (ok, ret) = address(nft).staticcall(abi.encodeWithSelector(0xf1cb7e06, node, uint256(60)));
        assertTrue(ok);
        assertEq(ret, abi.encode(bytes("")), "addr(bytes32,uint256) returns empty bytes");
        // with a saved default both answer it, as 20 bytes and as an address
        vm.prank(holder);
        nft.setAddrForCoin(id, 0x80000000, abi.encodePacked(holder));
        (ok, ret) = address(nft).staticcall(abi.encodeWithSelector(0xf1cb7e06, node, uint256(60)));
        assertTrue(ok);
        assertEq(ret, abi.encode(abi.encodePacked(holder)), "addr(bytes32,uint256) returns bytes");
        (ok, ret) = address(nft).staticcall(abi.encodeWithSelector(0x3b3b57de, node));
        assertTrue(ok);
        assertEq(ret, abi.encode(holder), "addr(bytes32) returns the same address");
        (ok, ret) = address(nft).staticcall(abi.encodeWithSelector(0x59d1d43c, node, "url"));
        assertTrue(ok);
        assertEq(ret, abi.encode(string("https://example.org")), "text(bytes32,string) returns a string");
        (ok, ret) = address(nft).staticcall(abi.encodeWithSelector(0xbc1c58d1, node));
        assertTrue(ok);
        assertEq(ret, abi.encode(bytes(hex"e30101701220")), "contenthash(bytes32) returns bytes");
        (ok, ret) = address(nft).staticcall(abi.encodeWithSelector(0xecbfada3, node, "blob"));
        assertTrue(ok);
        assertEq(ret, abi.encode(bytes(hex"00ff10")), "data(bytes32,string) returns bytes");
    }
}

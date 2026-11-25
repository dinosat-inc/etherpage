// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {NamingBase, StorageReader} from "../../utils/NamingBase.sol";

contract ReaderAndLabelsTest is NamingBase {
    StorageReader reader;
    uint256 top;
    uint256 sub;
    uint256 longTop;
    uint256 tri;
    uint256 moved;
    uint256 kept;
    uint256 t0;

    string constant LONG63 = "abcdefghijklmnopqrstuvwxyz0123456789-abcdefghijklmnopqrstuvwxyz";
    string constant LONGTEXT = "https://a-long-profile-url.example/that/needs/the/long/string/form";

    function setUp() public override {
        super.setUp();
        reader = new StorageReader(address(nft));
        top = _buy(alice, "alice");
        longTop = _buy(bob, LONG63);
        vm.startPrank(alice);
        sub = nft.registerSubpageFor(LONG63, top, carol);
        nft.setText(top, "url", LONGTEXT);
        nft.setContenthash(top, bytes(LONGTEXT));
        nft.setAddr(top, bob);
        // coin answers come only from saves, so one name has a coin 60 entry for the reader to rebuild
        nft.setAddrForCoin(top, 60, abi.encodePacked(bob));
        nft.setPrimaryPage(top);
        vm.stopPrank();
        vm.prank(carol);
        nft.setText(sub, "avatar", LONGTEXT);
        tri = _trial("tryme", carol);
        // a profile that stopped counting at a transfer, and one the new holder kept
        moved = _buy(bob, "moved");
        kept = _buy(bob, "kept");
        vm.startPrank(bob);
        nft.setText(moved, "url", LONGTEXT);
        nft.setContenthash(moved, hex"e301");
        nft.setAddrForCoin(moved, 0x80000000, abi.encodePacked(bob));
        nft.setText(kept, "url", "short");
        nft.setContenthash(kept, bytes(LONGTEXT));
        nft.transferFrom(bob, carol, moved);
        nft.transferFrom(bob, carol, kept);
        vm.stopPrank();
        vm.prank(carol);
        nft.keepProfile(kept);
        t0 = block.timestamp;
    }

    function test_readerIsNotVacuous() public {
        assertEq(bytes(LONG63).length, 63);
        assertEq(reader.text(top, "url"), LONGTEXT);
        assertEq(reader.contenthash(top), bytes(LONGTEXT));
        assertEq(reader.resolve(top), bob);
        assertEq(reader.owner(top), alice);
        assertEq(reader.fullName(sub), string.concat(LONG63, ".alice"));
        assertEq(reader.text(sub, "avatar"), LONGTEXT);
        assertEq(reader.fullName(longTop), LONG63);
        assertEq(reader.addr(top, 60), abi.encodePacked(bob), "own coin 60 entry");
        assertEq(reader.text(moved, "url"), "");
        assertEq(reader.contenthash(moved), "");
        assertEq(reader.addr(moved, 60), "", "the seller's default stopped counting at the transfer");
        assertEq(reader.addr(moved, 0x80000000), "");
        assertEq(reader.text(kept, "url"), "short");
        assertEq(reader.contenthash(kept), bytes(LONGTEXT));
        // nothing saved for the trial, so coin 60 is empty until its holder saves a default, and then exactly that
        assertEq(reader.addr(tri, 60), "");
        vm.prank(carol);
        nft.setAddrForCoin(tri, 0x80000000, abi.encodePacked(carol));
        assertEq(reader.addr(tri, 60), abi.encodePacked(carol));
        assertEq(reader.addr(tri, 60), nft.addr(tri, 60));
    }

    // raw storage answers equal the views at any moment across a name's life
    function testFuzz_readerMatchesViews(uint32 dt) public {
        vm.warp(t0 + uint256(dt) % (500 days));
        uint256[6] memory ids = [top, sub, longTop, tri, moved, kept];
        for (uint256 i; i < ids.length; ++i) {
            uint256 id = ids[i];
            assertEq(reader.resolve(id), nft.resolve(id));
            assertEq(reader.addr(id, 60), nft.addr(id, 60));
            assertEq(reader.addr(id, 0x8000000a), nft.addr(id, 0x8000000a));
            assertEq(reader.addr(id, 0x80000000), nft.addr(id, 0x80000000));
            assertEq(reader.text(id, "url"), nft.text(id, "url"));
            assertEq(reader.text(id, "avatar"), nft.text(id, "avatar"));
            assertEq(reader.contenthash(id), nft.contenthash(id));
            assertEq(reader.fullName(id), nft.getPageName(id));
            assertEq(reader.active(id), nft.resolve(id) != address(0));
        }
        address[3] memory who = [alice, bob, carol];
        for (uint256 i; i < who.length; ++i) assertEq(reader.reverseResolve(who[i]), nft.reverseResolve(who[i]));
    }

    function _isLdh(bytes memory b) internal pure returns (bool) {
        if (b.length < 1 || b.length > 63) return false;
        if (b[0] == "-" || b[b.length - 1] == "-") return false;
        for (uint256 i; i < b.length; ++i) {
            bytes1 c = b[i];
            bool ok = (c >= "a" && c <= "z") || (c >= "0" && c <= "9") || c == "-";
            if (!ok) return false;
        }
        return true;
    }

    // every accepted label is a lower case LDH DNS label of at most 63 bytes, never with hyphens in places three and four
    function testFuzz_acceptedLabelsAreDnsLabels(bytes memory raw) public view {
        try nft.normalize(string(raw)) returns (string memory n) {
            bytes memory b = bytes(n);
            assertTrue(_isLdh(b), "LDH");
            assertEq(b.length, raw.length);
            if (b.length >= 4) assertFalse(b[2] == "-" && b[3] == "-", "no punycode style prefix");
            // normalizing is idempotent
            assertEq(nft.normalize(n), n);
        } catch {}
    }

    bytes constant ALPHA = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-----._$";

    function _pick(uint256 seed, uint256 len) internal pure returns (bytes memory b) {
        b = new bytes(len);
        for (uint256 i; i < len; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            b[i] = ALPHA[seed % ALPHA.length];
        }
    }

    function testFuzz_biasedLabels(uint256 seed, uint8 len) public view {
        bytes memory raw = _pick(seed, uint256(len) % 70);
        try nft.normalize(string(raw)) returns (string memory n) {
            assertTrue(_isLdh(bytes(n)));
        } catch {}
    }
}

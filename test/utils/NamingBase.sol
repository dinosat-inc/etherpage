// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {trialCommitment} from "./TrialCommitment.sol";

import {Test} from "forge-std/Test.sol";
import {PageNFT} from "../../src/PageNFT.sol";
import {PageCard} from "../../src/PageCard.sol";

// the read surface a gateway uses, every function declared view or pure so the compiler emits STATICCALL
interface INameViews {
    function computeId(string calldata fullName) external pure returns (uint256);
    function addr(uint256 tokenId, uint256 coinType) external view returns (bytes memory);
    function addr(bytes32 node) external view returns (address);
    function text(uint256 tokenId, string calldata key) external view returns (string memory);
    function contenthash(uint256 tokenId) external view returns (bytes memory);
    function resolve(uint256 tokenId) external view returns (address);
    function reverseResolve(address a) external view returns (string memory);
    function getPageName(uint256 tokenId) external view returns (string memory);
    function status(uint256 tokenId) external view returns (PageCard.Status);
}

// An offchain CCIP-read gateway modelled as a view contract. It gets an extended resolver query
// (DNS wire name plus resolver calldata) for <our name>.<suffix>, strips the suffix, turns
// the rest into our id with computeId and answers from PageNFT views only.
contract ViewGateway {
    INameViews public immutable nft;
    bytes public suffix; // dotted, e.g. "etherpage.com"

    constructor(INameViews n, bytes memory dottedSuffix) {
        nft = n;
        suffix = dottedSuffix;
    }

    // DNS wire format to a dotted string
    function dnsToDotted(bytes memory dns) public pure returns (bytes memory out) {
        uint256 i;
        while (i < dns.length) {
            uint256 len = uint8(dns[i]);
            if (len == 0) break;
            if (out.length != 0) out = bytes.concat(out, ".");
            bytes memory part = new bytes(len);
            for (uint256 k; k < len; ++k) part[k] = dns[i + 1 + k];
            out = bytes.concat(out, part);
            i += len + 1;
        }
    }

    // our name inside a suffixed name, empty when the suffix does not match or nothing is left
    function stripSuffix(bytes memory dotted) public view returns (bytes memory) {
        bytes memory s = suffix;
        if (dotted.length <= s.length + 1) return "";
        uint256 cut = dotted.length - s.length;
        if (dotted[cut - 1] != ".") return "";
        for (uint256 k; k < s.length; ++k) if (dotted[cut + k] != s[k]) return "";
        bytes memory head = new bytes(cut - 1);
        for (uint256 k; k < head.length; ++k) head[k] = dotted[k];
        return head;
    }

    // (found, id): found is false for a wrong suffix, more than two labels of ours, or a bad string
    function idOf(bytes calldata dns) public view returns (bool, uint256) {
        bytes memory ours = stripSuffix(dnsToDotted(dns));
        if (ours.length == 0) return (false, 0);
        try nft.computeId(string(ours)) returns (uint256 id) {
            return (true, id);
        } catch {
            return (false, 0);
        }
    }

    // the extended resolver call resolve(bytes name, bytes data), answered with the standard return encoding
    function resolve(bytes calldata dns, bytes calldata data) external view returns (bytes memory) {
        (bool found, uint256 id) = idOf(dns);
        bytes4 sel = bytes4(data[:4]);
        if (sel == 0x3b3b57de) {
            // addr(node) here means coin 60, not our OP main address
            bytes memory a = found ? nft.addr(id, 60) : bytes("");
            return abi.encode(a.length == 20 ? address(bytes20(a)) : address(0));
        }
        if (sel == 0xf1cb7e06) {
            (, uint256 coinType) = abi.decode(data[4:], (bytes32, uint256));
            return abi.encode(found ? nft.addr(id, coinType) : bytes(""));
        }
        if (sel == 0x59d1d43c) {
            (, string memory key) = abi.decode(data[4:], (bytes32, string));
            return abi.encode(found ? nft.text(id, key) : "");
        }
        if (sel == 0xbc1c58d1) {
            return abi.encode(found ? nft.contenthash(id) : bytes(""));
        }
        revert("unsupported");
    }

    // the display name with the suffix a bridge adds, empty when reverseResolve is empty
    function reverseName(address a) external view returns (string memory) {
        string memory n = nft.reverseResolve(a);
        if (bytes(n).length == 0) return "";
        return string.concat(n, ".", string(suffix));
    }
}

// Rebuilds every answer from raw storage words, as a storage proof reader would. The only input that is not
// contract storage is the block time: no answer depends on the code at an address.
contract StorageReader is Test {
    address immutable target;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    constructor(address t) {
        target = t;
    }

    function _w(bytes32 slot) internal view returns (bytes32) {
        return vm.load(target, slot);
    }

    function _mapSlot(uint256 key, uint256 slot) internal pure returns (bytes32) {
        return keccak256(abi.encode(key, slot));
    }

    function _nested(bytes32 outer, uint256 key) internal pure returns (bytes32) {
        return keccak256(abi.encode(key, outer));
    }

    // solidity bytes and string storage: short form in place, long form at keccak(slot)
    function _bytesAt(bytes32 slot) internal view returns (bytes memory out) {
        uint256 w = uint256(_w(slot));
        if (w & 1 == 0) {
            uint256 len = (w & 0xff) / 2;
            out = new bytes(len);
            for (uint256 i; i < len; ++i) out[i] = bytes32(w)[i];
        } else {
            uint256 len = (w - 1) / 2;
            out = new bytes(len);
            bytes32 start = keccak256(abi.encode(slot));
            for (uint256 i; i < len; ++i) {
                bytes32 word = _w(bytes32(uint256(start) + i / 32));
                out[i] = word[i % 32];
            }
        }
    }

    struct Rec {
        bytes label;
        uint256 parent;
        uint64 expiresAt;
        uint64 epoch;
        uint64 parentEpoch;
    }

    function rec(uint256 id) public view returns (Rec memory r) {
        bytes32 base = _mapSlot(id, 0);
        r.label = _bytesAt(base);
        r.parent = uint256(_w(bytes32(uint256(base) + 1)));
        uint256 w2 = uint256(_w(bytes32(uint256(base) + 2)));
        r.expiresAt = uint64(w2);
        r.epoch = uint64(w2 >> 64);
        r.parentEpoch = uint64(w2 >> 128);
    }

    // solady ERC721 ownership slot, as its STORAGE comment gives it
    function ownerSlot(uint256 id) public pure returns (bytes32 s) {
        assembly {
            mstore(0x00, id)
            mstore(0x1c, shl(192, 0x7d8825530a5a2e7a))
            s := add(id, add(id, keccak256(0x00, 0x20)))
        }
    }

    function owner(uint256 id) public view returns (address) {
        return address(uint160(uint256(_w(ownerSlot(id)))));
    }

    function version(uint256 id) public view returns (uint256) {
        return uint256(_w(_mapSlot(id, 1)));
    }

    function deposit(uint256 id) public view returns (uint256) {
        return uint256(_w(_mapSlot(id, 5)));
    }

    // a page held by the dead address is never active
    function active(uint256 id) public view returns (bool) {
        Rec memory r = rec(id);
        if (r.label.length == 0) return false;
        if (owner(id) == DEAD) return false;
        if (r.parent == 0) return block.timestamp <= r.expiresAt;
        Rec memory p = rec(r.parent);
        if (r.parentEpoch != p.epoch) return false;
        return block.timestamp <= p.expiresAt;
    }

    // holderSince and addressesUpdatedAt sit in slots 16 and 17, one word per id
    function holderSince(uint256 id) public view returns (uint256) {
        return uint256(_w(_mapSlot(id, 16)));
    }

    function addressesUpdatedAt(uint256 id) public view returns (uint256) {
        return uint256(_w(_mapSlot(id, 17)));
    }

    // a data record sits in slot 18 under its record version and key, its saver first and its value next; it counts
    // only while its saver holds the name
    function data(uint256 id, string memory key) public view returns (bytes memory) {
        if (!active(id)) return "";
        bytes32 e = keccak256(abi.encodePacked(bytes(key), _nested(_mapSlot(id, 18), version(id))));
        if (address(uint160(uint256(_w(e)))) != owner(id)) return "";
        return _bytesAt(bytes32(uint256(e) + 1));
    }

    function pointee(uint256 id, address o) public view returns (address) {
        uint256 v = version(id);
        address a = address(uint160(uint256(_w(_nested(_mapSlot(id, 7), v)))));
        address saver = address(uint160(uint256(_w(_nested(_mapSlot(id, 11), v)))));
        return (a != address(0) && saver == o) ? a : o;
    }

    function resolve(uint256 id) public view returns (address) {
        if (!active(id)) return address(0);
        return pointee(id, owner(id));
    }

    function _coinEntry(uint256 id, uint256 coinType) internal view returns (bytes32) {
        return keccak256(abi.encode(coinType, _nested(_mapSlot(id, 9), version(id))));
    }

    function _isEvm(uint256 c) internal pure returns (bool) {
        return c == 60 || (c >= 0x80000000 && c <= 0xffffffff);
    }

    function _enc(address a) internal pure returns (bytes memory) {
        return a == address(0) ? bytes("") : abi.encodePacked(a);
    }

    function addr(uint256 id, uint256 coinType) public view returns (bytes memory) {
        if (!active(id)) return "";
        address o = owner(id);
        address main = pointee(id, o);
        if (coinType == 0x8000000a) return _enc(main);
        bytes32 e = _coinEntry(id, coinType);
        address saver = address(uint160(uint256(_w(e))));
        bytes memory value = _bytesAt(bytes32(uint256(e) + 1));
        if (_isEvm(coinType)) {
            address a;
            if (saver == o) a = address(bytes20(value));
            // then the default the holder saved for every EVM chain, coin type 0x80000000
            bytes32 d = _coinEntry(id, 0x80000000);
            if (a == address(0) && address(uint160(uint256(_w(d)))) == o) a = address(bytes20(_bytesAt(bytes32(uint256(d) + 1))));
            return _enc(a);
        }
        return saver == o ? value : bytes("");
    }

    // the profile word holds its writer and its number; it counts only while the writer holds the name
    function profileSlot(uint256 id) public view returns (bool ok, uint256 slot) {
        uint256 w = uint256(_w(_mapSlot(id, 15)));
        address writer = address(uint160(w));
        ok = active(id) && writer == owner(id);
        slot = version(id) << 96 | (w >> 160);
    }

    function text(uint256 id, string memory key) public view returns (string memory) {
        (bool ok, uint256 slot) = profileSlot(id);
        if (!ok) return "";
        bytes32 inner = _nested(_mapSlot(id, 10), slot);
        return string(_bytesAt(keccak256(abi.encodePacked(bytes(key), inner))));
    }

    function contenthash(uint256 id) public view returns (bytes memory) {
        (bool ok, uint256 slot) = profileSlot(id);
        if (!ok) return "";
        return _bytesAt(_nested(_mapSlot(id, 8), slot));
    }

    function fullName(uint256 id) public view returns (string memory) {
        Rec memory r = rec(id);
        if (r.label.length == 0) return "";
        if (r.parent == 0) return string(r.label);
        Rec memory p = rec(r.parent);
        if (r.parentEpoch != p.epoch) return "";
        return string.concat(string(r.label), ".", string(p.label));
    }

    function reverseResolve(address a) public view returns (string memory) {
        uint256 id = uint256(_w(keccak256(abi.encode(a, uint256(3)))));
        address holder = address(uint160(uint256(_w(keccak256(abi.encode(a, uint256(13)))))));
        if (id == 0 || !active(id) || owner(id) != holder || resolve(id) != a) return "";
        return fullName(id);
    }
}

abstract contract NamingBase is Test {
    PageNFT nft;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address relayer = makeAddr("relayer");

    function setUp() public virtual {
        vm.warp(1_800_000_000);
        nft = new PageNFT(new PageCard());
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(carol, 100 ether);
        vm.deal(relayer, 100 ether);
    }

    function _secret(string memory label, address to) internal pure returns (bytes32) {
        return keccak256(abi.encode("s", label, to));
    }

    function _buy(address who, string memory label) internal returns (uint256 id) {
        bytes32 commitment = nft.makeCommitment(label, who, 0, _secret(label, who));
        vm.prank(who);
        nft.commit(commitment);
        vm.warp(vm.getBlockTimestamp() + 61);
        (,,, uint256 total) = nft.quote(label);
        vm.prank(who);
        id = nft.reveal{value: total}(label, who, 0, _secret(label, who));
    }

    function _trial(string memory label, address to) internal returns (uint256 id) {
        bytes32 commitment = trialCommitment(address(nft), label, to, 0, _secret(label, to));
        vm.prank(relayer);
        nft.commit(commitment);
        vm.warp(vm.getBlockTimestamp() + 61);
        uint256 price = nft.getFee(bytes(label).length) / 10;
        vm.prank(relayer);
        id = nft.revealTrial{value: price}(label, to, 0, _secret(label, to));
    }

    // DNS wire format of a dotted name
    function _dns(string memory dotted) internal pure returns (bytes memory out) {
        bytes memory b = bytes(dotted);
        uint256 start;
        for (uint256 i; i <= b.length; ++i) {
            if (i == b.length || b[i] == ".") {
                out = bytes.concat(out, bytes1(uint8(i - start)));
                for (uint256 k = start; k < i; ++k) out = bytes.concat(out, b[k]);
                start = i + 1;
            }
        }
        out = bytes.concat(out, bytes1(0));
    }

    function _zeroRootNamehash(string memory dotted) internal pure returns (bytes32 node) {
        bytes memory b = bytes(dotted);
        uint256 end = b.length;
        for (uint256 i = b.length; i > 0; --i) {
            if (b[i - 1] == ".") {
                node = keccak256(abi.encodePacked(node, keccak256(_slice(b, i, end))));
                end = i - 1;
            }
        }
        node = keccak256(abi.encodePacked(node, keccak256(_slice(b, 0, end))));
    }

    function _slice(bytes memory b, uint256 s, uint256 e) internal pure returns (bytes memory out) {
        out = new bytes(e - s);
        for (uint256 i = s; i < e; ++i) out[i - s] = b[i];
    }
}

// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Vm} from "forge-std/Test.sol";
import {PageNFT} from "../../src/PageNFT.sol";
import {RulesBase} from "./RulesBase.sol";

// holds names for someone and gives them back, and never writes records
contract Vault {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    function give(PageNFT nft, address to, uint256 id) external {
        nft.transferFrom(address(this), to, id);
    }
}

// a loan against a name: the borrower deposits it and takes it back with repay, and the lender can take it
// with seize at any time, as on a default
contract Lending {
    PageNFT immutable nft;
    mapping(uint256 => address) public borrower;
    mapping(uint256 => address) public lender;

    constructor(PageNFT n) {
        nft = n;
    }

    function onERC721Received(address, address from, uint256 id, bytes calldata data) external returns (bytes4) {
        borrower[id] = from;
        lender[id] = abi.decode(data, (address));
        return this.onERC721Received.selector;
    }

    function repay(uint256 id) external {
        require(msg.sender == borrower[id]);
        nft.safeTransferFrom(address(this), msg.sender, id);
    }

    function seize(uint256 id) external {
        require(msg.sender == lender[id]);
        nft.safeTransferFrom(address(this), msg.sender, id);
    }
}

// shared helpers for the profile tests
abstract contract ProfileBase is RulesBase {
    string constant PUNK = "eip155:1/erc721:0xb47e3cd837ddf8e4c57f05d70ab865de6e193bbb/5822";
    string constant MILADY = "eip155:1/erc721:0x5af0d9827e0c53e4799bb226655a1de152a425a5/42";
    string constant SCAM = "https://scam.example";
    bytes constant SITE = hex"e3010170122029f2d17be6139079dc48696d1f582a8530eb9805b561eda517e22a892c7e3f1f";
    uint256 constant BTC = 0;

    bytes32 constant T_PWC = keccak256("ProfileWriterChanged(bytes32,address,bool)");
    bytes32 constant T_TEXT = keccak256("TextChanged(bytes32,string,string,string)");
    bytes32 constant T_SITE = keccak256("ContenthashChanged(bytes32,bytes)");
    bytes32 constant T_VERSION = keccak256("VersionChanged(bytes32,uint64)");
    bytes32 constant T_TRANSFER = keccak256("Transfer(address,address,uint256)");

    address user2 = makeAddr("user2");
    address seaport = makeAddr("seaport-conduit");

    function _paid(address who, string memory l) internal returns (uint256 id) {
        vm.deal(who, 1000 ether);
        id = _buy(who, l);
    }

    // a name with a full profile and a Bitcoin address, all written by its holder
    function _profiled(address who, string memory l) internal returns (uint256 id) {
        id = _paid(who, l);
        _write(who, id);
    }

    function _write(address who, uint256 id) internal {
        vm.startPrank(who);
        nft.setText(id, "avatar", PUNK);
        nft.setText(id, "url", "https://alice.example");
        nft.setText(id, "com.twitter", "alice");
        nft.setContenthash(id, SITE);
        nft.setAddrForCoin(id, BTC, bytes("bc1qalice"));
        vm.stopPrank();
    }

    function _eqs(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    // the whole profile of the helper above is visible
    function _assertFull(uint256 id) internal view {
        assertEq(nft.text(id, "avatar"), PUNK, "avatar");
        assertEq(nft.text(id, "url"), "https://alice.example", "url");
        assertEq(nft.text(id, "com.twitter"), "alice", "twitter");
        assertEq(nft.contenthash(id), SITE, "website");
    }

    // nothing of the profile is visible
    function _assertEmpty(uint256 id) internal view {
        assertEq(nft.text(id, "avatar"), "", "avatar hidden");
        assertEq(nft.text(id, "url"), "", "url hidden");
        assertEq(nft.text(id, "com.twitter"), "", "twitter hidden");
        assertEq(nft.contenthash(id).length, 0, "website hidden");
        assertEq(nft.text(bytes32(id), "avatar"), "", "avatar hidden, bytes32 form");
        assertEq(nft.contenthash(bytes32(id)).length, 0, "website hidden, bytes32 form");
    }

    function _move(address from, address to, uint256 id) internal {
        vm.prank(from);
        nft.transferFrom(from, to, id);
    }

    function _keep(address who, uint256 id) internal {
        vm.prank(who);
        nft.keepProfile(id);
    }

    function _profileLogs(Vm.Log[] memory logs) internal view returns (uint256 n) {
        return _count(logs, T_PWC);
    }

    // a ProfileWriterChanged log, checked field by field
    function _assertPwc(Vm.Log memory l, uint256 id, address writer, bool fresh) internal view {
        assertEq(l.emitter, address(nft));
        assertEq(l.topics.length, 2);
        assertEq(l.topics[0], T_PWC);
        assertEq(l.topics[1], bytes32(id));
        (address w, bool f) = abi.decode(l.data, (address, bool));
        assertEq(w, writer, "event writer");
        assertEq(f, fresh, "event fresh flag");
    }

    // lapses a paid name past grace and auction, then registers it for who
    function _lapseAndBuy(uint256 id, address who, string memory l) internal {
        vm.warp(nft.expiresAt(id) + 111 days + 1);
        vm.deal(who, 1000 ether);
        _buy(who, l);
    }
}

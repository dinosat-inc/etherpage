// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Test, Vm} from "forge-std/Test.sol";
import {PageCard} from "../../src/PageCard.sol";
import {PageNFT} from "../../src/PageNFT.sol";
import {SubpageRegistrar, IPageNFT} from "../../src/SubpageRegistrar.sol";
import {MockERC20} from "./MinterMocks.sol";

abstract contract MinterBase is Test {
    bytes4 constant TOKEN_DOES_NOT_EXIST = 0xceea21b6; // TokenDoesNotExist()
    bytes4 constant NOT_OWNER_NOR_APPROVED = 0x4b6e7f18; // NotOwnerNorApproved()
    bytes4 constant NON_RECEIVER = 0xd1a57ed6; // TransferToNonERC721ReceiverImplementer()
    bytes4 constant REENTRANCY = 0xab143c06; // Reentrancy()
    bytes4 constant ETH_TRANSFER_FAILED = 0xb12d13eb; // ETHTransferFailed()

    bytes32 constant T_TRANSFER = keccak256("Transfer(address,address,uint256)");
    bytes32 constant T_APPROVAL = keccak256("Approval(address,address,uint256)");
    bytes32 constant T_APPROVAL_ALL = keccak256("ApprovalForAll(address,address,bool)");
    bytes32 constant T_MINTER_SET = keccak256("SubpageMinterSet(uint256,address,address,uint64)");

    uint256 constant COIN_OP = 0x8000000a;
    uint256 constant MINTER_SLOT = 12;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    PageCard card;
    PageNFT nft;
    SubpageRegistrar reg;
    MockERC20 usd;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address dave = makeAddr("dave");
    address hot = makeAddr("hot");
    address hot2 = makeAddr("hot2");
    address buyer = makeAddr("buyer");
    address stranger = makeAddr("stranger");
    address payout = makeAddr("payout");

    function setUp() public virtual {
        vm.warp(1_800_000_000);
        card = new PageCard();
        nft = new PageNFT(card);
        reg = new SubpageRegistrar(IPageNFT(address(nft)));
        usd = new MockERC20();
        address[8] memory who = [alice, bob, carol, dave, hot, buyer, stranger, hot2];
        for (uint256 i; i < who.length; ++i) vm.deal(who[i], 1000 ether);
    }

    function _reg(address who, string memory label) internal returns (uint256 id) {
        return _regTo(who, label, who);
    }

    function _regTo(address payer, string memory label, address to) internal returns (uint256 id) {
        bytes32 secret = keccak256(abi.encode(payer, label, to, block.timestamp));
        bytes32 commitment = nft.makeCommitment(label, to, 0, secret);
        vm.prank(payer);
        nft.commit(commitment);
        vm.warp(vm.getBlockTimestamp() + 61);
        (,,, uint256 total) = nft.quote(label);
        vm.deal(payer, payer.balance + total);
        vm.prank(payer);
        id = nft.reveal{value: total}(label, to, 0, secret);
    }

    bytes32 constant ROOT = 0x62460c06d95b73747abf6ea4f28aefd78b4ad2abee112e7cf15fe6a924cca3c6;

    function _id(string memory label) internal pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(ROOT, keccak256(bytes(label)))));
    }

    function _subId(string memory label, uint256 parentId) internal pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(bytes32(parentId), keccak256(bytes(label)))));
    }

    function _setMinter(uint256 parentId, address minter) internal {
        vm.prank(nft.ownerOf(parentId));
        nft.setSubpageMinter(parentId, minter);
    }

    function _minter(uint256 parentId) internal view returns (address m) {
        m = nft.subpageMinterOf(parentId);
    }

    // the raw slot pair of _subpageMinter[parentId]
    function _raw(uint256 parentId) internal view returns (address minter, uint64 epoch, address setter) {
        bytes32 base = keccak256(abi.encode(parentId, MINTER_SLOT));
        uint256 w0 = uint256(vm.load(address(nft), base));
        uint256 w1 = uint256(vm.load(address(nft), bytes32(uint256(base) + 1)));
        minter = address(uint160(w0));
        epoch = uint64(w0 >> 160);
        setter = address(uint160(w1));
        assertEq(w0 >> 224, 0, "word 0 high bytes");
        assertEq(w1 >> 160, 0, "word 1 high bytes");
    }

    // moves past grace and the premium window and registers the name again for who
    function _lapseAndRegister(uint256 id, address who) internal returns (uint256) {
        vm.warp(nft.expiresAt(id) + 90 days + 21 days + 1);
        string memory label = nft.getPageName(id);
        return _reg(who, label);
    }

    function _expectMinterSet(uint256 parentId, address account, address minter, uint64 epoch) internal {
        vm.expectEmit(true, true, true, true, address(nft));
        emit PageNFT.SubpageMinterSet(parentId, account, minter, epoch);
    }

    function _configure(uint256 parentId, address pay, address feeToken, uint256 price, bool commitReveal) internal {
        vm.prank(nft.ownerOf(parentId));
        reg.configure(parentId, pay, feeToken, price, true, address(0), 0, commitReveal);
    }

    // parent sells through the registrar at price in ETH
    function _sellSetup(uint256 parentId, uint256 price) internal {
        _setMinter(parentId, address(reg));
        _configure(parentId, payout, address(0), price, false);
    }

    function _has(Vm.Log[] memory logs, bytes32 topic0) internal pure returns (bool) {
        for (uint256 i; i < logs.length; ++i) if (logs[i].topics.length > 0 && logs[i].topics[0] == topic0) return true;
        return false;
    }
}

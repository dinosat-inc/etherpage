// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {PageNFT} from "../../../src/PageNFT.sol";
import {PageCard} from "../../../src/PageCard.sol";
import {SimpleDelegateLike, PQAccountLike} from "../../utils/WalletMocks.sol";

// account shapes from the Kohaku wallet stack and the EF desktop wallet
contract WalletCompatTest is Test {
    PageNFT nft;
    SimpleDelegateLike delegate;

    address bob = makeAddr("bob");
    address entryPoint = makeAddr("entryPoint");
    uint256 vaultKey = 0xA11CE;
    address vault;

    // solady ERC721 TransferToNonERC721ReceiverImplementer()
    bytes4 constant NOT_RECEIVER = 0xd1a57ed6;
    uint256 constant COIN_BASE = 0x80000000 | 8453;
    uint256 constant COIN_DEFAULT_EVM = 0x80000000;
    uint256 constant COIN_RAILGUN = 1984;
    string constant STEALTH_KEY = "stealth-address-scheme-1";

    function setUp() public {
        vm.warp(1_800_000_000);
        nft = new PageNFT(new PageCard());
        delegate = new SimpleDelegateLike();
        vm.deal(bob, 1000 ether);
        vault = vm.addr(vaultKey);
    }

    // turns the vault key wallet into a real 7702 account delegated to the desktop wallet delegate
    function _delegateVault() internal {
        vm.signAndAttachDelegation(address(delegate), vaultKey);
        (bool ok,) = vault.call("");
        assertTrue(ok, "receive() on the delegated account");
        bytes memory code = vault.code;
        assertEq(code.length, 23, "7702 marker length");
        assertEq(uint8(code[0]), 0xef);
        assertEq(uint8(code[1]), 0x01);
        assertEq(uint8(code[2]), 0x00);
    }

    function _s(string memory l, address o) internal pure returns (bytes32) {
        return keccak256(abi.encode(l, o));
    }

    function _commit(string memory l, address owner) internal {
        bytes32 commitment = nft.makeCommitment(l, owner, 0, _s(l, owner));
        vm.prank(bob);
        nft.commit(commitment);
        vm.warp(vm.getBlockTimestamp() + 61);
    }

    function _buy(string memory l, address owner) internal returns (uint256 id) {
        _commit(l, owner);
        (,,, uint256 total) = nft.quote(l);
        vm.prank(bob);
        id = nft.reveal{value: total}(l, owner, 0, _s(l, owner));
    }

    // the desktop wallet vault has no receiver hook, but its key can always move a name, so it can be named owner;
    // other chains answer it once it saves a default
    function test_registerToDesktopWalletVaultWorks() public {
        _delegateVault();
        uint256 id = _buy("vaultname", vault);
        assertEq(nft.ownerOf(id), vault);
        assertEq(nft.resolve(id), vault);
        assertEq(nft.addr(id, COIN_BASE), "");
        vm.prank(vault);
        nft.setAddrForCoin(id, COIN_DEFAULT_EVM, abi.encodePacked(vault));
        assertEq(nft.addr(id, COIN_BASE), abi.encodePacked(vault));
        vm.prank(vault, vault);
        nft.transferFrom(vault, bob, id);
        assertEq(nft.ownerOf(id), bob);
    }

    // a safe transfer to the vault reverts, since it has no receiver hook
    function test_safeTransferToDesktopWalletVaultReverts() public {
        _delegateVault();
        uint256 id = _buy("safemove", bob);
        vm.prank(bob);
        vm.expectRevert(NOT_RECEIVER);
        nft.safeTransferFrom(bob, vault, id);
    }

    // plain transferFrom works, and the vault answers on other EVM chains exactly what it saves, like any holder
    function test_transferFromToDesktopWalletVaultWorksAndAnswersWhatItSaves() public {
        _delegateVault();
        uint256 id = _buy("plainmove", bob);
        vm.prank(bob);
        nft.transferFrom(bob, vault, id);
        assertEq(nft.ownerOf(id), vault);
        assertEq(nft.resolve(id), vault);
        assertEq(nft.addr(id, 60), "");
        assertEq(nft.addr(id, COIN_BASE), "");
        vm.prank(vault);
        nft.setAddrForCoin(id, COIN_DEFAULT_EVM, abi.encodePacked(vault));
        assertEq(nft.addr(id, 60), abi.encodePacked(vault));
        assertEq(nft.addr(id, COIN_BASE), abi.encodePacked(vault));
        vm.prank(vault);
        nft.setPrimaryPage(id);
        assertEq(nft.reverseResolve(vault), "plainmove");
    }

    function test_subpageForDesktopWalletVaultWorks() public {
        _delegateVault();
        uint256 parent = _buy("alice", bob);
        vm.prank(bob);
        uint256 sub = nft.registerSubpageFor("app", parent, vault);
        assertEq(nft.ownerOf(sub), vault);
    }

    // a per app address can show a subpage as its display name without holding it
    function test_perAppAddressShowsSubpageItDoesNotHold() public {
        _delegateVault();
        uint256 parent = _buy("alice", bob);
        vm.startPrank(bob);
        uint256 sub = nft.registerSubpage("app", parent);
        nft.setAddr(sub, vault);
        vm.stopPrank();
        vm.prank(vault);
        nft.setPrimaryPage(sub);
        assertEq(nft.reverseResolve(vault), "app.alice");
        // the parent keeps its own display name on the main account
        vm.prank(bob);
        nft.setPrimaryPage(parent);
        assertEq(nft.reverseResolve(bob), "alice");
    }

    // a fresh plain key per app, the Kohaku extension shape, registers normally, and answers on another chain once
    // it saves an address for it
    function test_freshKeyWalletRegistersNormally() public {
        address fresh = vm.addr(0xF2E5);
        uint256 id = _buy("fresh", fresh);
        assertEq(nft.ownerOf(id), fresh);
        assertEq(nft.resolve(id), fresh);
        assertEq(nft.addr(id, COIN_BASE), "");
        vm.prank(fresh);
        nft.setAddrForCoin(id, COIN_BASE, abi.encodePacked(fresh));
        assertEq(nft.addr(id, COIN_BASE), abi.encodePacked(fresh));
        assertEq(nft.addr(id, 60), "", "an entry for one chain answers that chain only");
    }

    // Kohaku's post quantum 4337 account has an empty fallback and no hook: someone else cannot name it
    // owner, it can buy for itself, a plain transfer reaches it, and it answers no other chain
    function test_pqAccount() public {
        PQAccountLike pq = new PQAccountLike(entryPoint);
        vm.deal(address(pq), 1 ether);
        _commit("pqname", address(pq));
        (,,, uint256 total) = nft.quote("pqname");
        vm.prank(bob);
        vm.expectRevert(NOT_RECEIVER);
        nft.reveal{value: total}("pqname", address(pq), 0, _s("pqname", address(pq)));
        vm.prank(entryPoint);
        pq.execute(address(nft), total, abi.encodeCall(PageNFT.reveal, ("pqname", address(pq), 0, _s("pqname", address(pq)))));
        assertEq(nft.ownerOf(nft.computeId("pqname")), address(pq));

        uint256 id = _buy("pqmove", bob);
        vm.prank(bob);
        nft.transferFrom(bob, address(pq), id);
        assertEq(nft.resolve(id), address(pq));
        assertEq(nft.addr(id, 60).length, 0);
        assertEq(nft.addr(id, COIN_BASE).length, 0);
    }

    // the four calls kohaku-cli's name library makes against a wei-names registry
    function test_weiNamesLibraryAbiWorksSuffixless() public {
        uint256 id = _buy("alice", bob);
        vm.startPrank(bob);
        nft.setText(id, STEALTH_KEY, "st:eth:0x02aa");
        nft.setPrimaryPage(id);
        vm.stopPrank();
        assertEq(nft.computeId("alice"), id);
        assertEq(nft.resolve(nft.computeId("alice")), bob);
        assertEq(nft.text(nft.computeId("alice"), STEALTH_KEY), "st:eth:0x02aa");
        assertEq(nft.reverseResolve(bob), "alice");
        // a library that appends a suffix computes a subpage id under a top level name instead
        uint256 wrong = nft.computeId("alice.names");
        assertTrue(wrong != id);
        assertEq(wrong, uint256(keccak256(abi.encodePacked(bytes32(nft.computeId("names")), keccak256("alice")))));
        assertEq(nft.computeId("alice.tags"), uint256(keccak256(abi.encodePacked(bytes32(nft.computeId("tags")), keccak256("alice")))));
    }

    // a Railgun 0zk receive code fits a coin type outside the EVM or a text key; both take any bytes
    function test_railgunReceiverStorable() public {
        uint256 id = _buy("shielded", bob);
        bytes memory payload = new bytes(73);
        payload[0] = 0x01;
        payload[72] = 0x02;
        string memory zk = string(abi.encodePacked("0zk1", new bytes(123)));
        vm.startPrank(bob);
        nft.setAddrForCoin(id, COIN_RAILGUN, payload);
        nft.setText(id, "railgun", zk);
        vm.stopPrank();
        assertEq(nft.addr(id, COIN_RAILGUN), payload);
        assertEq(bytes(nft.text(id, "railgun")).length, 127);
    }

    // a sale resets every address and hides the seller's stealth key; the buyer writes a fresh one
    function test_saleHidesSellerStealthKeyAndResetsAddresses() public {
        address buyer = makeAddr("buyer");
        uint256 id = _buy("forsale", bob);
        vm.startPrank(bob);
        nft.setText(id, STEALTH_KEY, "st:eth:0xSELLER");
        nft.setAddrForCoin(id, COIN_RAILGUN, hex"5e11");
        nft.setAddr(id, makeAddr("bobOther"));
        nft.transferFrom(bob, buyer, id);
        vm.stopPrank();
        assertEq(nft.resolve(id), buyer);
        assertEq(nft.addr(id, COIN_RAILGUN).length, 0);
        assertEq(nft.text(id, STEALTH_KEY), "");
        vm.prank(buyer);
        nft.setText(id, STEALTH_KEY, "st:eth:0xBUYER");
        assertEq(nft.text(id, STEALTH_KEY), "st:eth:0xBUYER");
    }

    // moving to your own new account needs one keepProfile call
    function test_ownMoveNeedsKeepProfile() public {
        address newKey = makeAddr("rotated");
        uint256 id = _buy("mine", bob);
        vm.startPrank(bob);
        nft.setText(id, "avatar", "eip155:1/erc721:0x1/1");
        nft.transferFrom(bob, newKey, id);
        vm.stopPrank();
        assertEq(nft.text(id, "avatar"), "");
        vm.prank(newKey);
        nft.keepProfile(id);
        assertEq(nft.text(id, "avatar"), "eip155:1/erc721:0x1/1");
    }
}

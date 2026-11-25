// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {trialCommitmentRaw} from "../utils/TrialCommitment.sol";

import {Test, console} from "forge-std/Test.sol";
import {PageNFT} from "../../src/PageNFT.sol";
import {PageCard} from "../../src/PageCard.sol";
import {SubpageRegistrar, IPageNFT} from "../../src/SubpageRegistrar.sol";
import {PageNFTSafe} from "./harness/PageNFTSafe.sol";
import {PageNFTPlain} from "./harness/PageNFTPlain.sol";
import {PageNFTKeyOnly} from "./harness/PageNFTKeyOnly.sol";
import {SafeLike, Delegate7702} from "../utils/MinterMocks.sol";
import {SimpleDelegateLike, PQAccountLike, TokenLike, WethLike} from "../utils/WalletMocks.sol";

// Four builds side by side that differ only in how a name is minted: S asks every recipient with code,
// P never asks, H1 skips the check for key wallets, EIP7702 accounts included, and H2 is the real
// source, which also skips it when the recipient is the caller. All share one ABI, and the first three
// are generated from the source.
abstract contract SafeMintBase is Test {
    uint256 constant S = 0;
    uint256 constant P = 1;
    uint256 constant H1 = 2;
    uint256 constant H2 = 3;
    string[4] vname = ["S", "P", "H1", "H2"];

    uint256 constant KEY = 0;
    uint256 constant D7702_NOHOOK = 1;
    uint256 constant D7702_HOOK = 2;
    uint256 constant PQ = 3;
    uint256 constant SAFE = 4;
    uint256 constant TOKEN = 5;
    uint256 constant WETH = 6;
    uint256 constant NFT_ITSELF = 7;
    uint256 constant REGISTRAR = 8;
    uint256 constant NREC = 9;
    string[9] rname =
        ["key wallet", "7702 no hook", "7702 with hook", "PQ 4337 account", "Safe-like", "token", "WETH-like", "the PageNFT", "the registrar"];

    bytes4 constant NOT_RECEIVER = 0xd1a57ed6; // TransferToNonERC721ReceiverImplementer()
    bytes4 constant OK = 0x00000000;
    uint256 constant FEE5 = 0.0001 ether;
    uint256 constant PRICE5 = 0.00001 ether;

    PageCard card;
    PageNFT[4] nfts;
    SubpageRegistrar[4] regs;

    address bob = makeAddr("bob");
    address alice = makeAddr("alice");
    address entryPoint = makeAddr("entryPoint");
    address safeOwner = makeAddr("safeOwner");
    address keyWallet = makeAddr("keyWallet");

    uint256 constant VAULT_NOHOOK_KEY = 0xA11CE;
    uint256 constant VAULT_HOOK_KEY = 0xB0B0;
    address vaultNoHook;
    address vaultHook;
    PQAccountLike pq;
    SafeLike safe;
    TokenLike token;
    WethLike weth;

    uint256 counter;

    function setUp() public virtual {
        vm.warp(1_800_000_000);
        card = new PageCard();
        nfts[S] = PageNFT(address(new PageNFTSafe(card)));
        nfts[P] = PageNFT(address(new PageNFTPlain(card)));
        nfts[H1] = PageNFT(address(new PageNFTKeyOnly(card)));
        nfts[H2] = new PageNFT(card);
        for (uint256 v; v < 4; ++v) regs[v] = new SubpageRegistrar(IPageNFT(address(nfts[v])));

        vaultNoHook = vm.addr(VAULT_NOHOOK_KEY);
        vaultHook = vm.addr(VAULT_HOOK_KEY);
        SimpleDelegateLike sd = new SimpleDelegateLike();
        Delegate7702 dh = new Delegate7702();
        vm.signAndAttachDelegation(address(sd), VAULT_NOHOOK_KEY);
        (bool ok,) = vaultNoHook.call("");
        assertTrue(ok);
        vm.signAndAttachDelegation(address(dh), VAULT_HOOK_KEY);
        (ok,) = vaultHook.call("");
        assertTrue(ok);
        assertEq(vaultNoHook.code.length, 23);
        assertEq(vaultHook.code.length, 23);

        pq = new PQAccountLike(entryPoint);
        safe = new SafeLike(safeOwner);
        token = new TokenLike();
        weth = new WethLike();

        vm.deal(bob, 1000 ether);
        vm.deal(alice, 1000 ether);
        vm.deal(keyWallet, 10 ether);
        vm.deal(vaultNoHook, 10 ether);
        vm.deal(vaultHook, 10 ether);
        vm.deal(address(pq), 10 ether);
        vm.deal(address(safe), 10 ether);
    }

    function _rec(uint256 v, uint256 r) internal view returns (address) {
        if (r == KEY) return keyWallet;
        if (r == D7702_NOHOOK) return vaultNoHook;
        if (r == D7702_HOOK) return vaultHook;
        if (r == PQ) return address(pq);
        if (r == SAFE) return address(safe);
        if (r == TOKEN) return address(token);
        if (r == WETH) return address(weth);
        if (r == NFT_ITSELF) return address(nfts[v]);
        return address(regs[v]);
    }

    function _canAct(uint256 r) internal pure returns (bool) {
        return r <= SAFE;
    }

    function _s(string memory l, address o) internal pure returns (bytes32) {
        return keccak256(abi.encode(l, o));
    }

    function _label() internal returns (string memory) {
        return string.concat("name", vm.toString(++counter));
    }

    // sends a call as recipient r through the way that account really acts
    function _actAs(uint256 r, address target, uint256 value, bytes memory data)
        internal
        returns (bool ok, bytes memory ret)
    {
        if (r == KEY) {
            vm.prank(keyWallet, keyWallet);
            (ok, ret) = target.call{value: value}(data);
        } else if (r == D7702_NOHOOK || r == D7702_HOOK) {
            address a = r == D7702_NOHOOK ? vaultNoHook : vaultHook;
            vm.prank(a, a);
            (ok, ret) = target.call{value: value}(data);
        } else if (r == PQ) {
            vm.prank(entryPoint);
            (ok, ret) = address(pq).call(abi.encodeCall(PQAccountLike.execute, (target, value, data)));
        } else if (r == SAFE) {
            vm.prank(safeOwner);
            (ok, ret) = address(safe).call(abi.encodeCall(SafeLike.exec, (target, value, data)));
        } else {
            revert("cannot act");
        }
    }

    function _sel(bool ok, bytes memory ret) internal pure returns (bytes4 s) {
        if (ok) return OK;
        if (ret.length < 4) return bytes4(0xffffffff);
        assembly ("memory-safe") {
            s := mload(add(ret, 0x20))
        }
    }

    // a paid top level name for alice in build v
    function _aliceParent(uint256 v) internal returns (uint256 id) {
        PageNFT nft = nfts[v];
        string memory l = _label();
        bytes32 commitment = nft.makeCommitment(l, alice, 0, _s(l, alice));
        vm.prank(alice);
        nft.commit(commitment);
        vm.warp(vm.getBlockTimestamp() + 61);
        vm.prank(alice);
        id = nft.reveal{value: FEE5}(l, alice, 0, _s(l, alice));
    }

    // such a name, with the registrar of build v as its subpage minter selling subpages for free
    function _registrarParent(uint256 v) internal returns (uint256 id) {
        id = _aliceParent(v);
        vm.startPrank(alice);
        regs[v].configure(id, alice, address(0), 0, true, address(0), 0, false);
        nfts[v].setSubpageMinter(id, address(regs[v]));
        vm.stopPrank();
    }

    // path 0 reveal, 1 revealTrial, 2 registerSubpageFor by the parent's holder, 3 a registrar sale
    function _attempt(uint256 v, uint256 path, uint256 r, bool self) internal returns (bytes4) {
        PageNFT nft = nfts[v];
        address to = _rec(v, r);
        string memory l = _label();
        bool ok;
        bytes memory ret;
        if (path <= 1) {
            bytes32 c = nft.makeCommitment(l, to, 0, _s(l, to));
            vm.prank(bob);
            nft.commit(path == 1 ? trialCommitmentRaw(l, to, 0, _s(l, to)) : c);
            vm.warp(vm.getBlockTimestamp() + 61);
            bytes memory data = path == 1
                ? abi.encodeCall(PageNFT.revealTrial, (l, to, 0, _s(l, to)))
                : abi.encodeCall(PageNFT.reveal, (l, to, 0, _s(l, to)));
            uint256 value = path == 1 ? PRICE5 : FEE5;
            if (self) {
                (ok, ret) = _actAs(r, address(nft), value, data);
            } else {
                vm.prank(bob);
                (ok, ret) = address(nft).call{value: value}(data);
            }
        } else if (path == 2) {
            uint256 parent = _aliceParent(v);
            if (self) {
                // the recipient holds the parent and mints its own subpage
                vm.prank(alice);
                nft.transferFrom(alice, to, parent);
                (ok, ret) = _actAs(r, address(nft), 0, abi.encodeCall(PageNFT.registerSubpageFor, (l, parent, to)));
            } else {
                vm.prank(alice);
                (ok, ret) = address(nft).call(abi.encodeCall(PageNFT.registerSubpageFor, (l, parent, to)));
            }
        } else {
            uint256 parent = _registrarParent(v);
            bytes memory data = abi.encodeCall(SubpageRegistrar.registerSubpageFor, (parent, l, to, 0, address(0)));
            if (self) {
                (ok, ret) = _actAs(r, address(regs[v]), 0, data);
            } else {
                vm.prank(bob);
                (ok, ret) = address(regs[v]).call(data);
            }
        }
        return _sel(ok, ret);
    }

    function _expect(uint256 v, uint256 path, uint256 r, bool self) internal pure returns (bytes4) {
        if (r == REGISTRAR && path == 3) return SubpageRegistrar.NotAuthorized.selector;
        if (r == NFT_ITSELF) return PageNFT.InvalidRecipient.selector;
        bool hasHook = r == KEY || r == D7702_HOOK || r == SAFE;
        if (hasHook || v == P) return OK;
        if (v == S) return NOT_RECEIVER;
        if (r == D7702_NOHOOK) return OK;
        if (v == H2 && self && path != 3) return OK;
        return NOT_RECEIVER;
    }

    function _show(bytes4 s) internal pure returns (string memory) {
        if (s == OK) return "ok";
        if (s == NOT_RECEIVER) return "NotReceiver";
        if (s == PageNFT.InvalidRecipient.selector) return "InvalidRecipient";
        if (s == PageNFT.Unpaid.selector) return "Unpaid";
        if (s == SubpageRegistrar.NotAuthorized.selector) return "reg.NotAuthorized";
        return vm.toString(abi.encodePacked(s));
    }
}

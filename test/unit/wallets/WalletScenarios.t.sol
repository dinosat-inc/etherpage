// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Test, Vm} from "forge-std/Test.sol";
import {PageNFT} from "../../../src/PageNFT.sol";
import {PageCard} from "../../../src/PageCard.sol";

// the ERC6538 rule that matters here: an account can only register its own meta-address
contract MiniRegistry6538 {
    mapping(address => mapping(uint256 => bytes)) public stealthMetaAddressOf;

    function registerKeys(uint256 schemeId, bytes calldata meta) external {
        stealthMetaAddressOf[msg.sender][schemeId] = meta;
    }
}

// a stand in for an avatar collection such as CryptoPunks 721, with only a mint and the ownerOf that an
// avatar check reads
contract AvatarNFT {
    mapping(uint256 => address) public ownerOf;

    function mint(address to, uint256 id) external {
        ownerOf[id] = to;
    }
}

// delegate code with no receiver hook, the shape of the desktop wallet's SimpleDelegate
contract HooklessDelegate {
    receive() external payable {}
}

// payment codes, per app addresses, transfers and own wallet moves, as wallets and apps see them
contract WalletScenariosTest is Test {
    PageNFT nft;
    MiniRegistry6538 registry;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 constant COIN_ETH = 60;
    uint256 constant COIN_OP = 0x8000000a;
    uint256 constant COIN_BASE = 0x80002105;
    uint256 constant COIN_BTC = 0;
    uint256 constant COIN_DEFAULT_EVM = 0x80000000;
    string constant STEALTH_KEY = "stealth-address-scheme-1";

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address mallory = makeAddr("mallory");
    address victim = makeAddr("victim");

    function setUp() public {
        vm.warp(1_800_000_000);
        nft = new PageNFT(new PageCard());
        registry = new MiniRegistry6538();
    }

    function _secret(string memory l, address o) internal pure returns (bytes32) {
        return keccak256(abi.encode("wallets", l, o));
    }

    // the commitment is computed before the prank, so the commit really comes from the payer
    function _buy(address payer, string memory l, address owner) internal returns (uint256 id) {
        vm.deal(payer, payer.balance + 1 ether);
        bytes32 c = nft.makeCommitment(l, owner, 0, _secret(l, owner));
        vm.prank(payer);
        nft.commit(c);
        vm.warp(vm.getBlockTimestamp() + 61);
        (,,, uint256 total) = nft.quote(l);
        vm.prank(payer);
        id = nft.reveal{value: total}(l, owner, 0, _secret(l, owner));
    }

    function _buy(address who, string memory l) internal returns (uint256) {
        return _buy(who, l, who);
    }

    // a stealth meta-address in the st:eth:0x form, 66 bytes of keys written as hex
    function _meta(string memory tag) internal pure returns (string memory) {
        return string.concat("st:eth:0x", _hex(abi.encodePacked(keccak256(bytes(tag)), keccak256(bytes(tag)), bytes2(0x0203))));
    }

    function _hex(bytes memory b) internal pure returns (string memory s) {
        bytes memory out = new bytes(b.length * 2);
        bytes16 digits = "0123456789abcdef";
        for (uint256 i; i < b.length; ++i) {
            out[2 * i] = digits[uint8(b[i]) >> 4];
            out[2 * i + 1] = digits[uint8(b[i]) & 15];
        }
        s = string(out);
    }

    // the lookup order of eth-stealth-address-resolver 0.2.0 for a name: the text record first,
    // then ERC6538 for the address the name resolves to
    function _stealthForName(uint256 id) internal view returns (string memory meta, bool fromText) {
        string memory t = nft.text(id, STEALTH_KEY);
        if (bytes(t).length != 0) return (t, true);
        address a = nft.resolve(id);
        if (a == address(0)) return ("", false);
        return (string(registry.stealthMetaAddressOf(a, 1)), false);
    }

    // the same library for an address: ERC6538 first, then the text record of its display name
    function _stealthForAddress(address a) internal view returns (string memory meta, bool fromText) {
        bytes memory r = registry.stealthMetaAddressOf(a, 1);
        if (r.length != 0) return (string(r), false);
        string memory n = nft.reverseResolve(a);
        if (bytes(n).length == 0) return ("", false);
        uint256 id = nft.computeId(n);
        return (nft.text(id, STEALTH_KEY), true);
    }

    // the four reads of the name library kohaku-cli uses answer on a plain name, by selector;
    // a typed suffix, as in alice.names, is a different, unregistered name
    function test_nameLibraryReadsAnswer() public {
        uint256 id = _buy(alice, "alice");
        vm.startPrank(alice);
        nft.setText(id, "avatar", "a1");
        nft.setPrimaryPage(id);
        vm.stopPrank();
        assertEq(bytes4(keccak256("computeId(string)")), bytes4(0xfb021939));
        assertEq(bytes4(keccak256("resolve(uint256)")), bytes4(0x4f896d4f));
        assertEq(bytes4(keccak256("reverseResolve(address)")), bytes4(0x9af8b7aa));
        assertEq(bytes4(keccak256("text(uint256,string)")), bytes4(0x308e3386));
        (bool ok, bytes memory r) = address(nft).staticcall(abi.encodeWithSelector(0xfb021939, "alice"));
        assertTrue(ok);
        assertEq(abi.decode(r, (uint256)), id);
        (ok, r) = address(nft).staticcall(abi.encodeWithSelector(0x4f896d4f, id));
        assertTrue(ok);
        assertEq(abi.decode(r, (address)), alice);
        (ok, r) = address(nft).staticcall(abi.encodeWithSelector(0x9af8b7aa, alice));
        assertTrue(ok);
        assertEq(abi.decode(r, (string)), "alice");
        (ok, r) = address(nft).staticcall(abi.encodeWithSelector(0x308e3386, id, "avatar"));
        assertTrue(ok);
        assertEq(abi.decode(r, (string)), "a1");
        uint256 suffixed = nft.computeId("alice.names");
        assertTrue(suffixed != id);
        assertEq(nft.resolve(suffixed), address(0));
    }

    // a fresh per app address shows nothing; it cannot pick alice as its display name unless alice
    // points at it, and an app subpage makes the link to alice public
    function test_perAppAddressShowsNothingByDefault() public {
        uint256 id = _buy(alice, "alice");
        address perApp = makeAddr("perApp");
        vm.prank(perApp);
        vm.expectRevert(PageNFT.Unauthorized.selector);
        nft.setPrimaryPage(id);
        assertEq(nft.reverseResolve(perApp), "");
        vm.prank(alice);
        uint256 sub = nft.registerSubpageFor("app1", id, perApp);
        vm.prank(perApp);
        nft.setPrimaryPage(sub);
        assertEq(nft.reverseResolve(perApp), "app1.alice", "the display name itself names the parent");
    }

    // Impersonation with a payment key, two routes. Pointing (mallory keeps the NFT and sets the
    // victim as main address, and as coin 60 address too) still shows mallory's records. Sending
    // the NFT to the victim hides them.
    function test_impersonationPointingVersusAirdrop() public {
        AvatarNFT punks = new AvatarNFT();
        punks.mint(victim, 1234);
        vm.prank(victim);
        registry.registerKeys(1, bytes(_meta("victim")));

        uint256 a = _buy(mallory, "victim-support");
        vm.startPrank(mallory);
        nft.setText(a, STEALTH_KEY, _meta("mallory"));
        nft.setText(a, "avatar", "punk-1234");
        nft.setAddr(a, victim);
        vm.stopPrank();

        uint256 b = _buy(mallory, "victim-help");
        vm.startPrank(mallory);
        nft.setText(b, STEALTH_KEY, _meta("mallory"));
        nft.setText(b, "avatar", "punk-1234");
        nft.transferFrom(mallory, victim, b);
        vm.stopPrank();

        assertEq(nft.resolve(a), victim);
        assertEq(nft.resolve(b), victim);
        assertEq(nft.reverseResolve(victim), "", "the victim chose neither name");

        // pointing: the main address alone gives no coin 60 answer, so an avatar check against the
        // coin 60 address finds nothing; once mallory saves the victim for coin 60 too that check
        // passes, a check against the holder fails, and a lookup that reads text first pays mallory
        bool addrCheckA = bytes(nft.text(a, "avatar")).length != 0
            && punks.ownerOf(1234) == address(bytes20(nft.addr(a, COIN_ETH)));
        assertEq(nft.addr(a, COIN_ETH), "", "the main address does not answer coin 60");
        assertFalse(addrCheckA, "pointing the main address alone fails an address based avatar check");
        vm.prank(mallory);
        nft.setAddrForCoin(a, COIN_ETH, abi.encodePacked(victim));
        addrCheckA = bytes(nft.text(a, "avatar")).length != 0
            && punks.ownerOf(1234) == address(bytes20(nft.addr(a, COIN_ETH)));
        bool holderCheckA = bytes(nft.text(a, "avatar")).length != 0 && punks.ownerOf(1234) == nft.ownerOf(a);
        assertTrue(addrCheckA, "pointing passes an address based avatar check");
        assertFalse(holderCheckA, "pointing fails the holder check");
        (string memory metaA, bool textA) = _stealthForName(a);
        assertTrue(textA);
        assertEq(metaA, _meta("mallory"), "pointing: text first pays mallory");

        // airdrop: the planted records are hidden and the lookup falls through to the victim's own key
        bool holderCheckB = bytes(nft.text(b, "avatar")).length != 0 && punks.ownerOf(1234) == nft.ownerOf(b);
        (string memory metaB, bool textB) = _stealthForName(b);
        assertFalse(holderCheckB, "the plant is hidden");
        assertFalse(textB);
        assertEq(metaB, _meta("victim"), "falls through to the victim's own registry key");

        // the registry at resolve(id) gives the victim's own key on both routes
        assertEq(string(registry.stealthMetaAddressOf(nft.resolve(a), 1)), _meta("victim"));
        assertEq(string(registry.stealthMetaAddressOf(nft.resolve(b), 1)), _meta("victim"));
    }

    // an honest sale: the buyer uses the name as his display name and finds no payment key of the
    // seller, by name or by address, until he keeps the profile
    function test_saleStealthKeyByNameAndByAddress() public {
        uint256 id = _buy(alice, "alice");
        vm.startPrank(alice);
        nft.setText(id, STEALTH_KEY, _meta("alice"));
        nft.setText(id, "railgun", "0zk1alicealicealice");
        nft.setPrimaryPage(id);
        nft.transferFrom(alice, bob, id);
        vm.stopPrank();
        vm.prank(bob);
        nft.setPrimaryPage(id);
        assertEq(nft.reverseResolve(bob), "alice");
        assertEq(nft.resolve(id), bob);

        (string memory byName,) = _stealthForName(id);
        (string memory byAddr,) = _stealthForAddress(bob);
        assertEq(byName, "", "no key found, the payer is told so");
        assertEq(byAddr, "");
        assertEq(nft.text(id, "railgun"), "");
        // keeping the profile brings the seller's keys back with it
        vm.prank(bob);
        nft.keepProfile(id);
        (byName,) = _stealthForName(id);
        assertEq(byName, _meta("alice"), "keep revives the seller's payment key");
    }

    // what a transfer resets: the main address follows the new holder, every address the seller
    // saved and the profile and website stop counting; subpages, deposit and expiry stay
    function test_whatATransferResets() public {
        uint256 id = _buy(alice, "alice");
        vm.startPrank(alice);
        uint256 sub = nft.registerSubpage("shop", id);
        nft.setAddrForCoin(id, COIN_BTC, hex"0014aabbccddeeff00112233445566778899aabbccdd");
        nft.setAddrForCoin(id, COIN_BASE, abi.encodePacked(address(0xBA5E)));
        nft.setAddrForCoin(id, COIN_DEFAULT_EVM, abi.encodePacked(address(0xDEF)));
        nft.setText(id, "url", "https://alice.example");
        nft.setContenthash(id, hex"e3010170122001");
        nft.setPrimaryPage(id);
        uint256 dep = nft.depositOf(id);
        uint256 exp = nft.expiresAt(id);
        nft.transferFrom(alice, bob, id);
        vm.stopPrank();

        assertEq(nft.resolve(id), bob);
        assertEq(nft.addr(id, COIN_OP), abi.encodePacked(bob));
        assertEq(nft.addr(id, COIN_ETH), "", "the seller's default stops counting");
        assertEq(nft.addr(id, COIN_BASE), "", "the seller's Base entry stops counting");
        assertEq(nft.addr(id, COIN_DEFAULT_EVM), "");
        assertEq(nft.addr(id, COIN_BTC), "");
        assertEq(nft.primaryPage(alice), 0);
        assertEq(nft.ownerOf(sub), alice);
        assertEq(nft.getPageName(sub), "shop.alice");
        assertEq(nft.depositOf(id), dep);
        assertEq(nft.expiresAt(id), exp);
        assertEq(nft.text(id, "url"), "");
        assertEq(nft.contenthash(id), "");
    }

    // moving to your own new wallet with a website that knows keepProfile: one bundle from the new wallet
    function test_ownWalletMoveWithKeepInTheBundle() public {
        uint256 id = _buy(alice, "alice");
        address cold = makeAddr("aliceCold");
        vm.startPrank(alice);
        nft.setText(id, "avatar", "glam-7");
        nft.setContenthash(id, hex"e30101701220aa");
        nft.setPrimaryPage(id);
        nft.transferFrom(alice, cold, id);
        vm.stopPrank();

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(PageNFT.keepProfile, (id));
        calls[1] = abi.encodeCall(PageNFT.setPrimaryPage, (id));
        vm.prank(cold);
        uint256 g = gasleft();
        nft.multicall(calls);
        g -= gasleft();
        emit log_named_uint("new wallet bundle, exec gas", g);
        assertEq(nft.reverseResolve(cold), "alice");
        assertEq(nft.text(id, "avatar"), "glam-7");
        assertEq(nft.contenthash(id), hex"e30101701220aa");
    }

    // the same move through an app that does not know keepProfile leaves the profile and the
    // website dark until the new wallet keeps them
    function test_ownWalletMoveWithAnUnawareApp() public {
        uint256 id = _buy(alice, "alice");
        address cold = makeAddr("aliceCold");
        vm.startPrank(alice);
        nft.setText(id, "avatar", "glam-7");
        nft.setContenthash(id, hex"e30101701220aa");
        nft.transferFrom(alice, cold, id);
        vm.stopPrank();
        vm.prank(cold);
        nft.setPrimaryPage(id);
        assertEq(nft.reverseResolve(cold), "alice");
        assertEq(nft.text(id, "avatar"), "");
        assertEq(nft.contenthash(id), "", "the website is offline until the new wallet keeps it");
        // hidden, not lost: a keep later restores it
        vm.prank(cold);
        nft.keepProfile(id);
        assertEq(nft.contenthash(id), hex"e30101701220aa");
    }

    // a keep screen can preview known keys with one plain call (eth_call of a bundle), with no
    // events and no indexer, and the preview changes nothing
    function test_keepPreviewWithAPlainCall() public {
        uint256 id = _buy(alice, "alice");
        vm.startPrank(alice);
        nft.setText(id, "url", "https://alice.example");
        nft.setText(id, STEALTH_KEY, _meta("alice"));
        nft.setContenthash(id, hex"e30101701220bb");
        nft.transferFrom(alice, bob, id);
        vm.stopPrank();
        bytes[] memory calls = new bytes[](4);
        calls[0] = abi.encodeCall(PageNFT.keepProfile, (id));
        calls[1] = abi.encodeWithSignature("text(uint256,string)", id, "url");
        calls[2] = abi.encodeWithSignature("text(uint256,string)", id, STEALTH_KEY);
        calls[3] = abi.encodeWithSignature("contenthash(uint256)", id);
        uint256 snap = vm.snapshotState();
        vm.prank(bob);
        bytes[] memory out = nft.multicall(calls);
        vm.revertToState(snap);
        assertEq(abi.decode(out[1], (string)), "https://alice.example");
        assertEq(abi.decode(out[2], (string)), _meta("alice"), "the preview shows the payment key it would bring back");
        assertEq(abi.decode(out[3], (bytes)), hex"e30101701220bb");
        assertEq(nft.profileWriter(id), alice);
        assertEq(nft.text(id, "url"), "");
    }

    // Gift back. Bob buys, plants a scam link and gives the name back. The hot wallet alice pointed
    // at shows alice again. The plant stays hidden, and a keep would adopt it, not alice's old profile.
    function test_giftBackPlant() public {
        uint256 id = _buy(alice, "alice");
        address hot = makeAddr("aliceHot");
        vm.startPrank(alice);
        nft.setText(id, "url", "https://alice.example");
        nft.setAddr(id, hot);
        vm.stopPrank();
        vm.prank(hot);
        nft.setPrimaryPage(id);
        assertEq(nft.reverseResolve(hot), "alice");
        vm.prank(alice);
        nft.transferFrom(alice, bob, id);
        assertEq(nft.reverseResolve(hot), "", "hidden while bob holds the name");
        vm.startPrank(bob);
        nft.setText(id, "url", "https://scam.example");
        nft.transferFrom(bob, alice, id);
        vm.stopPrank();
        assertEq(nft.reverseResolve(hot), "alice", "the hot wallet shows alice again");
        assertEq(nft.text(id, "url"), "", "the plant is hidden");
        vm.prank(alice);
        nft.keepProfile(id);
        assertEq(nft.text(id, "url"), "https://scam.example", "keep adopts the last writer's profile");
    }

    // A 7702 account whose delegate has no hook can be named owner by anyone, because its key can
    // always move the name. A safe transfer to it still fails, a plain transfer works, and it
    // answers on coin type 60 once it saves a default, like any holder. A delegation made for
    // Ethereum only leaves no code on OP.
    function test_hooklessDelegate() public {
        (address l1Vault,) = makeAddrAndKey("l1OnlyVault");
        uint256 id = _buy(alice, "vaultname", l1Vault);
        assertEq(nft.ownerOf(id), l1Vault, "no code on OP, a normal mint");

        (address opVault, uint256 key) = makeAddrAndKey("opVault");
        HooklessDelegate d = new HooklessDelegate();
        vm.signAndAttachDelegation(address(d), key);
        assertEq(opVault.code.length, 23);
        uint256 v = _buy(alice, "opvaultname", opVault);
        assertEq(nft.ownerOf(v), opVault);
        assertEq(nft.addr(v, COIN_ETH), "", "nothing saved for coin 60 yet");

        uint256 id2 = _buy(alice, "opvaultmove");
        vm.prank(alice);
        vm.expectRevert(bytes4(0xd1a57ed6));
        nft.safeTransferFrom(alice, opVault, id2);
        vm.prank(alice);
        nft.transferFrom(alice, opVault, id2);
        assertEq(nft.ownerOf(id2), opVault);
        assertEq(nft.addr(id2, COIN_ETH), "", "its code changes no answer");
        vm.prank(opVault);
        nft.setAddrForCoin(id2, COIN_DEFAULT_EVM, abi.encodePacked(opVault));
        assertEq(nft.addr(id2, COIN_ETH), abi.encodePacked(opVault), "the saved default answers coin 60");
    }

    // neither way of changing wallets is private: pointing logs AddressChanged for the home chain coin type, moving
    // logs Transfer
    function test_rotationIsAlwaysPublic() public {
        uint256 id = _buy(alice, "alice");
        address hot = makeAddr("hot");
        address cold = makeAddr("cold");
        vm.recordLogs();
        vm.prank(alice);
        nft.setAddr(id, hot);
        vm.prank(alice);
        nft.transferFrom(alice, cold, id);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool pointLogged;
        bool moveLogged;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == keccak256("AddressChanged(bytes32,uint256,bytes)")) {
                (uint256 coin, bytes memory a) = abi.decode(logs[i].data, (uint256, bytes));
                if (coin == COIN_OP && keccak256(a) == keccak256(abi.encodePacked(hot))) pointLogged = true;
            }
            if (
                logs[i].topics[0] == keccak256("Transfer(address,address,uint256)")
                    && logs[i].topics[1] == bytes32(uint256(uint160(alice))) && logs[i].topics[2] == bytes32(uint256(uint160(cold)))
            ) moveLogged = true;
        }
        assertTrue(pointLogged);
        assertTrue(moveLogged);
    }

    // A holder that never sends an OP transaction (a wallet used only on Ethereum). Pointing at it,
    // with the main address and a coin 60 entry saved by the holder, keeps the profile; moving the
    // NFT there darkens the profile until a keep and empties coin 60 until a save, and that wallet
    // can send neither.
    function test_l1OnlyWalletPointNotMove() public {
        uint256 id = _buy(alice, "alice");
        address l1Wallet = makeAddr("l1Wallet");
        vm.startPrank(alice);
        nft.setText(id, "avatar", "glam-9");
        nft.setAddr(id, l1Wallet);
        vm.stopPrank();
        assertEq(nft.addr(id, COIN_ETH), "", "pointing the main address alone leaves coin 60 empty");
        vm.prank(alice);
        nft.setAddrForCoin(id, COIN_ETH, abi.encodePacked(l1Wallet));
        assertEq(nft.addr(id, COIN_ETH), abi.encodePacked(l1Wallet), "pointing: coin 60 answers the wallet");
        assertEq(nft.text(id, "avatar"), "glam-9", "pointing: the profile stays");
        vm.prank(alice);
        nft.transferFrom(alice, l1Wallet, id);
        assertEq(nft.addr(id, COIN_ETH), "", "moving: alice's coin 60 entry stops counting");
        assertEq(nft.text(id, "avatar"), "", "moving: dark until a keep");
    }
}

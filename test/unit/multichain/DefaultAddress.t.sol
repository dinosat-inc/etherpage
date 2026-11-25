// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Test, Vm} from "forge-std/Test.sol";
import {ERC721} from "solady/tokens/ERC721.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {PageCard} from "../../../src/PageCard.sol";
import {PageNFT} from "../../../src/PageNFT.sol";
import {SubpageRegistrar, IPageNFT} from "../../../src/SubpageRegistrar.sol";
import {StorageReader} from "../../utils/NamingBase.sol";

// wallet code with both hooks, standing in for the code an account adopts under EIP8298
contract AdoptedWallet {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    receive() external payable {}
}

// wallet code with neither hook
contract BareWallet {
    function ping() external pure returns (uint256) {
        return 1;
    }
}

// a contract holder that runs calls for its controller
contract DefaultHolder {
    address immutable controller;

    constructor(address c) {
        controller = c;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    function exec(address to, bytes calldata data) external payable returns (bytes memory) {
        require(msg.sender == controller, "not controller");
        (bool ok, bytes memory ret) = to.call{value: msg.value}(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        return ret;
    }
}

// The default address for every EVM chain, coin type 0x80000000, that a holder may save. Every EVM chain but the
// home chain with no address of its own answers it, and with no default such a chain answers nothing, whatever the
// code of the holder or the main address. It counts only while its saver holds the name in the record version it was
// saved in, and it never moves the main address, the payee, the answer of the home chain or a display name.
contract DefaultAddressTest is Test {
    PageNFT nft;
    SubpageRegistrar reg;

    uint256 constant ETH = 60;
    uint256 constant OP = 0x8000000a;
    uint256 constant DEF = 0x80000000;
    uint256 constant BASE = 0x80002105;
    uint256 constant ARB = 0x8000a4b1;
    uint256 constant NEWCHAIN = 0x80000000 | 999_999;
    uint256 constant BTC = 0;
    uint256 constant GRACE = 90 days;
    uint256 constant DECAY = 21 days;
    bytes32 constant T_ADDRESS = keccak256("AddressChanged(bytes32,uint256,bytes)");
    bytes32 constant T_ADDR = keccak256("AddrChanged(bytes32,address)");
    bytes32 constant T_META = keccak256("MetadataUpdate(uint256)");

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address relayer = makeAddr("relayer");
    address stranger = makeAddr("stranger");
    address cold = makeAddr("cold");
    address other = makeAddr("other");

    function setUp() public {
        vm.warp(1_800_000_000);
        nft = new PageNFT(new PageCard());
        reg = new SubpageRegistrar(IPageNFT(address(nft)));
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(relayer, 100 ether);
    }

    function _reveal(address payer, string memory label, address owner) internal returns (uint256 id) {
        bytes32 secret = keccak256(abi.encode(label, owner, vm.getBlockTimestamp()));
        bytes32 c = nft.makeCommitment(label, owner, 0, secret);
        vm.prank(payer);
        nft.commit(c);
        vm.warp(vm.getBlockTimestamp() + 61);
        (,,, uint256 total) = nft.quote(label);
        vm.deal(payer, payer.balance + total);
        vm.prank(payer);
        id = nft.reveal{value: total}(label, owner, 0, secret);
    }

    function _enc(address a) internal pure returns (bytes memory) {
        return a == address(0) ? bytes("") : abi.encodePacked(a);
    }

    // every EVM chain but OP that has no entry of its own
    function _unsavedEvm(uint256 id, address want, string memory why) internal view {
        bytes memory w = _enc(want);
        assertEq(nft.addr(id, DEF), w, string.concat(why, ": the default"));
        assertEq(nft.addr(id, ARB), w, string.concat(why, ": Arbitrum"));
        assertEq(nft.addr(id, NEWCHAIN), w, string.concat(why, ": a chain that does not exist yet"));
        assertEq(nft.addr(id, 0xffffffff), w, string.concat(why, ": the last EVM coin type"));
    }

    function _save(address who, uint256 id, uint256 coin, bytes memory v) internal {
        vm.prank(who);
        nft.setAddrForCoin(id, coin, v);
    }

    function _coinLogs(Vm.Log[] memory logs) internal view returns (uint256[] memory coins, bytes[] memory values) {
        coins = new uint256[](logs.length);
        values = new bytes[](logs.length);
        uint256 n;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(nft) || logs[i].topics[0] != T_ADDRESS) continue;
            (coins[n], values[n]) = abi.decode(logs[i].data, (uint256, bytes));
            ++n;
        }
        assembly ("memory-safe") {
            mstore(coins, n)
            mstore(values, n)
        }
    }

    // A 7702 account registers, then adopts regular code as EIP8298 would. Outside the home chain it answers nothing
    // before and after, so the new code changes no answer, and one save of the default makes every EVM chain answer
    // it, the ones that do not exist yet included.
    function test_hardenedAccountAnswersEverywhereAfterOneSave() public {
        (address acct, uint256 key) = makeAddrAndKey("seven");
        vm.signAndAttachDelegation(address(new AdoptedWallet()), key);
        (bool ok,) = acct.call("");
        assertTrue(ok);
        assertEq(acct.code.length, 23);
        uint256 id = _reveal(acct, "alice", acct);
        assertEq(nft.addr(id, OP), _enc(acct), "the home chain answers the main address");
        _unsavedEvm(id, address(0), "a 7702 account, nothing saved");
        assertEq(nft.addr(id, ETH), "", "coin type 60 answers nothing before a save");

        vm.etch(acct, type(AdoptedWallet).runtimeCode);
        assertEq(nft.addr(id, OP), _enc(acct), "OP answers the main address whatever its code");
        assertEq(nft.addr(id, ETH), "", "hardened: coin type 60 is still silent");
        _unsavedEvm(id, address(0), "hardened, nothing saved");

        vm.recordLogs();
        _save(acct, id, DEF, abi.encodePacked(acct));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 3, "three events and nothing else");
        (uint256[] memory coins, bytes[] memory values) = _coinLogs(logs);
        assertEq(coins.length, 2);
        assertEq(coins[0], DEF, "the default first");
        assertEq(values[0], _enc(acct));
        assertEq(coins[1], ETH, "then the Ethereum answer it implies");
        assertEq(values[1], _enc(acct));
        assertEq(logs[2].topics[0], T_ADDR, "and AddrChanged last");
        assertEq(abi.decode(logs[2].data, (address)), acct, "with the same Ethereum answer");

        _unsavedEvm(id, acct, "hardened, default saved");
        assertEq(nft.addr(id, ETH), _enc(acct));
        assertEq(nft.addr(id, BASE), _enc(acct));
        assertEq(nft.addr(id, OP), _enc(acct));
        assertEq(nft.resolve(id), acct);
        assertEq(nft.payee(id), acct);
    }

    // own entry, then the saved default, then empty, the same for every kind of holder; the home chain always
    // answers the main address. Run for a key wallet holder, a 7702 holder and a holder with regular code.
    function test_precedenceForEveryHolderKind() public {
        address seven = makeAddr("sevenHolder");
        vm.etch(seven, abi.encodePacked(hex"ef0100", address(new AdoptedWallet())));
        address hardened = makeAddr("hardenedHolder");
        address[3] memory holders = [alice, seven, hardened];
        string[3] memory labels = ["kind-a", "kind-b", "kind-c"];
        for (uint256 i; i < 3; ++i) {
            address h = holders[i];
            uint256 id = _reveal(relayer, labels[i], h);
            if (i == 2) vm.etch(h, type(AdoptedWallet).runtimeCode);
            _unsavedEvm(id, address(0), "nothing saved");
            assertEq(nft.addr(id, ETH), "", "coin type 60 answers nothing before a save");

            _save(h, id, BASE, abi.encodePacked(other));
            _save(h, id, DEF, abi.encodePacked(cold));
            assertEq(nft.addr(id, BASE), _enc(other), "an own entry wins");
            assertEq(nft.addr(id, ETH), _enc(cold), "Ethereum follows the default");
            _unsavedEvm(id, cold, "default saved");
            assertEq(nft.addr(id, OP), _enc(h), "OP stays the main address");
            assertEq(nft.resolve(id), h);
            assertEq(nft.payee(id), h);

            _save(h, id, ETH, abi.encodePacked(bob));
            assertEq(nft.addr(id, ETH), _enc(bob), "an Ethereum entry wins over the default");

            // twenty zero bytes and empty bytes both clear it, and those chains answer nothing again
            _save(h, id, DEF, new bytes(20));
            _unsavedEvm(id, address(0), "cleared with zero");
            _save(h, id, DEF, abi.encodePacked(cold));
            _save(h, id, DEF, "");
            _unsavedEvm(id, address(0), "cleared with empty bytes");
            assertEq(nft.addr(id, BASE), _enc(other), "the own entries stay");
            assertEq(nft.addr(id, ETH), _enc(bob));
            assertEq(nft.addr(id, BTC), "", "outside the EVM nothing falls back");
        }
    }

    // only the holder of an active name may save it; the error order is Expired, Unauthorized, InvalidLength
    function test_onlyTheHolderSavesIt() public {
        uint256 id = _reveal(relayer, "club", alice);
        address appr = makeAddr("approved");
        address op = makeAddr("operator");
        address minter = makeAddr("minter");
        vm.startPrank(alice);
        nft.setAddr(id, cold);
        nft.approve(appr, id);
        nft.setApprovalForAll(op, true);
        nft.setSubpageMinter(id, minter);
        uint256 sub = nft.registerSubpageFor("pay", id, bob);
        vm.stopPrank();

        address[6] memory others = [appr, op, minter, relayer, cold, stranger];
        for (uint256 i; i < others.length; ++i) {
            vm.startPrank(others[i]);
            vm.expectRevert(PageNFT.Unauthorized.selector);
            nft.setAddrForCoin(id, DEF, abi.encodePacked(others[i]));
            vm.expectRevert(PageNFT.Unauthorized.selector);
            nft.setAddrForCoin(id, DEF, hex"01");
            vm.stopPrank();
        }
        // the parent holder cannot save a default on the subpage
        vm.prank(alice);
        vm.expectRevert(PageNFT.Unauthorized.selector);
        nft.setAddrForCoin(sub, DEF, abi.encodePacked(alice));
        // the holder: the length is checked
        vm.startPrank(alice);
        vm.expectRevert(PageNFT.InvalidLength.selector);
        nft.setAddrForCoin(id, DEF, hex"01");
        vm.expectRevert(PageNFT.InvalidLength.selector);
        nft.setAddrForCoin(id, DEF, abi.encodePacked(alice, hex"00"));
        vm.stopPrank();
        // inside multicall it is the same call by the same caller
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeCall(PageNFT.setAddrForCoin, (id, DEF, abi.encodePacked(stranger)));
        vm.prank(stranger);
        vm.expectRevert(PageNFT.Unauthorized.selector);
        nft.multicall(calls);
        vm.prank(alice);
        nft.multicall(calls);
        assertEq(nft.addr(id, ARB), _enc(stranger), "the holder may point it anywhere, as with any entry");
        // an expired name: Expired for everyone, before anything else
        vm.warp(nft.expiresAt(id) + 1);
        vm.prank(alice);
        vm.expectRevert(PageNFT.Expired.selector);
        nft.setAddrForCoin(id, DEF, hex"01");
        vm.prank(stranger);
        vm.expectRevert(PageNFT.Expired.selector);
        nft.setAddrForCoin(id, DEF, hex"01");
    }

    // it counts only while its saver holds the name, and the move announces the coin type 60 answer it changes
    function test_followsItsSaver() public {
        uint256 id = _reveal(relayer, "move", alice);
        _save(alice, id, DEF, abi.encodePacked(cold));
        _unsavedEvm(id, cold, "seller");

        vm.recordLogs();
        vm.prank(alice);
        nft.transferFrom(alice, bob, id);
        (uint256[] memory coins, bytes[] memory values) = _coinLogs(vm.getRecordedLogs());
        bool sawEth;
        for (uint256 i; i < coins.length; ++i) {
            if (coins[i] == ETH) {
                sawEth = true;
                assertEq(values[i], "", "the move announces the buyer's empty coin type 60 answer");
            }
        }
        assertTrue(sawEth);
        assertEq(nft.addr(id, ETH), "");
        _unsavedEvm(id, address(0), "the seller's default does not count for the buyer");

        vm.prank(bob);
        nft.transferFrom(bob, alice, id);
        _unsavedEvm(id, cold, "back with its saver, it counts again");

        // one entry per record version: a save by the next holder takes it over, so it does not come back
        vm.prank(alice);
        nft.transferFrom(alice, bob, id);
        _save(bob, id, DEF, abi.encodePacked(other));
        _unsavedEvm(id, other, "the buyer's own default");
        vm.prank(bob);
        nft.transferFrom(bob, alice, id);
        _unsavedEvm(id, address(0), "the entry is the buyer's now, so the seller has none and nothing answers");
    }

    // clearRecords, a new registration and a new mint of a subpage retire it for good
    function test_retiredForGood() public {
        uint256 id = _reveal(relayer, "gone", alice);
        _save(alice, id, DEF, abi.encodePacked(cold));
        vm.prank(alice);
        nft.clearRecords(id);
        _unsavedEvm(id, address(0), "after clearRecords");
        vm.prank(alice);
        nft.transferFrom(alice, bob, id);
        vm.prank(bob);
        nft.transferFrom(bob, alice, id);
        _unsavedEvm(id, address(0), "not even after a round trip");

        _save(alice, id, DEF, abi.encodePacked(cold));
        vm.warp(nft.expiresAt(id) + GRACE + DECAY + 1);
        assertEq(_reveal(relayer, "gone", alice), id, "the same account registers it again");
        _unsavedEvm(id, address(0), "after a new registration");

        vm.startPrank(alice);
        uint256 sub = nft.registerSubpageFor("pay", id, bob);
        vm.stopPrank();
        _save(bob, sub, DEF, abi.encodePacked(other));
        _unsavedEvm(sub, other, "the subpage holder's default");
        vm.prank(alice);
        nft.registerSubpageFor("pay", id, bob);
        _unsavedEvm(sub, address(0), "minted again by the parent holder, even to the same account");
    }

    // keepProfile brings back text and website only, never an address
    function test_keepProfileNeverBringsItBack() public {
        uint256 id = _reveal(relayer, "keep", alice);
        vm.startPrank(alice);
        nft.setText(id, "url", "https://alice.example");
        nft.setAddrForCoin(id, DEF, abi.encodePacked(cold));
        nft.setAddrForCoin(id, BASE, abi.encodePacked(cold));
        nft.transferFrom(alice, bob, id);
        vm.stopPrank();
        vm.prank(bob);
        nft.keepProfile(id);
        assertEq(nft.text(id, "url"), "https://alice.example", "the profile is kept");
        _unsavedEvm(id, address(0), "the seller's default is not");
        assertEq(nft.addr(id, BASE), "", "nor its chain entries");
    }

    // the default is never the main address, the payee, the OP answer or a display name
    function test_noMoneyOrDisplayEffect() public {
        uint256 id = _reveal(relayer, "money", alice);
        bytes32 uriBefore = keccak256(bytes(nft.tokenURI(id)));
        _save(alice, id, DEF, abi.encodePacked(cold));
        assertEq(keccak256(bytes(nft.tokenURI(id))), uriBefore, "the card does not change");
        assertEq(nft.resolve(id), alice);
        // addr by node answers coin type 60, which the default reaches, never the main address
        assertEq(nft.addr(bytes32(id)), cold);
        assertEq(nft.addr(id, OP), _enc(alice));
        assertEq(nft.payee(id), alice);
        vm.prank(cold);
        vm.expectRevert(PageNFT.Unauthorized.selector);
        nft.setPrimaryPage(id);
        assertEq(nft.reverseResolve(cold), "");
        // money the contract pays for the name is credited to the main address
        vm.warp(nft.expiresAt(id) + GRACE + DECAY + 1);
        uint256 deposit = nft.depositOf(id);
        nft.release(id);
        assertEq(nft.owed(alice), deposit);
        assertEq(nft.owed(cold), 0);
    }

    // a default saved before a push never counts for the receiver, nor after the receiver gets code
    function test_pushedDefaultNeverCounts() public {
        address h = makeAddr("receiver");
        uint256 id = _reveal(relayer, "push", other);
        vm.startPrank(other);
        nft.setAddrForCoin(id, DEF, abi.encodePacked(other));
        nft.setAddrForCoin(id, BASE, abi.encodePacked(other));
        nft.transferFrom(other, h, id);
        vm.stopPrank();
        _unsavedEvm(id, address(0), "the receiver saved nothing");
        assertEq(nft.addr(id, ETH), "");
        vm.etch(h, type(AdoptedWallet).runtimeCode);
        _unsavedEvm(id, address(0), "silent, never the sender's default");
        assertEq(nft.addr(id, ETH), "");
    }

    // nothing answers while the name is not active; a renewal in grace brings the default back
    function test_inactiveAnswersNothing() public {
        uint256 id = _reveal(relayer, "lapse", alice);
        _save(alice, id, DEF, abi.encodePacked(cold));
        vm.warp(nft.expiresAt(id) + 1);
        _unsavedEvm(id, address(0), "expired");
        assertEq(nft.addr(id, ETH), "");
        vm.prank(stranger);
        vm.deal(stranger, 1 ether);
        nft.renew{value: nft.getFee(5)}(id);
        _unsavedEvm(id, cold, "renewed by anyone");
    }

    // once saved, the default does not follow code appearing or leaving, so no Ethereum answer changes silently
    function test_savedDefaultIgnoresCode() public {
        uint256 id = _reveal(relayer, "code", alice);
        _save(alice, id, DEF, abi.encodePacked(alice));
        vm.recordLogs();
        vm.etch(alice, type(AdoptedWallet).runtimeCode);
        assertEq(vm.getRecordedLogs().length, 0);
        _unsavedEvm(id, alice, "code appeared");
        assertEq(nft.addr(id, ETH), _enc(alice), "the last Ethereum event still holds");
        vm.etch(alice, "");
        _unsavedEvm(id, alice, "code left");
    }

    // a contract holder opts in with one save, from its own call, and stays the only one that can change it
    function test_contractHolderOptsIn() public {
        DefaultHolder safe = new DefaultHolder(alice);
        uint256 id = _reveal(relayer, "vault", address(safe));
        _unsavedEvm(id, address(0), "a contract answers only on OP");
        vm.prank(alice);
        safe.exec(address(nft), abi.encodeCall(PageNFT.setAddrForCoin, (id, DEF, abi.encodePacked(address(safe)))));
        _unsavedEvm(id, address(safe), "opted in");
        vm.prank(bob);
        vm.expectRevert("not controller");
        safe.exec(address(nft), abi.encodeCall(PageNFT.setAddrForCoin, (id, DEF, abi.encodePacked(bob))));
    }

    // what a storage proof reader rebuilds from raw storage matches every answer after default saves and moves
    function test_storageReaderAgrees() public {
        StorageReader reader = new StorageReader(address(nft));
        uint256 id = _reveal(relayer, "proof", alice);
        uint256[6] memory coins = [ETH, OP, DEF, BASE, NEWCHAIN, BTC];
        for (uint256 step; step < 6; ++step) {
            if (step == 1) _save(alice, id, DEF, abi.encodePacked(cold));
            if (step == 2) _save(alice, id, BASE, abi.encodePacked(other));
            if (step == 3) vm.etch(alice, type(AdoptedWallet).runtimeCode);
            if (step == 4) {
                vm.prank(alice);
                nft.transferFrom(alice, bob, id);
            }
            if (step == 5) _save(bob, id, DEF, abi.encodePacked(bob));
            for (uint256 c; c < coins.length; ++c) {
                assertEq(reader.addr(id, coins[c]), nft.addr(id, coins[c]), "reader and contract");
            }
        }
    }

    // who must accept a name: a mint by someone else asks code that is not a key wallet, a mint by the account
    // itself does not, and a payout to code without receive stays owed
    function test_hooksAHardenedAccountNeeds() public {
        address bare = makeAddr("bare");
        address full = makeAddr("full");
        vm.etch(bare, type(BareWallet).runtimeCode);
        vm.etch(full, type(AdoptedWallet).runtimeCode);

        // a relayer pays a reveal for each
        string memory label = "hooked";
        bytes32 secret = keccak256("hooked");
        vm.prank(relayer);
        nft.commit(nft.makeCommitment(label, bare, 0, secret));
        vm.warp(vm.getBlockTimestamp() + 61);
        (,,, uint256 total) = nft.quote(label);
        vm.prank(relayer);
        vm.expectRevert(ERC721.TransferToNonERC721ReceiverImplementer.selector);
        nft.reveal{value: total}(label, bare, 0, secret);
        uint256 id = _reveal(relayer, "hooked-full", full);
        assertEq(nft.ownerOf(id), full);

        // a parent holder mints a subpage, and the registrar sells one, to each
        uint256 shop = _reveal(relayer, "shop", alice);
        vm.prank(alice);
        vm.expectRevert(ERC721.TransferToNonERC721ReceiverImplementer.selector);
        nft.registerSubpageFor("b", shop, bare);
        vm.prank(alice);
        nft.registerSubpageFor("f", shop, full);
        vm.startPrank(alice);
        nft.setSubpageMinter(shop, address(reg));
        reg.configure(shop, address(0), address(0), 0.001 ether, true, address(0), 0, false);
        vm.stopPrank();
        vm.deal(bare, 1 ether);
        vm.prank(bare);
        vm.expectRevert(ERC721.TransferToNonERC721ReceiverImplementer.selector);
        reg.registerSubpage{value: 0.001 ether}(shop, "bb", 0.001 ether, address(0));
        vm.deal(full, 1 ether);
        vm.prank(full);
        reg.registerSubpage{value: 0.001 ether}(shop, "ff", 0.001 ether, address(0));

        // the account reveals for itself, so no hook is asked
        vm.deal(bare, 1 ether);
        uint256 own = _reveal(bare, "selfmade", bare);
        assertEq(nft.ownerOf(own), bare);

        // a payout to code without receive cannot be sent, and stays owed
        vm.warp(nft.expiresAt(own) + GRACE + DECAY + 1);
        nft.release(own);
        uint256 owedBare = nft.owed(bare);
        assertGt(owedBare, 0);
        vm.expectRevert(SafeTransferLib.ETHTransferFailed.selector);
        nft.withdraw(bare);
        assertEq(nft.owed(bare), owedBare, "still owed");
    }

    // Any walk of saves, clears, moves and code changes: every EVM chain but the home chain with no entry of its own
    // answers what the default answers, and the default is exactly what the current holder saved in the current
    // record version, else empty, whatever the code of the holder or the main address.
    function testFuzz_unsavedChainsFollowTheDefault(uint256 seed, address v1, address v2) public {
        address h1 = alice;
        address h2 = address(new DefaultHolder(address(this)));
        uint256 id = _reveal(relayer, "walk", h1);
        address cur = h1;
        uint256 savedCoin = seed % 2 == 0 ? ETH : BASE;
        address[4] memory pool = [v1, v2, address(0), cur];
        for (uint256 i; i < 12; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            uint256 step = r % 7;
            address val = pool[(r >> 8) % 4];
            bytes memory data;
            if (step == 0) data = abi.encodeCall(PageNFT.setAddrForCoin, (id, DEF, abi.encodePacked(val)));
            if (step == 1) data = abi.encodeCall(PageNFT.setAddrForCoin, (id, DEF, bytes("")));
            if (step == 2) data = abi.encodeCall(PageNFT.setAddrForCoin, (id, savedCoin, abi.encodePacked(val)));
            if (step == 3 && val != address(nft)) data = abi.encodeCall(PageNFT.setAddr, (id, val));
            if (step == 4) data = abi.encodeCall(PageNFT.clearRecords, (id));
            if (step == 5) {
                address to = cur == h1 ? h2 : h1;
                data = abi.encodeCall(PageNFT.transferFrom, (cur, to, id));
                _as(cur, data);
                cur = to;
                data = "";
            }
            if (step == 6 && cur == h1) {
                if (h1.code.length == 0) vm.etch(h1, type(AdoptedWallet).runtimeCode);
                else vm.etch(h1, "");
            }
            if (data.length != 0) _as(cur, data);

            bytes memory def = nft.addr(id, DEF);
            uint256[4] memory reads = [ETH, ARB, NEWCHAIN, 0xffffffff];
            for (uint256 k; k < 4; ++k) {
                if (reads[k] == savedCoin) continue;
                assertEq(nft.addr(id, reads[k]), def, "an EVM chain with no entry of its own differs from the default");
            }
            // the default itself is what the current holder saved, else empty
            if (def.length != 0) {
                assertTrue(_holderSaved(id, cur, address(bytes20(def))), "a default no current save explains");
            }
            assertEq(def, _enc(_savedDefault(id, cur)), "the default is exactly the current holder's save, or empty");
        }
    }

    // whether the current holder saved this default in the current record version, read from storage
    function _holderSaved(uint256 id, address holder, address a) internal view returns (bool) {
        uint256 v = nft.recordVersion(id);
        bytes32 entry = keccak256(abi.encode(DEF, keccak256(abi.encode(v, keccak256(abi.encode(id, uint256(9)))))));
        address saver = address(uint160(uint256(vm.load(address(nft), entry))));
        bytes32 w = vm.load(address(nft), bytes32(uint256(entry) + 1));
        return saver == holder && address(bytes20(w)) == a && uint256(w) & 0xff == 40;
    }

    // the default the holder saved in the current record version, read from storage, or zero when it saved none
    function _savedDefault(uint256 id, address holder) internal view returns (address) {
        uint256 v = nft.recordVersion(id);
        bytes32 entry = keccak256(abi.encode(DEF, keccak256(abi.encode(v, keccak256(abi.encode(id, uint256(9)))))));
        address saver = address(uint160(uint256(vm.load(address(nft), entry))));
        bytes32 w = vm.load(address(nft), bytes32(uint256(entry) + 1));
        return saver == holder && uint256(w) & 0xff == 40 ? address(bytes20(w)) : address(0);
    }

    function _as(address h, bytes memory data) internal {
        if (h.code.length > 23 && h != alice) {
            DefaultHolder(h).exec(address(nft), data);
        } else {
            vm.prank(h);
            (bool ok, bytes memory ret) = address(nft).call(data);
            if (!ok) {
                assembly ("memory-safe") {
                    revert(add(ret, 0x20), mload(ret))
                }
            }
        }
    }
}

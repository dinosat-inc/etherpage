// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Vm} from "forge-std/Test.sol";
import {PageNFT} from "../../../src/PageNFT.sol";
import {MinterBase} from "../../utils/MinterBase.sol";

// saves a main address on a name it holds, when told to or from inside its receiver hook when armed
contract SavingHolder {
    address public saveAs;
    bool public armed;
    bool public viaCoin;

    function arm(address a, bool coin) external {
        saveAs = a;
        viaCoin = coin;
        armed = true;
    }

    function save(PageNFT nft, uint256 id, address a, bool coin) public {
        if (coin) nft.setAddrForCoin(id, 0x8000000a, abi.encodePacked(a));
        else nft.setAddr(id, a);
    }

    function onERC721Received(address, address, uint256 id, bytes calldata) external returns (bytes4) {
        if (armed) save(PageNFT(msg.sender), id, saveAs, viaCoin);
        return this.onERC721Received.selector;
    }
}

// The main address is never PageNFT itself. The same calls run with PageNFT as the address and with any other
// address, on every route a main address is saved by: setAddr and setAddrForCoin for OP, with clean and dirty
// calldata, inside a bundle, by a contract holder, and from a receiver hook inside a transfer, a subpage mint, a
// registrar sale and a registration, on a top level name and on a subpage. PageNFT is refused with
// InvalidRecipient and nothing changes; every other address is saved and counts.
contract RegistryRefusalTest is MinterBase {
    uint256 constant PRICE = 0.001 ether;

    uint256 club;
    uint256 sub;

    struct Answers {
        address owner;
        address resolved;
        address payee;
        bytes op;
        bytes eth;
        bytes32 saved;
        bytes32 saver;
    }

    function setUp() public override {
        super.setUp();
        club = _register(alice, "club", alice);
        vm.prank(alice);
        sub = nft.registerSubpageFor("sub", club, alice);
        _sellSetup(club, PRICE);
        // earlier saves, which a refused call must leave in place
        vm.startPrank(alice);
        nft.setAddr(club, hot);
        nft.setAddr(sub, hot);
        vm.stopPrank();
        // the raw words the checks compare hold the save
        Answers memory a = _answers(sub);
        assertEq(address(uint160(uint256(a.saved))), hot, "saved word");
        assertEq(address(uint160(uint256(a.saver))), alice, "saver word");
    }

    function _register(address payer, string memory label, address to) internal returns (uint256 id) {
        bytes32 secret = keccak256(abi.encode(label, to));
        bytes32 c = nft.makeCommitment(label, to, 0, secret);
        vm.prank(payer);
        nft.commit(c);
        vm.warp(vm.getBlockTimestamp() + 61);
        (,,, uint256 total) = nft.quote(label);
        vm.prank(payer);
        id = nft.reveal{value: total}(label, to, 0, secret);
    }

    function _answers(uint256 id) internal view returns (Answers memory s) {
        uint256 v = nft.recordVersion(id);
        s.owner = nft.ownerOf(id);
        s.resolved = nft.resolve(id);
        s.payee = nft.payee(id);
        s.op = nft.addr(id, COIN_OP);
        s.eth = nft.addr(id, 60);
        s.saved = vm.load(address(nft), keccak256(abi.encode(v, keccak256(abi.encode(id, uint256(7))))));
        s.saver = vm.load(address(nft), keccak256(abi.encode(v, keccak256(abi.encode(id, uint256(11))))));
    }

    function _assertSame(Answers memory a, Answers memory b) internal pure {
        assertEq(a.owner, b.owner, "owner");
        assertEq(a.resolved, b.resolved, "resolve");
        assertEq(a.payee, b.payee, "payee");
        assertEq(a.op, b.op, "OP answer");
        assertEq(a.eth, b.eth, "Ethereum answer");
        assertEq(a.saved, b.saved, "saved main address");
        assertEq(a.saver, b.saver, "its saver");
    }

    // PageNFT is refused and nothing moves; any other address is saved and counts for the holder that saved it
    function _outcome(bool ok, bytes memory err, uint256 id, address holder, address a, Answers memory before)
        internal
        view
    {
        if (a == address(nft)) {
            assertFalse(ok, "PageNFT is refused");
            assertEq(bytes4(err), PageNFT.InvalidRecipient.selector);
            _assertSame(_answers(id), before);
        } else {
            assertTrue(ok, "any other address is saved");
            assertEq(nft.ownerOf(id), holder);
            assertEq(nft.resolve(id), a == address(0) ? holder : a);
            assertEq(nft.payee(id), a == address(0) ? holder : a);
            assertEq(nft.addr(id, COIN_OP), abi.encodePacked(a == address(0) ? holder : a));
        }
    }

    function _one(bytes memory call) internal pure returns (bytes[] memory calls) {
        calls = new bytes[](1);
        calls[0] = call;
    }

    // route 0 setAddr, 1 setAddrForCoin for OP, 2 the same with the twelve bytes after the address in the
    // calldata set, 3 and 4 the first two inside multicall
    function _directCall(uint256 route, uint256 id, address a) internal pure returns (bytes memory) {
        bytes memory plain = abi.encodeCall(PageNFT.setAddr, (id, a));
        bytes memory coin = abi.encodeCall(PageNFT.setAddrForCoin, (id, COIN_OP, abi.encodePacked(a)));
        if (route == 0) return plain;
        if (route == 1) return coin;
        if (route == 2) {
            // selector, id, coin type, offset and length take 132 bytes, then the 20 address bytes
            for (uint256 i = 152; i < 164; ++i) coin[i] = 0xff;
            return coin;
        }
        if (route == 3) return abi.encodeCall(PageNFT.multicall, (_one(plain)));
        return abi.encodeCall(PageNFT.multicall, (_one(coin)));
    }

    function _direct(uint256 id, address a) internal {
        for (uint256 route; route < 5; ++route) {
            Answers memory before = _answers(id);
            bytes memory d = _directCall(route, id, a);
            vm.recordLogs();
            vm.prank(alice);
            (bool ok, bytes memory err) = address(nft).call(d);
            uint256 logs = vm.getRecordedLogs().length;
            _outcome(ok, err, id, alice, a, before);
            if (a == address(nft)) assertEq(logs, 0, "a refused save emits nothing");
        }
    }

    // a contract that holds the name saves through both setters
    function _contractHolder(uint256 id, address a) internal {
        SavingHolder h = new SavingHolder();
        vm.prank(alice);
        nft.transferFrom(alice, address(h), id);
        Answers memory before = _answers(id);
        for (uint256 coin; coin < 2; ++coin) {
            (bool ok, bytes memory err) = address(h).call(abi.encodeCall(SavingHolder.save, (nft, id, a, coin == 1)));
            _outcome(ok, err, id, address(h), a, before);
        }
        vm.prank(address(h));
        nft.transferFrom(address(h), alice, id);
        // a refused save leaves the earlier holder's save in place, and it counts again now
        if (a == address(nft)) assertEq(nft.resolve(id), hot);
    }

    // the receiver saves from its hook inside the transfer, so a refusal reverts the transfer
    function _transferHook(uint256 id, address a) internal {
        for (uint256 coin; coin < 2; ++coin) {
            SavingHolder h = new SavingHolder();
            h.arm(a, coin == 1);
            Answers memory before = _answers(id);
            vm.prank(alice);
            (bool ok, bytes memory err) = address(nft).call(
                abi.encodeWithSignature("safeTransferFrom(address,address,uint256)", alice, address(h), id)
            );
            _outcome(ok, err, id, address(h), a, before);
            if (ok) {
                vm.prank(address(h));
                nft.transferFrom(address(h), alice, id);
            }
        }
    }

    // the outcome of a mint whose receiver saved from its hook: a refusal reverts the whole mint
    function _mintOutcome(bool ok, bytes memory err, uint256 id, string memory label, uint256 parentId, address h, address a)
        internal
        view
    {
        if (a == address(nft)) {
            assertFalse(ok, "the mint reverts");
            assertEq(bytes4(err), PageNFT.InvalidRecipient.selector);
            assertTrue(nft.isAvailable(label, parentId), "nothing was minted");
            assertEq(nft.getPageName(id), "");
        } else {
            assertTrue(ok, "minted and saved");
            assertEq(nft.ownerOf(id), h);
            assertEq(nft.resolve(id), a == address(0) ? h : a);
        }
    }

    function _mintHooks(address a) internal {
        for (uint256 coin; coin < 2; ++coin) {
            SavingHolder h = new SavingHolder();
            h.arm(a, coin == 1);
            string memory label = coin == 1 ? "minted-coin" : "minted";
            vm.prank(alice);
            (bool ok, bytes memory err) =
                address(nft).call(abi.encodeCall(PageNFT.registerSubpageFor, (label, club, address(h))));
            _mintOutcome(ok, err, _subId(label, club), label, club, address(h), a);
        }
    }

    function _saleHooks(address a) internal {
        for (uint256 coin; coin < 2; ++coin) {
            SavingHolder h = new SavingHolder();
            h.arm(a, coin == 1);
            string memory label = coin == 1 ? "sold-coin" : "sold";
            uint256 paid = buyer.balance;
            uint256 proceeds = reg.proceedsOf(payout);
            vm.prank(buyer);
            (bool ok, bytes memory err) = address(reg).call{value: PRICE}(
                abi.encodeWithSignature(
                    "registerSubpageFor(uint256,string,address,uint256,address)", club, label, address(h), PRICE, address(0)
                )
            );
            _mintOutcome(ok, err, _subId(label, club), label, club, address(h), a);
            uint256 spent = a == address(nft) ? 0 : PRICE;
            assertEq(buyer.balance, paid - spent, "the buyer pays only for a sale that went through");
            assertEq(reg.proceedsOf(payout), proceeds + spent);
        }
    }

    function _revealHooks(address a) internal {
        for (uint256 coin; coin < 2; ++coin) {
            SavingHolder h = new SavingHolder();
            h.arm(a, coin == 1);
            string memory label = coin == 1 ? "joined-coin" : "joined";
            bytes32 secret = keccak256(abi.encode(label));
            bytes32 c = nft.makeCommitment(label, address(h), 0, secret);
            vm.prank(bob);
            nft.commit(c);
            vm.warp(vm.getBlockTimestamp() + 61);
            (,,, uint256 total) = nft.quote(label);
            vm.prank(bob);
            (bool ok, bytes memory err) =
                address(nft).call{value: total}(abi.encodeCall(PageNFT.reveal, (label, address(h), 0, secret)));
            _mintOutcome(ok, err, _id(label), label, 0, address(h), a);
            if (a == address(nft)) assertGt(nft.commitments(c), 0, "the commitment survives the refused reveal");
        }
    }

    function _everyRoute(address a) internal {
        _direct(club, a);
        _direct(sub, a);
        _mintHooks(a);
        _saleHooks(a);
        _revealHooks(a);
        _contractHolder(club, a);
        _contractHolder(sub, a);
        _transferHook(club, a);
        _transferHook(sub, a);
    }

    function test_registryRefusedOnEveryRoute() public {
        _everyRoute(address(nft));
        // Expired and Unauthorized come first, also on a subpage
        vm.prank(stranger);
        vm.expectRevert(PageNFT.Unauthorized.selector);
        nft.setAddr(sub, address(nft));
        vm.warp(nft.expiresAt(club) + 1);
        vm.prank(alice);
        vm.expectRevert(PageNFT.Expired.selector);
        nft.setAddr(sub, address(nft));
    }

    function testFuzz_everyOtherAddressIsSavedOnEveryRoute(address x) public {
        vm.assume(x != address(nft));
        _everyRoute(x);
    }

    // zero clears, and DEAD, the registrar, the card and this test contract are saved like any address
    function test_zeroClearsAndNearbyAddressesAreSavedOnEveryRoute() public {
        address[5] memory others = [address(0), DEAD, address(reg), address(card), address(this)];
        uint256 snap = vm.snapshotState();
        for (uint256 i; i < others.length; ++i) {
            _everyRoute(others[i]);
            assertTrue(vm.revertToState(snap));
        }
    }

    // empty OP bytes clear the main address even with stray calldata after the length
    function test_emptyOpBytesWithStrayCalldataClear() public {
        bytes memory d = abi.encodeCall(PageNFT.setAddrForCoin, (club, COIN_OP, bytes("")));
        d = bytes.concat(d, abi.encodePacked(address(nft)));
        assertEq(nft.resolve(club), hot);
        vm.prank(alice);
        (bool ok,) = address(nft).call(d);
        assertTrue(ok);
        assertEq(nft.resolve(club), alice, "the name points back at its holder");
    }
}

// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {RulesBase} from "../../utils/RulesBase.sol";
import {trialCommitment} from "../../utils/TrialCommitment.sol";
import {PageNFT} from "../../../src/PageNFT.sol";
import {SubpageRegistrar} from "../../../src/SubpageRegistrar.sol";

// keeps every call it gets and accepts the token
contract RecordingReceiver {
    uint256 public calls;
    address public operator;
    address public from;
    uint256 public id;
    bytes public data;

    function onERC721Received(address o, address f, uint256 i, bytes calldata d) external returns (bytes4) {
        ++calls;
        (operator, from, id, data) = (o, f, i, d);
        return this.onERC721Received.selector;
    }
}

// answers every call in one fixed way
contract ScriptedReceiver {
    error Refused(uint256 code);

    uint8 public immutable mode;

    constructor(uint8 m) {
        mode = m;
    }

    fallback(bytes calldata) external returns (bytes memory) {
        uint8 m = mode;
        // the selector in a full word, then a word more
        if (m == 0) return abi.encodePacked(bytes32(bytes4(0x150b7a02)), bytes32(uint256(7)));
        // another selector
        if (m == 1) return abi.encode(bytes4(0xdeadbeef));
        // the selector with a nonzero bit in its padding
        if (m == 2) return abi.encodePacked(bytes32(bytes4(0x150b7a02)) | bytes32(uint256(1)));
        // the four bytes of the selector alone
        if (m == 3) return abi.encodePacked(bytes4(0x150b7a02));
        // nothing
        if (m == 4) return "";
        if (m == 5) revert Refused(42);
        if (m == 6) revert();
        // burns all the gas it is given
        uint256 x;
        while (gasleft() > 0) ++x;
        return abi.encode(x);
    }
}

// a contract with no receiver hook that can act for itself; a call with the hook selector reverts with no data
contract HooklessCaller {
    receive() external payable {}

    function exec(address target, uint256 value, bytes calldata data) external returns (bool ok, bytes memory ret) {
        (ok, ret) = target.call{value: value}(data);
    }
}

// Every mint asks the receiver to accept the token, through onERC721Received with the caller of PageNFT as the
// operator, from zero, the new id and empty data, unless the receiver is the caller or a key wallet: an account with
// no code or with the 23 byte EIP7702 delegation. This holds on every path that mints: reveal, revealTrial,
// registerSubpageFor and registerSubpage by the holder, registerSubpageFor by a minter and a sale of the registrar,
// whose mint has the registrar as its caller. A receiver must answer the 32 byte selector; any other answer, a revert
// with no data or a hook that runs out of gas undoes the whole call, and a revert with data passes that data up.
contract ReceiverCheckTest is RulesBase {
    bytes4 constant HOOK = 0x150b7a02;
    bytes4 constant NOT_RECEIVER = 0xd1a57ed6; // TransferToNonERC721ReceiverImplementer()
    uint256 constant SALE_PRICE = 0.002 ether;

    enum Path {
        Reveal,
        Trial,
        HolderFor,
        HolderSelf,
        Minter,
        Sale
    }

    string[6] pathNames = ["reveal", "trial", "holder", "holderself", "minter", "sale"];

    uint256 minterParent;
    uint256 saleParent;
    address minter = makeAddr("minter");
    address payout = makeAddr("payout");
    uint256 n;

    function setUp() public override {
        super.setUp();
        vm.deal(minter, 1000 ether);
        minterParent = _buy(bob, "mparent");
        vm.prank(bob);
        nft.setSubpageMinter(minterParent, minter);
        saleParent = _buy(bob, "sparent");
        vm.startPrank(bob);
        nft.setSubpageMinter(saleParent, address(shop));
        shop.configure(saleParent, payout, address(0), SALE_PRICE, true, address(0), 0, false);
        vm.stopPrank();
    }

    function _label(Path p) internal returns (string memory) {
        return string.concat(pathNames[uint256(p)], "x", vm.toString(++n));
    }

    // a call as who: through its exec when it is a HooklessCaller, else as a prank
    function _call(address who, address target, uint256 value, bytes memory data, uint256 gasCap)
        internal
        returns (bool ok, bytes memory ret)
    {
        if (who.code.length != 0) {
            vm.deal(who, who.balance + value);
            return HooklessCaller(payable(who)).exec{gas: gasCap}(target, value, data);
        }
        vm.prank(who);
        (ok, ret) = target.call{value: value, gas: gasCap}(data);
    }

    // the parent a holder path mints under: bob's for an account, or one the caller registers for itself
    function _holderParent(address who) internal returns (uint256 parent, string memory parentLabel) {
        if (who == bob) return (minterParent, "mparent");
        parentLabel = string.concat("own", vm.toString(++n));
        (bool ok,, uint256 id) = _mint(Path.Reveal, who, who, parentLabel, 0, 30_000_000);
        assertTrue(ok, "the caller registers its own parent");
        return (id, parentLabel);
    }

    // mints label on path p, called by who, for to; returns the outcome, the expected id and the operator the hook
    // must see
    function _mint(Path p, address who, address to, string memory label, uint256 parent, uint256 gasCap)
        internal
        returns (bool ok, bytes memory ret, uint256 id)
    {
        if (p == Path.Reveal || p == Path.Trial) {
            bytes32 secret = keccak256(abi.encode(label, to));
            bytes32 c = p == Path.Reveal
                ? nft.makeCommitment(label, to, 0, secret)
                : trialCommitment(address(nft), label, to, 0, secret);
            (bool committed,) = _call(who, address(nft), 0, abi.encodeCall(PageNFT.commit, (c)), 30_000_000);
            assertTrue(committed, "commit");
            vm.warp(vm.getBlockTimestamp() + 61);
            id = nft.computeId(label);
            if (p == Path.Reveal) {
                (,,, uint256 total) = nft.quote(label);
                (ok, ret) = _call(who, address(nft), total, abi.encodeCall(PageNFT.reveal, (label, to, 0, secret)), gasCap);
            } else {
                (ok, ret) = _call(
                    who, address(nft), _price(label), abi.encodeCall(PageNFT.revealTrial, (label, to, 0, secret)), gasCap
                );
            }
            return (ok, ret, id);
        }
        string memory parentLabel = p == Path.Minter ? "mparent" : p == Path.Sale ? "sparent" : nft.getPageName(parent);
        id = nft.computeId(string.concat(label, ".", parentLabel));
        if (p == Path.Sale) {
            (ok, ret) = _call(
                who,
                address(shop),
                SALE_PRICE,
                abi.encodeCall(SubpageRegistrar.registerSubpageFor, (saleParent, label, to, SALE_PRICE, address(0))),
                gasCap
            );
        } else if (p == Path.HolderSelf) {
            assertEq(to, who, "registerSubpage mints to the caller");
            (ok, ret) = _call(who, address(nft), 0, abi.encodeCall(PageNFT.registerSubpage, (label, parent)), gasCap);
        } else {
            uint256 under = p == Path.Minter ? minterParent : parent;
            (ok, ret) = _call(who, address(nft), 0, abi.encodeCall(PageNFT.registerSubpageFor, (label, under, to)), gasCap);
        }
    }

    function _operator(Path p, address who) internal view returns (address) {
        return p == Path.Sale ? address(shop) : who;
    }

    // a receiver with a hook is asked once on every path, with the caller of PageNFT, zero, the new id and no data
    function test_hookGetsTheMintArgumentsOnEveryPath() public {
        address[6] memory callers = [dave, dave, bob, bob, minter, dave];
        for (uint256 i; i < 6; ++i) {
            Path p = Path(i);
            if (p == Path.HolderSelf) continue; // mints to its caller, an account here
            RecordingReceiver r = new RecordingReceiver();
            string memory label = _label(p);
            uint256 parent = p == Path.HolderFor ? minterParent : 0;
            uint256 expectedId = p == Path.Reveal || p == Path.Trial
                ? nft.computeId(label)
                : nft.computeId(string.concat(label, ".", p == Path.Sale ? "sparent" : "mparent"));
            address op = _operator(p, callers[i]);
            vm.expectCall(address(r), abi.encodeWithSelector(HOOK, op, address(0), expectedId, bytes("")), 1);
            (bool ok, bytes memory ret, uint256 id) = _mint(p, callers[i], address(r), label, parent, 30_000_000);
            assertTrue(ok, string.concat(pathNames[i], ": the mint succeeds ", vm.toString(ret)));
            assertEq(id, expectedId, pathNames[i]);
            assertEq(nft.ownerOf(id), address(r), pathNames[i]);
            assertEq(r.calls(), 1, string.concat(pathNames[i], ": asked once"));
            assertEq(r.operator(), op, string.concat(pathNames[i], ": operator"));
            assertEq(r.from(), address(0), string.concat(pathNames[i], ": from"));
            assertEq(r.id(), id, string.concat(pathNames[i], ": id"));
            assertEq(r.data(), "", string.concat(pathNames[i], ": data"));
        }
    }

    // a contract with no hook that mints for itself is never asked, on every path where it is PageNFT's caller
    function test_selfMintSkipsTheHook() public {
        HooklessCaller c = new HooklessCaller();
        vm.prank(bob);
        nft.setSubpageMinter(minterParent, address(c));
        vm.expectCall(address(c), abi.encodeWithSelector(HOOK), 0);
        for (uint256 i; i < 5; ++i) {
            Path p = Path(i);
            string memory label = _label(p);
            uint256 parent;
            if (p == Path.HolderFor || p == Path.HolderSelf) (parent,) = _holderParent(address(c));
            (bool ok, bytes memory ret, uint256 id) = _mint(p, address(c), address(c), label, parent, 30_000_000);
            assertTrue(ok, string.concat(pathNames[i], ": a self mint needs no hook ", vm.toString(ret)));
            assertEq(nft.ownerOf(id), address(c), pathNames[i]);
        }
    }

    // in a sale PageNFT's caller is the registrar, so a buyer with code but no hook cannot buy for itself; the whole
    // purchase is undone and the buyer keeps its money
    function test_saleToAHooklessBuyerIsUndone() public {
        HooklessCaller c = new HooklessCaller();
        vm.deal(address(c), 1 ether);
        uint256 before = address(c).balance;
        uint256 proceeds = shop.proceedsOf(payout);
        string memory label = _label(Path.Sale);
        (bool ok, bytes memory ret, uint256 id) = _mint(Path.Sale, address(c), address(c), label, 0, 30_000_000);
        assertFalse(ok, "the sale reverts");
        assertEq(ret, abi.encodeWithSelector(NOT_RECEIVER), "with the receiver error");
        // _call dealt the price on top before the call
        assertEq(address(c).balance, before + SALE_PRICE, "the buyer keeps its money");
        assertEq(shop.proceedsOf(payout), proceeds, "no proceeds");
        assertTrue(nft.isAvailable(label, saleParent), "nothing was minted");
        vm.expectRevert();
        nft.ownerOf(id);
    }

    // no code, an address with no code yet and the 23 byte EIP7702 delegation are never asked, even when the
    // delegate would refuse, on every path
    function test_keyWalletsAreNeverAsked() public {
        ScriptedReceiver refuser = new ScriptedReceiver(5);
        address delegated = makeAddr("delegated");
        vm.etch(delegated, abi.encodePacked(hex"ef0100", address(refuser)));
        (bool live, bytes memory r) = delegated.call(abi.encodeWithSelector(HOOK, dave, address(0), 1, bytes("")));
        assertFalse(live, "the delegate refuses when asked directly");
        assertEq(r, abi.encodeWithSelector(ScriptedReceiver.Refused.selector, 42));
        address[3] memory keys = [carol, address(uint160(uint256(keccak256("not deployed yet")))), delegated];
        address[6] memory callers = [dave, dave, bob, bob, minter, dave];
        for (uint256 k; k < 3; ++k) {
            vm.expectCall(keys[k], abi.encodeWithSelector(HOOK), 0);
            for (uint256 i; i < 6; ++i) {
                Path p = Path(i);
                if (p == Path.HolderSelf) continue;
                string memory label = _label(p);
                uint256 parent = p == Path.HolderFor ? minterParent : 0;
                (bool ok, bytes memory ret, uint256 id) = _mint(p, callers[i], keys[k], label, parent, 30_000_000);
                assertTrue(ok, string.concat(pathNames[i], ": a key wallet takes the page unasked ", vm.toString(ret)));
                assertEq(nft.ownerOf(id), keys[k], pathNames[i]);
            }
        }
    }

    // only the selector in a full word is an acceptance; a longer answer is read by its first word
    function test_hookAnswersOnEveryPath() public {
        address[6] memory callers = [dave, dave, bob, bob, minter, dave];
        for (uint8 mode; mode < 8; ++mode) {
            for (uint256 i; i < 6; ++i) {
                Path p = Path(i);
                if (p == Path.HolderSelf) continue;
                ScriptedReceiver r = new ScriptedReceiver(mode);
                string memory label = _label(p);
                uint256 parent = p == Path.HolderFor ? minterParent : 0;
                address who = callers[i];
                uint256 balance = who.balance;
                uint256 proceeds = shop.proceedsOf(payout);
                uint256 cap = mode == 7 ? 5_000_000 : 30_000_000;
                (bool ok, bytes memory ret, uint256 id) = _mint(p, who, address(r), label, parent, cap);
                string memory what = string.concat(pathNames[i], " mode ", vm.toString(mode));
                if (mode == 0) {
                    assertTrue(ok, what);
                    assertEq(nft.ownerOf(id), address(r), what);
                    continue;
                }
                assertFalse(ok, what);
                if (mode == 5) assertEq(ret, abi.encodeWithSelector(ScriptedReceiver.Refused.selector, 42), what);
                else assertEq(ret, abi.encodeWithSelector(NOT_RECEIVER), what);
                assertEq(who.balance, balance, string.concat(what, ": the payer keeps its money"));
                assertEq(shop.proceedsOf(payout), proceeds, string.concat(what, ": no proceeds"));
                uint256 under = p == Path.Minter || p == Path.HolderFor ? minterParent : p == Path.Sale ? saleParent : 0;
                assertTrue(nft.isAvailable(label, under), string.concat(what, ": nothing was minted"));
            }
        }
    }

    // a refused reveal keeps the commitment, so the same reveal goes through once the receiver accepts
    function test_refusedRevealKeepsTheCommitment() public {
        address target = makeAddr("target");
        vm.etch(target, address(new ScriptedReceiver(1)).code);
        string memory label = "keepcommit";
        bytes32 secret = keccak256(abi.encode(label, target));
        _call(dave, address(nft), 0, abi.encodeCall(PageNFT.commit, (nft.makeCommitment(label, target, 0, secret))), 30_000_000);
        vm.warp(vm.getBlockTimestamp() + 61);
        (,,, uint256 total) = nft.quote(label);
        (bool ok, bytes memory ret) =
            _call(dave, address(nft), total, abi.encodeCall(PageNFT.reveal, (label, target, 0, secret)), 30_000_000);
        assertFalse(ok);
        assertEq(ret, abi.encodeWithSelector(NOT_RECEIVER));
        vm.etch(target, address(new RecordingReceiver()).code);
        (ok, ret) = _call(dave, address(nft), total, abi.encodeCall(PageNFT.reveal, (label, target, 0, secret)), 30_000_000);
        assertTrue(ok, vm.toString(ret));
        assertEq(nft.ownerOf(nft.computeId(label)), target);
        assertEq(RecordingReceiver(target).calls(), 1);
    }
}

// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Vm} from "forge-std/Test.sol";
import {PageNFT} from "../../../src/PageNFT.sol";
import {SubpageRegistrar} from "../../../src/SubpageRegistrar.sol";
import {MinterBase} from "../../utils/MinterBase.sol";
import {NoHook} from "../../utils/MinterMocks.sol";

// a buyer contract that counts the ETH it gets back
contract CountingBuyer {
    uint256 public received;
    uint256 public calls;

    function buy(address target, bytes calldata d, uint256 value) external returns (bytes memory) {
        (bool ok, bytes memory ret) = target.call{value: value}(d);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        return ret;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    receive() external payable {
        received += msg.value;
        ++calls;
    }
}

// holds a parent and sells under it; it has no receive, so it refuses ETH
contract ParentHolder {
    function exec(address to, bytes calldata d) external returns (bytes memory) {
        (bool ok, bytes memory ret) = to.call(d);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        return ret;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}

// takes names and refuses ETH
contract NameOnly {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}

// a buyer whose refund reads the finished sale, or makes one call into the registrar
contract SaleWatcher {
    SubpageRegistrar immutable reg;
    PageNFT immutable nft;
    uint256 sub;
    uint256 parent;
    bytes32 commitment;
    address payout;
    bytes public seen;
    bytes public call;
    bool public bubble;
    bytes public inner;

    constructor(SubpageRegistrar r, PageNFT n) {
        reg = r;
        nft = n;
    }

    function watch(uint256 s, uint256 p, bytes32 c, address pay) external {
        sub = s;
        parent = p;
        commitment = c;
        payout = pay;
    }

    function arm(bytes calldata c, bool b) external {
        call = c;
        bubble = b;
        delete inner;
    }

    function buy(bytes calldata d, uint256 value) external returns (bytes memory) {
        (bool ok, bytes memory ret) = address(reg).call{value: value}(d);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        return ret;
    }

    function views() public view returns (bytes memory) {
        return abi.encode(
            nft.ownerOf(sub), nft.ownerOf(parent), reg.subCommitments(commitment), reg.proceedsOf(payout),
            address(reg).balance
        );
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    receive() external payable {
        if (call.length == 0) {
            seen = views();
            return;
        }
        (bool ok, bytes memory ret) = address(reg).call(call);
        if (!ok && bubble) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        inner = ok ? bytes("ok") : ret;
    }
}

// What a buyer of a subpage pays and gets back, what a refund can see and do, the price a buyer agreed to, the label
// a sale logs, and a subpage given to someone who did not ask for it.
contract SaleBuyerTest is MinterBase {
    uint256 constant PRICE = 0.01 ether;

    uint256 club;

    function setUp() public override {
        super.setUp();
        club = _reg(alice, "club");
    }

    function _call(uint8 path, uint256 parentId, string memory label, address to, bytes32 secret, uint256 maxPrice)
        internal
        pure
        returns (bytes memory)
    {
        if (path == 0) return abi.encodeCall(SubpageRegistrar.registerSubpage, (parentId, label, maxPrice, address(0)));
        if (path == 1) {
            return abi.encodeCall(SubpageRegistrar.registerSubpageFor, (parentId, label, to, maxPrice, address(0)));
        }
        if (path == 2) {
            return abi.encodeCall(SubpageRegistrar.revealSubpage, (parentId, label, secret, maxPrice, address(0)));
        }
        return abi.encodeCall(SubpageRegistrar.revealSubpageFor, (parentId, label, to, secret, maxPrice, address(0)));
    }

    function _hashLogs(Vm.Log[] memory logs) internal pure returns (bytes32 h) {
        for (uint256 i; i < logs.length; ++i) h = keccak256(abi.encode(h, logs[i].emitter, logs[i].topics, logs[i].data));
    }

    // on every entry point, money above the price goes back to the buyer in the same call and to no one else, even
    // when the receiver, the parent's holder and the payout refuse ETH; the registrar keeps exactly the price, the
    // log is that of an exact payment, and an exact payment makes no call at all
    function testFuzz_saleOverpaymentRefunded(uint256 value, uint8 pathSeed, bool buyerIsPayout) public {
        uint8 path = pathSeed % 4;
        value = PRICE + value % (200 ether - PRICE + 1);
        ParentHolder holder = new ParentHolder();
        uint256 p = _regTo(alice, "shop", address(holder));
        CountingBuyer b = new CountingBuyer();
        vm.deal(address(b), 300 ether);
        address recipient = address(new NameOnly());
        address pay = buyerIsPayout ? address(b) : address(new NoHook());
        holder.exec(address(nft), abi.encodeCall(PageNFT.setSubpageMinter, (p, address(reg))));
        holder.exec(
            address(reg),
            abi.encodeCall(SubpageRegistrar.configure, (p, pay, address(0), PRICE, true, address(0), 0, false))
        );
        address to = path % 2 == 0 ? address(b) : recipient;
        bytes32 secret = keccak256("secret");
        if (path >= 2) {
            reg.commitSubpage(reg.makeSubpageCommitment(p, "kid", to, secret));
            vm.warp(vm.getBlockTimestamp() + 61);
        }
        bytes memory d = _call(path, p, "kid", to, secret, PRICE);
        uint256 regBefore = address(reg).balance;
        uint256 snap = vm.snapshotState();

        // the exact price
        vm.recordLogs();
        b.buy(address(reg), d, PRICE);
        bytes32 exactLogs = _hashLogs(vm.getRecordedLogs());
        assertEq(b.calls(), 0, "an exact payment makes no call");

        vm.revertToState(snap);
        uint256 buyerBefore = address(b).balance;
        vm.recordLogs();
        b.buy(address(reg), d, value);
        assertEq(_hashLogs(vm.getRecordedLogs()), exactLogs, "the same log as an exact payment");
        assertEq(b.received(), value - PRICE, "the excess comes back to the buyer");
        assertEq(b.calls(), value > PRICE ? 1 : 0);
        assertEq(buyerBefore - address(b).balance, PRICE, "the buyer pays the price");
        assertEq(address(reg).balance, regBefore + PRICE, "the registrar keeps the price");
        assertEq(reg.proceedsOf(pay), PRICE, "credited to the payout");
        if (!buyerIsPayout) assertEq(reg.proceedsOf(address(b)), 0, "nothing credited to the buyer");
        assertEq(reg.proceedsOf(recipient) + reg.proceedsOf(address(holder)) + reg.proceedsOf(alice), 0);
        assertEq(recipient.balance + address(holder).balance, 0, "nothing reaches the receiver or the holder");
        if (!buyerIsPayout) assertEq(pay.balance, 0, "nothing reaches the payout");
        assertEq(nft.ownerOf(_subId("kid", p)), to);
    }

    // inside the buyer's refund the sale is finished: the subpage is minted, the parent untouched, the commitment
    // gone and the price credited, and the registrar holds exactly the proceeds
    function test_saleRefundHookSeesFinishedSale() public {
        _sellSetup(club, PRICE);
        SaleWatcher w = new SaleWatcher(reg, nft);
        vm.deal(address(w), 10 ether);
        bytes32 secret = keccak256("s");
        bytes32 c = reg.makeSubpageCommitment(club, "kid", carol, secret);
        reg.commitSubpage(c);
        vm.warp(vm.getBlockTimestamp() + 61);
        w.watch(_subId("kid", club), club, c, payout);
        w.buy(abi.encodeCall(SubpageRegistrar.revealSubpageFor, (club, "kid", carol, secret, PRICE, address(0))), PRICE + 1);
        (address subOwner, address parentOwner, uint256 committed, uint256 proceeds, uint256 balance) =
            abi.decode(w.seen(), (address, address, uint256, uint256, uint256));
        assertEq(subOwner, carol, "the subpage is minted");
        assertEq(parentOwner, alice, "the parent did not move");
        assertEq(committed, 0, "the commitment is gone");
        assertEq(proceeds, PRICE, "the price is credited");
        assertEq(balance, proceeds, "the registrar holds exactly the proceeds");
        assertEq(keccak256(w.seen()), keccak256(w.views()), "and nothing changes after the refund");
    }

    // the refund calling any guarded registrar function gets Reentrancy; passed on, it reverts the purchase as a
    // whole, keeping the commitment, and the exact price then buys
    function test_saleRefundHookCannotEnterAndFailsItsOwnPurchase() public {
        _sellSetup(club, PRICE);
        SaleWatcher w = new SaleWatcher(reg, nft);
        vm.deal(address(w), 10 ether);
        bytes[6] memory calls = [
            abi.encodeCall(SubpageRegistrar.registerSubpageFor, (club, "other", carol, PRICE, address(0))),
            abi.encodeCall(SubpageRegistrar.revealSubpageFor, (club, "other", carol, bytes32(0), PRICE, address(0))),
            abi.encodeCall(SubpageRegistrar.configure, (club, payout, address(0), 0, true, address(0), 0, false)),
            abi.encodeCall(SubpageRegistrar.disable, (club)),
            abi.encodeCall(SubpageRegistrar.claimProceeds, (address(0))),
            abi.encodeCall(SubpageRegistrar.claimProceedsFor, (payout))
        ];
        for (uint256 i; i < 6; ++i) {
            string memory label = string.concat("k", vm.toString(i));
            w.arm(calls[i], false);
            w.buy(abi.encodeCall(SubpageRegistrar.registerSubpage, (club, label, PRICE, address(0))), PRICE + 1);
            assertEq(w.inner(), abi.encodeWithSelector(REENTRANCY), string.concat("call ", vm.toString(i)));
        }
        // passed on, on the reveal path
        bytes32 secret = keccak256("s");
        bytes32 c = reg.makeSubpageCommitment(club, "kept", address(w), secret);
        reg.commitSubpage(c);
        uint256 committedAt = vm.getBlockTimestamp();
        vm.warp(committedAt + 61);
        bytes memory d = abi.encodeCall(SubpageRegistrar.revealSubpage, (club, "kept", secret, PRICE, address(0)));
        for (uint256 i; i < 6; ++i) {
            w.arm(calls[i], true);
            vm.expectRevert(ETH_TRANSFER_FAILED);
            w.buy(d, PRICE + 1);
        }
        // the commitment survived, so the exact price buys
        w.buy(d, PRICE);
        assertEq(nft.ownerOf(_subId("kept", club)), address(w));
    }

    // a holder that reprices a token sale above the buyer's maximum makes every entry point refuse with
    // PriceTooHigh; the buyer keeps its tokens and its commitments, and buys at the price it agreed to
    function test_repricedERC20SaleReverts() public {
        _setMinter(club, address(reg));
        vm.prank(alice);
        reg.configure(club, payout, address(usd), 1e6, true, address(0), 0, false);
        usd.mint(buyer, 900_000e6);
        vm.prank(buyer);
        usd.approve(address(reg), type(uint256).max);
        bytes32 secret = keccak256("s");
        bytes32 c1 = reg.makeSubpageCommitment(club, "sub", buyer, secret);
        bytes32 c2 = reg.makeSubpageCommitment(club, "sub", carol, secret);
        reg.commitSubpage(c1);
        reg.commitSubpage(c2);
        vm.warp(vm.getBlockTimestamp() + 61);
        // the holder raises the price before the buyer's call lands
        vm.prank(alice);
        reg.configure(club, payout, address(usd), 900_000e6, true, address(0), 0, false);
        vm.startPrank(buyer);
        vm.expectRevert(SubpageRegistrar.PriceTooHigh.selector);
        reg.registerSubpage(club, "sub", 1e6, address(usd));
        vm.expectRevert(SubpageRegistrar.PriceTooHigh.selector);
        reg.registerSubpageFor(club, "sub", carol, 1e6, address(usd));
        vm.expectRevert(SubpageRegistrar.PriceTooHigh.selector);
        reg.revealSubpage(club, "sub", secret, 1e6, address(usd));
        vm.expectRevert(SubpageRegistrar.PriceTooHigh.selector);
        reg.revealSubpageFor(club, "sub", carol, secret, 1e6, address(usd));
        vm.stopPrank();
        // at the price the buyer agreed to the same purchase goes through, with the commitment made before
        vm.prank(alice);
        reg.configure(club, payout, address(usd), 1e6, true, address(0), 0, false);
        vm.prank(buyer);
        uint256 id = reg.revealSubpageFor(club, "sub", carol, secret, 1e6, address(usd));
        assertEq(nft.ownerOf(id), carol);
        assertEq(usd.balanceOf(payout), 1e6);
        assertEq(usd.balanceOf(buyer), 900_000e6 - 1e6);
    }

    // the label of the subpage and the label a sale logs
    function _soldLabels(Vm.Log[] memory logs, uint256 sub)
        internal
        view
        returns (string memory stored, string memory typed)
    {
        bytes32 subReg = keccak256("SubpageRegistered(uint256,uint256,string)");
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory l = logs[i];
            if (l.emitter == address(nft) && l.topics[0] == subReg) {
                assertEq(uint256(l.topics[1]), sub);
                stored = abi.decode(l.data, (string));
            }
            if (l.emitter == address(reg) && l.topics[0] == SubpageRegistrar.SubpageSold.selector) {
                assertEq(uint256(l.topics[2]), sub);
                (,,,, typed) = abi.decode(l.data, (address, address, address, uint256, string));
            }
        }
    }

    // a sale logs the label as typed in SubpageSold and as stored in SubpageRegistered, on both paths; 63 characters
    // sell, 64 are refused
    function test_soldLabelIsInput() public {
        _sellSetup(club, PRICE);
        uint256 zoo = _reg(bob, "zoo");
        _sellSetup(zoo, PRICE);
        vm.recordLogs();
        vm.prank(buyer);
        uint256 a = reg.registerSubpage{value: PRICE}(club, "Shop", PRICE, address(0));
        (string memory stored, string memory typed) = _soldLabels(vm.getRecordedLogs(), a);
        assertEq(a, _subId("shop", club));
        assertEq(stored, "shop");
        assertEq(typed, "Shop");
        assertEq(nft.getPageName(a), "shop.club");

        bytes32 secret = keccak256("s");
        reg.commitSubpage(reg.makeSubpageCommitment(zoo, "Shop", buyer, secret));
        vm.warp(vm.getBlockTimestamp() + 61);
        vm.recordLogs();
        vm.prank(buyer);
        uint256 b = reg.revealSubpage{value: PRICE}(zoo, "Shop", secret, PRICE, address(0));
        (stored, typed) = _soldLabels(vm.getRecordedLogs(), b);
        assertEq(b, _subId("shop", zoo));
        assertEq(stored, "shop");
        assertEq(typed, "Shop");
        assertEq(nft.getPageName(b), "shop.zoo");

        bytes memory l63 = new bytes(63);
        bytes memory low63 = new bytes(63);
        for (uint256 i; i < 63; ++i) {
            l63[i] = i % 2 == 0 ? bytes1("A") : bytes1("9");
            low63[i] = i % 2 == 0 ? bytes1("a") : bytes1("9");
        }
        vm.prank(buyer);
        uint256 c = reg.registerSubpage{value: PRICE}(club, string(l63), PRICE, address(0));
        assertEq(c, _subId(string(low63), club));
        assertEq(nft.getPageName(c), string.concat(string(low63), ".club"));

        string memory l64 = string.concat(string(l63), "a");
        vm.prank(buyer);
        vm.expectRevert(PageNFT.InvalidLength.selector);
        reg.revealSubpage{value: PRICE}(club, l64, secret, PRICE, address(0));
        vm.prank(buyer);
        vm.expectRevert(SubpageRegistrar.NotAvailable.selector);
        reg.registerSubpage{value: PRICE}(club, l64, PRICE, address(0));
    }

    // a subpage minted to an account that asked for nothing, by the parent's holder or through a sale, changes
    // nothing of that account's money or display name; only its own call shows it, and the parent's holder can
    // take it back
    function test_unsolicitedSubpageAccepted() public {
        uint256 own = _reg(stranger, "ownname");
        vm.prank(stranger);
        nft.setPrimaryPage(own);
        assertEq(nft.reverseResolve(stranger), "ownname");
        uint256 nftBalance = address(nft).balance;

        vm.prank(alice);
        uint256 gift = nft.registerSubpageFor("gift", club, stranger);
        _sellSetup(club, PRICE);
        vm.prank(buyer);
        uint256 sold = reg.registerSubpageFor{value: PRICE}(club, "sold", stranger, PRICE, address(0));
        uint256[2] memory subs = [gift, sold];
        for (uint256 i; i < 2; ++i) {
            assertEq(nft.ownerOf(subs[i]), stranger);
            assertEq(nft.depositOf(subs[i]), 0, "a subpage holds no deposit");
            assertEq(nft.referrerOf(subs[i]), 0);
        }
        assertEq(nft.primaryPage(stranger), own, "the display name is unchanged");
        assertEq(nft.reverseResolve(stranger), "ownname");
        assertEq(nft.owed(stranger), 0);
        assertEq(reg.proceedsOf(stranger), 0);
        assertEq(address(nft).balance, nftBalance, "no money moved in PageNFT");
        // an account with no display name still has none after both kinds of gift
        vm.prank(alice);
        nft.registerSubpageFor("given", club, hot2);
        vm.prank(buyer);
        reg.registerSubpageFor{value: PRICE}(club, "bought", hot2, PRICE, address(0));
        assertEq(nft.primaryPage(hot2), 0);
        assertEq(nft.reverseResolve(hot2), "");
        assertEq(address(nft).balance, nftBalance);

        // the parent's holder and the buyer cannot choose these subpages as their own display name
        vm.prank(alice);
        vm.expectRevert(PageNFT.Unauthorized.selector);
        nft.setPrimaryPage(gift);
        vm.prank(buyer);
        vm.expectRevert(PageNFT.Unauthorized.selector);
        nft.setPrimaryPage(sold);

        vm.prank(stranger);
        nft.setPrimaryPage(gift);
        assertEq(nft.reverseResolve(stranger), "gift.club");
        // the parent's holder takes it back, which clears that display name
        vm.prank(alice);
        nft.registerSubpageFor("gift", club, alice);
        assertEq(nft.ownerOf(gift), alice);
        assertEq(nft.primaryPage(stranger), 0);
        assertEq(nft.reverseResolve(stranger), "");
    }
}

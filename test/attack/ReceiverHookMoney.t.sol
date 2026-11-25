// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {PageCard} from "../../src/PageCard.sol";
import {PageNFT} from "../../src/PageNFT.sol";
import {trialCommitmentRaw} from "../utils/TrialCommitment.sol";

// A receiver that acts from inside onERC721Received. It tries every entry point that moves money, saves a data record
// and addresses in one bundle, registers another page, tries to move an unpaid trial, and passes the page on.
contract HookActor {
    PageNFT immutable nft;

    uint256 constant GUARDED = 1;
    uint256 constant WRITE = 2;
    uint256 constant MOVE = 4;
    uint256 constant TRY_ALT = 8;
    uint256 constant REVEAL_SIDE = 16;

    uint256 public mode;
    address public next;
    address public alt;
    string public label2;
    bytes32 public secret2;
    bytes4[] internal _errs;
    uint256 public hookHolderSince;
    address public hookOwner;
    uint256 public sideId;

    constructor(PageNFT n) payable {
        nft = n;
    }

    function configure(uint256 m, address nextHolder, address altHolder) external {
        mode = m;
        next = nextHolder;
        alt = altHolder;
    }

    // commits to a second page for itself, which the hook tries to register
    function prepSide(string calldata l, bytes32 s) external {
        label2 = l;
        secret2 = s;
        nft.commit(nft.makeCommitment(l, address(this), 0, s));
    }

    function errs() external view returns (bytes4[] memory) {
        return _errs;
    }

    function revealSide() external returns (uint256 id) {
        id = nft.reveal{value: nft.getFee(bytes(label2).length)}(label2, address(this), 0, secret2);
    }

    // the selector of the revert data, or zero when the call worked
    function _try(uint256 value, bytes memory d) internal returns (bytes4) {
        (bool ok, bytes memory ret) = address(nft).call{value: value}(d);
        if (ok) return bytes4(0);
        if (ret.length < 4) return bytes4(0xffffffff);
        return bytes4(ret);
    }

    function _must(uint256 value, bytes memory d) internal returns (bytes memory ret) {
        bool ok;
        (ok, ret) = address(nft).call{value: value}(d);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }

    // the seven guarded entry points, and withdraw inside a bundle
    function _guarded(uint256 id) internal {
        uint256 fee = nft.getFee(bytes(label2).length);
        _errs.push(_try(fee, abi.encodeCall(PageNFT.reveal, (label2, address(this), 0, secret2))));
        _errs.push(_try(fee, abi.encodeCall(PageNFT.revealTrial, (label2, address(this), 0, secret2))));
        _errs.push(_try(1 ether, abi.encodeCall(PageNFT.renew, (id))));
        _errs.push(_try(0, abi.encodeCall(PageNFT.release, (id))));
        _errs.push(_try(0, abi.encodeCall(PageNFT.withdraw, (address(this)))));
        _errs.push(_try(0, abi.encodeCall(PageNFT.registerSubpage, ("inner", id))));
        _errs.push(_try(0, abi.encodeCall(PageNFT.registerSubpageFor, ("inner", id, address(this)))));
        bytes[] memory c = new bytes[](1);
        c[0] = abi.encodeCall(PageNFT.withdraw, (address(this)));
        _errs.push(_try(0, abi.encodeCall(PageNFT.multicall, (c))));
    }

    function onERC721Received(address, address, uint256 id, bytes calldata) external returns (bytes4) {
        hookHolderSince = nft.holderSince(id);
        hookOwner = nft.ownerOf(id);
        if (mode & GUARDED != 0) _guarded(id);
        if (mode & WRITE != 0) {
            bytes[] memory c = new bytes[](3);
            c[0] = abi.encodeCall(PageNFT.setData, (id, "k", hex"c0ffee"));
            c[1] = abi.encodeCall(PageNFT.setAddr, (id, address(0xA1)));
            c[2] = abi.encodeCall(PageNFT.setAddrForCoin, (id, 60, abi.encodePacked(address(0xE1))));
            _must(0, abi.encodeCall(PageNFT.multicall, (c)));
        }
        if (mode & REVEAL_SIDE != 0) {
            bytes memory ret = _must(
                nft.getFee(bytes(label2).length), abi.encodeCall(PageNFT.reveal, (label2, address(this), 0, secret2))
            );
            sideId = abi.decode(ret, (uint256));
        }
        if (mode & TRY_ALT != 0) {
            _errs.push(
                _try(0, abi.encodeWithSignature("transferFrom(address,address,uint256)", address(this), alt, id))
            );
        }
        if (mode & MOVE != 0) {
            _must(0, abi.encodeWithSignature("transferFrom(address,address,uint256)", address(this), next, id));
        }
        return this.onERC721Received.selector;
    }
}

// What a receiver can do from inside the hook of a paid mint, a premium buyout, a trial and a safe transfer.
// holderSince is already set when the hook runs. Inside the hook of a paid mint, every guarded entry point refuses
// with Reentrancy, while a safe transfer has no guard. What the receiver saves does not count once the page moves
// on, and a page it sends to DEAD is deleted with its money split as on any buyout. After every step the contract
// holds exactly the deposits, the trial money and the credits.
contract ReceiverHookMoneyTest is Test {
    bytes4 constant REENTRANCY = 0xab143c06;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    PageNFT nft;
    HookActor actor;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address dave = makeAddr("dave");
    address alicePay = makeAddr("alicePay");

    address[] accts;
    uint256[] ids;

    function setUp() public {
        vm.warp(1_800_000_000);
        nft = new PageNFT(new PageCard());
        actor = new HookActor{value: 10 ether}(nft);
        address[4] memory who = [alice, bob, carol, dave];
        for (uint256 i; i < who.length; ++i) {
            vm.deal(who[i], 100 ether);
            accts.push(who[i]);
        }
        accts.push(alicePay);
        accts.push(address(actor));
        accts.push(DEAD);
    }

    function _commitReveal(address payer, string memory label, address to, uint256 ref, uint256 extra)
        internal
        returns (uint256 id)
    {
        bytes32 s = keccak256(abi.encode(label, to, vm.getBlockTimestamp()));
        bytes32 c = nft.makeCommitment(label, to, ref, s);
        vm.prank(payer);
        nft.commit(c);
        vm.warp(vm.getBlockTimestamp() + 61);
        (,,, uint256 total) = nft.quote(label);
        vm.prank(payer);
        id = nft.reveal{value: total + extra}(label, to, ref, s);
        ids.push(id);
    }

    function _conserved() internal view {
        uint256 sum;
        for (uint256 i; i < accts.length; ++i) sum += nft.owed(accts[i]);
        for (uint256 i; i < ids.length; ++i) {
            sum += nft.depositOf(ids[i]);
            (, uint96 amount) = nft.trialPaymentOf(ids[i]);
            sum += amount;
        }
        assertEq(address(nft).balance, sum, "the balance is the deposits, the trial money and the credits");
    }

    function _allReentrancy(uint256 n) internal view {
        bytes4[] memory e = actor.errs();
        assertEq(e.length, n, "every guarded call was tried");
        for (uint256 i; i < e.length; ++i) assertEq(e[i], REENTRANCY, "refused with Reentrancy");
    }

    // a paid mint to the receiver, which tries every money entry point, saves records and passes the page to carol
    function test_paidMintHookCannotReachMoneyAndItsRecordsStayBehind() public {
        actor.prepSide("sidename", keccak256("s2"));
        actor.configure(1 | 2 | 4, carol, address(0));
        uint256 aliceBefore = alice.balance;
        uint256 id = _commitReveal(alice, "evilname", address(actor), 0, 1 ether);
        uint256 t = vm.getBlockTimestamp();
        assertEq(aliceBefore - alice.balance, nft.getFee(8), "alice pays the fee and gets the rest back");
        _allReentrancy(8);
        assertEq(actor.hookOwner(), address(actor));
        assertEq(actor.hookHolderSince(), t, "holderSince is set before the hook runs");
        assertEq(nft.ownerOf(id), carol);
        assertEq(nft.holderSince(id), t);
        assertEq(nft.addressesUpdatedAt(id), t, "the hook saved addresses");
        assertEq(nft.data(bytes32(id), "k"), "", "the receiver's data record does not count for carol");
        assertEq(nft.resolve(id), carol);
        assertEq(nft.addr(bytes32(id)), address(0), "nor its coin type 60 entry");
        assertEq(nft.depositOf(id), nft.getFee(8));
        _conserved();
        // the second commitment was good: only the guard stopped its reveal inside the hook
        uint256 side = actor.revealSide();
        ids.push(side);
        assertEq(nft.ownerOf(side), address(actor));
        _conserved();
    }

    // A premium buyout mints to a receiver that sends the page to DEAD from its hook. The money of the old
    // registration is split exactly as on any buyout, and the deleted page stays taken.
    function test_premiumBuyoutToAReceiverThatDeletesIt() public {
        uint256 refPage = _commitReveal(bob, "bobref", bob, 0, 0);
        uint256 id = _commitReveal(alice, "victim", alice, refPage, 0);
        vm.startPrank(alice);
        nft.setAddr(id, alicePay);
        nft.setData(id, "k", hex"01");
        vm.stopPrank();
        uint256 paid = nft.depositOf(id);

        vm.warp(nft.expiresAt(id) + 90 days + 3 days);
        actor.configure(4, DEAD, address(0));
        bytes32 s = keccak256("dave");
        bytes32 c = nft.makeCommitment("victim", address(actor), 0, s);
        vm.prank(dave);
        nft.commit(c);
        vm.warp(vm.getBlockTimestamp() + 61);
        (uint256 fee, uint256 carried, uint256 premium, uint256 total) = nft.quote("victim");
        assertGt(premium, 0);
        assertEq(carried, paid);
        uint256 daveBefore = dave.balance;
        vm.prank(dave);
        assertEq(nft.reveal{value: total + 1 ether}("victim", address(actor), 0, s), id);
        assertEq(daveBefore - dave.balance, total, "dave pays the quote");
        uint256 refShare = premium * 2500 / 10_000;
        assertEq(nft.owed(alicePay), carried + premium - refShare, "the old payee: the deposit and 75 percent");
        assertEq(nft.owed(bob), refShare, "the referrer's payee: 25 percent");
        assertEq(nft.ownerOf(id), DEAD);
        assertEq(uint256(nft.status(id)), uint256(PageCard.Status.Invalid));
        assertEq(nft.resolve(id), address(0));
        assertEq(nft.payee(id), DEAD);
        assertEq(nft.data(bytes32(id), "k"), "");
        assertFalse(nft.isAvailable("victim", 0), "a deleted top level page stays taken");
        assertEq(nft.holderSince(id), vm.getBlockTimestamp());
        assertEq(nft.depositOf(id), carried + fee, "the bought out deposit stays in the page");
        _conserved();

        // anyone may renew the deleted page, and its deposit then goes to DEAD on release
        vm.prank(carol);
        nft.renew{value: fee}(id);
        _conserved();
        vm.warp(nft.expiresAt(id) + 90 days + 21 days + 1);
        nft.release(id);
        assertEq(nft.owed(DEAD), carried + 2 * fee);
        _conserved();
        // and the page comes back at the plain fee, with nothing of its old records
        uint256 again = _commitReveal(carol, "victim", carol, 0, 0);
        ids.pop();
        assertEq(again, id);
        assertEq(nft.ownerOf(id), carol);
        assertEq(nft.data(bytes32(id), "k"), "");
        _conserved();
    }

    // A trial minted to a receiver that tries every money entry point, then tries to pass the unpaid trial to carol,
    // which is refused, and sends it to DEAD. The trial money still goes back to its payer.
    function test_trialToAReceiverThatDeletesIt() public {
        actor.prepSide("sidename", keccak256("s2"));
        actor.configure(1 | 8 | 4, DEAD, carol);
        bytes32 s = keccak256("trial");
        bytes32 c = trialCommitmentRaw("trialname", address(actor), 0, s);
        vm.prank(alice);
        nft.commit(c);
        vm.warp(vm.getBlockTimestamp() + 61);
        uint256 price = nft.getFee(9) / 10;
        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        uint256 id = nft.revealTrial{value: price + 1 ether}("trialname", address(actor), 0, s);
        ids.push(id);
        assertEq(aliceBefore - alice.balance, price);
        bytes4[] memory e = actor.errs();
        assertEq(e.length, 9);
        for (uint256 i; i < 8; ++i) assertEq(e[i], REENTRANCY);
        assertEq(e[8], PageNFT.Unpaid.selector, "an unpaid trial moves only to DEAD");
        assertEq(nft.ownerOf(id), DEAD);
        assertEq(uint256(nft.status(id)), uint256(PageCard.Status.Invalid));
        (address payer, uint96 amount) = nft.trialPaymentOf(id);
        assertEq(payer, alice);
        assertEq(amount, price);
        _conserved();
        vm.warp(nft.expiresAt(id) + 1);
        nft.release(id);
        assertEq(nft.owed(alice), price, "the trial money goes back to its payer");
        _conserved();
    }

    // a safe transfer, which takes no guard, to a receiver whose hook registers another page and saves records
    function test_safeTransferHookRegistersAPageAndSavesRecords() public {
        uint256 id = _commitReveal(alice, "plainname", alice, 0, 0);
        actor.prepSide("sidename", keccak256("s2"));
        vm.warp(vm.getBlockTimestamp() + 61);
        uint256 t = vm.getBlockTimestamp();
        actor.configure(2 | 16, address(0), address(0));
        vm.prank(alice);
        nft.safeTransferFrom(alice, address(actor), id);
        uint256 side = actor.sideId();
        ids.push(side);
        assertEq(nft.ownerOf(id), address(actor));
        assertEq(nft.holderSince(id), t);
        assertEq(actor.hookHolderSince(), t);
        assertEq(nft.addressesUpdatedAt(id), t);
        assertEq(nft.data(bytes32(id), "k"), hex"c0ffee");
        assertEq(nft.addr(bytes32(id)), address(0xE1));
        assertEq(nft.resolve(id), address(0xA1));
        assertEq(nft.ownerOf(side), address(actor));
        assertEq(nft.holderSince(side), t);
        assertEq(nft.addressesUpdatedAt(side), 0);
        assertEq(nft.depositOf(side), nft.getFee(8));
        _conserved();
    }
}

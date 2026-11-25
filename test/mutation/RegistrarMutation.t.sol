// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {SubpageRegistrar} from "../../src/SubpageRegistrar.sol";
import {MinterBase} from "../utils/MinterBase.sol";

// reads the payout's own proceeds while it is being paid
contract ProceedsReader {
    SubpageRegistrar immutable reg;
    uint256 public seen = type(uint256).max;

    constructor(SubpageRegistrar r) {
        reg = r;
    }

    receive() external payable {
        seen = reg.proceedsOf(address(this));
    }
}

// a gate token that answers one byte short of a word
contract AlmostWordGate {
    fallback() external {
        assembly {
            mstore(0, not(0))
            return(0, 31)
        }
    }
}

// buys a subpage at the exact price and cannot take ETH back
contract ExactBuyer {
    SubpageRegistrar immutable reg;

    constructor(SubpageRegistrar r) {
        reg = r;
    }

    function buy(uint256 parent, string calldata label, uint256 price) external payable returns (uint256) {
        return reg.registerSubpageFor{value: price}(parent, label, msg.sender, price, address(0));
    }
}

// The registrar at the edges its other tests leave open.
contract RegistrarMutationTest is MinterBase {
    uint256 club;

    function setUp() public override {
        super.setUp();
        club = _reg(alice, "club");
    }

    // the balance is zeroed before the ETH leaves, so the payout sees nothing left while it is paid
    function test_proceedsZeroedBeforeTheTransfer() public {
        ProceedsReader r = new ProceedsReader(reg);
        _setMinter(club, address(reg));
        _configure(club, address(r), address(0), 0.01 ether, false);
        vm.prank(buyer);
        reg.registerSubpage{value: 0.01 ether}(club, "sub", 0.01 ether, address(0));
        assertEq(reg.proceedsOf(address(r)), 0.01 ether);
        reg.claimProceedsFor(address(r));
        assertEq(r.seen(), 0, "zero during the payout");
        assertEq(address(r).balance, 0.01 ether);
    }

    // a gate token at address(1), a precompile with no balanceOf, reads as zero like any other failing token
    function test_gateAtAddressOne() public {
        _setMinter(club, address(reg));
        vm.prank(alice);
        reg.configure(club, payout, address(0), 0, true, address(1), 1, false);
        vm.prank(buyer);
        vm.expectRevert(SubpageRegistrar.GateFailed.selector);
        reg.registerSubpage(club, "one", 0, address(0));
    }

    // an answer of 31 bytes is too short and reads as zero
    function test_gateNeedsAFullWord() public {
        _setMinter(club, address(reg));
        address g = address(new AlmostWordGate());
        vm.prank(alice);
        reg.configure(club, payout, address(0), 0, true, g, 1, false);
        vm.prank(buyer);
        vm.expectRevert(SubpageRegistrar.GateFailed.selector);
        reg.registerSubpage(club, "short", 0, address(0));
    }

    // any address but PageNFT and the registrar can be the fee token, whatever its place in the address space: the
    // highest address is taken and the registrar is refused
    function test_feeTokenOfAnyOtherAddress() public {
        address high = address(type(uint160).max);
        vm.prank(alice);
        reg.configure(club, payout, high, 1, true, address(0), 0, false);
        (,,, address feeToken,,,,,) = reg.config(club);
        assertEq(feeToken, high);
        vm.prank(alice);
        vm.expectRevert(SubpageRegistrar.BadFeeToken.selector);
        reg.configure(club, payout, address(reg), 1, true, address(0), 0, false);
    }

    // a commitment can name any receiver but the registrar
    function test_commitmentForAnyReceiver() public {
        reg.makeSubpageCommitment(club, "x", address(type(uint160).max), bytes32(0));
        reg.makeSubpageCommitment(club, "x", address(1), bytes32(0));
        vm.expectRevert(SubpageRegistrar.NotAuthorized.selector);
        reg.makeSubpageCommitment(club, "x", address(reg), bytes32(0));
    }

    // a commitment can be made at any time, and again only once it is more than a day old
    function test_subCommitmentTimes() public {
        vm.warp(1000);
        reg.commitSubpage(keccak256("c"));
        assertEq(reg.subCommitments(keccak256("c")), 1000);
        vm.warp(1000 + 86400);
        vm.expectRevert(SubpageRegistrar.AlreadyCommitted.selector);
        reg.commitSubpage(keccak256("c"));
        vm.warp(1000 + 86401);
        reg.commitSubpage(keccak256("c"));
        assertEq(reg.subCommitments(keccak256("c")), 1000 + 86401);
    }

    // a reveal works from 20 seconds to exactly one day after the commitment, and not a second outside
    function test_revealWindowToTheSecond() public {
        _setMinter(club, address(reg));
        _configure(club, payout, address(0), 0, true);
        bytes32 secret = keccak256("s");
        bytes32 c = reg.makeSubpageCommitment(club, "early", buyer, secret);
        reg.commitSubpage(c);
        uint256 t = vm.getBlockTimestamp();
        vm.warp(t + 19);
        vm.prank(buyer);
        vm.expectRevert(SubpageRegistrar.CommitmentTooNew.selector);
        reg.revealSubpage(club, "early", secret, 0, address(0));
        vm.warp(t + 20);
        vm.prank(buyer);
        reg.revealSubpage(club, "early", secret, 0, address(0));
        c = reg.makeSubpageCommitment(club, "late", buyer, secret);
        reg.commitSubpage(c);
        t = vm.getBlockTimestamp();
        vm.warp(t + 86400);
        vm.prank(buyer);
        uint256 id = reg.revealSubpage(club, "late", secret, 0, address(0));
        assertEq(nft.ownerOf(id), buyer, "works at exactly one day");
        c = reg.makeSubpageCommitment(club, "later", buyer, secret);
        reg.commitSubpage(c);
        t = vm.getBlockTimestamp();
        vm.warp(t + 86401);
        vm.prank(buyer);
        vm.expectRevert(SubpageRegistrar.CommitmentTooOld.selector);
        reg.revealSubpage(club, "later", secret, 0, address(0));
    }

    // the terms sell only while this registrar is the minter, whichever other address is picked instead
    function test_otherMinterStopsTheSale() public {
        _setMinter(club, address(reg));
        _configure(club, payout, address(0), 0, false);
        address[2] memory others = [address(type(uint160).max), address(1)];
        for (uint256 i; i < 2; ++i) {
            _setMinter(club, others[i]);
            vm.prank(buyer);
            vm.expectRevert(SubpageRegistrar.NotMinter.selector);
            reg.registerSubpage(club, "x", 0, address(0));
        }
    }

    // a buyer that pays the exact price gets no call back, so a contract with no receive function can buy
    function test_exactPriceBuyerGetsNoCall() public {
        _setMinter(club, address(reg));
        _configure(club, payout, address(0), 0.01 ether, false);
        ExactBuyer b = new ExactBuyer(reg);
        vm.deal(address(b), 1 ether);
        vm.prank(buyer);
        uint256 id = b.buy(club, "exact", 0.01 ether);
        assertEq(nft.ownerOf(id), buyer);
    }

    // a minimum gate balance above 96 bits is refused, like a price above 96 bits
    function test_valuesAbove96Bits() public {
        vm.startPrank(alice);
        vm.expectRevert(SubpageRegistrar.ValueTooLarge.selector);
        reg.configure(club, payout, address(0), 0, true, address(usd), uint256(type(uint96).max) + 1, false);
        vm.expectRevert(SubpageRegistrar.ValueTooLarge.selector);
        reg.configure(club, payout, address(0), uint256(type(uint96).max) + 1, true, address(0), 0, false);
        reg.configure(club, payout, address(0), type(uint96).max, true, address(usd), type(uint96).max, false);
        vm.stopPrank();
    }

    // configure and disable log every term in its own place, and commitSubpage logs the committer
    function test_configureDisableAndCommitLogs() public {
        address gate = address(usd);
        uint64 epoch = nft.epochOf(club);
        vm.expectEmit(true, true, true, true, address(reg));
        emit SubpageRegistrar.ParentConfigured(club, alice, payout, address(0xFEE), 7, gate, 3, true, false, epoch);
        vm.prank(alice);
        reg.configure(club, payout, address(0xFEE), 7, true, gate, 3, false);
        vm.expectEmit(true, true, true, true, address(reg));
        emit SubpageRegistrar.ParentConfigured(club, alice, payout, address(0xFEE), 7, gate, 3, false, false, epoch);
        vm.prank(alice);
        reg.disable(club);
        vm.expectEmit(true, true, false, true, address(reg));
        emit SubpageRegistrar.Committed(keccak256("c"), carol);
        vm.prank(carol);
        reg.commitSubpage(keccak256("c"));
    }

    // disable logs sales as off and keeps the commit and reveal choice in its own place
    function test_disableLogsTheKeptCommitReveal() public {
        uint64 epoch = nft.epochOf(club);
        vm.prank(alice);
        reg.configure(club, payout, address(0), 7, true, address(0), 0, true);
        vm.expectEmit(true, true, true, true, address(reg));
        emit SubpageRegistrar.ParentConfigured(club, alice, payout, address(0), 7, address(0), 0, false, true, epoch);
        vm.prank(alice);
        reg.disable(club);
    }

    // a sale logs the parent, the subpage, the buyer, the receiver, the payout, the token and the price in their
    // places, and a claim logs the account and where the money went
    function test_saleAndClaimLogs() public {
        _setMinter(club, address(reg));
        _configure(club, payout, address(0), 0.01 ether, false);
        uint256 sub = _subId("kid", club);
        vm.expectEmit(true, true, true, true, address(reg));
        emit SubpageRegistrar.SubpageSold(club, sub, buyer, carol, payout, address(0), 0.01 ether, "kid");
        vm.prank(buyer);
        reg.registerSubpageFor{value: 0.01 ether}(club, "kid", carol, 0.01 ether, address(0));
        vm.expectEmit(true, true, false, true, address(reg));
        emit SubpageRegistrar.ProceedsClaimed(payout, dave, 0.01 ether);
        vm.prank(payout);
        reg.claimProceeds(dave);
        assertEq(dave.balance, 1000 ether + 0.01 ether);
    }
}

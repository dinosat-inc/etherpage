// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {SubpageRegistrar, IPageNFT} from "../../src/SubpageRegistrar.sol";
import {MinterBase} from "../utils/MinterBase.sol";
import {SubpageRegistrarNoPush} from "./harness/SubpageRegistrarNoPush.sol";

interface IClaimOwn {
    function claimProceeds(address to) external returns (uint256);
}

interface IDepositHook {
    function onDeposit() external;
}

// credits whoever calls deposit with what its own balance rose by during the call, so any ETH that arrives
// inside the call counts as the caller's
contract BalanceCreditPayout {
    mapping(address => uint256) public credit;

    function deposit() external {
        uint256 before = address(this).balance;
        IDepositHook(msg.sender).onDeposit();
        credit[msg.sender] += address(this).balance - before;
    }

    function withdrawCredit() external {
        uint256 a = credit[msg.sender];
        credit[msg.sender] = 0;
        (bool ok,) = msg.sender.call{value: a}("");
        require(ok, "send failed");
    }

    function collect(IClaimOwn reg) external {
        reg.claimProceeds(address(0));
    }

    receive() external payable {}
}

// calls deposit and, inside its hook, pushes the payout's proceeds so that they count as its deposit
contract PushingDepositor is IDepositHook {
    address reg;
    BalanceCreditPayout target;
    bool public pushed;

    function attack(address r, BalanceCreditPayout t) external {
        reg = r;
        target = t;
        t.deposit();
        t.withdrawCredit();
    }

    function onDeposit() external {
        (bool ok,) = reg.call(abi.encodeWithSignature("claimProceedsFor(address)", address(target)));
        pushed = ok;
    }

    receive() external payable {}
}

// splits every payment it receives among the members it has at that moment; joining stakes 1 ether, which
// quitting pays back with the member's share
contract SplitPayout {
    address[] public members;
    mapping(address => uint256) public share;
    mapping(address => uint256) public stake;
    mapping(address => bool) public isMember;

    constructor(address founder) {
        members.push(founder);
        isMember[founder] = true;
    }

    function join() external payable {
        require(msg.value == 1 ether && !isMember[msg.sender], "join");
        stake[msg.sender] = 1 ether;
        isMember[msg.sender] = true;
        members.push(msg.sender);
    }

    function quit() external {
        require(isMember[msg.sender], "not a member");
        isMember[msg.sender] = false;
        for (uint256 i; i < members.length; ++i) {
            if (members[i] == msg.sender) {
                members[i] = members[members.length - 1];
                members.pop();
                break;
            }
        }
        uint256 a = share[msg.sender] + stake[msg.sender];
        share[msg.sender] = 0;
        stake[msg.sender] = 0;
        (bool ok,) = msg.sender.call{value: a}("");
        require(ok, "send failed");
    }

    function collect(IClaimOwn reg) external {
        reg.claimProceeds(address(0));
    }

    receive() external payable {
        uint256 each = msg.value / members.length;
        for (uint256 i; i < members.length; ++i) share[members[i]] += each;
    }
}

// takes ETH and has no way to send it on; its own claim with a destination is its only way to move its proceeds
contract SinkPayout {
    function claimTo(IClaimOwn reg, address to) external {
        reg.claimProceeds(to);
    }

    receive() external payable {}
}

// Anyone may push a payout's proceeds with claimProceedsFor, so the caller chooses when a payout is paid. Three
// payout designs lose money to that on the registrar, and the same designs lose nothing on a reference copy
// that has no claimProceedsFor, where only the payout's own claim moves its proceeds.
contract ClaimPushDifferentialTest is MinterBase {
    SubpageRegistrarNoPush copy;
    uint256 club;
    uint256 zoo;
    address founder = makeAddr("founder");
    address newcomer = makeAddr("newcomer");

    function setUp() public override {
        super.setUp();
        copy = new SubpageRegistrarNoPush(IPageNFT(address(nft)));
        club = _reg(alice, "club");
        zoo = _reg(bob, "zoo");
        _setMinter(club, address(reg));
        _setMinter(zoo, address(copy));
        vm.deal(newcomer, 10 ether);
    }

    // one ETH sale on each, crediting realPayout on the registrar and copyPayout on the copy with price
    function _earn(address realPayout, address copyPayout, uint256 price, string memory label) internal {
        vm.prank(alice);
        reg.configure(club, realPayout, address(0), price, true, address(0), 0, false);
        vm.prank(bob);
        copy.configure(zoo, copyPayout, address(0), price, true, address(0), 0, false);
        vm.prank(buyer);
        reg.registerSubpage{value: price}(club, label, price, address(0));
        vm.prank(buyer);
        copy.registerSubpage{value: price}(zoo, label, price, address(0));
        assertEq(reg.proceedsOf(realPayout), price);
        assertEq(copy.proceedsOf(copyPayout), price);
    }

    function test_claimForTimingChosenByCaller() public {
        // a payout that credits its caller with its own balance increase loses its 3 ether to a depositor that
        // pushes during the deposit; on the copy there is no push and the depositor gets nothing
        BalanceCreditPayout realBc = new BalanceCreditPayout();
        BalanceCreditPayout copyBc = new BalanceCreditPayout();
        _earn(address(realBc), address(copyBc), 3 ether, "bc");
        PushingDepositor thief = new PushingDepositor();
        thief.attack(address(reg), realBc);
        assertTrue(thief.pushed());
        assertEq(address(thief).balance, 3 ether, "the depositor took the 3 ether");
        assertEq(address(realBc).balance, 0, "the payout has nothing left");
        assertEq(reg.proceedsOf(address(realBc)), 0);
        PushingDepositor thief2 = new PushingDepositor();
        thief2.attack(address(copy), copyBc);
        assertFalse(thief2.pushed(), "the copy has no push");
        assertEq(address(thief2).balance, 0, "the depositor got nothing");
        assertEq(copy.proceedsOf(address(copyBc)), 3 ether);
        copyBc.collect(IClaimOwn(address(copy)));
        assertEq(address(copyBc).balance, 3 ether, "the payout collects at a time it chooses");
        assertEq(copyBc.credit(address(thief2)), 0);

        // a payout that splits each payment among its current members: with 9 ether earned and one member, a
        // newcomer who joins for 1 ether, pushes and leaves takes 4.5 ether earned before it joined; on the copy
        // its push fails and it leaves with its stake alone
        SplitPayout realSp = new SplitPayout(founder);
        SplitPayout copySp = new SplitPayout(founder);
        _earn(address(realSp), address(copySp), 9 ether, "sp");
        uint256 before = newcomer.balance;
        vm.startPrank(newcomer);
        realSp.join{value: 1 ether}();
        reg.claimProceedsFor(address(realSp));
        realSp.quit();
        vm.stopPrank();
        assertEq(newcomer.balance - before, 4.5 ether, "the newcomer took half of what was earned before it joined");
        assertEq(realSp.share(founder), 4.5 ether);
        before = newcomer.balance;
        vm.startPrank(newcomer);
        copySp.join{value: 1 ether}();
        (bool pushed,) = address(copy).call(abi.encodeWithSignature("claimProceedsFor(address)", address(copySp)));
        copySp.quit();
        vm.stopPrank();
        assertFalse(pushed, "the copy has no push");
        assertEq(newcomer.balance, before, "the newcomer leaves with its stake and nothing more");
        copySp.collect(IClaimOwn(address(copy)));
        assertEq(copySp.share(founder), 9 ether, "the founder alone gets what was earned before");

        // a payout with a receive and no way to send ETH on keeps a pushed payment for good, although its own
        // claim could have sent its proceeds anywhere; on the copy only that claim exists
        SinkPayout realSink = new SinkPayout();
        SinkPayout copySink = new SinkPayout();
        _earn(address(realSink), address(copySink), 3 ether, "sink");
        vm.prank(stranger);
        reg.claimProceedsFor(address(realSink));
        vm.expectRevert(SubpageRegistrar.NothingToClaim.selector);
        realSink.claimTo(IClaimOwn(address(reg)), dave);
        assertEq(address(realSink).balance, 3 ether, "the ETH stays in a contract that cannot send it on");
        uint256 daveBefore = dave.balance;
        vm.prank(stranger);
        (bool ok,) = address(copy).call(abi.encodeWithSignature("claimProceedsFor(address)", address(copySink)));
        assertFalse(ok, "the copy has no push");
        copySink.claimTo(IClaimOwn(address(copy)), dave);
        assertEq(dave.balance, daveBefore + 3 ether, "on the copy the payout sends its proceeds where it chooses");
        assertEq(address(copySink).balance, 0);
    }
}

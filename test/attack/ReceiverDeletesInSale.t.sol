// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Vm} from "forge-std/Test.sol";
import {PageCard} from "../../src/PageCard.sol";
import {PageNFT} from "../../src/PageNFT.sol";
import {SubpageRegistrar} from "../../src/SubpageRegistrar.sol";
import {MinterBase} from "../utils/MinterBase.sol";

// a sale recipient whose hook sends the new subpage to DEAD, then tries to buy the freed label again
contract DeletingRecipient {
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    PageNFT immutable nft;
    SubpageRegistrar immutable reg;
    uint256 public hookCalls;
    bool public rebought;
    bytes public rebuyError;

    constructor(PageNFT n, SubpageRegistrar r) {
        nft = n;
        reg = r;
    }

    function onERC721Received(address, address, uint256 id, bytes calldata) external returns (bytes4) {
        ++hookCalls;
        nft.transferFrom(address(this), DEAD, id);
        try reg.registerSubpageFor(nft.parentOf(id), "hk", address(this), type(uint256).max, address(0)) {
            rebought = true;
        } catch (bytes memory e) {
            rebuyError = e;
        }
        return this.onERC721Received.selector;
    }
}

// A sale recipient deletes the subpage it is being sold inside the sale. SubpageSold still names it, PageNFT says
// DEAD holds the subpage, which answers nothing and is free again, and the hook cannot buy it a second time.
contract ReceiverDeletesInSaleTest is MinterBase {
    bytes32 constant T_SOLD = keccak256("SubpageSold(uint256,uint256,address,address,address,address,uint256,string)");
    bytes32 constant T_ADDRESS = keccak256("AddressChanged(bytes32,uint256,bytes)");
    bytes32 constant T_ADDR = keccak256("AddrChanged(bytes32,address)");
    uint256 constant PRICE = 0.01 ether;

    uint256 club;

    function setUp() public override {
        super.setUp();
        bytes32 secret = keccak256("club");
        bytes32 c = nft.makeCommitment("club", alice, 0, secret);
        vm.prank(alice);
        nft.commit(c);
        vm.warp(vm.getBlockTimestamp() + 61);
        (,,, uint256 total) = nft.quote("club");
        vm.prank(alice);
        club = nft.reveal{value: total}("club", alice, 0, secret);
        _sellSetup(club, PRICE);
    }

    function _countSales(Vm.Log[] memory logs) internal view returns (uint256 n) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(reg) && logs[i].topics[0] == T_SOLD) ++n;
        }
    }

    // replaying the address logs of the sale ends on the empty answers
    function _assertReplayEmpty(Vm.Log[] memory logs, uint256 id) internal view {
        bool seenMain;
        address main = address(1);
        bytes memory op = hex"01";
        bytes memory eth = hex"01";
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory l = logs[i];
            if (l.emitter != address(nft) || l.topics.length < 2 || l.topics[1] != bytes32(id)) continue;
            if (l.topics[0] == T_ADDR) {
                seenMain = true;
                main = abi.decode(l.data, (address));
            }
            if (l.topics[0] == T_ADDRESS) {
                (uint256 c, bytes memory v) = abi.decode(l.data, (uint256, bytes));
                if (c == COIN_OP) op = v;
                if (c == 60) eth = v;
            }
        }
        assertTrue(seenMain);
        assertEq(main, address(0));
        assertEq(op, "");
        assertEq(eth, "");
    }

    function test_atk14_receiverDeletesDuringSale() public {
        DeletingRecipient h = new DeletingRecipient(nft, reg);
        uint256 id = _subId("hk", club);
        // the sale record names the recipient the buyer chose, who will not hold the subpage when the sale ends
        vm.expectEmit(true, true, true, true, address(reg));
        emit SubpageRegistrar.SubpageSold(club, id, buyer, address(h), payout, address(0), PRICE, "hk");
        vm.recordLogs();
        vm.prank(buyer);
        uint256 sold = reg.registerSubpageFor{value: PRICE}(club, "hk", address(h), PRICE, address(0));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(sold, id);
        assertEq(h.hookCalls(), 1);

        // PageNFT says DEAD holds it, and it answers nothing
        assertEq(nft.ownerOf(id), DEAD);
        assertEq(nft.resolve(id), address(0));
        assertEq(nft.addr(bytes32(id)), address(0));
        assertEq(nft.addr(id, COIN_OP), "");
        assertEq(nft.addr(id, 60), "");
        assertEq(nft.payee(id), DEAD);
        assertEq(uint256(nft.status(id)), uint256(PageCard.Status.Invalid));
        assertTrue(nft.isAvailable("hk", club), "the label is free again");

        // the second purchase from inside the hook hit the registrar's guard
        assertFalse(h.rebought());
        assertEq(bytes4(h.rebuyError()), REENTRANCY);

        assertEq(_countSales(logs), 1, "one sale");
        assertEq(reg.proceedsOf(payout), PRICE);
        _assertReplayEmpty(logs, id);

        // the next buyer gets the same id at the same price
        vm.prank(buyer);
        reg.registerSubpageFor{value: PRICE}(club, "hk", buyer, PRICE, address(0));
        assertEq(nft.ownerOf(id), buyer);
        assertEq(nft.resolve(id), buyer);
        assertEq(reg.proceedsOf(payout), 2 * PRICE);
    }
}

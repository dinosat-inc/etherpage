// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {SubpageRegistrar} from "../../../src/SubpageRegistrar.sol";
import {MinterBase} from "../../utils/MinterBase.sol";

// buys subpages for itself through the registrar and has no receive, so any ETH sent to it fails
contract RefusingBuyer {
    SubpageRegistrar immutable reg;

    constructor(SubpageRegistrar r) {
        reg = r;
    }

    function buy(uint256 parentId, string calldata label, uint256 maxPrice, uint256 value) external returns (uint256) {
        return reg.registerSubpage{value: value}(parentId, label, maxPrice, address(0));
    }

    function commit(bytes32 c) external {
        reg.commitSubpage(c);
    }

    function reveal(uint256 parentId, string calldata label, bytes32 secret, uint256 maxPrice, uint256 value)
        external
        returns (uint256)
    {
        return reg.revealSubpage{value: value}(parentId, label, secret, maxPrice, address(0));
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}

// The controller lowers the price by a wei or two between the buyer's quote and the inclusion of its purchase.
// A buyer that takes ETH pays the new price and gets the difference back in the same call. A buyer that refuses
// ETH and sent the old price reverts its own purchase on the refund, on both paths, keeps its commitment, and
// buys at the new price.
contract SaleRepriceDownTest is MinterBase {
    uint256 constant PRICE = 0.01 ether;

    uint256 parent;

    function setUp() public override {
        super.setUp();
        parent = _reg(alice, "shop");
        _sellSetup(parent, PRICE);
    }

    function _price() internal view returns (uint256 p) {
        (,,,, p,,,,) = reg.config(parent);
    }

    function test_downwardRepriceRefundsTheDifferenceToTheBuyer() public {
        uint256 quoted = _price();
        assertEq(quoted, PRICE);
        _configure(parent, payout, address(0), quoted - 1, false);
        uint256 before = buyer.balance;
        vm.prank(buyer);
        uint256 sub = reg.registerSubpage{value: quoted}(parent, "kid", quoted, address(0));
        assertEq(nft.ownerOf(sub), buyer);
        assertEq(before - buyer.balance, quoted - 1, "the buyer pays the new price");
        assertEq(reg.proceedsOf(payout), quoted - 1, "the payout is credited the new price");
        assertEq(address(reg).balance, quoted - 1, "the registrar keeps nothing else");
    }

    function test_downwardRepriceRevertsABuyerThatRefusesEthOnBothPaths() public {
        RefusingBuyer b = new RefusingBuyer(reg);
        vm.deal(address(b), 1 ether);
        uint256 quoted = _price();

        // the direct path
        _configure(parent, payout, address(0), quoted - 1, false);
        vm.expectRevert(ETH_TRANSFER_FAILED);
        b.buy(parent, "kid", quoted, quoted);
        assertTrue(nft.isAvailable("kid", parent), "nothing was minted");
        assertEq(reg.proceedsOf(payout), 0);
        assertEq(address(b).balance, 1 ether);
        uint256 sub = b.buy(parent, "kid", quoted, quoted - 1);
        assertEq(nft.ownerOf(sub), address(b), "the new price buys");
        assertEq(address(b).balance, 1 ether - (quoted - 1));

        // the commit and reveal path
        _configure(parent, payout, address(0), quoted, true);
        bytes32 secret = keccak256("reprice");
        bytes32 c = reg.makeSubpageCommitment(parent, "kid2", address(b), secret);
        b.commit(c);
        vm.warp(vm.getBlockTimestamp() + 61);
        _configure(parent, payout, address(0), quoted - 2, true);
        vm.expectRevert(ETH_TRANSFER_FAILED);
        b.reveal(parent, "kid2", secret, quoted, quoted);
        assertGt(reg.subCommitments(c), 0, "the commitment survives");
        assertTrue(nft.isAvailable("kid2", parent));
        uint256 sub2 = b.reveal(parent, "kid2", secret, quoted, quoted - 2);
        assertEq(nft.ownerOf(sub2), address(b));
        assertEq(reg.proceedsOf(payout), 2 * quoted - 3);
    }
}

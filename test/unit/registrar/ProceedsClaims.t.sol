// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {SubpageRegistrar} from "../../../src/SubpageRegistrar.sol";
import {MinterBase} from "../../utils/MinterBase.sol";
import {WethLike} from "../../utils/WalletMocks.sol";
import {PlainPayout, HeavyPayoutLogic, HeavyPayout, BurnerPayout, ClaimBatcher} from "../../utils/ProceedsMocks.sol";

// Pushing registrar proceeds with claimProceedsFor: many claims in one transaction, too little gas, and a
// payout shaped like WETH.
contract ProceedsClaimsTest is MinterBase {
    uint256 club;

    function setUp() public override {
        super.setUp();
        club = _reg(alice, "club");
        _setMinter(club, address(reg));
    }

    // one ETH sale on club that credits account with price
    function _credit(address account, uint256 price, string memory label) internal {
        vm.prank(alice);
        reg.configure(club, account, address(0), price, true, address(0), 0, false);
        vm.prank(buyer);
        reg.registerSubpage{value: price}(club, label, price, address(0));
    }

    // A batch of claims in one transaction pays each account its own balance and the batcher nothing. Once
    // someone else has claimed one account, a batch that fails as a whole reverts NothingToClaim and pays no
    // one, while a batch that caps each claim's gas and catches each revert pays every other account that
    // takes ETH and carries on past a payout that burns all the gas it is given; every balance not paid
    // stays whole.
    function test_claimForBatchIsolatesEachAccount() public {
        PlainPayout plain = new PlainPayout();
        BurnerPayout burner = new BurnerPayout();
        _credit(carol, 1 ether, "one");
        _credit(address(plain), 2 ether, "two");
        _credit(address(burner), 3 ether, "three");
        _credit(dave, 4 ether, "four");
        ClaimBatcher b = new ClaimBatcher();
        uint256 carol0 = carol.balance;
        uint256 dave0 = dave.balance;
        address[] memory three = new address[](3);
        three[0] = carol;
        three[1] = address(plain);
        three[2] = dave;

        uint256 snap = vm.snapshotState();
        vm.prank(stranger);
        assertEq(b.claimAll(reg, three), 7 ether);
        assertEq(carol.balance, carol0 + 1 ether);
        assertEq(address(plain).balance, 2 ether);
        assertEq(dave.balance, dave0 + 4 ether);
        assertEq(address(b).balance, 0, "the batcher is paid nothing");
        assertEq(reg.proceedsOf(address(burner)), 3 ether, "an account outside the batch keeps its balance");
        assertEq(address(reg).balance, 3 ether);
        vm.revertToState(snap);

        // someone pushes dave's proceeds first, so the batch that fails as a whole reverts and pays no one
        vm.prank(bob);
        reg.claimProceedsFor(dave);
        assertEq(dave.balance, dave0 + 4 ether);
        vm.prank(stranger);
        vm.expectRevert(SubpageRegistrar.NothingToClaim.selector);
        b.claimAll(reg, three);
        assertEq(reg.proceedsOf(carol), 1 ether);
        assertEq(reg.proceedsOf(address(plain)), 2 ether);
        assertEq(carol.balance, carol0);
        assertEq(address(plain).balance, 0);

        // the batch that caps each claim's gas pays carol and plain past the burner and dave
        address[] memory four = new address[](4);
        four[0] = address(burner);
        four[1] = carol;
        four[2] = dave;
        four[3] = address(plain);
        vm.prank(stranger);
        (uint256[] memory paid, bytes[] memory errors) = b.claimEach(reg, four, 200_000);
        assertEq(paid[0], 0);
        assertEq(bytes4(errors[0]), ETH_TRANSFER_FAILED, "the burner's claim fails on its own");
        assertEq(paid[1], 1 ether);
        assertEq(errors[1].length, 0);
        assertEq(paid[2], 0);
        assertEq(bytes4(errors[2]), SubpageRegistrar.NothingToClaim.selector, "dave was paid already");
        assertEq(paid[3], 2 ether);
        assertEq(carol.balance, carol0 + 1 ether);
        assertEq(address(plain).balance, 2 ether);
        assertEq(dave.balance, dave0 + 4 ether, "dave was paid once");
        assertEq(reg.proceedsOf(address(burner)), 3 ether, "the burner's balance stays whole");
        assertEq(address(burner).balance, 0);
        assertEq(address(reg).balance, 3 ether);
        assertEq(address(b).balance, 0, "the batcher is paid nothing");
    }

    // claims for a payout whose receive needs far more than a stipend, at gas limit g: paid in full or nothing
    // changed; returns whether it paid and whether it failed inside the payout's receive
    function _claimAtGas(HeavyPayout heavy, uint256 g) internal returns (bool ok, bool failedInReceive) {
        bytes memory ret;
        vm.prank(stranger);
        (ok, ret) = address(reg).call{gas: g}(abi.encodeCall(SubpageRegistrar.claimProceedsFor, (address(heavy))));
        if (ok) {
            assertEq(address(heavy).balance, 1 ether, "paid in full");
            assertEq(HeavyPayoutLogic(payable(address(heavy))).received(), 1 ether);
            assertEq(reg.proceedsOf(address(heavy)), 0);
            assertEq(address(reg).balance, 0);
        } else {
            failedInReceive = ret.length == 4 && bytes4(ret) == ETH_TRANSFER_FAILED;
            assertEq(address(heavy).balance, 0, "nothing moved");
            assertEq(HeavyPayoutLogic(payable(address(heavy))).payments(), 0);
            assertEq(reg.proceedsOf(address(heavy)), 1 ether, "the balance stays whole");
            assertEq(address(reg).balance, 1 ether);
        }
    }

    // At every gas limit from 20,000 to 300,000 in steps of 1,000 a claim either pays the whole balance or
    // changes nothing. Both happen, and some failures come from the payout's receive, after the balance was
    // set to zero inside the call, which the failed transfer undoes.
    function test_claimForWithTooLittleGasNeverZeroes() public {
        HeavyPayout heavy = new HeavyPayout(address(new HeavyPayoutLogic()));
        _credit(address(heavy), 1 ether, "sub");
        uint256 paid;
        uint256 failed;
        uint256 failedInReceive;
        for (uint256 g = 20_000; g <= 300_000; g += 1_000) {
            uint256 snap = vm.snapshotState();
            (bool ok, bool inReceive) = _claimAtGas(heavy, g);
            if (ok) ++paid;
            else ++failed;
            if (inReceive) ++failedInReceive;
            vm.revertToState(snap);
        }
        assertGt(paid, 0, "some limits are enough");
        assertGt(failed, 0, "some limits are too low");
        assertGt(failedInReceive, 0, "some fail inside the payout's receive");
    }

    // the same at any gas limit in that range
    function testFuzz_claimForAtAnyGasLimitPaysInFullOrNothing(uint256 g) public {
        HeavyPayout heavy = new HeavyPayout(address(new HeavyPayoutLogic()));
        _credit(address(heavy), 1 ether, "sub");
        _claimAtGas(heavy, bound(g, 20_000, 300_000));
    }

    // A payout shaped like WETH turns every ETH payment into WETH credited to the sender. A claim for it
    // leaves the registrar holding WETH, which no function of the registrar can move, and a payout's own
    // claim to a WETH-like destination does the same; the ETH sits in the WETH contract.
    function test_wethPayoutStrandsTokens() public {
        WethLike weth = new WethLike();
        _credit(address(weth), 1 ether, "one");
        vm.prank(stranger);
        assertEq(reg.claimProceedsFor(address(weth)), 1 ether);
        assertEq(reg.proceedsOf(address(weth)), 0);
        assertEq(weth.balanceOf(address(reg)), 1 ether, "the registrar now holds WETH");
        assertEq(address(weth).balance, 1 ether);
        assertEq(address(reg).balance, 0);

        _credit(payout, 2 ether, "two");
        vm.prank(payout);
        reg.claimProceeds(address(weth));
        assertEq(weth.balanceOf(address(reg)), 3 ether, "the registrar holds this WETH too");
        assertEq(address(weth).balance, 3 ether);
        assertEq(address(reg).balance, 0);
    }
}

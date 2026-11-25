// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {trialCommitment} from "../../utils/TrialCommitment.sol";

import {Test, Vm} from "forge-std/Test.sol";
import {PageNFT} from "../../../src/PageNFT.sol";
import {PageCard} from "../../../src/PageCard.sol";
import {SubpageRegistrar, IPageNFT} from "../../../src/SubpageRegistrar.sol";

// Shared setup for the tests of the accepted behaviours. Every helper reads its price and builds its commitment
// before the prank, because a prank is used up by the next call of any kind, a view call included.
abstract contract AcceptedBase is Test {
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    bytes4 constant ETH_TRANSFER_FAILED = 0xb12d13eb; // ETHTransferFailed()

    // Multicall3 sits at this address on OP Mainnet, as on most chains; the fixture is the code deployed
    // there on OP Mainnet
    address constant MULTICALL3 = 0xcA11bde05977b3631167028862bE2a173976CA11;
    bytes32 constant MULTICALL3_CODEHASH = 0xd5c15df687b16f2ff992fc8d767b4216323184a2bbc6ee2f9c398c318e770891;

    PageNFT nft;
    SubpageRegistrar reg;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address dave = makeAddr("dave");
    address user = makeAddr("user");
    address relayer = makeAddr("relayer");
    address stranger = makeAddr("stranger");
    address hot = makeAddr("hot");
    address payout = makeAddr("payout");

    function setUp() public virtual {
        vm.warp(1_800_000_000);
        nft = new PageNFT(new PageCard());
        reg = new SubpageRegistrar(IPageNFT(address(nft)));
        address[8] memory who = [alice, bob, carol, dave, user, relayer, stranger, hot];
        for (uint256 i; i < who.length; ++i) vm.deal(who[i], 1000 ether);
    }

    function _secret(string memory label, address owner) internal pure returns (bytes32) {
        return keccak256(abi.encode("accepted", label, owner));
    }

    // sender commits to a paid registration of label for owner
    function _commitPaid(address sender, string memory label, address owner, uint256 ref) internal {
        bytes32 c = nft.makeCommitment(label, owner, ref, _secret(label, owner));
        vm.prank(sender);
        nft.commit(c);
    }

    // sender commits to a trial of label for owner
    function _commitTrial(address sender, string memory label, address owner, uint256 ref) internal {
        bytes32 c = trialCommitment(address(nft), label, owner, ref, _secret(label, owner));
        vm.prank(sender);
        nft.commit(c);
    }

    // payer registers label for owner for a year, 61 seconds after its commit, paying exactly the quote
    function _buy(address payer, string memory label, address owner, uint256 ref) internal returns (uint256 id) {
        _commitPaid(payer, label, owner, ref);
        vm.warp(vm.getBlockTimestamp() + 61);
        (,,, uint256 total) = nft.quote(label);
        bytes32 s = _secret(label, owner);
        vm.prank(payer);
        id = nft.reveal{value: total}(label, owner, ref, s);
    }

    // payer starts a trial of label for owner, 61 seconds after its commit, paying exactly the trial price
    function _trial(address payer, string memory label, address owner, uint256 ref) internal returns (uint256 id) {
        _commitTrial(payer, label, owner, ref);
        vm.warp(vm.getBlockTimestamp() + 61);
        uint256 price = _trialPrice(label);
        bytes32 s = _secret(label, owner);
        vm.prank(payer);
        id = nft.revealTrial{value: price}(label, owner, ref, s);
    }

    // a tenth of the yearly fee
    function _trialPrice(string memory label) internal view returns (uint256) {
        return nft.getFee(bytes(label).length) / 10;
    }

    // the parent's holder picks the registrar as its minter and sells subpages for an ETH price
    function _openShop(uint256 parentId, uint256 price, bool commitReveal) internal {
        address holder = nft.ownerOf(parentId);
        vm.prank(holder);
        nft.setSubpageMinter(parentId, address(reg));
        vm.prank(holder);
        reg.configure(parentId, payout, address(0), price, true, address(0), 0, commitReveal);
    }

    // puts the OP Mainnet Multicall3 code at its address and checks it is that code
    function _etchMulticall3() internal {
        vm.etch(MULTICALL3, vm.parseBytes(vm.readFile("test/fixtures/multicall3-op.hex")));
        assertEq(MULTICALL3.codehash, MULTICALL3_CODEHASH, "the fixture is the OP Mainnet Multicall3");
    }

    function _count(Vm.Log[] memory logs, bytes32 topic0) internal pure returns (uint256 n) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == topic0) ++n;
        }
    }
}

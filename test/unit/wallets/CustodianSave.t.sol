// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {PageCard} from "../../../src/PageCard.sol";
import {PageNFT} from "../../../src/PageNFT.sol";

// keeps names for depositors, saves a depositor's address only when asked, and never clears it
contract SavingVault {
    PageNFT immutable nft;
    mapping(uint256 => address) public depositor;

    constructor(PageNFT n) {
        nft = n;
    }

    function onERC721Received(address, address from, uint256 id, bytes calldata) external returns (bytes4) {
        require(msg.sender == address(nft), "not the registry");
        depositor[id] = from;
        return this.onERC721Received.selector;
    }

    // points the name at its depositor, so the name pays the depositor while the vault holds it
    function saveDepositor(uint256 id) external {
        require(msg.sender == depositor[id], "not the depositor");
        nft.setAddr(id, msg.sender);
    }

    // gives the name back and leaves the save in place
    function withdraw(uint256 id) external {
        require(msg.sender == depositor[id], "not the depositor");
        delete depositor[id];
        nft.transferFrom(address(this), msg.sender, id);
    }
}

// A vault's save counts again whenever the vault holds the same name, whoever deposited it, until a clearRecords
// or a fresh save retires it.
contract CustodianSaveTest is Test {
    PageNFT nft;
    SavingVault vault;

    address a = makeAddr("depositor a");
    address b = makeAddr("depositor b");
    address carol = makeAddr("carol");

    uint256 constant GRACE = 90 days;

    function setUp() public {
        vm.warp(1_800_000_000);
        nft = new PageNFT(new PageCard());
        vault = new SavingVault(nft);
        vm.deal(a, 100 ether);
        vm.deal(b, 100 ether);
        vm.deal(carol, 1000 ether);
    }

    function _register(address payer, string memory label, address to) internal returns (uint256 id) {
        bytes32 secret = keccak256(abi.encode(label, to, vm.getBlockTimestamp()));
        bytes32 c = nft.makeCommitment(label, to, 0, secret);
        vm.prank(payer);
        nft.commit(c);
        vm.warp(vm.getBlockTimestamp() + 61);
        (,,, uint256 total) = nft.quote(label);
        vm.prank(payer);
        id = nft.reveal{value: total}(label, to, 0, secret);
    }

    function _deposit(address who, uint256 id) internal {
        vm.prank(who);
        nft.safeTransferFrom(who, address(vault), id);
        assertEq(vault.depositor(id), who);
    }

    // carol buys the lapsed name at auction, one day into the premium; returns what the old payee was credited
    function _auction(uint256 id, string memory label, address oldPayee) internal returns (uint256 credited) {
        vm.warp(nft.expiresAt(id) + GRACE + 1 days);
        bytes32 secret = keccak256("auction");
        bytes32 c = nft.makeCommitment(label, carol, 0, secret);
        vm.prank(carol);
        nft.commit(c);
        vm.warp(vm.getBlockTimestamp() + 61);
        (, uint256 carried, uint256 premium, uint256 total) = nft.quote(label);
        assertGt(premium, 0, "inside the premium");
        uint256 before = nft.owed(oldPayee);
        vm.prank(carol);
        nft.reveal{value: total}(label, carol, 0, secret);
        credited = nft.owed(oldPayee) - before;
        // no referrer, so the referrer's quarter of the premium goes to DEAD
        assertEq(credited, carried + premium - premium * 2500 / 10_000, "deposit and three quarters of the premium");
    }

    function test_custodianStaleSavePaysEarlierDepositor() public {
        uint256 id = _register(a, "vaulted", a);
        _deposit(a, id);
        assertEq(nft.payee(id), address(vault), "a vault that saved nothing is paid itself");
        vm.prank(a);
        vault.saveDepositor(id);
        assertEq(nft.payee(id), a, "the vault's save points the name at a");
        vm.prank(a);
        vault.withdraw(id);
        vm.prank(a);
        nft.transferFrom(a, b, id);
        assertEq(nft.payee(id), b);
        uint256 snap = vm.snapshotState();

        // b deposits: the vault's old save counts again and the name pays a, not b and not the vault
        _deposit(b, id);
        assertEq(nft.ownerOf(id), address(vault));
        assertEq(nft.payee(id), a);
        assertEq(nft.resolve(id), a);
        assertEq(nft.addr(bytes32(id), 0x8000000a), abi.encodePacked(a), "the main address is a");
        assertEq(nft.addr(bytes32(id)), address(0), "the vault saved nothing for coin type 60");
        assertEq(nft.resolveAs(id, address(vault)), a);
        assertGt(_auction(id, "vaulted", a), 0);
        assertEq(nft.owed(b), 0, "b gets nothing");
        assertEq(nft.owed(address(vault)), 0);

        // a clearRecords by b before the deposit retires the vault's save: the vault is paid itself
        assertTrue(vm.revertToState(snap));
        vm.prank(b);
        nft.clearRecords(id);
        _deposit(b, id);
        assertEq(nft.payee(id), address(vault));
        assertEq(nft.resolve(id), address(vault));
        assertGt(_auction(id, "vaulted", address(vault)), 0);
        assertEq(nft.owed(a), 0, "a gets nothing");

        // a fresh save by the vault retires it too: the name pays b
        assertTrue(vm.revertToState(snap));
        _deposit(b, id);
        assertEq(nft.payee(id), a);
        vm.prank(b);
        vault.saveDepositor(id);
        assertEq(nft.payee(id), b);
        assertGt(_auction(id, "vaulted", b), 0);
        assertEq(nft.owed(a), 0, "a gets nothing");
    }
}

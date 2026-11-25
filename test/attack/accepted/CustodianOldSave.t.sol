// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {PageNFT} from "../../../src/PageNFT.sol";
import {AcceptedBase} from "./AcceptedBase.sol";

// keeps pages for depositors: it saves a depositor's address as the main address when asked and delivers a page where
// its depositor says. As built by default it never clears a save; with clearOnReceipt it clears the records of every
// page it receives, and with saveOnReceipt it saves each page's depositor as soon as it receives it.
contract CustodianVault {
    PageNFT immutable nft;
    bool immutable clearOnReceipt;
    bool immutable saveOnReceipt;
    mapping(uint256 => address) public depositor;

    constructor(PageNFT n, bool clear, bool save) {
        nft = n;
        clearOnReceipt = clear;
        saveOnReceipt = save;
    }

    function onERC721Received(address, address from, uint256 id, bytes calldata) external returns (bytes4) {
        require(msg.sender == address(nft), "not the registry");
        depositor[id] = from;
        if (clearOnReceipt) nft.clearRecords(id);
        if (saveOnReceipt) nft.setAddr(id, from);
        return this.onERC721Received.selector;
    }

    // points the page at its depositor, so the page pays and names the depositor while the vault holds it
    function saveDepositor(uint256 id) external {
        require(msg.sender == depositor[id], "not the depositor");
        nft.setAddr(id, msg.sender);
    }

    // sends the page where its depositor says, a buyer for one, and leaves the save in place
    function deliver(uint256 id, address to) external {
        require(msg.sender == depositor[id], "not the depositor");
        delete depositor[id];
        nft.transferFrom(address(this), to, id);
    }
}

// A saved main address counts while the account that saved it holds the page, judged by that account's address and
// not by when it held the page. When the page comes back to an account that held it before in the same registration,
// each address that account saved counts again, unless another holder has since written that coin type or the main
// address, or a clearRecords, a new registration or a new subpage mint retired them (README.md, Addresses).
// So a contract that held alice's page and saved alice as its main address, and later holds the same page for bob,
// who wrote nothing while he held it, points the page at alice again: every payment to the page and the money of its
// auction go to alice, and alice's display name shows again, until a clearRecords or a new save retires the old save.
// Nothing onchain looks wrong; holderSince moves at the deposit, so a wallet that warns on a recent change sees it
// while it is recent. A contract that holds pages for different people, such as a vault, a marketplace or a
// custodian, calls clearRecords or saves again on each page it receives, and a depositor can clear the records
// before depositing.
contract AcceptedCustodianOldSaveTest is AcceptedBase {
    string constant L = "vaulted";

    // alice registers the page, deposits it in the vault and has the vault save her as its main address, chooses it
    // as her display name, then sells it and has the vault deliver it to bob, who deposits it in the same vault
    function _aliceSavedThenBobDeposits(CustodianVault v) internal returns (uint256 id) {
        id = _buy(alice, L, alice, 0);
        vm.prank(alice);
        nft.safeTransferFrom(alice, address(v), id);
        vm.prank(alice);
        v.saveDepositor(id);
        assertEq(nft.payee(id), alice, "the vault's save points the page at alice");
        vm.prank(alice);
        nft.setPrimaryPage(id);
        assertEq(nft.reverseResolve(alice), L);

        vm.prank(alice);
        v.deliver(id, bob);
        assertEq(nft.ownerOf(id), bob);
        assertEq(nft.payee(id), bob, "the save does not count while bob holds the page");
        assertEq(nft.resolve(id), bob);
        assertEq(nft.reverseResolve(alice), "", "nor does alice's display name");

        vm.warp(vm.getBlockTimestamp() + 30 days);
        vm.prank(bob);
        nft.safeTransferFrom(bob, address(v), id);
        assertEq(v.depositor(id), bob);
        assertEq(nft.ownerOf(id), address(v));
        assertEq(nft.holderSince(id), vm.getBlockTimestamp(), "holderSince moves at the deposit");
    }

    // carol buys the lapsed page one day into the premium; returns what the old payee was credited
    function _auction(uint256 id, address oldPayee) internal returns (uint256 credited) {
        vm.warp(nft.expiresAt(id) + 90 days + 1 days);
        _commitPaid(carol, L, carol, 0);
        vm.warp(vm.getBlockTimestamp() + 61);
        (, uint256 carried, uint256 premium, uint256 total) = nft.quote(L);
        assertGt(premium, 0, "inside the premium");
        uint256 before = nft.owed(oldPayee);
        bytes32 s = _secret(L, carol);
        vm.prank(carol);
        nft.reveal{value: total}(L, carol, 0, s);
        credited = nft.owed(oldPayee) - before;
        // no referrer, so the referrer's quarter of the premium goes to DEAD
        assertEq(credited, carried + premium - premium * 2500 / 10_000, "deposit and three quarters of the premium");
    }

    // bob's page in the vault pays alice and names her again, and the money of its auction goes to alice
    function test_custodiansOldSavePaysAndNamesAnEarlierDepositor() public {
        CustodianVault v = new CustodianVault(nft, false, false);
        uint256 id = _aliceSavedThenBobDeposits(v);
        assertEq(nft.payee(id), alice, "the vault's old save counts again");
        assertEq(nft.resolve(id), alice);
        assertEq(nft.resolveAs(id, address(v)), alice);
        assertEq(nft.addr(bytes32(id), 0x8000000a), abi.encodePacked(alice), "the main address is alice");
        assertEq(nft.addr(bytes32(id)), address(0), "the vault saved nothing for coin type 60");
        assertEq(nft.reverseResolve(alice), L, "alice's display name is shown again");
        assertGt(_auction(id, alice), 0);
        assertEq(nft.owed(bob), 0, "bob gets nothing");
        assertEq(nft.owed(address(v)), 0);
    }

    // a clearRecords before the deposit, a new save, or a vault that clears or saves on each receipt retires the old
    // save
    function test_clearOrSaveOnEachReceiptRetiresTheOldSave() public {
        uint256 snap = vm.snapshotState();

        // bob clears the records before he deposits: the vault, which saved nothing since, is paid itself
        CustodianVault v = new CustodianVault(nft, false, false);
        uint256 id = _buy(alice, L, alice, 0);
        vm.prank(alice);
        nft.safeTransferFrom(alice, address(v), id);
        vm.prank(alice);
        v.saveDepositor(id);
        vm.prank(alice);
        v.deliver(id, bob);
        vm.prank(bob);
        nft.clearRecords(id);
        vm.prank(bob);
        nft.safeTransferFrom(bob, address(v), id);
        assertEq(nft.payee(id), address(v));
        assertEq(nft.resolve(id), address(v));
        assertEq(nft.reverseResolve(alice), "");
        assertGt(_auction(id, address(v)), 0);
        assertEq(nft.owed(alice), 0, "alice gets nothing");

        // the vault saves bob when he asks: the page pays bob
        vm.revertToState(snap);
        v = new CustodianVault(nft, false, false);
        id = _aliceSavedThenBobDeposits(v);
        assertEq(nft.payee(id), alice);
        vm.prank(bob);
        v.saveDepositor(id);
        assertEq(nft.payee(id), bob);
        assertEq(nft.reverseResolve(alice), "");
        assertGt(_auction(id, bob), 0);
        assertEq(nft.owed(alice), 0, "alice gets nothing");

        // a vault that clears the records of each page it receives: the page pays the vault itself
        vm.revertToState(snap);
        v = new CustodianVault(nft, true, false);
        id = _aliceSavedThenBobDeposits(v);
        assertEq(nft.payee(id), address(v));
        assertEq(nft.resolve(id), address(v));
        assertEq(nft.reverseResolve(alice), "");
        assertGt(_auction(id, address(v)), 0);
        assertEq(nft.owed(alice), 0, "alice gets nothing");

        // a vault that saves each page's depositor on receipt: the page pays bob
        vm.revertToState(snap);
        v = new CustodianVault(nft, false, true);
        id = _aliceSavedThenBobDeposits(v);
        assertEq(nft.payee(id), bob);
        assertEq(nft.resolve(id), bob);
        assertEq(nft.reverseResolve(alice), "");
        assertGt(_auction(id, bob), 0);
        assertEq(nft.owed(alice), 0, "alice gets nothing");
    }
}

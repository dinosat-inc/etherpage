// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Test, Vm} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {PageCard} from "../../../src/PageCard.sol";
import {PageNFT} from "../../../src/PageNFT.sol";
import {SubpageRegistrar, IPageNFT} from "../../../src/SubpageRegistrar.sol";

// A deployed contract is its code and its immutables: no constructor touches storage, emits an event or takes ETH.
contract ConstructorStateTest is Test {
    function _assertNoStorage(address a, string memory what) internal {
        (bytes32[] memory reads, bytes32[] memory writes) = vm.accesses(a);
        assertEq(writes.length, 0, string.concat(what, " wrote storage"));
        assertEq(reads.length, 0, string.concat(what, " read storage"));
    }

    function test_constructorsWriteNothing() public {
        vm.record();
        vm.recordLogs();
        PageCard card = new PageCard();
        PageNFT nft = new PageNFT(card);
        SubpageRegistrar reg = new SubpageRegistrar(IPageNFT(address(nft)));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        _assertNoStorage(address(card), "PageCard");
        _assertNoStorage(address(nft), "PageNFT");
        _assertNoStorage(address(reg), "SubpageRegistrar");
        assertEq(logs.length, 0, "a constructor emitted");
        // the immutables are the addresses passed
        assertEq(address(nft.card()), address(card));
        assertEq(address(reg.registry()), address(nft));
    }

    // forge test deploys code of any size here, so the size limits are checked by hand: at most 24,576 bytes of
    // runtime code and 49,152 bytes of creation code with its constructor argument, as each is deployed
    function test_eachContractFitsTheSizeLimits() public {
        // forge coverage builds without the optimizer, so the code there is larger than as deployed
        if (vm.isContext(VmSafe.ForgeContext.Coverage)) return;
        PageCard card = new PageCard();
        PageNFT nft = new PageNFT(card);
        SubpageRegistrar reg = new SubpageRegistrar(IPageNFT(address(nft)));
        assertLe(address(card).code.length, 24_576, "PageCard runtime");
        assertLe(address(nft).code.length, 24_576, "PageNFT runtime");
        assertLe(address(reg).code.length, 24_576, "SubpageRegistrar runtime");
        assertLe(type(PageCard).creationCode.length, 49_152, "PageCard creation code");
        assertLe(
            abi.encodePacked(type(PageNFT).creationCode, abi.encode(card)).length, 49_152, "PageNFT creation code"
        );
        assertLe(
            abi.encodePacked(type(SubpageRegistrar).creationCode, abi.encode(nft)).length,
            49_152,
            "SubpageRegistrar creation code"
        );
    }

    function _create(uint256 value, bytes memory init) internal returns (address a) {
        assembly ("memory-safe") {
            a := create(value, add(init, 0x20), mload(init))
        }
    }

    // one wei makes the creation fail and leaves nothing behind, and the same code deploys with no value
    function _assertRefusesValue(bytes memory init, string memory what) internal {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        uint256 before = address(this).balance;
        assertEq(_create(1, init), address(0), string.concat(what, " took ETH"));
        assertEq(predicted.code.length, 0, "no code at the address");
        assertEq(predicted.balance, 0, "no ETH at the address");
        assertEq(address(this).balance, before, "the wei stayed with the deployer");
        address deployed = _create(0, init);
        assertTrue(deployed != address(0), string.concat(what, " deploys with no value"));
        assertGt(deployed.code.length, 0);
    }

    function test_constructorsRejectValue() public {
        PageCard card = new PageCard();
        PageNFT nft = new PageNFT(card);
        _assertRefusesValue(type(PageCard).creationCode, "PageCard");
        _assertRefusesValue(abi.encodePacked(type(PageNFT).creationCode, abi.encode(card)), "PageNFT");
        _assertRefusesValue(abi.encodePacked(type(SubpageRegistrar).creationCode, abi.encode(nft)), "SubpageRegistrar");
    }
}

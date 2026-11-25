// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {ERC721} from "solady/tokens/ERC721.sol";
import {PageNFT} from "../../../src/PageNFT.sol";
import {PageCard} from "../../../src/PageCard.sol";

// deploys init code with CREATE, or with CREATE2 and the salt given
contract LookalikeDeployer {
    function deploy(bytes memory init, bool salted, bytes32 salt) external returns (address a) {
        assembly ("memory-safe") {
            switch salted
            case 0 { a := create(0, add(init, 0x20), mload(init)) }
            default { a := create2(0, add(init, 0x20), mload(init), salt) }
        }
    }
}

// the code an account delegates to
contract LookalikeDelegate {
    fallback() external payable {}
}

// The key wallet test passes 23 bytes of code that start with 0xef0100. CREATE and CREATE2 refuse runtime
// code that starts with 0xef (EIP3541), so no contract deployed under that rule can have that code, and in
// this test only an EIP7702 delegation writes it. The key wallet test only decides whether a registration asks the
// receiver to accept the name; no answer depends on the code at an address.
contract DesignatorLookalikeTest is Test {
    PageNFT nft;
    LookalikeDeployer deployer;
    address alice = makeAddr("alice");
    address constant TARGET = address(0xBEEF);

    function setUp() public {
        vm.warp(1_800_000_000);
        nft = new PageNFT(new PageCard());
        deployer = new LookalikeDeployer();
        vm.deal(alice, 1 ether);
    }

    // init code that returns runtime as the code of the new contract
    function _init(bytes memory runtime) internal pure returns (bytes memory) {
        return abi.encodePacked(hex"61", uint16(runtime.length), hex"80600c6000396000f3", runtime);
    }

    function _register(string memory label) internal returns (uint256 id) {
        bytes32 secret = keccak256(bytes(label));
        bytes32 c = nft.makeCommitment(label, alice, 0, secret);
        vm.prank(alice);
        nft.commit(c);
        vm.warp(vm.getBlockTimestamp() + 61);
        (,,, uint256 total) = nft.quote(label);
        vm.prank(alice);
        id = nft.reveal{value: total}(label, alice, 0, secret);
    }

    // the Ethereum answer of a name whose main address is a
    function _ethAnswerFor(uint256 id, address a) internal returns (bytes memory) {
        vm.prank(alice);
        nft.setAddr(id, a);
        return nft.addr(id, 60);
    }

    // commits a registration of label for to, paid by alice, and returns its secret and price 61 seconds later
    function _commitFor(string memory label, address to) internal returns (bytes32 secret, uint256 total) {
        secret = keccak256(abi.encode(label, to));
        bytes32 c = nft.makeCommitment(label, to, 0, secret);
        vm.prank(alice);
        nft.commit(c);
        vm.warp(vm.getBlockTimestamp() + 61);
        (,,, total) = nft.quote(label);
    }

    function test_designatorLookalikeCannotBeDeployed() public {
        bytes[4] memory refused = [
            abi.encodePacked(hex"ef0100", TARGET), // the 23 byte designator itself
            bytes(hex"ef"),
            abi.encodePacked(hex"ef0100", TARGET, hex"00"),
            abi.encodePacked(hex"ef00", TARGET, hex"00")
        ];
        for (uint256 i; i < refused.length; ++i) {
            bytes memory init = _init(refused[i]);
            assertEq(deployer.deploy{gas: 1_000_000}(init, false, 0), address(0), "CREATE refused");
            assertEq(deployer.deploy{gas: 1_000_000}(init, true, bytes32(i)), address(0), "CREATE2 refused");
        }

        // the same code with another first byte deploys, and is a contract to the key wallet test: a registration
        // for it asks it to accept the name, and its first byte makes that call fail. As the main address it gives
        // no coin type 60 answer, as alice saves nothing for it.
        uint256 id = _register("vault");
        bytes memory other = abi.encodePacked(hex"fe0100", TARGET);
        address made = deployer.deploy(_init(other), false, 0);
        assertEq(made.code, other, "23 bytes deployed");
        assertEq(_ethAnswerFor(id, made).length, 0, "no coin type 60 answer from the main address");
        address made2 = deployer.deploy(_init(other), true, bytes32(uint256(7)));
        assertEq(made2.code, other, "23 bytes deployed with CREATE2");
        assertEq(_ethAnswerFor(id, made2).length, 0, "no coin type 60 answer from the main address");
        address[2] memory made23 = [made, made2];
        string[2] memory labels = ["madeone", "madetwo"];
        for (uint256 i; i < 2; ++i) {
            (bytes32 secret, uint256 total) = _commitFor(labels[i], made23[i]);
            // the failed call burns the gas it is given, so the registration gets a bounded amount
            vm.prank(alice);
            vm.expectRevert(ERC721.TransferToNonERC721ReceiverImplementer.selector);
            nft.reveal{value: total, gas: 2_000_000}(labels[i], made23[i], 0, secret);
            assertTrue(nft.isAvailable(labels[i], 0), "the contract was asked to accept, so nothing was registered");
        }

        // a delegation writes exactly the designator, and that account passes the test: a registration for it goes
        // through without asking it to accept the name, which its delegate could not do. As the main address it
        // gives no coin type 60 answer either, as the code at an address changes no answer.
        uint256 key = 0x7702;
        address eoa = vm.addr(key);
        LookalikeDelegate impl = new LookalikeDelegate();
        vm.signAndAttachDelegation(address(impl), key);
        (bool ok,) = eoa.call("");
        assertTrue(ok);
        assertEq(eoa.code, abi.encodePacked(hex"ef0100", address(impl)), "the designator");
        assertEq(_ethAnswerFor(id, eoa), "", "a delegated main address gives no coin type 60 answer");
        (bytes32 s, uint256 price) = _commitFor("delegated", eoa);
        vm.prank(alice);
        uint256 got = nft.reveal{value: price}("delegated", eoa, 0, s);
        assertEq(nft.ownerOf(got), eoa, "registered to the delegated account without asking it");
    }
}

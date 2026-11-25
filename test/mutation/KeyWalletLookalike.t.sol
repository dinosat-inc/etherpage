// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {ERC721} from "solady/tokens/ERC721.sol";
import {RulesBase} from "../utils/RulesBase.sol";

// A key wallet has no code or exactly the 23 byte EIP7702 delegation, 0xef0100 and an address. Code that only
// starts like a delegation is a contract. EIP3541 refuses new code starting with 0xef from the London rules on,
// which OP Mainnet took at its Bedrock block, so an account made before then can hold such code. These tests
// make it under the Berlin rules; vm.etch refuses it. The key wallet test only decides whether a registration asks
// the receiver to accept the name; no answer depends on the code at an address.
contract KeyWalletLookalikeTest is RulesBase {
    uint256 constant OP = 0x8000000a;
    uint256 constant BASE = 0x80002105;

    // creation code that copies the runtime following its 12 bytes into memory and returns it
    function _init(bytes memory runtime) internal pure returns (bytes memory) {
        uint8 n = uint8(runtime.length);
        return abi.encodePacked(hex"60", n, hex"600c600039", hex"60", n, hex"6000f3", runtime);
    }

    // deploys runtime code under the Berlin rules, then goes back to the rules the tests run under
    function _legacy(bytes memory runtime) internal returns (address a) {
        string memory evm = vm.getEvmVersion();
        bytes memory init = _init(runtime);
        vm.setEvmVersion("berlin");
        assembly ("memory-safe") {
            a := create(0, add(init, 0x20), mload(init))
        }
        vm.setEvmVersion(evm);
        assertEq(a.code, runtime, "the lookalike code is in place");
    }

    // bob holds the name and saves x as its main address
    function _mainAddress(string memory l, address x) internal returns (uint256 id) {
        id = _buy(bob, l);
        vm.prank(bob);
        nft.setAddr(id, x);
        assertEq(nft.addr(id, OP), abi.encodePacked(x), "x is the main address");
    }

    // commits a paid registration for owner from bob and returns its price 61 seconds later
    function _commitAndQuote(string memory l, address owner) internal returns (uint256 total) {
        bytes32 c = nft.makeCommitment(l, owner, 0, _s(l, owner, 0));
        vm.prank(bob);
        nft.commit(c);
        vm.warp(vm.getBlockTimestamp() + 61);
        (,,, total) = nft.quote(l);
    }

    // CREATE, or CREATE2 when salted, of init under the rules the tests run under
    function deployNow(bytes calldata init, bool salted) external returns (address a) {
        bytes memory code = init;
        assembly ("memory-safe") {
            switch salted
            case 0 { a := create(0, add(code, 0x20), mload(code)) }
            default { a := create2(0, add(code, 0x20), mload(code), 0x01) }
        }
    }

    // under the rules the tests run under, CREATE and CREATE2 refuse the lookalike code and deploy the same
    // code with another first byte; a refused creation burns the gas it is given, so each gets a bounded amount
    function test_lookalikeCodeCannotBeDeployedNow() public {
        bytes[2] memory runtimes =
            [abi.encodePacked(hex"ef0100", address(0xBEEF), hex"00"), abi.encodePacked(hex"ef0101", address(0xBEEF))];
        for (uint256 i; i < 2; ++i) {
            bytes memory init = _init(runtimes[i]);
            assertEq(this.deployNow{gas: 1_000_000}(init, false), address(0), "CREATE refuses code starting with 0xef");
            assertEq(this.deployNow{gas: 1_000_000}(init, true), address(0), "CREATE2 refuses code starting with 0xef");
            bytes memory plain = runtimes[i];
            plain[0] = 0x5f;
            assertEq(this.deployNow{gas: 1_000_000}(_init(plain), false).code, plain, "CREATE deploys it with 0x5f first");
            assertEq(this.deployNow{gas: 1_000_000}(_init(plain), true).code, plain, "CREATE2 deploys it with 0x5f first");
        }
    }

    // the delegation prefix in 24 and in 22 bytes of code at the main address gives no answer on coin type 60 or
    // Base while bob saves nothing for them, and neither does the exact delegation; once bob saves a default, each
    // of them answers exactly that default, as the code at the main address changes no answer
    function test_delegationPrefixAtTheMainAddressChangesNoAnswer() public {
        address code24 = _legacy(abi.encodePacked(hex"ef0100", address(0xBEEF), hex"00"));
        address code22 = _legacy(abi.encodePacked(hex"ef0100", bytes19(uint152(0xBEEF))));
        address exact = makeAddr("exact");
        vm.etch(exact, abi.encodePacked(hex"ef0100", address(0xBEEF)));

        uint256 id = _mainAddress("lookalike", code24);
        assertEq(nft.addr(id, 60), bytes(""), "24 bytes on coin type 60");
        assertEq(nft.addr(id, BASE), bytes(""), "24 bytes on Base");

        vm.prank(bob);
        nft.setAddr(id, code22);
        assertEq(nft.addr(id, OP), abi.encodePacked(code22), "the 22 byte account is the main address");
        assertEq(nft.addr(id, 60), bytes(""), "22 bytes on coin type 60");
        assertEq(nft.addr(id, BASE), bytes(""), "22 bytes on Base");

        vm.prank(bob);
        nft.setAddr(id, exact);
        assertEq(nft.addr(id, OP), abi.encodePacked(exact), "the exact delegation is the main address");
        assertEq(nft.addr(id, 60), bytes(""), "the exact delegation gives no answer on coin type 60");
        assertEq(nft.addr(id, BASE), bytes(""), "nor on Base");

        address d = makeAddr("default");
        vm.prank(bob);
        nft.setAddrForCoin(id, 0x80000000, abi.encodePacked(d));
        address[3] memory mains = [exact, code22, code24];
        for (uint256 i; i < 3; ++i) {
            vm.prank(bob);
            nft.setAddr(id, mains[i]);
            assertEq(nft.addr(id, OP), abi.encodePacked(mains[i]), "the main address");
            assertEq(nft.addr(id, 60), abi.encodePacked(d), "the default on coin type 60");
            assertEq(nft.addr(id, BASE), abi.encodePacked(d), "the default on Base");
        }
    }

    // 23 bytes that start with 0xef01 but carry another version byte, at the main address, give no answer on coin
    // type 60 or Base, as bob saves nothing for them; test_registrationForALookalikeAsksItToAccept shows they are no
    // key wallet
    function test_otherDelegationVersionChangesNoAnswer() public {
        address other = _legacy(abi.encodePacked(hex"ef0101", address(0xBEEF)));
        uint256 id = _mainAddress("versioned", other);
        assertEq(nft.addr(id, 60), bytes(""), "another version on coin type 60");
        assertEq(nft.addr(id, BASE), bytes(""), "another version on Base");
    }

    // a registration for a lookalike asks it to accept the name, as for any contract; its code starts with
    // 0xef, so the call fails and the registration reverts without a record
    function test_registrationForALookalikeAsksItToAccept() public {
        address[3] memory lookalikes = [
            _legacy(abi.encodePacked(hex"ef0100", address(0xBEEF), hex"00")),
            _legacy(abi.encodePacked(hex"ef0101", address(0xBEEF))),
            _legacy(abi.encodePacked(hex"ef0100", bytes19(uint152(0xBEEF))))
        ];
        string[3] memory labels = ["lookalike", "versioned", "short"];
        for (uint256 i; i < 3; ++i) {
            uint256 total = _commitAndQuote(labels[i], lookalikes[i]);
            bytes32 secret = _s(labels[i], lookalikes[i], 0);
            // the failed call burns the gas it is given, so the registration gets a bounded amount
            vm.prank(bob);
            vm.expectRevert(ERC721.TransferToNonERC721ReceiverImplementer.selector);
            nft.reveal{value: total, gas: 2_000_000}(labels[i], lookalikes[i], 0, secret);
            assertTrue(nft.isAvailable(labels[i], 0), "nothing was registered");
        }
    }
}

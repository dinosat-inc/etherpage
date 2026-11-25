// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {NamingBase, ViewGateway, INameViews} from "../../utils/NamingBase.sol";

contract AnswersSafe {
    receive() external payable {}
}

// what each wallet style gets back for a name through a gateway, and what happens right after a sale
contract WalletAnswersTest is NamingBase {
    ViewGateway gw;

    uint256 constant OP = 0x8000000a;
    uint256 constant BASE = 0x80002105;
    uint256 constant ARB = 0x8000a4b1;
    uint256 constant DEFAULT_EVM = 0x80000000;

    function setUp() public override {
        super.setUp();
        gw = new ViewGateway(INameViews(address(nft)), "etherpage.com");
    }

    function _coin(string memory full, uint256 c) internal view returns (bytes memory) {
        return abi.decode(gw.resolve(_dns(full), abi.encodeWithSelector(0xf1cb7e06, bytes32(0), c)), (bytes));
    }

    function _addr60(string memory full) internal view returns (address) {
        return abi.decode(gw.resolve(_dns(full), abi.encodeWithSelector(0x3b3b57de, bytes32(0))), (address));
    }

    // a key wallet answers nothing outside the home chain until it saves an address for a chain or a default for
    // every EVM chain, and then exactly that; once alice saves a default, a wallet on the home chain, on coin type 60
    // and a Safe on Base all get her
    function test_keyWalletAnswersOnlyWhatItSaves() public {
        uint256 a = _buy(alice, "alice");
        assertEq(_coin("alice.etherpage.com", OP), abi.encodePacked(alice));
        assertEq(_coin("alice.etherpage.com", 60).length, 0);
        assertEq(_coin("alice.etherpage.com", BASE).length, 0);
        assertEq(_coin("alice.etherpage.com", ARB).length, 0);
        assertEq(_coin("alice.etherpage.com", DEFAULT_EVM).length, 0);
        assertEq(_addr60("alice.etherpage.com"), address(0));
        // an entry for one chain answers that chain only
        vm.prank(alice);
        nft.setAddrForCoin(a, BASE, abi.encodePacked(alice));
        assertEq(_coin("alice.etherpage.com", BASE), abi.encodePacked(alice));
        assertEq(_coin("alice.etherpage.com", 60).length, 0);
        assertEq(_coin("alice.etherpage.com", ARB).length, 0);
        // the default answers every EVM chain without an entry of its own
        vm.prank(alice);
        nft.setAddrForCoin(a, DEFAULT_EVM, abi.encodePacked(alice));
        assertEq(_coin("alice.etherpage.com", OP), abi.encodePacked(alice));
        assertEq(_coin("alice.etherpage.com", 60), abi.encodePacked(alice));
        assertEq(_coin("alice.etherpage.com", BASE), abi.encodePacked(alice));
        assertEq(_coin("alice.etherpage.com", ARB), abi.encodePacked(alice));
        assertEq(_coin("alice.etherpage.com", DEFAULT_EVM), abi.encodePacked(alice));
        assertEq(_addr60("alice.etherpage.com"), alice);
    }

    // a contract as the main address answers only on the home chain, as every main address does, so a wallet on
    // another chain finds nothing instead of a wrong address
    function test_contractAnswersOnlyOnOp() public {
        uint256 a = _buy(alice, "alice");
        AnswersSafe s = new AnswersSafe();
        vm.prank(alice);
        nft.setAddr(a, address(s));
        assertEq(_coin("alice.etherpage.com", OP), abi.encodePacked(address(s)));
        assertEq(_coin("alice.etherpage.com", 60).length, 0);
        assertEq(_coin("alice.etherpage.com", BASE).length, 0);
        assertEq(_coin("alice.etherpage.com", DEFAULT_EVM).length, 0);
        assertEq(_addr60("alice.etherpage.com"), address(0));
    }

    // after a sale the next read already points at the buyer on the home chain, with no address or text kept from
    // the seller; other chains answer nothing until the buyer saves, and then the buyer
    function test_saleSwitchesAtOnce() public {
        uint256 a = _buy(alice, "alice");
        address cold = makeAddr("aliceCold");
        vm.startPrank(alice);
        nft.setAddr(a, cold);
        nft.setAddrForCoin(a, BASE, abi.encodePacked(cold));
        nft.setAddrForCoin(a, DEFAULT_EVM, abi.encodePacked(cold));
        nft.setText(a, "url", "https://alice.example");
        vm.stopPrank();
        assertEq(_coin("alice.etherpage.com", OP), abi.encodePacked(cold));
        assertEq(_coin("alice.etherpage.com", 60), abi.encodePacked(cold));
        vm.prank(alice);
        nft.transferFrom(alice, bob, a);
        assertEq(_coin("alice.etherpage.com", OP), abi.encodePacked(bob), "OP answer is the buyer");
        assertEq(_coin("alice.etherpage.com", 60).length, 0, "seller default is not used");
        assertEq(_coin("alice.etherpage.com", BASE).length, 0, "seller Base address is not used");
        assertEq(_addr60("alice.etherpage.com"), address(0));
        string memory t = abi.decode(gw.resolve(_dns("alice.etherpage.com"), abi.encodeWithSelector(0x59d1d43c, bytes32(0), "url")), (string));
        assertEq(t, "", "seller text is not used");
        vm.prank(bob);
        nft.setAddrForCoin(a, DEFAULT_EVM, abi.encodePacked(bob));
        assertEq(_coin("alice.etherpage.com", 60), abi.encodePacked(bob), "coin 60 answer is the buyer's default");
        assertEq(_coin("alice.etherpage.com", BASE), abi.encodePacked(bob), "Base answer is the buyer's default");
        assertEq(_addr60("alice.etherpage.com"), bob);
    }

    // the wallet form of each of our names never has more than four labels, and one more label finds nothing
    function test_depthLimit() public {
        uint256 a = _buy(alice, "alice");
        vm.prank(alice);
        uint256 p = nft.registerSubpageFor("pay", a, carol);
        assertEq(_coin("pay.alice.etherpage.com", OP), abi.encodePacked(carol));
        assertEq(_addr60("pay.alice.etherpage.com"), address(0), "nothing saved for coin 60 yet");
        vm.prank(carol);
        nft.setAddrForCoin(p, 60, abi.encodePacked(carol));
        assertEq(_addr60("pay.alice.etherpage.com"), carol);
        (bool found,) = gw.idOf(_dns("x.pay.alice.etherpage.com"));
        assertFalse(found);
        assertEq(_addr60("x.pay.alice.etherpage.com"), address(0));
    }
}

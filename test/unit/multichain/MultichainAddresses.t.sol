// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {PageCard} from "../../../src/PageCard.sol";
import {PageNFT} from "../../../src/PageNFT.sol";

// stands in for a Safe or smart account deployed on OP
contract ChainSmartAcct {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    function exec(address to, bytes calldata data) external returns (bytes memory) {
        (bool ok, bytes memory ret) = to.call(data);
        require(ok, "exec failed");
        return ret;
    }
}

// what a name answers on each chain for each kind of holder and main address
contract MultichainAddressesTest is Test {
    PageCard card;
    PageNFT nft;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address whale = makeAddr("whale");

    uint256 constant ETH = 60;
    uint256 constant OP = 0x8000000a;
    uint256 constant DEF = 0x80000000;
    uint256 constant BASE = 0x80002105;
    uint256 constant ARB = 0x8000a4b1;
    uint256 constant BTC = 0;
    uint256 constant SOL = 501;
    uint256 constant NEWCHAIN = 0x80000000 | 999_999;

    function setUp() public {
        vm.warp(1_800_000_000);
        card = new PageCard();
        nft = new PageNFT(card);
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
    }

    function _register(address payer, address owner, string memory label) internal returns (uint256 id) {
        bytes32 secret = keccak256(abi.encode(owner, label));
        bytes32 commitment = nft.makeCommitment(label, owner, 0, secret);
        vm.prank(payer);
        nft.commit(commitment);
        vm.warp(block.timestamp + 61);
        (,,, uint256 total) = nft.quote(label);
        vm.prank(payer);
        id = nft.reveal{value: total}(label, owner, 0, secret);
    }

    function _expectEvm(uint256 id, address a) internal view {
        bytes memory want = a == address(0) ? bytes("") : abi.encodePacked(a);
        assertEq(nft.addr(id, ETH), want, "coin 60");
        assertEq(nft.addr(id, DEF), want, "DEFAULT_EVM");
        assertEq(nft.addr(id, BASE), want, "Base");
        assertEq(nft.addr(id, ARB), want, "Arbitrum");
    }

    // a plain key wallet holder with nothing saved answers on the home chain only
    function test_eoaHolder() public {
        uint256 id = _register(alice, alice, "alice");
        assertEq(nft.addr(id, OP), abi.encodePacked(alice));
        assertEq(nft.resolve(id), alice);
        // addr by node answers coin type 60, so nothing until the holder saves an entry or a default
        assertEq(nft.addr(bytes32(id)), address(0));
        _expectEvm(id, address(0));
        assertEq(nft.addr(id, BTC), "");
        assertEq(nft.addr(id, SOL), "");
    }

    // the home chain is coin type 0x8000000a, that is 0x80000000 | 10, on any network the contract runs on. On a test
    // network the coin type of its own chain id is one more EVM chain, and a save for it leaves the main address
    function test_theHomeChainCoinTypeIsTheSameOnATestNetwork() public {
        uint256 sepolia = 0x80000000 | 11155420;
        vm.chainId(11155420);
        uint256 id = _register(alice, alice, "alice");
        assertEq(OP, 0x80000000 | 10);
        assertEq(nft.addr(id, OP), abi.encodePacked(alice), "the main address");
        assertEq(nft.addr(id, sepolia), "", "the test network's own coin type answers nothing yet");
        vm.prank(alice);
        nft.setAddrForCoin(id, sepolia, abi.encodePacked(bob));
        assertEq(nft.addr(id, sepolia), abi.encodePacked(bob));
        assertEq(nft.resolve(id), alice, "the main address stays");
        assertEq(nft.payee(id), alice, "and so does the payee");
    }

    // a key wallet answers nothing on any other EVM chain, including one that does not exist yet, until it saves a
    // default, and then exactly that
    function test_keyWalletFutureChainAfterDefault() public {
        uint256 id = _register(alice, alice, "alice");
        assertEq(nft.addr(id, NEWCHAIN), "");
        assertEq(nft.addr(id, ETH), "");
        vm.prank(alice);
        nft.setAddrForCoin(id, DEF, abi.encodePacked(alice));
        assertEq(nft.addr(id, NEWCHAIN), abi.encodePacked(alice));
        assertEq(nft.addr(id, ETH), abi.encodePacked(alice));
        assertEq(nft.addr(id, OP), abi.encodePacked(alice));
    }

    // a 7702 delegated holder answers like any other holder: the home chain only, until it saves a default
    function test_7702Holder() public {
        address d = makeAddr("delegated");
        ChainSmartAcct impl = new ChainSmartAcct();
        vm.etch(d, abi.encodePacked(hex"ef0100", address(impl)));
        assertEq(d.code.length, 23);
        uint256 id = _register(alice, alice, "seven");
        vm.prank(alice);
        nft.transferFrom(alice, d, id);
        assertEq(nft.addr(id, OP), abi.encodePacked(d));
        _expectEvm(id, address(0));
        vm.prank(d);
        nft.setAddrForCoin(id, DEF, abi.encodePacked(d));
        _expectEvm(id, d);
        assertEq(nft.addr(id, OP), abi.encodePacked(d));
    }

    // minting straight to a 7702 holder, which then answers on the home chain only
    function test_7702HolderMint() public {
        address d = makeAddr("delegated2");
        ChainSmartAcct impl = new ChainSmartAcct();
        vm.etch(d, abi.encodePacked(hex"ef0100", address(impl)));
        uint256 id = _register(alice, d, "seven2");
        assertEq(nft.ownerOf(id), d);
        assertEq(nft.addr(id, OP), abi.encodePacked(d));
        _expectEvm(id, address(0));
    }

    // a Safe deployed on OP answers only on OP until it saves other chains
    function test_deployedSafeHolder() public {
        ChainSmartAcct safe = new ChainSmartAcct();
        uint256 id = _register(alice, address(safe), "safe");
        assertEq(nft.addr(id, OP), abi.encodePacked(address(safe)));
        _expectEvm(id, address(0));
        assertEq(nft.addr(id, NEWCHAIN), "");
        // the Safe opts in for Ethereum only, the other chains stay empty
        vm.prank(address(safe));
        nft.setAddrForCoin(id, ETH, abi.encodePacked(address(safe)));
        assertEq(nft.addr(id, ETH), abi.encodePacked(address(safe)));
        assertEq(nft.addr(id, DEF), "");
        assertEq(nft.addr(id, BASE), "");
        // the Safe opts in for every EVM chain with the default, and its Ethereum entry still wins
        vm.prank(address(safe));
        nft.setAddrForCoin(id, DEF, abi.encodePacked(address(safe)));
        assertEq(nft.addr(id, DEF), abi.encodePacked(address(safe)));
        assertEq(nft.addr(id, BASE), abi.encodePacked(address(safe)));
        assertEq(nft.addr(id, NEWCHAIN), abi.encodePacked(address(safe)));
        assertEq(nft.addr(id, ETH), abi.encodePacked(address(safe)));
    }

    // a Safe holder that saves a key wallet as main address answers it on the home chain only, and on every other EVM
    // chain once it saves that address as the default too
    function test_deployedSafeSavesEoaMain() public {
        ChainSmartAcct safe = new ChainSmartAcct();
        uint256 id = _register(alice, address(safe), "safe2");
        vm.prank(address(safe));
        nft.setAddr(id, alice);
        assertEq(nft.addr(id, OP), abi.encodePacked(alice));
        _expectEvm(id, address(0));
        vm.prank(address(safe));
        nft.setAddrForCoin(id, DEF, abi.encodePacked(alice));
        _expectEvm(id, alice);
        assertEq(nft.addr(id, OP), abi.encodePacked(alice));
    }

    // a counterfactual account with no code here answers like any other holder, and code appearing later changes
    // nothing
    function test_counterfactualHolder() public {
        address cf = makeAddr("counterfactual");
        assertEq(cf.code.length, 0);
        uint256 id = _register(alice, cf, "cf");
        assertEq(nft.ownerOf(id), cf);
        _expectEvm(id, address(0));
        vm.prank(cf);
        nft.setAddrForCoin(id, DEF, abi.encodePacked(cf));
        _expectEvm(id, cf);
        // once code appears here every answer stays as it was, with no event
        vm.recordLogs();
        vm.etch(cf, type(ChainSmartAcct).runtimeCode);
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(nft.addr(id, OP), abi.encodePacked(cf));
        _expectEvm(id, cf);
    }

    // a counterfactual account saved as main address by a key wallet holder answers on the home chain only, and code
    // appearing at it changes nothing
    function test_counterfactualSavedMain() public {
        address cf = makeAddr("counterfactual2");
        uint256 id = _register(alice, alice, "cfmain");
        vm.prank(alice);
        nft.setAddr(id, cf);
        assertEq(nft.addr(id, OP), abi.encodePacked(cf));
        _expectEvm(id, address(0));
        vm.etch(cf, type(ChainSmartAcct).runtimeCode);
        assertEq(nft.addr(id, OP), abi.encodePacked(cf));
        _expectEvm(id, address(0));
        // the holder can point coin type 60 at itself
        vm.prank(alice);
        nft.setAddrForCoin(id, ETH, abi.encodePacked(alice));
        assertEq(nft.addr(id, ETH), abi.encodePacked(alice));
        assertEq(nft.addr(id, BASE), "");
        // and every other EVM chain at the account with the default, whatever code it has now
        vm.prank(alice);
        nft.setAddrForCoin(id, DEF, abi.encodePacked(cf));
        assertEq(nft.addr(id, BASE), abi.encodePacked(cf));
        assertEq(nft.addr(id, ARB), abi.encodePacked(cf));
        assertEq(nft.addr(id, DEF), abi.encodePacked(cf));
        assertEq(nft.addr(id, ETH), abi.encodePacked(alice), "its own entry still wins over the default");
    }

    // a different main address answers on the home chain only, and entries per chain on top of it
    function test_savedDifferentMain() public {
        uint256 id = _register(alice, alice, "main");
        vm.prank(alice);
        nft.setAddr(id, bob);
        assertEq(nft.addr(id, OP), abi.encodePacked(bob));
        _expectEvm(id, address(0));
        // a coin 60 entry changes only coin 60, never DEFAULT_EVM or another chain
        vm.prank(alice);
        nft.setAddrForCoin(id, ETH, abi.encodePacked(alice));
        assertEq(nft.addr(id, ETH), abi.encodePacked(alice));
        assertEq(nft.addr(id, DEF), "");
        assertEq(nft.addr(id, BASE), "");
        // zero or empty bytes clear an entry back to the default, here none is saved, so the chain answers nothing
        vm.prank(alice);
        nft.setAddrForCoin(id, BASE, abi.encodePacked(address(0)));
        assertEq(nft.addr(id, BASE), "");
        vm.prank(alice);
        nft.setAddrForCoin(id, BASE, "");
        assertEq(nft.addr(id, BASE), "");
        // with bob saved as the default, a cleared entry answers bob
        vm.startPrank(alice);
        nft.setAddrForCoin(id, DEF, abi.encodePacked(bob));
        nft.setAddrForCoin(id, BASE, abi.encodePacked(whale));
        assertEq(nft.addr(id, BASE), abi.encodePacked(whale));
        nft.setAddrForCoin(id, BASE, abi.encodePacked(address(0)));
        assertEq(nft.addr(id, BASE), abi.encodePacked(bob));
        nft.setAddrForCoin(id, BASE, abi.encodePacked(whale));
        nft.setAddrForCoin(id, BASE, "");
        assertEq(nft.addr(id, BASE), abi.encodePacked(bob));
        vm.stopPrank();
        assertEq(nft.addr(id, ARB), abi.encodePacked(bob));
        assertEq(nft.addr(id, ETH), abi.encodePacked(alice), "the coin 60 entry still wins over the default");
        // an entry for a chain outside the EVM
        vm.prank(alice);
        nft.setAddrForCoin(id, BTC, hex"0014aabb");
        assertEq(nft.addr(id, BTC), hex"0014aabb");
    }

    // a transfer retires every save of the seller, profile included, and they return with the name
    function test_afterTransfer() public {
        string memory ape = "eip155:1/erc721:0xbc4ca0eda7647a8ab7c2061c2e118a18a936f13d/1";
        uint256 id = _register(alice, alice, "move");
        vm.startPrank(alice);
        nft.setAddr(id, whale);
        nft.setAddrForCoin(id, ETH, abi.encodePacked(whale));
        nft.setAddrForCoin(id, BASE, abi.encodePacked(whale));
        nft.setAddrForCoin(id, BTC, hex"01");
        nft.setText(id, "avatar", ape);
        nft.transferFrom(alice, bob, id);
        vm.stopPrank();
        assertEq(nft.addr(id, OP), abi.encodePacked(bob));
        _expectEvm(id, address(0));
        assertEq(nft.addr(id, BTC), "");
        assertEq(nft.text(id, "avatar"), "", "the seller's profile does not count for the buyer");
        // to a Safe: the home chain only, as for bob
        ChainSmartAcct safe = new ChainSmartAcct();
        vm.prank(bob);
        nft.transferFrom(bob, address(safe), id);
        assertEq(nft.addr(id, OP), abi.encodePacked(address(safe)));
        _expectEvm(id, address(0));
        assertEq(nft.text(id, "avatar"), "");
        // back to alice: her saves count again, and the chains she saved nothing for answer nothing
        vm.prank(address(safe));
        nft.transferFrom(address(safe), alice, id);
        assertEq(nft.addr(id, OP), abi.encodePacked(whale));
        assertEq(nft.addr(id, ETH), abi.encodePacked(whale));
        assertEq(nft.addr(id, BASE), abi.encodePacked(whale));
        assertEq(nft.addr(id, DEF), "");
        assertEq(nft.addr(id, ARB), "");
        assertEq(nft.addr(id, BTC), hex"01");
        assertEq(nft.text(id, "avatar"), ape);
    }

    // clearRecords retires everything, the saved default included: the holder is the main address again and the
    // other chains answer nothing
    function test_afterClearRecords() public {
        uint256 id = _register(alice, alice, "clear");
        vm.startPrank(alice);
        nft.setAddr(id, bob);
        nft.setAddrForCoin(id, ETH, abi.encodePacked(whale));
        nft.setAddrForCoin(id, DEF, abi.encodePacked(whale));
        nft.setAddrForCoin(id, BTC, hex"01");
        nft.setText(id, "avatar", "x");
        nft.clearRecords(id);
        vm.stopPrank();
        assertEq(nft.addr(id, OP), abi.encodePacked(alice));
        _expectEvm(id, address(0));
        assertEq(nft.addr(id, BTC), "");
        assertEq(nft.text(id, "avatar"), "");
    }

    // any holder can point any EVM chain at an account it does not control
    function test_noProofOfControl() public {
        uint256 id = _register(alice, alice, "claim");
        vm.prank(alice);
        nft.setAddrForCoin(id, ETH, abi.encodePacked(whale));
        assertEq(nft.addr(id, ETH), abi.encodePacked(whale));
        assertEq(nft.ownerOf(id), alice);
        vm.prank(alice);
        nft.setAddr(id, whale);
        assertEq(nft.resolve(id), whale);
        // the main address reaches the home chain only, and the default reaches every other EVM chain
        assertEq(nft.addr(id, DEF), "");
        assertEq(nft.addr(id, BASE), "");
        vm.prank(alice);
        nft.setAddrForCoin(id, DEF, abi.encodePacked(whale));
        _expectEvm(id, whale);
        // but whale did not choose this name as its display name
        assertEq(nft.reverseResolve(whale), "");
    }

    // after the reveal the holder bundles addresses, avatar and display name in one call
    function test_multicallAfterReveal() public {
        uint256 id = _register(alice, alice, "bundle");
        bytes[] memory calls = new bytes[](3);
        calls[0] = abi.encodeCall(PageNFT.setAddrForCoin, (id, ETH, abi.encodePacked(alice)));
        calls[1] = abi.encodeCall(PageNFT.setText, (id, "avatar", "eip155:10/erc721:0x0000000000000000000000000000000000000001/1"));
        calls[2] = abi.encodeCall(PageNFT.setPrimaryPage, (id));
        vm.prank(alice);
        nft.multicall(calls);
        assertEq(nft.addr(id, ETH), abi.encodePacked(alice));
        assertEq(nft.reverseResolve(alice), "bundle");
    }

    // a smart account can run the reveal and the bundle in one transaction
    function test_smartAccountRevealThenBundle() public {
        ChainSmartAcct acct = new ChainSmartAcct();
        vm.deal(address(acct), 1 ether);
        string memory label = "acct";
        bytes32 secret = keccak256("s");
        bytes32 commitment = nft.makeCommitment(label, address(acct), 0, secret);
        vm.prank(address(acct));
        nft.commit(commitment);
        vm.warp(block.timestamp + 61);
        (,,, uint256 total) = nft.quote(label);
        uint256 id = nft.computeId(label);
        vm.startPrank(address(acct));
        nft.reveal{value: total}(label, address(acct), 0, secret);
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeCall(PageNFT.setAddrForCoin, (id, ETH, abi.encodePacked(address(acct))));
        nft.multicall(calls);
        vm.stopPrank();
        assertEq(nft.addr(id, ETH), abi.encodePacked(address(acct)));
        assertEq(nft.addr(id, BASE), "");
    }

    // a payer who reveals for another owner cannot save records on that name
    function test_payerCannotSetRecords() public {
        uint256 id = _register(alice, bob, "gift");
        vm.prank(alice);
        vm.expectRevert(PageNFT.Unauthorized.selector);
        nft.setAddrForCoin(id, ETH, abi.encodePacked(alice));
    }

    // multicall is not payable, so a reveal cannot ride inside it
    function test_revealNotInMulticall() public {
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeCall(PageNFT.reveal, ("x", address(this), 0, bytes32(0)));
        (bool ok,) = address(nft).call{value: 1 ether}(abi.encodeCall(PageNFT.multicall, (calls)));
        assertFalse(ok);
        vm.expectRevert(PageNFT.InsufficientFee.selector);
        nft.multicall(calls);
    }
}

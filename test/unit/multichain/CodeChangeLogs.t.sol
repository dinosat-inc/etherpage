// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Test, Vm} from "forge-std/Test.sol";
import {PageCard} from "../../../src/PageCard.sol";
import {PageNFT} from "../../../src/PageNFT.sol";
import {SubpageRegistrar, IPageNFT} from "../../../src/SubpageRegistrar.sol";

// a deployed contract wallet that takes names
contract CodeWallet {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}

// the code an EIP7702 account delegates to
contract CodeDelegate {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    receive() external payable {}
}

// Registers a name for itself, or buys a subpage for itself through the registrar, from inside its constructor,
// and notes what it saw at that moment. Later it can save itself as the EVM default and send the name on.
contract ConstructorBuyer {
    PageNFT immutable nft;
    uint256 public id;
    uint256 public codeSizeThen;
    bytes public ethAnswerThen;

    constructor(PageNFT n, SubpageRegistrar reg, string memory label, bytes32 secret, uint256 parentId) payable {
        nft = n;
        uint256 got = parentId == 0
            ? n.reveal{value: msg.value}(label, address(this), 0, secret)
            : reg.registerSubpage{value: msg.value}(parentId, label, msg.value, address(0));
        uint256 size;
        assembly {
            size := extcodesize(address())
        }
        id = got;
        codeSizeThen = size;
        ethAnswerThen = n.addr(got, 60);
    }

    function saveDefault() external {
        nft.setAddrForCoin(id, 0x80000000, abi.encodePacked(address(this)));
    }

    function send(address to) external {
        nft.transferFrom(address(this), to, id);
    }
}

// No answer depends on the code at an address, so code that appears at or leaves a main address changes no answer
// and needs no event. An indexer that replays the address events keeps the last one for each node; these tests
// follow that replay against addr through every code change.
contract CodeChangeLogsTest is Test {
    PageNFT nft;

    bytes32 constant T_ADDRESS = keccak256("AddressChanged(bytes32,uint256,bytes)");
    bytes32 constant T_ADDR = keccak256("AddrChanged(bytes32,address)");
    uint256 constant ETH = 60;
    uint256 constant OP = 0x8000000a;
    uint256 constant GRACE = 90 days;
    uint256 constant DECAY = 21 days;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    // the replay: the last value each event carried for a node
    struct Seen {
        bool main;
        address addr;
        bytes op;
        bool eth;
        bytes ethValue;
    }

    mapping(uint256 => Seen) seen;

    function setUp() public {
        vm.warp(1_800_000_000);
        nft = new PageNFT(new PageCard());
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
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

    // applies every log recorded since the last call to the replay and returns them
    function _sync() internal returns (Vm.Log[] memory logs) {
        logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory l = logs[i];
            if (l.emitter != address(nft) || l.topics.length < 2) continue;
            uint256 id = uint256(l.topics[1]);
            if (l.topics[0] == T_ADDR) {
                seen[id].main = true;
                seen[id].addr = abi.decode(l.data, (address));
            } else if (l.topics[0] == T_ADDRESS) {
                (uint256 coin, bytes memory a) = abi.decode(l.data, (uint256, bytes));
                if (coin == OP) seen[id].op = a;
                if (coin == ETH) {
                    seen[id].eth = true;
                    seen[id].ethValue = a;
                }
            }
        }
    }

    // the OP answer and AddrChanged always follow the replay
    function _mainInStep(uint256 id) internal view {
        assertTrue(seen[id].main, "the name was announced");
        assertEq(seen[id].addr, nft.addr(bytes32(id)), "AddrChanged replay");
        assertEq(seen[id].op, nft.addr(id, OP), "OP replay");
    }

    function _ethInStep(uint256 id) internal view {
        assertTrue(seen[id].eth, "Ethereum was announced");
        assertEq(seen[id].ethValue, nft.addr(id, ETH), "Ethereum replay");
    }

    function _count(Vm.Log[] memory logs, bytes32 topic) internal view returns (uint256 n) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(nft) && logs[i].topics.length > 0 && logs[i].topics[0] == topic) ++n;
        }
    }

    // the coin 60 values in log order
    function _ethLogs(Vm.Log[] memory logs, uint256 id) internal view returns (bytes[] memory out) {
        out = new bytes[](logs.length);
        uint256 n;
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory l = logs[i];
            if (l.emitter != address(nft) || l.topics.length < 2 || l.topics[0] != T_ADDRESS) continue;
            if (uint256(l.topics[1]) != id) continue;
            (uint256 coin, bytes memory a) = abi.decode(l.data, (uint256, bytes));
            if (coin == ETH) out[n++] = a;
        }
        assembly ("memory-safe") {
            mstore(out, n)
        }
    }

    function _delegate(uint256 pk, address impl, address account) internal {
        vm.signAndAttachDelegation(impl, pk);
        vm.prank(bob);
        (bool ok,) = account.call("");
        assertTrue(ok, "the delegation call");
    }

    // the name lapses past grace and premium and bob registers it again for newOwner
    function _reRegister(uint256 id, string memory label, address newOwner) internal returns (Vm.Log[] memory) {
        vm.warp(nft.expiresAt(id) + GRACE + DECAY + 1);
        _sync();
        assertEq(_register(bob, label, newOwner), id);
        return _sync();
    }

    // code appears at the saved main address, then the name is registered again for newOwner, whose coin type 60
    // answer is empty whatever its code, as nothing is saved at the new record version
    function _codeAppearsThenReRegister(string memory label, address newOwner) internal {
        uint256 id = _register(alice, label, alice);
        address w = makeAddr(string.concat("counterfactual ", label));
        vm.prank(alice);
        nft.setAddr(id, w);
        _sync();
        assertEq(seen[id].ethValue, "", "nothing is saved for coin type 60, so setAddr announces it empty");
        vm.etch(w, type(CodeWallet).runtimeCode);
        assertEq(nft.payee(id), w, "code at the main address leaves the payee where it was");
        assertEq(nft.addr(id, ETH), "", "code at the main address leaves coin type 60 empty");
        assertEq(seen[id].ethValue, nft.addr(id, ETH), "the coin type 60 replay stays in step");
        _mainInStep(id);

        Vm.Log[] memory logs = _reRegister(id, label, newOwner);
        bytes[] memory eth = _ethLogs(logs, id);
        assertEq(eth.length, 2, "the burn and the mint each announce Ethereum");
        assertEq(eth[0], "", "the burn announces an empty answer");
        assertEq(eth[1], "", "the mint announces the new owner's empty answer");
        assertEq(nft.ownerOf(id), newOwner);
        _mainInStep(id);
        _ethInStep(id);
    }

    function test_reRegistrationAfterACodeChangeStaysInStep() public {
        vm.recordLogs();
        address eoa = makeAddr("next owner");
        address wallet = address(new CodeWallet());
        (address seven, uint256 pk) = makeAddrAndKey("next 7702 owner");
        _delegate(pk, address(new CodeDelegate()), seven);
        assertEq(seven.code.length, 23, "a 7702 designator");
        _codeAppearsThenReRegister("loaded-a", eoa);
        _codeAppearsThenReRegister("loaded-b", wallet);
        _codeAppearsThenReRegister("loaded-c", seven);

        // code leaves the main address: coin type 60 stays empty, so no event is missing
        address gone = address(new CodeWallet());
        uint256 id = _register(alice, "loaded-d", alice);
        vm.prank(alice);
        nft.setAddr(id, gone);
        _sync();
        assertEq(seen[id].ethValue, "", "a contract main address is announced empty for Ethereum");
        vm.etch(gone, "");
        assertEq(nft.payee(id), gone, "code leaving the main address leaves the payee where it was");
        assertEq(nft.addr(id, ETH), "", "a codeless main address still gives no coin type 60 answer");
        assertEq(seen[id].ethValue, nft.addr(id, ETH), "in step");
        Vm.Log[] memory logs = _reRegister(id, "loaded-d", wallet);
        assertEq(_ethLogs(logs, id).length, 2);
        assertEq(_ethLogs(logs, id)[0], "", "the burn announces an empty answer");
        assertEq(_ethLogs(logs, id)[1], "", "the mint announces the new owner's empty answer");
        _mainInStep(id);
        _ethInStep(id);
    }

    function test_codeChangeThenTransferWithTheSameMainStaysInStep() public {
        vm.recordLogs();
        // code appears at x, then the holder sends the name to x itself
        uint256 id = _register(alice, "edges", alice);
        address x = makeAddr("x");
        vm.prank(alice);
        nft.setAddr(id, x);
        _sync();
        assertEq(seen[id].ethValue, "", "alice saved nothing for coin type 60");
        vm.etch(x, type(CodeWallet).runtimeCode);
        assertEq(nft.addr(id, ETH), "", "code at x changes nothing");
        vm.prank(alice);
        nft.transferFrom(alice, x, id);
        Vm.Log[] memory logs = _sync();
        assertEq(nft.resolve(id), x, "the main address is x before and after");
        assertEq(_count(logs, T_ADDR), 0, "no AddrChanged");
        assertEq(_count(logs, T_ADDRESS), 0, "no AddressChanged, for Ethereum either");
        assertEq(nft.addr(id, ETH), "", "x saved nothing for coin type 60 either");
        assertEq(seen[id].ethValue, "", "the log says empty, in step");
        _mainInStep(id);
        _ethInStep(id);
        // the next main address change announces coin type 60 again, still empty as x saved nothing for it
        vm.prank(x);
        nft.setAddr(id, alice);
        _sync();
        _mainInStep(id);
        _ethInStep(id);
        assertEq(seen[id].ethValue, "");

        // code leaves y, then the holder sends the name to y
        uint256 id2 = _register(alice, "edges2", alice);
        address y = address(new CodeWallet());
        vm.prank(alice);
        nft.setAddr(id2, y);
        _sync();
        assertEq(seen[id2].ethValue, "");
        vm.etch(y, "");
        vm.prank(alice);
        nft.transferFrom(alice, y, id2);
        logs = _sync();
        assertEq(_count(logs, T_ADDRESS), 0, "the same main address and the same Ethereum answer on both sides");
        assertEq(nft.addr(id2, ETH), "", "code leaving y changes nothing");
        assertEq(seen[id2].ethValue, "", "the log says empty, in step");
        _mainInStep(id2);
        _ethInStep(id2);
        vm.prank(y);
        nft.setAddr(id2, address(0));
        _sync();
        _ethInStep(id2);
        assertEq(seen[id2].ethValue, "", "y saved nothing for coin type 60");
    }

    // an EIP7702 delegation set, changed or removed never changes the answer, so the log never goes stale
    function test_delegationChangesLeaveTheLogInStep() public {
        vm.recordLogs();
        (address k, uint256 pk) = makeAddrAndKey("7702 main");
        uint256 id = _register(alice, "seven", alice);
        vm.prank(alice);
        nft.setAddr(id, k);
        _sync();
        _ethInStep(id);
        _delegate(pk, address(new CodeDelegate()), k);
        assertEq(k.code.length, 23);
        _ethInStep(id);
        _delegate(pk, address(new CodeDelegate()), k);
        _ethInStep(id);
        _delegate(pk, address(0), k);
        assertEq(k.code.length, 0, "the delegation is removed");
        _ethInStep(id);
        assertEq(seen[id].ethValue, "", "the main address is not the coin type 60 answer");
        vm.prank(alice);
        nft.transferFrom(alice, k, id);
        assertEq(_count(_sync(), T_ADDRESS), 0);
        _mainInStep(id);
        _ethInStep(id);
    }

    // Code appears at a main address, or leaves it, and the coin 60 log stays in step, as no answer depends on
    // code; the next coin 60 event announces the same answer the log already holds, whether it comes from setAddr,
    // from setAddrForCoin for 60 or from a transfer that changes the main address.
    function test_codeChangeNeedsNoRefreshFromTheNextMainAnnouncement() public {
        vm.recordLogs();

        // setAddr with the same address again
        uint256 idA = _register(alice, "refresh-a", alice);
        address w = makeAddr("main a");
        vm.prank(alice);
        nft.setAddr(idA, w);
        _sync();
        vm.etch(w, type(CodeWallet).runtimeCode);
        assertEq(seen[idA].ethValue, "", "empty before and after code appears");
        assertEq(nft.addr(idA, ETH), "");
        _ethInStep(idA);
        vm.prank(alice);
        nft.setAddr(idA, w);
        assertEq(_ethLogs(_sync(), idA).length, 1, "setAddr announces Ethereum");
        _ethInStep(idA);
        _mainInStep(idA);

        // setAddrForCoin for 60 with an empty value, after code left the main address
        uint256 idB = _register(alice, "refresh-b", alice);
        address gone = address(new CodeWallet());
        vm.prank(alice);
        nft.setAddr(idB, gone);
        _sync();
        assertEq(seen[idB].ethValue, "", "a contract main address is announced empty");
        vm.etch(gone, "");
        assertEq(nft.addr(idB, ETH), "", "empty before and after code leaves");
        _ethInStep(idB);
        vm.prank(alice);
        nft.setAddrForCoin(idB, ETH, "");
        Vm.Log[] memory logs = _sync();
        assertEq(_ethLogs(logs, idB).length, 1, "setAddrForCoin for 60 announces its answer");
        assertEq(_ethLogs(logs, idB)[0], "", "no entry and no default, so empty");
        _ethInStep(idB);
        _mainInStep(idB);

        // a transfer that changes the main address
        uint256 idC = _register(alice, "refresh-c", alice);
        address x = makeAddr("main c");
        vm.prank(alice);
        nft.setAddr(idC, x);
        _sync();
        vm.etch(x, type(CodeWallet).runtimeCode);
        assertEq(seen[idC].ethValue, "", "empty before and after code appears");
        assertEq(nft.addr(idC, ETH), "");
        _ethInStep(idC);
        vm.prank(alice);
        nft.transferFrom(alice, bob, idC);
        logs = _sync();
        assertEq(nft.resolve(idC), bob, "the saved main address stops counting for the buyer");
        assertEq(_ethLogs(logs, idC).length, 1, "the transfer announces Ethereum");
        _ethInStep(idC);
        _mainInStep(idC);
        assertEq(seen[idC].ethValue, "", "bob saved nothing for coin type 60");
    }

    // A contract that registers a name, or buys a subpage, from inside its constructor has no code at that moment,
    // which changes nothing: the mint announces an empty coin 60 answer, and addr for 60 stays empty once it is
    // built. Once it saves itself as the EVM default, coin 60 answers exactly that, and a later sale of the name to
    // another contract announces the empty answer of the buyer.
    function test_constructorBuyerAnswersNothingUntilItSavesADefault() public {
        vm.recordLogs();
        SubpageRegistrar reg = new SubpageRegistrar(IPageNFT(address(nft)));

        // a top level name revealed from the constructor, committed for the address it is deployed at
        string memory label = "builder";
        bytes32 secret = keccak256("constructor buyer");
        address next = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        bytes32 commitment = nft.makeCommitment(label, next, 0, secret);
        vm.prank(alice);
        nft.commit(commitment);
        vm.warp(vm.getBlockTimestamp() + 61);
        (,,, uint256 total) = nft.quote(label);
        _sync();
        ConstructorBuyer top = new ConstructorBuyer{value: total}(nft, reg, label, secret, 0);
        assertEq(address(top), next);
        _bornWithNoAnswer(top, _sync());

        // a subpage bought from the constructor, through the registrar
        uint256 shop = _register(alice, "shopfront", alice);
        uint256 price = 0.001 ether;
        vm.startPrank(alice);
        nft.setSubpageMinter(shop, address(reg));
        reg.configure(shop, address(0), address(0), price, true, address(0), 0, false);
        vm.stopPrank();
        _sync();
        ConstructorBuyer sub = new ConstructorBuyer{value: price}(nft, reg, "kid", bytes32(0), shop);
        assertEq(nft.parentOf(sub.id()), shop);
        _bornWithNoAnswer(sub, _sync());
    }

    // checks one constructor buyer: what it saw, what the mint logged, its own default and the later sale
    function _bornWithNoAnswer(ConstructorBuyer b, Vm.Log[] memory mintLogs) internal {
        uint256 id = b.id();
        bytes memory self = abi.encodePacked(address(b));
        assertEq(nft.ownerOf(id), address(b));
        assertEq(b.codeSizeThen(), 0, "no code while the constructor runs");
        assertEq(b.ethAnswerThen(), "", "then addr for 60 is empty, as nothing is saved");
        bytes[] memory eth = _ethLogs(mintLogs, id);
        assertEq(eth.length, 1, "the mint announces Ethereum once");
        assertEq(eth[0], "", "as empty");

        assertGt(address(b).code.length, 0);
        assertEq(nft.addr(id, ETH), "", "a built contract still answers nothing for coin type 60");
        assertEq(seen[id].ethValue, "", "and the log agrees");
        _mainInStep(id);
        _ethInStep(id);

        // the buyer saves itself as the default, which answers for coin type 60 and is announced
        b.saveDefault();
        eth = _ethLogs(_sync(), id);
        assertEq(eth.length, 1, "the save of the default announces coin type 60");
        assertEq(eth[0], self, "as the saved default");
        assertEq(nft.addr(id, ETH), self, "coin type 60 answers exactly the default");
        _ethInStep(id);

        address wallet = address(new CodeWallet());
        b.send(wallet);
        eth = _ethLogs(_sync(), id);
        assertEq(eth.length, 1, "the sale announces Ethereum");
        assertEq(eth[0], "", "empty for the contract that bought it");
        assertEq(nft.ownerOf(id), wallet);
        _ethInStep(id);
        _mainInStep(id);
    }
}

// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Test, Vm} from "forge-std/Test.sol";
import {PageNFT} from "../../../src/PageNFT.sol";
import {PageCard} from "../../../src/PageCard.sol";
import {SubpageRegistrar, IPageNFT} from "../../../src/SubpageRegistrar.sol";

// the user operation of EntryPoint v0.6
struct UserOperation {
    address sender;
    uint256 nonce;
    bytes initCode;
    bytes callData;
    uint256 callGasLimit;
    uint256 verificationGasLimit;
    uint256 preVerificationGas;
    uint256 maxFeePerGas;
    uint256 maxPriorityFeePerGas;
    bytes paymasterAndData;
    bytes signature;
}

// one call of executeBatch
struct WalletCall {
    address target;
    uint256 value;
    bytes data;
}

// the signature a wallet reads: the index of the owner that signed and, for an address owner, r, s and v packed
struct SignatureWrapper {
    uint256 ownerIndex;
    bytes signatureData;
}

interface IEntryPoint06 {
    function handleOps(UserOperation[] calldata ops, address payable beneficiary) external;
    function getUserOpHash(UserOperation calldata userOp) external view returns (bytes32);
    function getNonce(address sender, uint192 key) external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
}

interface ICoinbaseWalletFactory {
    function createAccount(bytes[] calldata owners, uint256 nonce) external payable returns (address account);
    function getAddress(bytes[] calldata owners, uint256 nonce) external view returns (address);
    function implementation() external view returns (address);
}

interface ICoinbaseWallet {
    function execute(address target, uint256 value, bytes calldata data) external payable;
    function executeBatch(WalletCall[] calldata calls) external payable;
    function entryPoint() external view returns (address);
    function implementation() external view returns (address);
    function isOwnerAddress(address account) external view returns (bool);
    function ownerAtIndex(uint256 index) external view returns (bytes memory);
}

// Coinbase Smart Wallets of versions 1 and 1.1 built from the code deployed on OP Mainnet, with no fork. A wallet is
// a 61 byte proxy, so PageNFT treats it as a contract. It answers the ERC721 hook, so a page reaches it however it
// is minted or sent, and it takes ETH with all the gas it is sent. Its owner key runs it directly or through
// ERC4337 user operations of the real EntryPoint v0.6.
abstract contract CoinbaseWalletBase is Test {
    // the addresses of the github.com/coinbase/smart-wallet README, the same on OP Mainnet, Base and Ethereum
    address constant FACTORY = 0x0BA5ED0c6AA8c49038F819E587E2633c4A9F428a;
    address constant WALLET = 0x000100abaad02f1cfC8Bbe32bD5a564817339E72;
    address constant FACTORY11 = 0xBA5ED110eFDBa3D005bfC882d75358ACBbB85842;
    address constant WALLET11 = 0x00000110dCdEdC9581cb5eCB8467282f2926534d;
    address constant ENTRY_POINT = 0x5FF137D4b0FDCD49DcA30c7CF57E578a026d2789;
    // the EntryPoint makes new accounts through this contract, whose address is an immutable in its code
    address constant SENDER_CREATOR = 0x7fc98430eAEdbb6070B35B39D798725049088348;
    // keccak256 of the code at each address, as recorded in test/fixtures/cbsw/codehashes.txt
    bytes32 constant FACTORY_HASH = 0xc4900c000fd23885462a115b872741ad2b1e7ff2d7889aee18bc4d4bef3728f6;
    bytes32 constant WALLET_HASH = 0x179bcb847d3401ac830789a21cc37ed846fd5da9582a9c9d4b5140b6f26bd1a1;
    bytes32 constant FACTORY11_HASH = 0xb60a629aa7c6af9b550871fd21b67ab84638156683cec68491049cb5d235ed2f;
    bytes32 constant WALLET11_HASH = 0x136185896fc519277ec953c0b3d048fc0c9f607b8d04022e60f23ef8dbc6c4d5;
    bytes32 constant ENTRY_POINT_HASH = 0xc93c806e738300b5357ecdc2e971d6438d34d8e4e17b99b758b1f9cac91c8e70;
    bytes32 constant SENDER_CREATOR_HASH = 0xae818091eaaf1b6175ee41472359a689f3823d0908a41e2e5c4ad508f2fc04a3;
    // the code hash of the wallets on OP Mainnet, the proxy both factories make
    bytes32 constant PROXY_HASH = 0xaaa52c8cc8a0e3fd27ce756cc6b4e70c51423e9b597b11f32d3e49f8b1fc890d;
    // where an ERC1967 proxy keeps its implementation
    bytes32 constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 constant OP_EVENT = keccak256("UserOperationEvent(bytes32,address,address,uint256,bool,uint256,uint256)");
    // onERC721Received(address,address,uint256,bytes)
    bytes4 constant ON_RECEIVED = 0x150b7a02;
    uint256 constant COIN_OP = 0x8000000a;
    uint256 constant DEFAULT_EVM = 0x80000000;
    uint256 constant COIN_BASE = 0x80002105;
    // the base fee and priority fee of an OP Mainnet block on 4 November 2026, in wei
    uint256 constant BASE_FEE = 300;
    uint256 constant PRIORITY_FEE = 1_000_000;
    // covers the bundle's calldata and its share of the L1 data fee, which the EntryPoint only charges
    uint256 constant PRE_VERIFICATION_GAS = 60_000;
    // the upper end of an estimate, far above what any operation here needs
    uint256 constant GAS_CAP = 3_000_000;

    PageNFT nft;
    SubpageRegistrar reg;

    uint256 constant KEY = 0xc0ba5e;
    address owner = vm.addr(KEY);
    address payer = makeAddr("payer");
    address stranger = makeAddr("stranger");
    address buyer = makeAddr("buyer");
    address bundler = makeAddr("bundler");
    address friend = makeAddr("friend");

    function setUp() public virtual {
        vm.warp(1_800_000_000);
        vm.chainId(10);
        vm.fee(BASE_FEE);
        nft = new PageNFT(new PageCard());
        reg = new SubpageRegistrar(IPageNFT(address(nft)));
        _etchFixtures();
        vm.deal(payer, 10 ether);
        vm.deal(stranger, 10 ether);
        vm.deal(buyer, 1000 ether);
    }

    function _fixture(string memory name) internal view returns (bytes memory) {
        return vm.parseBytes(vm.readFile(string.concat("test/fixtures/cbsw/", name, ".hex")));
    }

    function _etchFixtures() internal {
        vm.etch(FACTORY, _fixture("factory"));
        vm.etch(WALLET, _fixture("wallet"));
        vm.etch(FACTORY11, _fixture("factory11"));
        vm.etch(WALLET11, _fixture("wallet11"));
        vm.etch(ENTRY_POINT, _fixture("entrypoint"));
        vm.etch(SENDER_CREATOR, _fixture("sendercreator"));
    }

    // version 1 for k = 0 and version 1.1 for k = 1
    function _factory(uint256 k) internal pure returns (address) {
        return k == 0 ? FACTORY : FACTORY11;
    }

    function _impl(uint256 k) internal pure returns (address) {
        return k == 0 ? WALLET : WALLET11;
    }

    // one owner, the address of the test key
    function _owners() internal view returns (bytes[] memory owners) {
        owners = new bytes[](1);
        owners[0] = abi.encode(owner);
    }

    // a wallet made through the factory, as the EntryPoint does with an operation's initCode
    function _wallet(uint256 k, uint256 salt) internal returns (address) {
        return ICoinbaseWalletFactory(_factory(k)).createAccount(_owners(), salt);
    }

    function _walletAddress(uint256 k, uint256 salt) internal view returns (address) {
        return ICoinbaseWalletFactory(_factory(k)).getAddress(_owners(), salt);
    }

    function _initCode(uint256 k, uint256 salt) internal view returns (bytes memory) {
        return abi.encodePacked(_factory(k), abi.encodeCall(ICoinbaseWalletFactory.createAccount, (_owners(), salt)));
    }

    // the owner key sends the wallet one call, which the wallet makes
    function _execute(address wallet, address to, uint256 value, bytes memory data) internal {
        vm.prank(owner);
        ICoinbaseWallet(wallet).execute(to, value, data);
    }

    function _secret(string memory label, address to) internal pure returns (bytes32) {
        return keccak256(abi.encode(label, to));
    }

    function _commit(string memory label, address to) internal returns (bytes32 c) {
        c = nft.makeCommitment(label, to, 0, _secret(label, to));
        vm.prank(payer);
        nft.commit(c);
    }

    // payer commits, then from reveals and pays a year of label for to
    function _reveal(address from, address to, string memory label) internal returns (uint256 id) {
        _commit(label, to);
        vm.warp(vm.getBlockTimestamp() + 61);
        (,,, uint256 total) = nft.quote(label);
        vm.prank(from);
        id = nft.reveal{value: total}(label, to, 0, _secret(label, to));
    }

    // a bundle is a transaction of its own, so every account and slot it touches starts cold
    function _cool(address sender) internal {
        vm.cool(address(nft));
        vm.cool(address(reg));
        vm.cool(sender);
        vm.cool(WALLET);
        vm.cool(WALLET11);
        vm.cool(FACTORY);
        vm.cool(FACTORY11);
        vm.cool(ENTRY_POINT);
        vm.cool(SENDER_CREATOR);
    }

    // an operation of sender with its next nonce, signed by the owner key over the EntryPoint's hash
    function _op(address sender, bytes memory initCode, bytes memory callData, uint256 callGas, uint256 verificationGas)
        internal
        view
        returns (UserOperation memory op)
    {
        op = UserOperation({
            sender: sender,
            nonce: IEntryPoint06(ENTRY_POINT).getNonce(sender, 0),
            initCode: initCode,
            callData: callData,
            callGasLimit: callGas,
            verificationGasLimit: verificationGas,
            preVerificationGas: PRE_VERIFICATION_GAS,
            maxFeePerGas: 2 * BASE_FEE + PRIORITY_FEE,
            maxPriorityFeePerGas: PRIORITY_FEE,
            paymasterAndData: "",
            signature: ""
        });
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(KEY, IEntryPoint06(ENTRY_POINT).getUserOpHash(op));
        op.signature = abi.encode(SignatureWrapper(0, abi.encodePacked(r, s, v)));
    }

    // a bundler sends the operation alone. handled is whether handleOps went through, and success whether the
    // operation's calls did, as its UserOperationEvent says. gasCost is what the wallet paid the bundler.
    function _send(UserOperation memory op) internal returns (bool handled, bool success, uint256 gasCost) {
        UserOperation[] memory ops = new UserOperation[](1);
        ops[0] = op;
        _cool(op.sender);
        vm.recordLogs();
        vm.prank(bundler, bundler);
        (handled,) = ENTRY_POINT.call(abi.encodeCall(IEntryPoint06.handleOps, (ops, payable(bundler))));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == ENTRY_POINT && logs[i].topics[0] == OP_EVENT) {
                (, success, gasCost,) = abi.decode(logs[i].data, (uint256, bool, uint256, uint256));
            }
        }
        success = handled && success;
    }

    // the smallest callGasLimit with which the operation's calls go through, as a bundler's estimate finds it
    function _callGasEstimate(address sender, bytes memory initCode, bytes memory callData)
        internal
        returns (uint256 hi)
    {
        uint256 lo;
        hi = GAS_CAP;
        while (lo + 1 < hi) {
            uint256 mid = (lo + hi) / 2;
            uint256 snap = vm.snapshotState();
            (, bool ok,) = _send(_op(sender, initCode, callData, mid, GAS_CAP));
            vm.revertToState(snap);
            if (ok) hi = mid;
            else lo = mid;
        }
    }

    // the smallest verificationGasLimit with which handleOps takes the operation
    function _verificationGasEstimate(address sender, bytes memory initCode, bytes memory callData, uint256 callGas)
        internal
        returns (uint256 hi)
    {
        uint256 lo;
        hi = GAS_CAP;
        while (lo + 1 < hi) {
            uint256 mid = (lo + hi) / 2;
            uint256 snap = vm.snapshotState();
            (bool ok,,) = _send(_op(sender, initCode, callData, callGas, mid));
            vm.revertToState(snap);
            if (ok) hi = mid;
            else lo = mid;
        }
    }

    // 125 percent of an estimate, rounded up, as the website sends (GAS_HEADROOM_PERCENT in src/lib/context.ts)
    function _headroom(uint256 estimate) internal pure returns (uint256) {
        return (estimate * 125 + 99) / 100;
    }

    // the operation with both limits estimated and given the headroom
    function _estimated(address sender, bytes memory initCode, bytes memory callData)
        internal
        returns (UserOperation memory)
    {
        uint256 callGas = _headroom(_callGasEstimate(sender, initCode, callData));
        uint256 verificationGas = _headroom(_verificationGasEstimate(sender, initCode, callData, callGas));
        emit log_named_uint("callGasLimit", callGas);
        emit log_named_uint("verificationGasLimit", verificationGas);
        return _op(sender, initCode, callData, callGas, verificationGas);
    }
}

// The owner key calls the wallet directly, which the wallet allows any address owner to do.
contract RealCoinbaseWalletTest is CoinbaseWalletBase {
    function test_walletFixturesAreTheCanonicalCode() public {
        assertEq(keccak256(_fixture("factory")), FACTORY_HASH, "factory file");
        assertEq(keccak256(_fixture("wallet")), WALLET_HASH, "wallet file");
        assertEq(keccak256(_fixture("factory11")), FACTORY11_HASH, "factory 1.1 file");
        assertEq(keccak256(_fixture("wallet11")), WALLET11_HASH, "wallet 1.1 file");
        assertEq(keccak256(_fixture("entrypoint")), ENTRY_POINT_HASH, "EntryPoint file");
        assertEq(keccak256(_fixture("sendercreator")), SENDER_CREATOR_HASH, "SenderCreator file");
        assertEq(FACTORY.codehash, FACTORY_HASH, "factory code");
        assertEq(WALLET.codehash, WALLET_HASH, "wallet code");
        assertEq(FACTORY11.codehash, FACTORY11_HASH, "factory 1.1 code");
        assertEq(WALLET11.codehash, WALLET11_HASH, "wallet 1.1 code");
        assertEq(ENTRY_POINT.codehash, ENTRY_POINT_HASH, "EntryPoint code");
        assertEq(SENDER_CREATOR.codehash, SENDER_CREATOR_HASH, "SenderCreator code");

        for (uint256 k; k < 2; ++k) {
            assertEq(ICoinbaseWalletFactory(_factory(k)).implementation(), _impl(k), "each factory has its version");
            address predicted = _walletAddress(k, 0);
            address wallet = _wallet(k, 0);
            assertEq(wallet, predicted, "the address the factory gives before the wallet exists");
            // the same proxy as the wallets on OP Mainnet, 61 bytes, so PageNFT never takes it for a key wallet
            assertEq(wallet.codehash, PROXY_HASH, "wallet proxy");
            assertEq(wallet.code.length, 61);
            assertEq(vm.load(wallet, IMPL_SLOT), bytes32(uint256(uint160(_impl(k)))));
            assertEq(ICoinbaseWallet(wallet).implementation(), _impl(k));
            assertEq(ICoinbaseWallet(wallet).entryPoint(), ENTRY_POINT);
            assertTrue(ICoinbaseWallet(wallet).isOwnerAddress(owner));
            assertEq(ICoinbaseWallet(wallet).ownerAtIndex(0), abi.encode(owner));
        }
    }

    // the owner key has the wallet commit and reveal for itself. PageNFT sees the wallet as the caller, so it mints
    // with no ERC721 hook, and the wallet gets back what it sent above the price.
    function test_walletRegistersForItself() public {
        string[2] memory labels = ["wallet", "walletone"];
        for (uint256 k; k < 2; ++k) {
            address wallet = _wallet(k, 1);
            vm.deal(wallet, 1 ether);
            string memory label = labels[k];
            bytes32 secret = _secret(label, wallet);
            bytes32 c = nft.makeCommitment(label, wallet, 0, secret);
            _execute(wallet, address(nft), 0, abi.encodeCall(PageNFT.commit, (c)));
            assertEq(nft.commitments(c), vm.getBlockTimestamp(), "the wallet committed");
            vm.warp(vm.getBlockTimestamp() + 61);
            (,,, uint256 total) = nft.quote(label);
            vm.expectCall(wallet, abi.encodeWithSelector(ON_RECEIVED), 0);
            bytes memory reveal = abi.encodeCall(PageNFT.reveal, (label, wallet, 0, secret));
            _execute(wallet, address(nft), total + 0.5 ether, reveal);
            uint256 id = nft.computeId(label);
            assertEq(nft.ownerOf(id), wallet);
            assertEq(wallet.balance, 1 ether - total, "the wallet paid the price and got the rest back");
            assertEq(nft.commitments(c), 0, "the commitment is used");
            assertEq(nft.depositOf(id), total);
        }
    }

    // pages another account pays for reach the wallet through its ERC721 hook, as do a subpage minted to it and a
    // page sent to it with safeTransferFrom. Anyone renews, and the wallet writes the records.
    function test_walletHoldsPagesOthersPayFor() public {
        string[2] memory labels = ["gift", "giftone"];
        string[2] memory members = ["ann", "ben"];
        string[2] memory sent = ["sent", "sentone"];
        uint256 team = _reveal(payer, payer, "team");
        for (uint256 k; k < 2; ++k) {
            address wallet = _wallet(k, 2);
            uint256 id = _giftedAndRenewed(wallet, labels[k]);
            _subpageAndSentPage(wallet, team, members[k], sent[k]);
            _walletWritesARecord(wallet, id);
        }
    }

    // a payer that is not the wallet commits and reveals for it, and the mint asks the wallet; then a third account
    // renews it. Kept apart from the test so forge coverage --ir-minimum can compile it.
    function _giftedAndRenewed(address wallet, string memory label) internal returns (uint256 id) {
        _commit(label, wallet);
        vm.warp(vm.getBlockTimestamp() + 61);
        (,,, uint256 total) = nft.quote(label);
        id = nft.computeId(label);
        bytes32 secret = _secret(label, wallet);
        uint256 before = payer.balance;
        vm.expectCall(wallet, abi.encodeWithSelector(ON_RECEIVED, payer, address(0), id, bytes("")), 1);
        vm.prank(payer);
        nft.reveal{value: total}(label, wallet, 0, secret);
        assertEq(nft.ownerOf(id), wallet);
        assertEq(before - payer.balance, total, "the payer paid exactly the price");

        // a third account renews it
        uint256 expiry = nft.expiresAt(id);
        uint256 fee = nft.getFee(bytes(label).length);
        vm.prank(stranger);
        nft.renew{value: fee}(id);
        assertEq(nft.expiresAt(id), expiry + 365 days);
    }

    // the holder of another page mints a subpage of it to the wallet, and a key wallet sends one of its pages with
    // safeTransferFrom. Kept apart from the test so forge coverage --ir-minimum can compile it.
    function _subpageAndSentPage(address wallet, uint256 team, string memory member, string memory sentLabel) internal {
        uint256 sub = nft.computeId(string.concat(member, ".team"));
        vm.expectCall(wallet, abi.encodeWithSelector(ON_RECEIVED, payer, address(0), sub, bytes("")), 1);
        vm.prank(payer);
        nft.registerSubpageFor(member, team, wallet);
        assertEq(nft.ownerOf(sub), wallet);

        // a key wallet sends one of its pages with safeTransferFrom
        uint256 other = _reveal(payer, payer, sentLabel);
        vm.expectCall(wallet, abi.encodeWithSelector(ON_RECEIVED, payer, payer, other, bytes("")), 1);
        vm.prank(payer);
        nft.safeTransferFrom(payer, wallet, other);
        assertEq(nft.ownerOf(other), wallet);
        assertEq(nft.balanceOf(wallet), 3);
    }

    // the wallet writes a record through its owner key. Kept apart from the test so forge coverage --ir-minimum can
    // compile it.
    function _walletWritesARecord(address wallet, uint256 id) internal {
        _execute(wallet, address(nft), 0, abi.encodeCall(PageNFT.setText, (id, "url", "https://example.org")));
        assertEq(nft.text(bytes32(id), "url"), "https://example.org");
        // the wallet is the main address and answers on OP, and with nothing saved there is no address for other
        // chains
        assertEq(nft.resolve(id), wallet);
        assertEq(nft.addr(bytes32(id), COIN_OP), abi.encodePacked(wallet));
        assertEq(nft.addr(bytes32(id), 60).length, 0);
        assertEq(nft.addr(bytes32(id)), address(0));
    }

    // one executeBatch writes the profile and the address for every EVM chain and sets the display page. One
    // PageNFT.multicall sent with execute does the same for a second page. A call that fails undoes its batch.
    function test_walletWritesRecordsInOneBatch() public {
        string[2] memory labels = ["batch", "batchone"];
        string[2] memory more = ["multi", "multione"];
        uint256 notMine = _reveal(payer, stranger, "notmine");
        for (uint256 k; k < 2; ++k) {
            address wallet = _wallet(k, 3);
            uint256 id = _reveal(payer, wallet, labels[k]);

            // the factory gives the wallet the same address on every chain, so it saves itself for all of them
            WalletCall[] memory calls = new WalletCall[](5);
            calls[0] = WalletCall(address(nft), 0, abi.encodeCall(PageNFT.setText, (id, "url", "https://example.org")));
            calls[1] = WalletCall(address(nft), 0, abi.encodeCall(PageNFT.setText, (id, "description", "hello")));
            calls[2] = WalletCall(address(nft), 0, abi.encodeCall(PageNFT.setContenthash, (id, hex"e301")));
            calls[3] = WalletCall(
                address(nft), 0, abi.encodeCall(PageNFT.setAddrForCoin, (id, DEFAULT_EVM, abi.encodePacked(wallet)))
            );
            calls[4] = WalletCall(address(nft), 0, abi.encodeCall(PageNFT.setPrimaryPage, (id)));
            vm.prank(owner);
            ICoinbaseWallet(wallet).executeBatch(calls);
            assertEq(nft.text(bytes32(id), "url"), "https://example.org");
            assertEq(nft.text(bytes32(id), "description"), "hello");
            assertEq(nft.contenthash(bytes32(id)), hex"e301");
            assertEq(nft.addr(bytes32(id)), wallet, "coin type 60 answers the default");
            assertEq(nft.addr(bytes32(id), COIN_BASE), abi.encodePacked(wallet), "so does Base");
            assertEq(nft.addr(bytes32(id), COIN_OP), abi.encodePacked(wallet));
            assertEq(nft.reverseResolve(wallet), labels[k]);

            // a second page, written in one multicall, becomes the display page
            uint256 id2 = _reveal(payer, wallet, more[k]);
            bytes[] memory writes = new bytes[](3);
            writes[0] = abi.encodeCall(PageNFT.setText, (id2, "url", "https://example.com"));
            writes[1] = abi.encodeCall(PageNFT.setAddrForCoin, (id2, DEFAULT_EVM, abi.encodePacked(wallet)));
            writes[2] = abi.encodeCall(PageNFT.setPrimaryPage, (id2));
            _execute(wallet, address(nft), 0, abi.encodeCall(PageNFT.multicall, (writes)));
            assertEq(nft.text(bytes32(id2), "url"), "https://example.com");
            assertEq(nft.addr(bytes32(id2)), wallet);
            assertEq(nft.reverseResolve(wallet), more[k]);

            // a write to a page the wallet does not hold fails, and the write before it in the batch is undone
            WalletCall[] memory bad = new WalletCall[](2);
            bad[0] = WalletCall(address(nft), 0, abi.encodeCall(PageNFT.setText, (id, "url", "https://changed.org")));
            bad[1] = WalletCall(address(nft), 0, abi.encodeCall(PageNFT.setText, (notMine, "url", "https://x.org")));
            vm.prank(owner);
            vm.expectRevert(PageNFT.Unauthorized.selector);
            ICoinbaseWallet(wallet).executeBatch(bad);
            assertEq(nft.text(bytes32(id), "url"), "https://example.org");
        }
    }

    // in a sale PageNFT sees the registrar as the caller, so the mint asks the wallet, which answers. The wallet
    // gets back what it sent above the price.
    function test_walletBuysASubpage() public {
        address seller = makeAddr("seller");
        uint256 parent = _reveal(payer, seller, "market");
        vm.startPrank(seller);
        nft.setSubpageMinter(parent, address(reg));
        reg.configure(parent, address(0), address(0), 0.001 ether, true, address(0), 0, false);
        vm.stopPrank();
        string[2] memory labels = ["alice", "bob"];
        for (uint256 k; k < 2; ++k) {
            address wallet = _wallet(k, 7);
            vm.deal(wallet, 1 ether);
            uint256 sub = nft.computeId(string.concat(labels[k], ".market"));
            bytes memory buy =
                abi.encodeCall(SubpageRegistrar.registerSubpage, (parent, labels[k], 0.001 ether, address(0)));
            vm.expectCall(wallet, abi.encodeWithSelector(ON_RECEIVED, address(reg), address(0), sub, bytes("")), 1);
            _execute(wallet, address(reg), 0.003 ether, buy);
            assertEq(nft.ownerOf(sub), wallet);
            assertEq(wallet.balance, 1 ether - 0.001 ether, "the wallet paid the price");
            assertEq(reg.proceedsOf(seller), (k + 1) * 0.001 ether);
        }
    }

    // withdraw and claimProceedsFor send all their gas, so they pay a wallet from cold. A send with only the 2,300
    // gas stipend, as transfer and send give, does not reach the wallet's code from cold.
    function test_withdrawAndClaimPayARealWallet() public {
        string[2] memory lapsed = ["lapsed", "lapsedone"];
        string[2] memory shops = ["shop", "shopone"];
        vm.deal(address(this), 1 ether);
        for (uint256 k; k < 2; ++k) {
            address wallet = _wallet(k, 8);

            // the proxy reads its implementation and calls it, and from cold that costs more than the stipend
            vm.cool(wallet);
            vm.cool(_impl(k));
            assertFalse(payable(wallet).send(1), "a 2,300 gas stipend is not enough from cold");

            // the wallet's page lapses and is bought at auction, which credits the wallet its deposit and a share of
            // the premium
            uint256 id = _reveal(payer, wallet, lapsed[k]);
            vm.warp(nft.expiresAt(id) + 90 days + 7 days);
            _commit(lapsed[k], buyer);
            vm.warp(vm.getBlockTimestamp() + 61);
            (, uint256 carried, uint256 premium, uint256 total) = nft.quote(lapsed[k]);
            assertGt(carried, 0);
            assertGt(premium, 0);
            bytes32 secret = _secret(lapsed[k], buyer);
            vm.prank(buyer);
            nft.reveal{value: total}(lapsed[k], buyer, 0, secret);
            uint256 owed = nft.owed(wallet);
            assertGt(owed, carried);

            // a third account withdraws for the wallet, from cold
            uint256 before = wallet.balance;
            vm.cool(wallet);
            vm.cool(_impl(k));
            vm.prank(stranger);
            assertEq(nft.withdraw(wallet), owed);
            assertEq(wallet.balance, before + owed, "withdraw paid the wallet");
            assertEq(nft.owed(wallet), 0);

            // the wallet sells subpages of another page through the registrar, set up in one batch
            uint256 parent = _reveal(payer, wallet, shops[k]);
            WalletCall[] memory calls = new WalletCall[](2);
            calls[0] = WalletCall(address(nft), 0, abi.encodeCall(PageNFT.setSubpageMinter, (parent, address(reg))));
            bytes memory terms = abi.encodeCall(
                SubpageRegistrar.configure, (parent, address(0), address(0), 0.002 ether, true, address(0), 0, false)
            );
            calls[1] = WalletCall(address(reg), 0, terms);
            vm.prank(owner);
            ICoinbaseWallet(wallet).executeBatch(calls);
            (,,,,,,, address payout,) = reg.config(parent);
            assertEq(payout, wallet);
            vm.prank(buyer);
            reg.registerSubpage{value: 0.002 ether}(parent, "alice", 0.002 ether, address(0));
            vm.prank(buyer);
            reg.registerSubpage{value: 0.002 ether}(parent, "bob", 0.002 ether, address(0));
            assertEq(reg.proceedsOf(wallet), 0.004 ether);

            // a third account claims for the wallet, again from cold
            before = wallet.balance;
            vm.cool(wallet);
            vm.cool(_impl(k));
            vm.prank(stranger);
            assertEq(reg.claimProceedsFor(wallet), 0.004 ether);
            assertEq(wallet.balance, before + 0.004 ether, "claimProceedsFor paid the wallet");
            assertEq(reg.proceedsOf(wallet), 0);
        }
    }
}

// The site's flow as user operations through the real EntryPoint, signed by the owner key, with the limits a
// bundler's estimate gives plus 25 percent. A test runs as one transaction, and a slot written earlier in it costs
// less to write again, so each operation here builds on state made in setUp, as a later block would see it.
contract RealCoinbaseWalletOpsTest is CoinbaseWalletBase {
    address[2] fresh;
    address[2] early;
    uint256[2] earlyIds;

    function _labels() internal pure returns (string[2] memory) {
        return ["fouruser", "fouruserone"];
    }

    function _earlyLabels() internal pure returns (string[2] memory) {
        return ["early", "earlyone"];
    }

    // the first operation of each version makes the wallet at the address the user funded, and commits
    function setUp() public override {
        super.setUp();
        for (uint256 k; k < 2; ++k) {
            address wallet = _walletAddress(k, 4);
            fresh[k] = wallet;
            assertEq(wallet.code.length, 0, "the wallet does not exist yet");
            vm.deal(wallet, 1 ether);
            string memory label = _labels()[k];
            bytes32 c = nft.makeCommitment(label, wallet, 0, _secret(label, wallet));
            WalletCall[] memory calls = new WalletCall[](1);
            calls[0] = WalletCall(address(nft), 0, abi.encodeCall(PageNFT.commit, (c)));
            UserOperation memory op =
                _estimated(wallet, _initCode(k, 4), abi.encodeCall(ICoinbaseWallet.executeBatch, (calls)));
            (bool handled, bool success,) = _send(op);
            assertTrue(handled && success, "the first operation");

            // a payer registers a page for the address of a wallet that is not made yet
            early[k] = _walletAddress(k, 5);
            earlyIds[k] = _reveal(payer, early[k], _earlyLabels()[k]);
        }
        // an etched account that vm.cool marks in setUp, and that nothing writes to after, starts the tests with no
        // code, so the fixtures are put back
        _etchFixtures();
    }

    function test_firstOperationMadeTheWalletAndCommitted() public view {
        for (uint256 k; k < 2; ++k) {
            address wallet = fresh[k];
            assertEq(wallet.codehash, PROXY_HASH, "the EntryPoint made the wallet");
            assertEq(vm.load(wallet, IMPL_SLOT), bytes32(uint256(uint160(_impl(k)))));
            assertTrue(ICoinbaseWallet(wallet).isOwnerAddress(owner));
            string memory label = _labels()[k];
            assertGt(nft.commitments(nft.makeCommitment(label, wallet, 0, _secret(label, wallet))), 0, "committed");
            assertEq(IEntryPoint06(ENTRY_POINT).getNonce(wallet, 0), 1);
            // the plain mint to an address with no code
            assertEq(nft.ownerOf(earlyIds[k]), early[k]);
            assertEq(early[k].code.length, 0);
        }
    }

    // a minute later the second operation pays a little more than the price and gets the rest back, writes the
    // profile and the address for every EVM chain in one multicall, and sets the display page
    function _secondOperation(uint256 k) internal {
        address wallet = fresh[k];
        string memory label = _labels()[k];
        bytes32 secret = _secret(label, wallet);
        vm.warp(vm.getBlockTimestamp() + 61);
        (,,, uint256 total) = nft.quote(label);
        uint256 id = nft.computeId(label);
        bytes[] memory writes = new bytes[](4);
        writes[0] = abi.encodeCall(PageNFT.setText, (id, "url", "https://example.org"));
        writes[1] = abi.encodeCall(PageNFT.setText, (id, "description", "hello"));
        writes[2] = abi.encodeCall(PageNFT.setAddrForCoin, (id, DEFAULT_EVM, abi.encodePacked(wallet)));
        writes[3] = abi.encodeCall(PageNFT.setPrimaryPage, (id));
        WalletCall[] memory calls = new WalletCall[](2);
        calls[0] =
            WalletCall(address(nft), total + 0.001 ether, abi.encodeCall(PageNFT.reveal, (label, wallet, 0, secret)));
        calls[1] = WalletCall(address(nft), 0, abi.encodeCall(PageNFT.multicall, (writes)));
        UserOperation memory op = _estimated(wallet, "", abi.encodeCall(ICoinbaseWallet.executeBatch, (calls)));

        uint256 held = wallet.balance + IEntryPoint06(ENTRY_POINT).balanceOf(wallet);
        uint256 bundlerBefore = bundler.balance;
        (bool handled, bool success, uint256 gasCost) = _send(op);
        assertTrue(handled && success, "the second operation");
        assertEq(nft.ownerOf(id), wallet);
        assertEq(nft.text(bytes32(id), "url"), "https://example.org");
        assertEq(nft.addr(bytes32(id)), wallet);
        assertEq(nft.reverseResolve(wallet), label);
        // the wallet paid the price and the gas, from its balance and its deposit at the EntryPoint, and the bundler
        // got the gas
        assertGt(gasCost, 0);
        assertEq(held - wallet.balance - IEntryPoint06(ENTRY_POINT).balanceOf(wallet), total + gasCost);
        assertEq(bundler.balance - bundlerBefore, gasCost);
        assertEq(IEntryPoint06(ENTRY_POINT).getNonce(wallet, 0), 2);
    }

    function test_secondOperationPaysAndWritesV1() public {
        _secondOperation(0);
    }

    function test_secondOperationPaysAndWritesV11() public {
        _secondOperation(1);
    }

    // the first operation of the wallet that holds a page from before it existed makes it there, and writes the
    // page's records and display page
    function _firstOperationOfAHolder(uint256 k) internal {
        address wallet = early[k];
        uint256 id = earlyIds[k];
        vm.deal(wallet, 0.01 ether);
        bytes[] memory writes = new bytes[](2);
        writes[0] = abi.encodeCall(PageNFT.setText, (id, "url", "https://example.org"));
        writes[1] = abi.encodeCall(PageNFT.setPrimaryPage, (id));
        WalletCall[] memory calls = new WalletCall[](1);
        calls[0] = WalletCall(address(nft), 0, abi.encodeCall(PageNFT.multicall, (writes)));
        UserOperation memory op =
            _estimated(wallet, _initCode(k, 5), abi.encodeCall(ICoinbaseWallet.executeBatch, (calls)));
        (bool handled, bool success,) = _send(op);
        assertTrue(handled && success);
        assertEq(wallet.codehash, PROXY_HASH);
        assertEq(nft.ownerOf(id), wallet);
        assertEq(nft.text(bytes32(id), "url"), "https://example.org");
        assertEq(nft.reverseResolve(wallet), _earlyLabels()[k]);
    }

    function test_pageForAWalletNotMadeYetV1() public {
        _firstOperationOfAHolder(0);
    }

    function test_pageForAWalletNotMadeYetV11() public {
        _firstOperationOfAHolder(1);
    }
}

// A transfer stores the block time in holderSince. Estimated in the second of the mint, it stores the same time again
// and costs less. Sent a block later with that estimate as its callGasLimit, its call runs out of gas inside the
// operation: handleOps goes through, the wallet pays the gas and keeps the page. With the 25 percent the website adds,
// it moves the page. The mint is made in setUp, so the test sees it as an earlier transaction.
contract RealCoinbaseWalletEstimateTest is CoinbaseWalletBase {
    address[2] wallets;
    uint256[2] ids;
    uint256 mintedAt;

    function setUp() public override {
        super.setUp();
        string[2] memory labels = ["moving", "movingone"];
        for (uint256 k; k < 2; ++k) {
            address wallet = _wallet(k, 6);
            wallets[k] = wallet;
            vm.deal(wallet, 1 ether);
            bytes32 c = nft.makeCommitment(labels[k], wallet, 0, _secret(labels[k], wallet));
            _execute(wallet, address(nft), 0, abi.encodeCall(PageNFT.commit, (c)));
        }
        vm.warp(vm.getBlockTimestamp() + 61);
        for (uint256 k; k < 2; ++k) {
            address wallet = wallets[k];
            (,,, uint256 total) = nft.quote(labels[k]);
            bytes memory reveal = abi.encodeCall(PageNFT.reveal, (labels[k], wallet, 0, _secret(labels[k], wallet)));
            _execute(wallet, address(nft), total, reveal);
            ids[k] = nft.computeId(labels[k]);
        }
        mintedAt = vm.getBlockTimestamp();
    }

    function _sameSecond(uint256 k) internal {
        address wallet = wallets[k];
        uint256 id = ids[k];
        assertEq(nft.holderSince(id), mintedAt);
        bytes memory send = abi.encodeCall(
            ICoinbaseWallet.execute, (address(nft), 0, abi.encodeCall(nft.transferFrom, (wallet, friend, id)))
        );
        uint256 sameSecond = _callGasEstimate(wallet, "", send);
        vm.warp(mintedAt + 2);
        uint256 later = _callGasEstimate(wallet, "", send);
        emit log_named_uint("callGasLimit estimate in the mint's second", sameSecond);
        emit log_named_uint("callGasLimit estimate 2 seconds later", later);
        emit log_named_uint("shortfall", later - sameSecond);
        // Under the deploy settings the shortfall is 2,889 gas, the figure README.md gives for an account
        // behind a proxy. It goes through the 63/64 rule of each call, so another build (the optimizer off, the
        // coverage build) or code that costs a few gas more or less gives a gas or two more or less, and the test
        // checks what it means instead: the estimate is short a block later, and by less than the 25 percent headroom
        assertGt(later, sameSecond, "the estimate made in the mint's second is short a block later");
        assertLt(later - sameSecond, sameSecond / 4, "the shortfall is less than the 25 percent headroom");
        uint256 verificationGas = _headroom(_verificationGasEstimate(wallet, "", send, later));

        uint256 held = wallet.balance + IEntryPoint06(ENTRY_POINT).balanceOf(wallet);
        uint256 bundlerBefore = bundler.balance;
        (bool handled, bool success, uint256 gasCost) = _send(_op(wallet, "", send, sameSecond, verificationGas));
        assertTrue(handled, "handleOps goes through");
        assertFalse(success, "the estimate sent as it is fails a block later");
        // the wallet paid the gas of the failed operation, from its balance and its deposit at the EntryPoint, and
        // keeps the page
        assertGt(gasCost, 0);
        assertEq(
            held - wallet.balance - IEntryPoint06(ENTRY_POINT).balanceOf(wallet), gasCost, "the wallet paid the gas"
        );
        assertEq(bundler.balance - bundlerBefore, gasCost);
        assertEq(nft.ownerOf(id), wallet);
        assertEq(nft.holderSince(id), mintedAt);
        assertEq(IEntryPoint06(ENTRY_POINT).getNonce(wallet, 0), 1, "the failed operation used its nonce");

        (handled, success,) = _send(_op(wallet, "", send, _headroom(sameSecond), verificationGas));
        assertTrue(handled && success, "125 percent of the estimate is enough");
        assertEq(nft.ownerOf(id), friend);
        assertEq(nft.holderSince(id), mintedAt + 2);
    }

    function test_aSameSecondEstimateNeedsTheHeadroomV1() public {
        _sameSecond(0);
    }

    function test_aSameSecondEstimateNeedsTheHeadroomV11() public {
        _sameSecond(1);
    }
}

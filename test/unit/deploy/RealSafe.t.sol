// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {PageNFT} from "../../../src/PageNFT.sol";
import {PageCard} from "../../../src/PageCard.sol";
import {SubpageRegistrar, IPageNFT} from "../../../src/SubpageRegistrar.sol";

interface ISafeProxyFactory141 {
    function createProxyWithNonce(address singleton, bytes memory initializer, uint256 saltNonce)
        external
        returns (address proxy);
}

interface ISafe141 {
    function setup(
        address[] calldata owners,
        uint256 threshold,
        address to,
        bytes calldata data,
        address fallbackHandler,
        address paymentToken,
        uint256 payment,
        address payable paymentReceiver
    ) external;

    function execTransaction(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address payable refundReceiver,
        bytes memory signatures
    ) external payable returns (bool);

    function getTransactionHash(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address refundReceiver,
        uint256 nonce
    ) external view returns (bytes32);

    function nonce() external view returns (uint256);
    function VERSION() external view returns (string memory);
    function getThreshold() external view returns (uint256);
}

// Safe 1.4.1 wallets built from the code deployed on OP Mainnet and Ethereum, with no fork. Another account's mint
// to a Safe needs the Safe's fallback handler; a Safe that registers for itself gets a plain mint and needs none.
// withdraw and claimProceedsFor pay a Safe like any account.
contract RealSafeTest is Test {
    // the canonical Safe 1.4.1 addresses, the same on OP Mainnet and Ethereum
    address constant SINGLETON = 0x41675C099F32341bf84BFc5382aF534df5C7461a;
    address constant SINGLETON_L2 = 0x29fcB43b46531BcA003ddC8FCB67FFE91900C762;
    address constant FACTORY = 0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67;
    address constant HANDLER = 0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99;
    // keccak256 of the code at each address on both chains, as recorded in test/fixtures/safe141/codehashes.txt
    bytes32 constant SINGLETON_HASH = 0x1fe2df852ba3299d6534ef416eefa406e56ced995bca886ab7a553e6d0c5e1c4;
    bytes32 constant SINGLETON_L2_HASH = 0xb1f926978a0f44a2c0ec8fe822418ae969bd8c3f18d61e5103100339894f81ff;
    bytes32 constant FACTORY_HASH = 0x50c3cdc4074750a7a974204a716c999edd37482f907608d960b2b025ee0b3317;
    bytes32 constant HANDLER_HASH = 0x7c6007a5d711cea8dfd5d91f5940ec29c7f200fe511eb1fc1397b367af3c42f9;
    // where a Safe keeps its fallback handler, keccak256("fallback_manager.handler.address")
    bytes32 constant HANDLER_SLOT = 0x6c9a6c4a39284e37ed1cf53d337577d14212a4870fb976a4366c693b939918d5;
    // solady TransferToNonERC721ReceiverImplementer()
    bytes4 constant NOT_RECEIVER = 0xd1a57ed6;
    uint256 constant COIN_OP = 0x8000000a;

    // emitted by a Safe when it receives ETH
    event SafeReceived(address indexed sender, uint256 value);

    PageNFT nft;
    SubpageRegistrar reg;

    uint256 constant KEY1 = 0x5afe01;
    uint256 constant KEY2 = 0x5afe02;
    address signer1 = vm.addr(KEY1);
    address signer2 = vm.addr(KEY2);
    address payer = makeAddr("payer");
    address stranger = makeAddr("stranger");
    address buyer = makeAddr("buyer");
    address relayer = makeAddr("relayer");

    function setUp() public {
        vm.warp(1_800_000_000);
        nft = new PageNFT(new PageCard());
        reg = new SubpageRegistrar(IPageNFT(address(nft)));
        vm.etch(SINGLETON, _fixture("singleton"));
        vm.etch(SINGLETON_L2, _fixture("singletonL2"));
        vm.etch(FACTORY, _fixture("factory"));
        vm.etch(HANDLER, _fixture("fallback"));
        vm.deal(payer, 10 ether);
        vm.deal(stranger, 10 ether);
        vm.deal(buyer, 1000 ether);
    }

    function _fixture(string memory name) internal view returns (bytes memory) {
        return vm.parseBytes(vm.readFile(string.concat("test/fixtures/safe141/", name, ".hex")));
    }

    // one label of each fee tier, of two, four and eight characters
    function _tiers() internal pure returns (string[3] memory) {
        return ["hq", "fund", "treasury"];
    }

    function _secret(string memory label, address to) internal pure returns (bytes32) {
        return keccak256(abi.encode(label, to));
    }

    // a Safe with two signers and a threshold of two, made through the factory like the Safe app does
    function _safe(address singleton, address handler, uint256 salt) internal returns (address safe) {
        address[] memory owners = new address[](2);
        owners[0] = signer1;
        owners[1] = signer2;
        bytes memory init = abi.encodeCall(
            ISafe141.setup, (owners, 2, address(0), "", handler, address(0), 0, payable(address(0)))
        );
        safe = ISafeProxyFactory141(FACTORY).createProxyWithNonce(singleton, init, salt);
    }

    // both signatures over the Safe transaction, ordered by signer as the Safe requires
    function _signatures(address safe, address to, uint256 value, bytes memory data)
        internal
        view
        returns (bytes memory)
    {
        uint256 nonce = ISafe141(safe).nonce();
        bytes32 h = ISafe141(safe).getTransactionHash(to, value, data, 0, 0, 0, 0, address(0), address(0), nonce);
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(KEY1, h);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(KEY2, h);
        bytes memory a = abi.encodePacked(r1, s1, v1);
        bytes memory b = abi.encodePacked(r2, s2, v2);
        return signer1 < signer2 ? bytes.concat(a, b) : bytes.concat(b, a);
    }

    // the Safe makes one call, signed by both signers and sent by a relayer
    function _exec(address safe, address to, uint256 value, bytes memory data) internal returns (bool) {
        bytes memory sigs = _signatures(safe, to, value, data);
        vm.prank(relayer);
        return ISafe141(safe).execTransaction(to, value, data, 0, 0, 0, 0, address(0), payable(address(0)), sigs);
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

    function test_safeFixturesAreTheCanonicalCode() public view {
        assertEq(keccak256(_fixture("singleton")), SINGLETON_HASH, "singleton file");
        assertEq(keccak256(_fixture("singletonL2")), SINGLETON_L2_HASH, "L2 singleton file");
        assertEq(keccak256(_fixture("factory")), FACTORY_HASH, "factory file");
        assertEq(keccak256(_fixture("fallback")), HANDLER_HASH, "handler file");
        assertEq(SINGLETON.codehash, SINGLETON_HASH, "singleton code");
        assertEq(SINGLETON_L2.codehash, SINGLETON_L2_HASH, "L2 singleton code");
        assertEq(FACTORY.codehash, FACTORY_HASH, "factory code");
        assertEq(HANDLER.codehash, HANDLER_HASH, "handler code");
    }

    // names another account pays for reach a Safe with its handler, anyone renews them, and the Safe writes
    // their records through its own transactions
    function test_realSafeHoldsNamesOthersPayFor() public {
        address safe = _safe(SINGLETON_L2, HANDLER, 0);
        assertEq(ISafe141(safe).VERSION(), "1.4.1");
        assertEq(ISafe141(safe).getThreshold(), 2);
        assertEq(vm.load(safe, HANDLER_SLOT), bytes32(uint256(uint160(HANDLER))));
        // a Safe proxy is a contract, not a key wallet
        assertGt(safe.code.length, 23);

        // a payer that is not the Safe commits and reveals one name of each fee tier for the Safe
        string[3] memory labels = _tiers();
        for (uint256 i; i < 3; ++i) _commit(labels[i], safe);
        vm.warp(vm.getBlockTimestamp() + 61);
        uint256 before = payer.balance;
        uint256 fees;
        for (uint256 i; i < 3; ++i) {
            (,,, uint256 total) = nft.quote(labels[i]);
            fees += nft.getFee(bytes(labels[i]).length);
            bytes32 secret = _secret(labels[i], safe);
            vm.prank(payer);
            uint256 id = nft.reveal{value: total}(labels[i], safe, 0, secret);
            assertEq(nft.ownerOf(id), safe, labels[i]);
        }
        assertEq(fees, 0.0111 ether, "the three yearly fees");
        assertEq(before - payer.balance, fees, "the payer paid exactly the fees");
        assertEq(nft.balanceOf(safe), 3);

        // a third account renews each one
        for (uint256 i; i < 3; ++i) {
            uint256 id = nft.computeId(labels[i]);
            uint256 expiry = nft.expiresAt(id);
            uint256 fee = nft.getFee(bytes(labels[i]).length);
            vm.prank(stranger);
            nft.renew{value: fee}(id);
            assertEq(nft.expiresAt(id), expiry + 365 days);
            assertEq(nft.depositOf(id), 2 * fee);
        }

        // the Safe writes a record of its name through its own transaction
        uint256 fund = nft.computeId("fund");
        bytes memory write = abi.encodeCall(PageNFT.setText, (fund, "url", "https://example.org"));
        assertTrue(_exec(safe, address(nft), 0, write));
        assertEq(nft.text(bytes32(fund), "url"), "https://example.org");
        // the Safe is the main address and answers on OP, but a contract gets no default on Ethereum, and addr with
        // no coin type answers coin type 60
        assertEq(nft.resolve(fund), safe);
        assertEq(nft.addr(bytes32(fund), COIN_OP), abi.encodePacked(safe));
        assertEq(nft.addr(bytes32(fund), 60).length, 0);
        assertEq(nft.addr(bytes32(fund)), address(0));
    }

    // another account's reveal to a Safe with no fallback handler fails and changes nothing, on both singletons
    function test_safeWithoutHandlerRejectsTheMint() public {
        address[2] memory singletons = [SINGLETON, SINGLETON_L2];
        string[2] memory labels = ["vault", "vaulttwo"];
        for (uint256 k; k < 2; ++k) {
            address bare = _safe(singletons[k], address(0), 1 + k);
            assertEq(vm.load(bare, HANDLER_SLOT), bytes32(0), "no handler");
            bytes32 c = _commit(labels[k], bare);
            uint256 committedAt = vm.getBlockTimestamp();
            vm.warp(committedAt + 61);
            (,,, uint256 total) = nft.quote(labels[k]);
            bytes32 secret = _secret(labels[k], bare);
            uint256 before = payer.balance;
            vm.prank(payer);
            vm.expectRevert(NOT_RECEIVER);
            nft.reveal{value: total}(labels[k], bare, 0, secret);
            assertEq(nft.commitments(c), committedAt, "the commitment survives");
            assertEq(payer.balance, before, "the payer keeps its money");
            assertTrue(nft.isAvailable(labels[k], 0), "the name is still free");
        }
    }

    // a Safe with no fallback handler reveals for itself with the commitment another account made, and gets a
    // plain mint
    function test_safeWithoutHandlerMintsForItself() public {
        address bare = _safe(SINGLETON_L2, address(0), 3);
        string memory label = "vault";
        bytes32 c = _commit(label, bare);
        vm.warp(vm.getBlockTimestamp() + 61);
        (,,, uint256 total) = nft.quote(label);
        bytes memory call = abi.encodeCall(PageNFT.reveal, (label, bare, 0, _secret(label, bare)));
        vm.deal(bare, 1 ether);
        // no onERC721Received reaches the Safe
        vm.expectCall(bare, abi.encodeWithSelector(bytes4(0x150b7a02)), 0);
        // the Safe sends more than the price and gets the rest back
        assertTrue(_exec(bare, address(nft), total + 0.5 ether, call));
        assertEq(nft.ownerOf(nft.computeId(label)), bare);
        assertEq(bare.balance, 1 ether - total, "the Safe paid the price");
        assertEq(nft.commitments(c), 0, "the commitment is used");
    }

    // in a sale PageNFT sees the registrar as the caller, so a Safe buying for itself needs its handler
    function test_safeBuyingThroughTheRegistrarNeedsItsHandler() public {
        address seller = makeAddr("seller");
        uint256 parent = _reveal(payer, seller, "market");
        vm.startPrank(seller);
        nft.setSubpageMinter(parent, address(reg));
        reg.configure(parent, address(0), address(0), 0.001 ether, true, address(0), 0, false);
        vm.stopPrank();
        address bare = _safe(SINGLETON_L2, address(0), 4);
        address full = _safe(SINGLETON_L2, HANDLER, 5);
        vm.deal(bare, 1 ether);
        vm.deal(full, 1 ether);
        bytes memory buy = abi.encodeCall(SubpageRegistrar.registerSubpage, (parent, "alice", 0.001 ether, address(0)));

        // the mint asks the Safe without a handler, which does not answer
        vm.prank(bare);
        vm.expectRevert(NOT_RECEIVER);
        reg.registerSubpage{value: 0.001 ether}(parent, "alice", 0.001 ether, address(0));
        // so its own transaction fails as a whole
        bytes memory sigs = _signatures(bare, address(reg), 0.001 ether, buy);
        vm.prank(relayer);
        vm.expectRevert(bytes("GS013"));
        ISafe141(bare).execTransaction(
            address(reg), 0.001 ether, buy, 0, 0, 0, 0, address(0), payable(address(0)), sigs
        );
        assertEq(bare.balance, 1 ether);
        assertEq(reg.proceedsOf(seller), 0);
        assertTrue(nft.isAvailable("alice", parent));

        // the Safe with the handler buys the same subpage for itself
        assertTrue(_exec(full, address(reg), 0.001 ether, buy));
        assertEq(nft.ownerOf(nft.computeId("alice.market")), full);
        assertEq(full.balance, 1 ether - 0.001 ether);
        assertEq(reg.proceedsOf(seller), 0.001 ether);
    }

    function test_claimForPaysARealSafe() public {
        address safe = _safe(SINGLETON_L2, HANDLER, 6);

        // the Safe's name lapses and is bought at auction, which credits the Safe its deposit and a premium share
        uint256 id = _reveal(payer, safe, "lapsed");
        vm.warp(nft.expiresAt(id) + 90 days + 7 days);
        _commit("lapsed", buyer);
        vm.warp(vm.getBlockTimestamp() + 61);
        (, uint256 carried, uint256 premium, uint256 total) = nft.quote("lapsed");
        assertGt(carried, 0);
        assertGt(premium, 0);
        uint256 deadBefore = nft.owed(address(0xdEaD));
        bytes32 secret = _secret("lapsed", buyer);
        vm.prank(buyer);
        nft.reveal{value: total}("lapsed", buyer, 0, secret);
        uint256 owed = nft.owed(safe);
        // with no referrer the referrer's share of the premium goes to the dead address, the rest to the Safe
        assertEq(owed + nft.owed(address(0xdEaD)) - deadBefore, carried + premium);
        assertGt(owed, carried);

        // a third account withdraws for the Safe, and the Safe receives all of it. On chain a withdrawal is a
        // transaction of its own, so the Safe and its singleton start cold, and reading them costs more than a
        // 2300 gas stipend.
        uint256 before = safe.balance;
        vm.cool(safe);
        vm.cool(SINGLETON_L2);
        vm.expectEmit(true, false, false, true, safe);
        emit SafeReceived(address(nft), owed);
        vm.prank(stranger);
        assertEq(nft.withdraw(safe), owed);
        assertEq(safe.balance, before + owed, "withdraw paid the Safe");
        assertEq(nft.owed(safe), 0);

        // the Safe sells subpages of another name through the registrar, its payout by default
        uint256 parent = _reveal(payer, safe, "shop");
        assertTrue(_exec(safe, address(nft), 0, abi.encodeCall(PageNFT.setSubpageMinter, (parent, address(reg)))));
        assertTrue(_exec(safe, address(reg), 0, abi.encodeCall(
            SubpageRegistrar.configure, (parent, address(0), address(0), 0.002 ether, true, address(0), 0, false)
        )));
        (,,,,,,, address payout,) = reg.config(parent);
        assertEq(payout, safe);
        vm.prank(buyer);
        reg.registerSubpage{value: 0.002 ether}(parent, "alice", 0.002 ether, address(0));
        vm.prank(buyer);
        reg.registerSubpage{value: 0.002 ether}(parent, "bob", 0.002 ether, address(0));
        assertEq(reg.proceedsOf(safe), 0.004 ether);

        // a third account claims for the Safe, and the Safe receives all of it, again from cold
        before = safe.balance;
        vm.cool(safe);
        vm.cool(SINGLETON_L2);
        vm.expectEmit(true, false, false, true, safe);
        emit SafeReceived(address(reg), 0.004 ether);
        vm.prank(stranger);
        assertEq(reg.claimProceedsFor(safe), 0.004 ether);
        assertEq(safe.balance, before + 0.004 ether, "claimProceedsFor paid the Safe");
        assertEq(reg.proceedsOf(safe), 0);
    }
}

// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {trialCommitment} from "../../utils/TrialCommitment.sol";

import {Test} from "forge-std/Test.sol";
import {PageCard} from "../../../src/PageCard.sol";
import {PageNFT} from "../../../src/PageNFT.sol";

// stands in for a Safe that its controller deploys on OP
contract PushSafe {
    address public controller;

    constructor(address c) {
        controller = c;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    function exec(address to, bytes calldata data) external payable returns (bytes memory) {
        require(msg.sender == controller, "not controller");
        (bool ok, bytes memory ret) = to.call{value: msg.value}(data);
        require(ok, "exec failed");
        return ret;
    }
}

// init code that writes records as the new address and then leaves no runtime code behind
contract ActsThenVanishes {
    constructor(PageNFT nft, uint256 id, address payTo, string memory avatar) {
        nft.setText(id, "avatar", avatar);
        nft.setAddr(id, payTo);
        assembly {
            return(0, 0)
        }
    }
}

// deploys with CREATE, so whoever controls this deployer controls the next address
contract VanishDeployer {
    function go(PageNFT nft, uint256 id, address payTo, string memory avatar) external returns (address a) {
        a = address(new ActsThenVanishes(nft, id, payTo, avatar));
    }
}

// Names sent or minted to an address someone else runs: the main address follows the holder on the home chain,
// every other chain answers nothing until the holder saves it, and a profile written before the send never counts
// for the new holder.
contract MultichainPushTest is Test {
    PageCard card;
    PageNFT nft;

    address attacker = makeAddr("attacker");
    address thief = makeAddr("thief");
    address friend = makeAddr("friend");
    address owners = makeAddr("owners");
    address alice = makeAddr("alice");

    uint256 constant ETH = 60;
    uint256 constant OP = 0x8000000a;
    uint256 constant DEF = 0x80000000;
    uint256 constant BASE = 0x80002105;
    uint256 constant ARB = 0x8000a4b1;
    uint256 constant LINEA = 0x8000e708;

    // a BAYC holder on Ethereum that is a Safe there and has no code on OP
    address constant H = 0xeb5cE9fD4ab6CcA2515AdFE54b58eFa3FE9EBca7;
    string constant APE = "eip155:1/erc721:0xbc4ca0eda7647a8ab7c2061c2e118a18a936f13d/22";

    function setUp() public {
        vm.warp(1_800_000_000);
        card = new PageCard();
        nft = new PageNFT(card);
        vm.deal(attacker, 100 ether);
        vm.deal(friend, 100 ether);
        vm.deal(alice, 100 ether);
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

    function _trial(address payer, address owner, string memory label) internal returns (uint256 id) {
        bytes32 secret = keccak256(abi.encode("trial", owner, label));
        bytes32 commitment = trialCommitment(address(nft), label, owner, 0, secret);
        vm.prank(payer);
        nft.commit(commitment);
        vm.warp(block.timestamp + 61);
        vm.prank(payer);
        id = nft.revealTrial{value: 1 ether}(label, owner, 0, secret);
    }

    function _expectEvm(uint256 id, address a) internal view {
        bytes memory want = a == address(0) ? bytes("") : abi.encodePacked(a);
        assertEq(nft.addr(id, ETH), want, "coin 60");
        assertEq(nft.addr(id, DEF), want, "DEFAULT_EVM");
        assertEq(nft.addr(id, BASE), want, "Base");
        assertEq(nft.addr(id, ARB), want, "Arbitrum");
        assertEq(nft.addr(id, LINEA), want, "Linea");
    }

    // a pushed name shows none of the sender's profile or saved addresses, and answers H on the home chain only
    function test_pushedProfileReadsEmpty() public {
        assertEq(H.code.length, 0, "H has no code here, as on OP");
        uint256 id = _register(attacker, attacker, "apetreasury");
        vm.startPrank(attacker);
        nft.setText(id, "avatar", APE);
        nft.setText(id, "url", "https://apetreasury.example");
        nft.setAddr(id, attacker);
        nft.setAddrForCoin(id, BASE, abi.encodePacked(attacker));
        nft.transferFrom(attacker, H, id);
        vm.stopPrank();

        assertEq(nft.ownerOf(id), H, "holder is the Ethereum Safe address");
        assertEq(nft.text(id, "avatar"), "", "the sender's avatar does not count for H");
        assertEq(nft.text(id, "url"), "");
        assertEq(nft.profileWriter(id), attacker);
        assertEq(nft.addr(id, OP), abi.encodePacked(H));
        _expectEvm(id, address(0));
    }

    // Whoever holds a leaked initial key of a Safe can create it on another chain, so H on OP can be a
    // thief's. The thief then controls every address answer, but the pushed avatar still never counts.
    function test_pushedNameThenThiefDeploysOnOp() public {
        uint256 id = _register(attacker, attacker, "apetreasury");
        vm.startPrank(attacker);
        nft.setText(id, "avatar", APE);
        nft.transferFrom(attacker, H, id);
        vm.stopPrank();
        assertEq(nft.addr(id, OP), abi.encodePacked(H));
        _expectEvm(id, address(0));

        // a friend pays the name on OP while H is still empty there
        vm.prank(friend);
        (bool ok,) = H.call{value: 5 ether}("");
        assertTrue(ok);

        // the thief creates H on OP with the leaked initial owner
        PushSafe code = new PushSafe(thief);
        vm.etch(H, address(code).code);
        vm.store(H, bytes32(0), bytes32(uint256(uint160(thief))));
        assertEq(H.balance, 5 ether, "the payment now sits under the thief's control");

        // and, as the holder, points the home chain at itself with the main address, which reaches no other chain
        vm.prank(thief);
        PushSafe(H).exec(address(nft), abi.encodeCall(nft.setAddr, (id, thief)));
        assertEq(nft.addr(id, OP), abi.encodePacked(thief));
        _expectEvm(id, address(0));
        // and every other chain at itself with the default
        vm.prank(thief);
        PushSafe(H).exec(address(nft), abi.encodeCall(nft.setAddrForCoin, (id, DEF, abi.encodePacked(thief))));
        _expectEvm(id, thief);
        assertEq(nft.text(id, "avatar"), "");
    }

    // no code on OP does not mean a key: a CREATE slot can write as the address and leave it empty, and the main
    // address it saves answers on the home chain only
    function test_codelessAddressWritesWithoutAKey() public {
        VanishDeployer d = new VanishDeployer();
        address next = vm.computeCreateAddress(address(d), vm.getNonce(address(d)));
        uint256 id = _register(attacker, attacker, "vanish");
        vm.prank(attacker);
        nft.transferFrom(attacker, next, id);

        address made = d.go(nft, id, thief, APE);
        assertEq(made, next);
        assertEq(made.code.length, 0, "no runtime code is left behind");
        assertEq(nft.ownerOf(id), made);
        assertEq(nft.text(id, "avatar"), APE, "written by the holder itself, so it counts");
        assertEq(nft.addr(id, OP), abi.encodePacked(thief));
        _expectEvm(id, address(0));
    }

    // a trial cannot carry records to another holder
    function test_trialCannotBePushed() public {
        uint256 id = _trial(attacker, attacker, "trialpush");
        vm.startPrank(attacker);
        nft.setText(id, "avatar", APE);
        vm.expectRevert(PageNFT.Unpaid.selector);
        nft.transferFrom(attacker, H, id);
        vm.stopPrank();
    }

    // a trial for H is possible, but the payer cannot write H's records, and H answers on the home chain only
    function test_trialForCodelessHolderHasNoAvatar() public {
        uint256 id = _trial(attacker, H, "trialfor");
        assertEq(nft.ownerOf(id), H);
        vm.prank(attacker);
        vm.expectRevert(PageNFT.Unauthorized.selector);
        nft.setText(id, "avatar", APE);
        assertEq(nft.text(id, "avatar"), "");
        assertEq(nft.addr(id, OP), abi.encodePacked(H));
        _expectEvm(id, address(0));
    }

    // the push as one multicall, with no approval step, carries no profile either
    function test_pushInsideMulticall() public {
        uint256 id = _register(attacker, attacker, "bundled");
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(nft.setText, (id, "avatar", APE));
        calls[1] = abi.encodeCall(nft.transferFrom, (attacker, H, id));
        vm.prank(attacker);
        nft.multicall(calls);
        assertEq(nft.ownerOf(id), H);
        assertEq(nft.text(id, "avatar"), "");
        assertEq(nft.addr(id, OP), abi.encodePacked(H));
        _expectEvm(id, address(0));
    }

    // a 7702 holder answers the same whatever its delegation, when it clears it, and even with contract code: nothing
    // outside the home chain until it saves a default, and then exactly that
    function test_7702DelegationChanges() public {
        address k = makeAddr("sevenkey");
        PushSafe impl1 = new PushSafe(k);
        PushSafe impl2 = new PushSafe(k);
        uint256 id = _register(attacker, attacker, "seven");
        vm.prank(attacker);
        nft.transferFrom(attacker, k, id);
        assertEq(nft.addr(id, OP), abi.encodePacked(k));
        _expectEvm(id, address(0));
        vm.etch(k, abi.encodePacked(hex"ef0100", address(impl1)));
        _expectEvm(id, address(0));
        vm.prank(k);
        nft.setAddrForCoin(id, DEF, abi.encodePacked(k));
        _expectEvm(id, k);
        vm.etch(k, abi.encodePacked(hex"ef0100", address(impl2)));
        _expectEvm(id, k);
        vm.etch(k, "");
        _expectEvm(id, k);
        // 23 bytes with another prefix is a contract, not a delegation (EIP3541 bars deployed code starting ef), and
        // the answers stay as they were
        vm.etch(k, abi.encodePacked(hex"fe0100", address(impl1)));
        _expectEvm(id, k);
        assertEq(nft.addr(id, OP), abi.encodePacked(k));
    }

    // a smart account that looks empty before the reveal is a contract right after it
    function test_counterfactualConnectThenDeploy() public {
        PushSafe code = new PushSafe(friend);
        address acct = makeAddr("cbsw");
        vm.deal(acct, 10 ether);
        assertEq(acct.code.length, 0, "a website reads it as a key wallet when it connects");
        // the first user operation deploys the account and then calls reveal
        vm.etch(acct, address(code).code);
        uint256 id = _register(acct, acct, "lazy");
        assertEq(nft.addr(id, OP), abi.encodePacked(acct));
        _expectEvm(id, address(0));
    }

    // a parent's holder can mint a subpage straight to a Safe address with no code here, and it answers H on the home
    // chain only
    function test_subpageForCodelessAnswersHomeChainOnly() public {
        uint256 parent = _register(attacker, attacker, "gifts");
        vm.prank(attacker);
        uint256 sub = nft.registerSubpageFor("treasury", parent, H);
        assertEq(nft.ownerOf(sub), H);
        assertEq(nft.addr(sub, OP), abi.encodePacked(H));
        _expectEvm(sub, address(0));
    }

    // a subpage written while held and then sent shows none of the sender's profile
    function test_subpagePushCarriesNoProfile() public {
        uint256 parent = _register(attacker, attacker, "gifts");
        vm.startPrank(attacker);
        uint256 sub = nft.registerSubpage("ape", parent);
        nft.setText(sub, "avatar", APE);
        nft.setAddr(sub, attacker);
        nft.transferFrom(attacker, H, sub);
        vm.stopPrank();
        assertEq(nft.ownerOf(sub), H);
        assertEq(nft.text(sub, "avatar"), "", "the avatar written before the send does not count");
        assertEq(nft.addr(sub, OP), abi.encodePacked(H), "the sender's main address stopped counting");
        _expectEvm(sub, address(0));
    }

    // paying a reveal for H carries no record: the payer can never write H's profile
    function test_sponsoredRevealCarriesNoRecords() public {
        uint256 id = _register(attacker, H, "sponsored");
        assertEq(nft.ownerOf(id), H);
        vm.prank(attacker);
        vm.expectRevert(PageNFT.Unauthorized.selector);
        nft.setText(id, "avatar", APE);
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeCall(nft.setText, (id, "avatar", APE));
        vm.prank(attacker);
        vm.expectRevert(PageNFT.Unauthorized.selector);
        nft.multicall(calls);
        assertEq(nft.text(id, "avatar"), "");
        // and the address answer stays on the home chain: no other EVM chain answers H
        assertEq(nft.addr(id, OP), abi.encodePacked(H));
        _expectEvm(id, address(0));
    }

    // minting a subpage straight to H carries no record either
    function test_subpageForCarriesNoRecords() public {
        uint256 parent = _register(attacker, attacker, "gifts2");
        vm.prank(attacker);
        uint256 sub = nft.registerSubpageFor("treasury", parent, H);
        vm.prank(attacker);
        vm.expectRevert(PageNFT.Unauthorized.selector);
        nft.setText(sub, "avatar", APE);
        assertEq(nft.text(sub, "avatar"), "");
        _expectEvm(sub, address(0));
    }

    // the real owners recover a pushed name by creating their Safe on the home chain: other chains never answered,
    // code appearing emits nothing and changes no answer, the pushed profile never showed, and clearRecords wipes it
    // for good
    function test_ownersRecoverPushedName() public {
        uint256 id = _register(attacker, attacker, "apetreasury");
        vm.startPrank(attacker);
        nft.setText(id, "avatar", APE);
        nft.setText(id, "url", "https://phish.example");
        nft.transferFrom(attacker, H, id);
        vm.stopPrank();
        assertEq(nft.addr(id, OP), abi.encodePacked(H));
        _expectEvm(id, address(0));
        assertEq(nft.text(id, "avatar"), "");
        assertEq(nft.text(id, "url"), "");

        PushSafe code = new PushSafe(owners);
        vm.recordLogs();
        vm.etch(H, address(code).code);
        vm.store(H, bytes32(0), bytes32(uint256(uint160(owners))));
        assertEq(vm.getRecordedLogs().length, 0, "code appearing emits nothing");
        assertEq(nft.addr(id, OP), abi.encodePacked(H));
        _expectEvm(id, address(0));

        vm.prank(owners);
        PushSafe(H).exec(address(nft), abi.encodeCall(nft.clearRecords, (id)));
        vm.prank(owners);
        PushSafe(H).exec(address(nft), abi.encodeCall(nft.keepProfile, (id)));
        assertEq(nft.text(id, "avatar"), "", "after clearRecords even a keep finds nothing");
        // the Safe exists on Ethereum with the same owners, so it may opt in there
        vm.prank(owners);
        PushSafe(H).exec(address(nft), abi.encodeCall(nft.setAddrForCoin, (id, ETH, abi.encodePacked(H))));
        assertEq(nft.addr(id, ETH), abi.encodePacked(H));
        assertEq(nft.addr(id, BASE), "");
    }

    // a change of main address never reaches coin type 60: a saved entry stays on the old address, and with nothing
    // saved coin type 60 answers nothing
    function test_savedCoin60DoesNotFollowMain() public {
        address cold = makeAddr("cold");
        uint256 id = _register(alice, alice, "pinned");
        uint256 id2 = _register(alice, alice, "follows");
        vm.startPrank(alice);
        nft.setAddrForCoin(id, ETH, abi.encodePacked(alice));
        nft.setAddr(id, cold);
        nft.setAddr(id2, cold);
        vm.stopPrank();
        assertEq(nft.addr(id, OP), abi.encodePacked(cold));
        assertEq(nft.addr(id, ETH), abi.encodePacked(alice), "the saved entry stays on the old address");
        assertEq(nft.addr(id, BASE), "");
        assertEq(nft.addr(id2, OP), abi.encodePacked(cold));
        assertEq(nft.addr(id2, ETH), "", "with nothing saved coin type 60 does not follow the main address");
    }

    // a smart account registering itself: reveal then one bundle of setters, all as the account,
    // in the order an EIP5792 atomic batch runs them
    function test_accountRevealThenBundleInOneBatch() public {
        PushSafe acct = new PushSafe(owners);
        vm.deal(owners, 1 ether);
        string memory label = "batched";
        bytes32 secret = keccak256("batched");
        bytes32 c = nft.makeCommitment(label, address(acct), 0, secret);
        vm.prank(owners);
        acct.exec(address(nft), abi.encodeCall(nft.commit, (c)));
        vm.warp(block.timestamp + 61);
        (,,, uint256 total) = nft.quote(label);
        uint256 id = nft.computeId(label);

        bytes[] memory calls = new bytes[](3);
        calls[0] = abi.encodeCall(nft.setAddrForCoin, (id, ETH, abi.encodePacked(address(acct))));
        calls[1] = abi.encodeCall(nft.setText, (id, "avatar", APE));
        calls[2] = abi.encodeCall(nft.setPrimaryPage, (id));
        vm.startPrank(owners);
        acct.exec{value: total}(address(nft), abi.encodeCall(nft.reveal, (label, address(acct), 0, secret)));
        acct.exec(address(nft), abi.encodeCall(nft.multicall, (calls)));
        vm.stopPrank();
        assertEq(nft.ownerOf(id), address(acct));
        assertEq(nft.addr(id, ETH), abi.encodePacked(address(acct)));
        assertEq(nft.addr(id, BASE), "", "only the chains it saved answer");
        assertEq(nft.text(id, "avatar"), APE);
        assertEq(nft.reverseResolve(address(acct)), "batched");
    }

    // A Safe holding many punks on Ethereum runs another contract at the same address on OP. A name
    // sent there shows no avatar, has no Ethereum answer by default, and whoever runs that address
    // on OP can make coin 60 answer it.
    function test_addressRunByOthersOnOp() public {
        address s = 0xB88F61E6FbdA83fbfffAbE364112137480398018;
        string memory punk = "eip155:1/erc721:0xb47e3cd837ddf8e4c57f05d70ab865de6e193bbb/1";
        PushSafe other = new PushSafe(attacker);
        vm.etch(s, address(other).code);
        vm.store(s, bytes32(0), bytes32(uint256(uint160(attacker))));

        uint256 id = _register(alice, alice, "punkvault");
        vm.startPrank(alice);
        nft.setText(id, "avatar", punk);
        nft.transferFrom(alice, s, id);
        vm.stopPrank();
        assertEq(nft.resolve(id), s);
        assertEq(nft.text(id, "avatar"), "", "the sender's avatar does not count for s");
        assertEq(nft.addr(id, ETH), "");
        assertEq(nft.addr(bytes32(id)), address(0), "addr by node is coin type 60, which answers nothing");
        vm.prank(attacker);
        PushSafe(s).exec(address(nft), abi.encodeCall(nft.setAddrForCoin, (id, ETH, abi.encodePacked(s))));
        assertEq(nft.addr(id, ETH), abi.encodePacked(s));
        assertEq(nft.addr(bytes32(id)), s);
        assertGt(s.code.length, 0);
    }

    // a key wallet registering itself answers on the home chain with no write, and on every other EVM chain, one that
    // does not exist yet included, once it saves a default
    function test_keyWalletNeedsOneDefaultWrite() public {
        uint256 id = _register(alice, alice, "plain");
        assertEq(nft.addr(id, OP), abi.encodePacked(alice));
        _expectEvm(id, address(0));
        assertEq(nft.addr(id, 0x80000000 | 999_999), "", "a chain that does not exist yet");
        vm.prank(alice);
        nft.setAddrForCoin(id, DEF, abi.encodePacked(alice));
        _expectEvm(id, alice);
        assertEq(nft.addr(id, 0x80000000 | 999_999), abi.encodePacked(alice), "a chain that does not exist yet");
        assertEq(nft.addr(id, OP), abi.encodePacked(alice));
    }

    // the writer's own profile comes back if the name returns to it
    function test_profileReturnsWithTheWriter() public {
        uint256 id = _register(attacker, attacker, "boomerang");
        address other = makeAddr("other");
        vm.startPrank(attacker);
        nft.setText(id, "avatar", APE);
        nft.transferFrom(attacker, other, id);
        vm.stopPrank();
        assertEq(nft.text(id, "avatar"), "");
        vm.prank(other);
        nft.transferFrom(other, attacker, id);
        assertEq(nft.text(id, "avatar"), APE);
    }
}

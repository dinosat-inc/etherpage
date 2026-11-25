// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {PageCard} from "../../../src/PageCard.sol";
import {PageNFT} from "../../../src/PageNFT.sol";
import {SubpageRegistrar, IPageNFT} from "../../../src/SubpageRegistrar.sol";
import {ITwinPageNFT, ITwinRegistrar, TwinUsd, TwinGate, TwinOtherCode, TwinFactoryDelegate} from "./L1TwinParts.sol";

// The L1 twin: code the deployer's key could put on Ethereum at the address of PageNFT or SubpageRegistrar, the
// threat that DEPLOY.md S3 item 7 closes by using up the deployer's nonces there. An OP deposit whose sender the
// portal does not alias runs on OP Mainnet as a top level call from that sender, msg.sender == tx.origin == from,
// with no signature and no code check, and its value is paid out of from's own balance on OP Mainnet.
// vm.prank(a, a) with a value models such a deposit. The tests list what such a caller could do as each of the
// three contracts, and show that the used up nonces leave no way to put code at their addresses. The three
// contracts are deployed from the deployer D at nonces N, N + 1 and N + 2 with plain CREATEs, as Deploy.s.sol does.
contract L1TwinTest is Test {
    uint256 constant N = 3; // the deployer's expected nonce: a redeploy after an abandoned first deployment
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    bytes4 constant ETH_TRANSFER_FAILED = bytes4(keccak256("ETHTransferFailed()"));

    address D = makeAddr("deployer");
    address card;
    address nftA;
    address regA;
    ITwinPageNFT nft;
    ITwinRegistrar reg;
    TwinUsd usd;
    TwinGate gate;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address dave = makeAddr("dave");
    address erin = makeAddr("erin");
    address frank = makeAddr("frank");
    address gina = makeAddr("gina");
    address hank = makeAddr("hank");
    address ivy = makeAddr("ivy");
    address jack = makeAddr("jack");
    address kim = makeAddr("kim");
    address relayer = makeAddr("relayer");
    address buyer = makeAddr("buyer");
    address attacker = makeAddr("attacker");
    address stranger = makeAddr("stranger");

    bytes32 constant SECRET_N = keccak256("newname");
    bytes32 constant SECRET_T = keccak256("newtrial");
    bytes32 constant SECRET_R = keccak256("rev1");
    bytes32 constant SECRET_R2 = keccak256("rev2");

    uint256 club; // alice: ETH price, commit and reveal, gate token
    uint256 shop; // bob: ERC20 price
    uint256 brand; // dave: registrar still the minter, sales switched off
    uint256 plain; // erin: no minter
    uint256 oops; // hank sent it to the registrar with a plain transferFrom
    uint256 trialx; // gina: a renewed trial, so its trial money is owed back to her
    uint256 open; // ivy: ETH price, no commit
    uint256 jackName; // jack made the registrar an operator of all his names
    uint256 kimName; // kim approved PageNFT's own address for one name
    uint256 frankClub;
    uint256 carolShop;
    uint256 s1Open;

    function _register(address who, string memory label) internal returns (uint256 id) {
        bytes32 secret = keccak256(abi.encode("name", label, who));
        bytes32 c = nft.makeCommitment(label, who, 0, secret);
        vm.prank(who);
        nft.commit(c);
        vm.warp(vm.getBlockTimestamp() + 21);
        uint256 fee = nft.getFee(bytes(label).length);
        vm.deal(who, who.balance + fee);
        vm.prank(who);
        id = nft.reveal{value: fee}(label, who, 0, secret);
    }

    function _trialCommit(string memory label, address to, bytes32 secret) internal pure returns (bytes32) {
        return keccak256(abi.encode(bytes(label), to, uint256(0), secret, true));
    }

    function _subCommit(uint256 parentId, string memory label, address to, bytes32 secret)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(parentId, label, to, secret));
    }

    function _trial(address who, string memory label) internal returns (uint256 id) {
        bytes32 secret = keccak256(abi.encode("trial", label, who));
        vm.prank(who);
        nft.commit(_trialCommit(label, who, secret));
        vm.warp(vm.getBlockTimestamp() + 21);
        uint256 price = nft.getFee(bytes(label).length) / 10;
        vm.deal(who, who.balance + price);
        vm.prank(who);
        id = nft.revealTrial{value: price}(label, who, 0, secret);
    }

    // the three contracts, created by the deployer in the order Deploy.s.sol creates them
    function _deployFrom(address deployer) internal returns (address c, address n, address r) {
        vm.startPrank(deployer, deployer);
        PageCard pageCard = new PageCard();
        PageNFT nameNft = new PageNFT(pageCard);
        SubpageRegistrar registrar = new SubpageRegistrar(IPageNFT(address(nameNft)));
        vm.stopPrank();
        (c, n, r) = (address(pageCard), address(nameNft), address(registrar));
    }

    function setUp() public {
        vm.warp(1_800_000_000);
        vm.setNonce(D, uint64(N));
        (card, nftA, regA) = _deployFrom(D);
        assertEq(card, vm.computeCreateAddress(D, N), "PageCard at nonce N");
        assertEq(nftA, vm.computeCreateAddress(D, N + 1), "PageNFT at nonce N + 1");
        assertEq(regA, vm.computeCreateAddress(D, N + 2), "SubpageRegistrar at nonce N + 2");
        assertEq(vm.getNonce(D), N + 3, "the deployer's OP nonce is N + 3");
        nft = ITwinPageNFT(nftA);
        reg = ITwinRegistrar(regA);
        assertEq(reg.registry(), nftA);
        usd = new TwinUsd();
        gate = new TwinGate();

        club = _register(alice, "club");
        vm.startPrank(alice);
        nft.setSubpageMinter(club, regA);
        reg.configure(club, alice, address(0), 0.01 ether, true, address(gate), 1, true);
        vm.stopPrank();

        shop = _register(bob, "shop");
        vm.startPrank(bob);
        nft.setSubpageMinter(shop, regA);
        reg.configure(shop, bob, address(usd), 5e18, true, address(0), 0, false);
        vm.stopPrank();

        // carol buys carol.shop and leaves the usual unlimited allowance to the registrar
        usd.mint(carol, 1000e18);
        vm.startPrank(carol);
        usd.approve(regA, type(uint256).max);
        carolShop = reg.registerSubpage(shop, "carol", 5e18, address(usd));
        vm.stopPrank();

        // frank buys frank.club through commit and reveal and writes his profile
        gate.mint(frank, 1);
        bytes32 fs = keccak256("frank-secret");
        bytes32 fc = reg.makeSubpageCommitment(club, "frank", frank, fs);
        vm.prank(frank);
        reg.commitSubpage(fc);
        vm.warp(vm.getBlockTimestamp() + 21);
        vm.deal(frank, 1 ether);
        vm.prank(frank);
        frankClub = reg.revealSubpage{value: 0.01 ether}(club, "frank", fs, 0.01 ether, address(0));
        vm.prank(frank);
        nft.setText(frankClub, "url", "https://frank.example");

        brand = _register(dave, "brand");
        vm.startPrank(dave);
        nft.setSubpageMinter(brand, regA);
        reg.configure(brand, dave, address(0), 1 ether, true, address(0), 0, false);
        reg.disable(brand);
        vm.stopPrank();

        plain = _register(erin, "plain");

        oops = _register(hank, "oops");
        vm.prank(hank);
        nft.transferFrom(hank, regA, oops);

        trialx = _trial(gina, "trialx");
        uint256 fee6 = nft.getFee(6);
        vm.deal(gina, gina.balance + fee6);
        vm.prank(gina);
        nft.renew{value: fee6}(trialx);
        assertGt(nft.owed(gina), 0, "gina is owed her trial money");

        open = _register(ivy, "open");
        vm.startPrank(ivy);
        nft.setSubpageMinter(open, regA);
        reg.configure(open, ivy, address(0), 0.02 ether, true, address(0), 0, false);
        vm.stopPrank();
        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        s1Open = reg.registerSubpage{value: 0.02 ether}(open, "s1", 0.02 ether, address(0));

        jackName = _register(jack, "jackname");
        vm.prank(jack);
        nft.setApprovalForAll(regA, true);

        kimName = _register(kim, "kimname");
        vm.prank(kim);
        nft.approve(nftA, kimName);

        // the reveal and the trial any actor may complete, a subpage reveal for each actor as its own receiver and
        // one for the attacker
        vm.startPrank(relayer);
        nft.commit(nft.makeCommitment("newname", attacker, 0, SECRET_N));
        nft.commit(_trialCommit("newtrl", attacker, SECRET_T));
        reg.commitSubpage(_subCommit(club, "rev1", stranger, SECRET_R));
        reg.commitSubpage(_subCommit(club, "rev1", nftA, SECRET_R));
        reg.commitSubpage(_subCommit(club, "rev1", regA, SECRET_R));
        reg.commitSubpage(_subCommit(club, "rev1", card, SECRET_R));
        reg.commitSubpage(_subCommit(club, "rev2", attacker, SECRET_R2));
        vm.stopPrank();
        // every actor holds the gate token, so the gate is never why a call fails
        gate.mint(stranger, 1);
        gate.mint(nftA, 1);
        gate.mint(regA, 1);
        gate.mint(card, 1);
        vm.warp(vm.getBlockTimestamp() + 21);
    }

    // Every state changing entry point, as a stranger and as each of the three twins, from the same state.

    struct Call {
        string what;
        address target;
        bytes data;
        uint256 value;
        uint8 expect; // which actors succeed: bit 0 stranger, bit 1 PageNFT, bit 2 registrar, bit 3 PageCard
    }

    uint8 constant ALL = 15;
    uint8 constant NONE = 0;
    uint8 constant STRANGER = 1;
    uint8 constant AS_NFT = 2;
    uint8 constant AS_REG = 4;

    function _calls() internal view returns (Call[] memory cs) {
        cs = new Call[](48);
        uint256 i;
        bytes[] memory inner = new bytes[](1);
        inner[0] = abi.encodeCall(ITwinPageNFT.setText, (oops, "url", "x"));
        cs[i++] = Call(
            "N approve(oops held by registrar)", nftA, abi.encodeCall(ITwinPageNFT.approve, (attacker, oops)), 0, AS_REG
        );
        cs[i++] =
            Call("N approve(frank.club)", nftA, abi.encodeCall(ITwinPageNFT.approve, (attacker, frankClub)), 0, NONE);
        cs[i++] = Call("N clearRecords(oops)", nftA, abi.encodeWithSignature("clearRecords(uint256)", oops), 0, AS_REG);
        cs[i++] = Call(
            "N clearRecords(frank.club)", nftA, abi.encodeWithSignature("clearRecords(uint256)", frankClub), 0, NONE
        );
        cs[i++] = Call("N commit(fresh)", nftA, abi.encodeCall(ITwinPageNFT.commit, (keccak256("fresh"))), 0, ALL);
        cs[i++] = Call("N keepProfile(oops)", nftA, abi.encodeWithSignature("keepProfile(uint256)", oops), 0, AS_REG);
        cs[i++] = Call(
            "N keepProfile(frank.club)", nftA, abi.encodeWithSignature("keepProfile(uint256)", frankClub), 0, NONE
        );
        cs[i++] = Call("N multicall([setText(oops)])", nftA, abi.encodeCall(ITwinPageNFT.multicall, (inner)), 0, AS_REG);
        cs[i++] = Call(
            "N registerSubpage(free1.club) to itself",
            nftA,
            abi.encodeCall(ITwinPageNFT.registerSubpage, ("free1", club)),
            0,
            AS_REG
        );
        cs[i++] = Call(
            "N registerSubpageFor(free2.club) gated priced commit sale",
            nftA,
            abi.encodeCall(ITwinPageNFT.registerSubpageFor, ("free2", club, attacker)),
            0,
            AS_REG
        );
        cs[i++] = Call(
            "N registerSubpageFor(ceo.brand) sales off",
            nftA,
            abi.encodeCall(ITwinPageNFT.registerSubpageFor, ("ceo", brand, attacker)),
            0,
            AS_REG
        );
        cs[i++] = Call(
            "N registerSubpageFor(y.shop) ERC20 sale",
            nftA,
            abi.encodeCall(ITwinPageNFT.registerSubpageFor, ("y", shop, attacker)),
            0,
            AS_REG
        );
        cs[i++] = Call(
            "N registerSubpageFor(frank.club) live",
            nftA,
            abi.encodeCall(ITwinPageNFT.registerSubpageFor, ("frank", club, attacker)),
            0,
            NONE
        );
        cs[i++] = Call(
            "N registerSubpageFor(carol.shop) live",
            nftA,
            abi.encodeCall(ITwinPageNFT.registerSubpageFor, ("carol", shop, attacker)),
            0,
            NONE
        );
        cs[i++] = Call(
            "N registerSubpageFor(x.plain) no minter",
            nftA,
            abi.encodeCall(ITwinPageNFT.registerSubpageFor, ("x", plain, attacker)),
            0,
            NONE
        );
        cs[i++] = Call("N release(club)", nftA, abi.encodeCall(ITwinPageNFT.release, (club)), 0, NONE);
        cs[i++] = Call("N renew(club) exact fee", nftA, abi.encodeCall(ITwinPageNFT.renew, (club)), nft.getFee(4), ALL);
        cs[i++] = Call(
            "N reveal(newname) exact fee",
            nftA,
            abi.encodeCall(ITwinPageNFT.reveal, ("newname", attacker, 0, SECRET_N)),
            nft.getFee(7),
            ALL
        );
        cs[i++] = Call(
            "N revealTrial(newtrl) exact price",
            nftA,
            abi.encodeCall(ITwinPageNFT.revealTrial, ("newtrl", attacker, 0, SECRET_T)),
            nft.getFee(6) / 10,
            ALL
        );
        cs[i++] = Call(
            "N safeTransferFrom(oops)",
            nftA,
            abi.encodeWithSignature("safeTransferFrom(address,address,uint256)", regA, attacker, oops),
            0,
            AS_REG
        );
        cs[i++] = Call(
            "N safeTransferFrom(oops,data)",
            nftA,
            abi.encodeWithSignature("safeTransferFrom(address,address,uint256,bytes)", regA, attacker, oops, hex"01"),
            0,
            AS_REG
        );
        cs[i++] = Call(
            "N safeTransferFrom(frank.club)",
            nftA,
            abi.encodeWithSignature("safeTransferFrom(address,address,uint256)", frank, attacker, frankClub),
            0,
            NONE
        );
        cs[i++] = Call("N setAddr(oops)", nftA, abi.encodeCall(ITwinPageNFT.setAddr, (oops, attacker)), 0, AS_REG);
        cs[i++] =
            Call("N setAddr(frank.club)", nftA, abi.encodeCall(ITwinPageNFT.setAddr, (frankClub, attacker)), 0, NONE);
        cs[i++] = Call(
            "N setAddrForCoin(oops,default)",
            nftA,
            abi.encodeCall(ITwinPageNFT.setAddrForCoin, (oops, 0x80000000, abi.encodePacked(attacker))),
            0,
            AS_REG
        );
        cs[i++] = Call(
            "N setAddrForCoin(frank.club,default)",
            nftA,
            abi.encodeCall(ITwinPageNFT.setAddrForCoin, (frankClub, 0x80000000, abi.encodePacked(attacker))),
            0,
            NONE
        );
        cs[i++] = Call(
            "N setAddrForCoin(frank.club,60)",
            nftA,
            abi.encodeCall(ITwinPageNFT.setAddrForCoin, (frankClub, 60, abi.encodePacked(attacker))),
            0,
            NONE
        );
        cs[i++] = Call(
            "N setApprovalForAll(own)", nftA, abi.encodeCall(ITwinPageNFT.setApprovalForAll, (attacker, true)), 0, ALL
        );
        cs[i++] = Call(
            "N setContenthash(oops)",
            nftA,
            abi.encodeWithSignature("setContenthash(uint256,bytes)", oops, hex"e301"),
            0,
            AS_REG
        );
        cs[i++] = Call(
            "N setContenthash(frank.club)",
            nftA,
            abi.encodeWithSignature("setContenthash(uint256,bytes)", frankClub, hex"e301"),
            0,
            NONE
        );
        cs[i++] =
            Call("N setPrimaryPage(oops)", nftA, abi.encodeWithSignature("setPrimaryPage(uint256)", oops), 0, AS_REG);
        cs[i++] = Call(
            "N setPrimaryPage(frank.club)", nftA, abi.encodeWithSignature("setPrimaryPage(uint256)", frankClub), 0, NONE
        );
        cs[i++] = Call(
            "N setSubpageMinter(oops)", nftA, abi.encodeCall(ITwinPageNFT.setSubpageMinter, (oops, attacker)), 0, AS_REG
        );
        cs[i++] = Call(
            "N setSubpageMinter(club, clear)",
            nftA,
            abi.encodeCall(ITwinPageNFT.setSubpageMinter, (club, address(0))),
            0,
            NONE
        );
        cs[i++] =
            Call("N setText(frank.club)", nftA, abi.encodeCall(ITwinPageNFT.setText, (frankClub, "url", "x")), 0, NONE);
        cs[i++] = Call(
            "N transferFrom(oops)", nftA, abi.encodeCall(ITwinPageNFT.transferFrom, (regA, attacker, oops)), 0, AS_REG
        );
        cs[i++] = Call(
            "N transferFrom(jackname, registrar is operator)",
            nftA,
            abi.encodeCall(ITwinPageNFT.transferFrom, (jack, attacker, jackName)),
            0,
            AS_REG
        );
        cs[i++] = Call(
            "N transferFrom(kimname, PageNFT approved)",
            nftA,
            abi.encodeCall(ITwinPageNFT.transferFrom, (kim, attacker, kimName)),
            0,
            AS_NFT
        );
        cs[i++] = Call(
            "N transferFrom(frank.club)",
            nftA,
            abi.encodeCall(ITwinPageNFT.transferFrom, (frank, attacker, frankClub)),
            0,
            NONE
        );
        cs[i++] = Call("N withdraw(gina)", nftA, abi.encodeCall(ITwinPageNFT.withdraw, (gina)), 0, ALL);
        cs[i++] = Call("R claimProceeds(own)", regA, abi.encodeCall(ITwinRegistrar.claimProceeds, (attacker)), 0, NONE);
        cs[i++] =
            Call("R claimProceedsFor(alice)", regA, abi.encodeCall(ITwinRegistrar.claimProceedsFor, (alice)), 0, ALL);
        cs[i++] = Call(
            "R commitSubpage(fresh)",
            regA,
            abi.encodeCall(ITwinRegistrar.commitSubpage, (keccak256("sub-fresh"))),
            0,
            ALL
        );
        cs[i++] = Call(
            "R configure(oops)",
            regA,
            abi.encodeCall(ITwinRegistrar.configure, (oops, attacker, address(0), 0, true, address(0), 0, false)),
            0,
            AS_REG
        );
        cs[i++] = Call(
            "R configure(club)",
            regA,
            abi.encodeCall(ITwinRegistrar.configure, (club, attacker, address(0), 0, true, address(0), 0, false)),
            0,
            NONE
        );
        cs[i++] = Call("R disable(oops)", regA, abi.encodeCall(ITwinRegistrar.disable, (oops)), 0, AS_REG);
        cs[i++] = Call("R disable(club)", regA, abi.encodeCall(ITwinRegistrar.disable, (club)), 0, NONE);
        cs[i++] = Call(
            "R registerSubpage(buy1.open) for itself",
            regA,
            abi.encodeCall(ITwinRegistrar.registerSubpage, (open, "buy1", 0.02 ether, address(0))),
            0.02 ether,
            STRANGER
        );
        assembly ("memory-safe") {
            mstore(cs, i)
        }
    }

    function _calls2() internal view returns (Call[] memory cs) {
        cs = new Call[](4);
        uint256 i;
        cs[i++] = Call(
            "R registerSubpageFor(buy2.open) for attacker",
            regA,
            abi.encodeCall(ITwinRegistrar.registerSubpageFor, (open, "buy2", attacker, 0.02 ether, address(0))),
            0.02 ether,
            ALL
        );
        cs[i++] = Call(
            "R registerSubpageFor(buy3.shop) ERC20",
            regA,
            abi.encodeCall(ITwinRegistrar.registerSubpageFor, (shop, "buy3", attacker, 5e18, address(usd))),
            0,
            NONE
        );
        cs[i++] = Call(
            "R revealSubpage(rev1.club) for itself",
            regA,
            abi.encodeCall(ITwinRegistrar.revealSubpage, (club, "rev1", SECRET_R, 0.01 ether, address(0))),
            0.01 ether,
            STRANGER
        );
        cs[i++] = Call(
            "R revealSubpageFor(rev2.club) for attacker",
            regA,
            abi.encodeCall(
                ITwinRegistrar.revealSubpageFor, (club, "rev2", attacker, SECRET_R2, 0.01 ether, address(0))
            ),
            0.01 ether,
            ALL
        );
    }

    // the call as each actor in turn, each from the same state, with the actors that succeeded as a bit mask
    function _run(Call memory c, address[4] memory actors) internal returns (uint8 mask) {
        for (uint256 a; a < 4; ++a) {
            uint256 snap = vm.snapshotState();
            address actor = actors[a];
            if (c.value != 0) vm.deal(actor, actor.balance + c.value);
            vm.prank(actor, actor);
            (bool ok,) = c.target.call{value: c.value}(c.data);
            if (ok) mask |= uint8(1 << a);
            vm.revertToState(snap);
        }
    }

    // the exact set of calls each twin can make that a stranger cannot, and the reverse
    function test_everyEntryPointAsEachTwinAndAsAStranger() public {
        Call[] memory a = _calls();
        Call[] memory b = _calls2();
        Call[] memory cs = new Call[](a.length + b.length);
        for (uint256 i; i < a.length; ++i) {
            cs[i] = a[i];
        }
        for (uint256 i; i < b.length; ++i) {
            cs[a.length + i] = b[i];
        }
        address[4] memory actors = [stranger, nftA, regA, card];
        uint256 mismatches;
        string memory wrong;
        for (uint256 i; i < cs.length; ++i) {
            uint8 mask = _run(cs[i], actors);
            if (mask != cs[i].expect) {
                ++mismatches;
                wrong = string.concat(
                    wrong, "; ", cs[i].what, ": ok mask ", vm.toString(mask), ", expected ", vm.toString(cs[i].expect)
                );
            }
        }
        assertEq(mismatches, 0, string.concat("every outcome as expected", wrong));
        // every state changing function of both contracts is in the list
        _assertCovers(cs);
    }

    function _assertCovers(Call[] memory cs) internal view {
        string[31] memory sigs = [
            "approve(address,uint256)",
            "clearRecords(uint256)",
            "commit(bytes32)",
            "keepProfile(uint256)",
            "multicall(bytes[])",
            "registerSubpage(string,uint256)",
            "registerSubpageFor(string,uint256,address)",
            "release(uint256)",
            "renew(uint256)",
            "reveal(string,address,uint256,bytes32)",
            "revealTrial(string,address,uint256,bytes32)",
            "safeTransferFrom(address,address,uint256)",
            "safeTransferFrom(address,address,uint256,bytes)",
            "setAddr(uint256,address)",
            "setAddrForCoin(uint256,uint256,bytes)",
            "setApprovalForAll(address,bool)",
            "setContenthash(uint256,bytes)",
            "setPrimaryPage(uint256)",
            "setSubpageMinter(uint256,address)",
            "setText(uint256,string,string)",
            "transferFrom(address,address,uint256)",
            "withdraw(address)",
            "claimProceeds(address)",
            "claimProceedsFor(address)",
            "commitSubpage(bytes32)",
            "configure(uint256,address,address,uint256,bool,address,uint256,bool)",
            "disable(uint256)",
            "registerSubpage(uint256,string,uint256,address)",
            "registerSubpageFor(uint256,string,address,uint256,address)",
            "revealSubpage(uint256,string,bytes32,uint256,address)",
            "revealSubpageFor(uint256,string,address,bytes32,uint256,address)"
        ];
        for (uint256 s; s < sigs.length; ++s) {
            bytes4 sel = bytes4(keccak256(bytes(sigs[s])));
            address target = s < 22 ? nftA : regA;
            bool found;
            for (uint256 i; i < cs.length; ++i) {
                if (cs[i].target == target && bytes4(cs[i].data) == sel) found = true;
            }
            assertTrue(found, sigs[s]);
        }
    }

    // What the deposit itself moves: value paid from the twin's own balance, and calls to other contracts.

    // every deposit and everything owed, as PageNFT accounts for it
    function _books() internal view returns (uint256 sum) {
        uint256[10] memory ids = [club, shop, brand, plain, oops, trialx, open, jackName, kimName, uint256(0)];
        for (uint256 i; i < 9; ++i) {
            sum += nft.depositOf(ids[i]);
            (, uint96 t) = nft.trialPaymentOf(ids[i]);
            sum += t;
        }
        sum += nft.owed(gina) + nft.owed(DEAD);
    }

    // the PageNFT twin sends all of PageNFT's ETH to the attacker, and withdrawals then fail
    function test_nameNftTwinTakesEveryDeposit() public {
        uint256 held = nftA.balance;
        assertEq(held, _books(), "solvent before: the balance is every deposit plus what is owed");
        // deposit: from = PageNFT, to = attacker, value = its whole balance on OP Mainnet, mint = 0
        vm.prank(nftA, nftA);
        (bool ok,) = attacker.call{value: held}("");
        assertTrue(ok);
        assertEq(nftA.balance, 0, "PageNFT is empty");
        assertEq(attacker.balance, held, "the attacker has it all");
        assertEq(_books(), held, "the books still say the money is there");
        vm.expectRevert(ETH_TRANSFER_FAILED);
        nft.withdraw(gina);
    }

    // the twin can also pay fees out of PageNFT's own balance: the books grow, the balance does not
    function test_nameNftTwinPaysWithNameNftsOwnEth() public {
        uint256 bal = nftA.balance;
        uint256 dep = nft.depositOf(club);
        uint256 fee = nft.getFee(4);
        vm.prank(nftA, nftA);
        nft.renew{value: fee}(club);
        assertEq(nftA.balance, bal, "no new ETH came in");
        assertEq(nft.depositOf(club), dep + fee, "yet the deposit grew");
        assertEq(_books(), bal + fee, "the books now exceed the balance");
    }

    // the registrar twin takes the unclaimed proceeds and spends the allowances buyers left to the registrar
    function test_registrarTwinTakesProceedsAndAllowances() public {
        uint256 held = regA.balance;
        assertEq(held, reg.proceedsOf(alice) + reg.proceedsOf(ivy), "solvent before");
        assertEq(held, 0.03 ether);
        // a stranger cannot spend carol's allowance
        vm.prank(stranger, stranger);
        vm.expectRevert(bytes("allowance"));
        usd.transferFrom(carol, stranger, 1);
        // the twin takes the unclaimed proceeds
        vm.prank(regA, regA);
        (bool ok,) = attacker.call{value: held}("");
        assertTrue(ok);
        assertEq(regA.balance, 0);
        vm.expectRevert(ETH_TRANSFER_FAILED);
        reg.claimProceedsFor(alice);
        vm.prank(ivy);
        vm.expectRevert(ETH_TRANSFER_FAILED);
        reg.claimProceeds(ivy);
        // and spends every allowance a buyer left to the registrar
        uint256 left = usd.balanceOf(carol);
        assertEq(left, 995e18);
        vm.prank(regA, regA);
        usd.transferFrom(carol, attacker, left);
        assertEq(usd.balanceOf(carol), 0);
        assertEq(usd.balanceOf(attacker), left);
    }

    // free, instant subpages under every parent whose counted minter is the registrar, whatever its terms say
    function test_registrarTwinMintsFreeSubpagesWhereverItIsTheMinter() public {
        uint256 pAlice = reg.proceedsOf(alice);
        uint256 usdBob = usd.balanceOf(bob);
        uint256[4] memory parents = [club, shop, brand, open];
        for (uint256 i; i < 4; ++i) {
            assertEq(nft.subpageMinterOf(parents[i]), regA);
            vm.prank(regA, regA);
            uint256 sid = nft.registerSubpageFor("support", parents[i], attacker);
            assertEq(nft.ownerOf(sid), attacker);
        }
        assertEq(reg.proceedsOf(alice), pAlice, "alice was paid nothing");
        assertEq(usd.balanceOf(bob), usdBob, "bob was paid nothing");
        // never over a live subpage, and never where it is not the minter
        vm.startPrank(regA, regA);
        vm.expectRevert(bytes4(keccak256("AlreadyRegistered()")));
        nft.registerSubpageFor("frank", club, attacker);
        vm.expectRevert(bytes4(keccak256("AlreadyRegistered()")));
        nft.registerSubpageFor("carol", shop, attacker);
        vm.expectRevert(bytes4(keccak256("NotParentOwner()")));
        nft.registerSubpageFor("support", plain, attacker);
        vm.stopPrank();
        assertEq(nft.ownerOf(frankClub), frank);
        assertEq(nft.text(frankClub, "url"), "https://frank.example");
    }

    // the twin's mint power is exactly the counted minter pick: it ends when the holder clears the pick, moves the
    // parent, or the parent is registered again, and a trial parent has none
    function test_registrarTwinMintPowerFollowsTheCountedPick() public {
        bytes4 notParentOwner = bytes4(keccak256("NotParentOwner()"));
        // alice clears her pick of the registrar
        vm.prank(alice);
        nft.setSubpageMinter(club, address(0));
        vm.prank(regA, regA);
        vm.expectRevert(notParentOwner);
        nft.registerSubpageFor("t1", club, attacker);
        // bob moves shop to carol, so his pick no longer counts
        vm.prank(bob);
        nft.transferFrom(bob, carol, shop);
        assertEq(nft.subpageMinterOf(shop), address(0));
        vm.prank(regA, regA);
        vm.expectRevert(notParentOwner);
        nft.registerSubpageFor("t2", shop, attacker);
        // a renewed trial whose holder picks the registrar is minted under like any parent, a running trial never
        vm.prank(gina);
        nft.setSubpageMinter(trialx, regA);
        vm.prank(regA, regA);
        nft.registerSubpageFor("t3", trialx, attacker);
        uint256 running = _trial(gina, "trialy");
        vm.prank(gina);
        nft.setSubpageMinter(running, regA);
        vm.prank(regA, regA);
        vm.expectRevert(bytes4(keccak256("Unpaid()")));
        nft.registerSubpageFor("t3", running, attacker);
        // open, registered again after it lapsed: the pick of the earlier registration is gone
        vm.warp(nft.expiresAt(open) + 90 days + 21 days + 1);
        _register(stranger, "open");
        assertEq(nft.subpageMinterOf(open), address(0));
        vm.prank(regA, regA);
        vm.expectRevert(notParentOwner);
        nft.registerSubpageFor("t4", open, attacker);
    }

    // the twin buys from the registrar with the registrar's own ETH: proceeds grow, the balance does not
    function test_registrarTwinPaysWithTheRegistrarsOwnEth() public {
        uint256 bal = regA.balance;
        uint256 p = reg.proceedsOf(ivy);
        vm.prank(regA, regA);
        reg.registerSubpageFor{value: 0.02 ether}(open, "buy9", attacker, 0.02 ether, address(0));
        assertEq(regA.balance, bal, "no new ETH came in");
        assertEq(reg.proceedsOf(ivy), p + 0.02 ether, "yet ivy is owed more");
        assertLt(regA.balance, reg.proceedsOf(alice) + reg.proceedsOf(ivy), "insolvent");
    }

    // PageCard holds nothing, can be paid nothing, and is nobody's minter, payout or approved account
    function test_pageCardTwinHasNothingToTake() public {
        assertEq(card.balance, 0);
        vm.deal(address(this), 1 ether);
        (bool ok,) = card.call{value: 1}("");
        assertFalse(ok, "PageCard refuses ETH");
        (ok,) = card.call{value: 1}(abi.encodeWithSignature("shortAddress(address)", address(1)));
        assertFalse(ok, "and refuses it with any call");
    }

    // Why the used up nonces close it: a CREATE address follows from the deployer and its nonce alone.

    function test_ethereumNoncesDecideTheTwinAndTheBurnClosesIt() public {
        address E = makeAddr("second deployer");
        vm.setNonce(E, uint64(N));
        uint256 fresh = vm.snapshotState();
        // on OP Mainnet: the three contracts at nonces N to N + 2
        (address c, address n, address r) = _deployFrom(E);
        vm.revertToState(fresh);
        // on Ethereum, where E is still at nonce N: any other code lands at exactly the same three addresses
        vm.startPrank(E, E);
        address x0 = address(new TwinOtherCode());
        address x1 = address(new TwinOtherCode());
        address x2 = address(new TwinOtherCode());
        vm.stopPrank();
        assertEq(x0, c, "other code at the PageCard address");
        assertEq(x1, n, "other code at the PageNFT address");
        assertEq(x2, r, "other code at the registrar address");
        assertEq(TwinOtherCode(x1).hello(), 42);
        vm.revertToState(fresh);
        // after the burn: three plain transactions took nonces N to N + 2 on Ethereum
        vm.setNonce(E, uint64(N + 3));
        vm.prank(E, E);
        address y = address(new TwinOtherCode());
        assertEq(y, vm.computeCreateAddress(E, N + 3));
        assertTrue(y != c && y != n && y != r);
        // an EIP7702 delegation does not help either: a CREATE from the account uses its nonce
        TwinFactoryDelegate f = new TwinFactoryDelegate();
        vm.etch(E, abi.encodePacked(hex"ef0100", address(f)));
        address z = TwinFactoryDelegate(E).make();
        assertEq(z, vm.computeCreateAddress(E, N + 4));
        assertTrue(z != c && z != n && z != r);
        // nonces only go up, and no later nonce gives one of the three addresses
        for (uint256 k = N + 3; k < N + 3 + 20000; ++k) {
            address a = vm.computeCreateAddress(E, k);
            assertTrue(a != c && a != n && a != r);
        }
        // the burn also covers an abandoned first deployment at nonces 0 to 2
        for (uint256 k; k < N + 3; ++k) {
            assertTrue(vm.computeCreateAddress(E, k) != vm.computeCreateAddress(E, N + 3));
        }
    }
}

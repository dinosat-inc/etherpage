// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {PageCard} from "../../../src/PageCard.sol";
import {PageNFT} from "../../../src/PageNFT.sol";
import {SubpageRegistrar, IPageNFT} from "../../../src/SubpageRegistrar.sol";

// takes every name sent to it and writes nothing
contract CostReceiver {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}

// shared setup and the gas meter of the cost tests
abstract contract RecordCostBase is Test {
    PageNFT nft;
    SubpageRegistrar reg;

    uint256 constant ETH = 60;
    uint256 constant BTC = 0;
    uint256 constant GRACE = 90 days;
    uint256 constant DECAY = 21 days;

    function setUp() public virtual {
        vm.warp(1_800_000_000);
        nft = new PageNFT(new PageCard());
        reg = new SubpageRegistrar(IPageNFT(address(nft)));
    }

    function _register(string memory label, address to) internal returns (uint256 id) {
        bytes32 secret = keccak256(abi.encode(label, to));
        bytes32 c = nft.makeCommitment(label, to, 0, secret);
        vm.deal(to, to.balance + 1 ether);
        vm.prank(to);
        nft.commit(c);
        vm.warp(vm.getBlockTimestamp() + 61);
        (,,, uint256 total) = nft.quote(label);
        vm.prank(to);
        id = nft.reveal{value: total}(label, to, 0, secret);
    }

    // gas of one call sent by `by`; the call data is built before the meter starts and no return data is copied.
    // It is execution gas inside the test's own transaction, so these tests run without --isolate, which would add
    // the call data cost and cap the refunds of each measured call.
    function _gas(address by, address target, uint256 value, bytes memory data) internal returns (uint256 used) {
        bool ok;
        vm.prank(by);
        uint256 g = gasleft();
        assembly ("memory-safe") {
            ok := call(gas(), target, value, add(data, 0x20), mload(data), 0, 0)
        }
        used = g - gasleft();
        if (!ok) {
            assembly ("memory-safe") {
                let p := mload(0x40)
                returndatacopy(p, 0, returndatasize())
                revert(p, returndatasize())
            }
        }
    }

    // makes the contract accounts warm before the first measurement, so no measured call pays for them
    function _warm() internal view returns (uint256) {
        return address(nft).code.length + address(reg).code.length;
    }

    function _repeat(string memory s, uint256 n) internal pure returns (string memory out) {
        for (uint256 i; i < n; ++i) out = string.concat(out, s);
    }
}

// Two names, each with a main address and an Ethereum entry saved; the second also holds a hundred more chain
// entries, fifty for EVM chains and fifty for other chains, forty text fields and a website. Each test measures
// one call on both names, with their own accounts, from a cold start.
contract RecordScalingGasTest is RecordCostBase {
    address s1 = makeAddr("seller1");
    address s2 = makeAddr("seller2");
    address b1 = makeAddr("buyer1");
    address b2 = makeAddr("buyer2");
    address m1 = makeAddr("main1");
    address m2 = makeAddr("main2");
    address e1 = makeAddr("eth1");
    address e2 = makeAddr("eth2");
    address r1 = makeAddr("registrant1");
    address r2 = makeAddr("registrant2");

    CostReceiver rc1;
    CostReceiver rc2;

    uint256 thin;
    uint256 fat;
    uint256 deposit;
    uint256 auctionEnd;

    uint256 constant EVM_ENTRIES = 50;
    uint256 constant OTHER_ENTRIES = 50;
    uint256 constant FIELDS = 40;
    bytes constant SITE = hex"e3010170122029f2d17be6139079dc48696d1f582a8530eb9805b561eda517e22a892c7e3f1f";

    function setUp() public override {
        super.setUp();
        rc1 = new CostReceiver();
        rc2 = new CostReceiver();
        // one name each, so no ERC721 balance goes to or from zero in a measured call
        address[6] memory all = [s1, s2, b1, b2, address(rc1), address(rc2)];
        for (uint256 i; i < all.length; ++i) {
            uint256 id = _register(string.concat("ballast", vm.toString(i)), s1);
            vm.prank(s1);
            nft.transferFrom(s1, all[i], id);
        }
        thin = _register("thinn", s1);
        fat = _register("fattt", s2);
        deposit = nft.depositOf(fat);
        assertEq(nft.depositOf(thin), deposit, "the two names hold the same deposit");
        _basic(s1, thin, m1, e1);
        _basic(s2, fat, m2, e2);
        _pile(s2, fat);
        assertEq(nft.text(fat, "key40"), "a profile value that fills a slot or two", "the fields are stored");
        assertEq(nft.addr(fat, 1000 + OTHER_ENTRIES), _entry(OTHER_ENTRIES), "the other chains are stored");
        assertEq(nft.addr(fat, 0x80000100 + EVM_ENTRIES), abi.encodePacked(address(uint160(0x1000 + EVM_ENTRIES))));
        assertEq(nft.contenthash(fat), SITE);
        assertEq(nft.text(thin, "key1"), "", "the thin name has no field");
        uint256 end = nft.expiresAt(thin) > nft.expiresAt(fat) ? nft.expiresAt(thin) : nft.expiresAt(fat);
        auctionEnd = end + GRACE + DECAY;
        // a second later, so a measured transfer writes a new holderSince time for both names alike, and not the
        // time fat was just registered at
        vm.warp(vm.getBlockTimestamp() + 1);
    }

    function _basic(address o, uint256 id, address main, address eth) internal {
        vm.startPrank(o);
        nft.setAddr(id, main);
        nft.setAddrForCoin(id, ETH, abi.encodePacked(eth));
        vm.stopPrank();
    }

    function _entry(uint256 i) internal pure returns (bytes memory) {
        return abi.encodePacked(keccak256(abi.encode(i)), keccak256(abi.encode(i + 1)));
    }

    function _pile(address o, uint256 id) internal {
        vm.startPrank(o);
        for (uint256 i = 1; i <= EVM_ENTRIES; ++i) {
            nft.setAddrForCoin(id, 0x80000100 + i, abi.encodePacked(address(uint160(0x1000 + i))));
        }
        for (uint256 i = 1; i <= OTHER_ENTRIES; ++i) {
            nft.setAddrForCoin(id, 1000 + i, _entry(i));
        }
        for (uint256 i = 1; i <= FIELDS; ++i) {
            nft.setText(id, string.concat("key", vm.toString(i)), "a profile value that fills a slot or two");
        }
        nft.setContenthash(id, SITE);
        vm.stopPrank();
    }

    function test_transferCostDoesNotGrowWithRecords() public {
        _warm();
        uint256 gThin = _gas(s1, address(nft), 0, abi.encodeCall(nft.transferFrom, (s1, b1, thin)));
        uint256 gFat = _gas(s2, address(nft), 0, abi.encodeCall(nft.transferFrom, (s2, b2, fat)));
        emit log_named_uint("transferFrom, main and Ethereum saved", gThin);
        emit log_named_uint("transferFrom, plus 100 chain entries, 40 fields and a website", gFat);
        assertEq(gFat, gThin, "a transfer costs the same whatever records the name holds");
        assertEq(nft.ownerOf(fat), b2);
        assertEq(nft.resolve(fat), b2, "the seller's main address stops counting");
        assertEq(nft.addr(fat, 1001), "", "and so do its chain entries");
    }

    function test_safeTransferCostDoesNotGrowWithRecords() public {
        _warm();
        bytes memory d1 = abi.encodeWithSignature(
            "safeTransferFrom(address,address,uint256,bytes)", s1, address(rc1), thin, bytes("listing")
        );
        bytes memory d2 = abi.encodeWithSignature(
            "safeTransferFrom(address,address,uint256,bytes)", s2, address(rc2), fat, bytes("listing")
        );
        uint256 gThin = _gas(s1, address(nft), 0, d1);
        uint256 gFat = _gas(s2, address(nft), 0, d2);
        emit log_named_uint("safeTransferFrom with data to a contract, main and Ethereum saved", gThin);
        emit log_named_uint("same, plus 100 chain entries, 40 fields and a website", gFat);
        assertApproxEqAbs(gFat, gThin, 50, "only the call layout may differ");
        assertEq(nft.ownerOf(fat), address(rc2));
        assertEq(nft.addr(fat, ETH), "", "the seller's coin type 60 entry stops counting and the new holder saved none");
    }

    function test_clearCostIsFixed() public {
        _warm();
        uint256 gThin = _gas(s1, address(nft), 0, abi.encodeCall(nft.clearRecords, (thin)));
        uint256 gFat = _gas(s2, address(nft), 0, abi.encodeCall(nft.clearRecords, (fat)));
        emit log_named_uint("clearRecords, main and Ethereum saved", gThin);
        emit log_named_uint("clearRecords, plus 100 chain entries, 40 fields and a website", gFat);
        assertEq(gFat, gThin, "clearRecords is one version increment and the address time");
        assertEq(nft.text(fat, "key7"), "");
        assertEq(nft.contenthash(fat), "");
        assertEq(nft.addr(fat, 1003), "");
        assertEq(nft.addr(fat, 0x80000105), "", "an EVM chain entry is gone and no default is saved");
        assertEq(nft.addr(fat, ETH), "", "so is the coin type 60 entry");
        assertEq(nft.resolve(fat), s2);
    }

    function test_reRegistrationCostDoesNotGrowWithRecords() public {
        // past the premium period, so each old deposit goes back to its payee first and each pays the yearly fee alone
        vm.warp(auctionEnd + 1);
        bytes32 k1 = keccak256("k1");
        bytes32 k2 = keccak256("k2");
        bytes32 c1 = nft.makeCommitment("thinn", r1, 0, k1);
        bytes32 c2 = nft.makeCommitment("fattt", r2, 0, k2);
        vm.prank(r1);
        nft.commit(c1);
        vm.prank(r2);
        nft.commit(c2);
        vm.warp(vm.getBlockTimestamp() + 61);
        uint256 total = nft.getFee(5);
        vm.deal(r1, total);
        vm.deal(r2, total);
        _warm();
        // the loaded name goes first, so any slot the two calls share is cold for it
        uint256 gFat = _gas(r2, address(nft), total, abi.encodeCall(nft.reveal, ("fattt", r2, 0, k2)));
        uint256 gThin = _gas(r1, address(nft), total, abi.encodeCall(nft.reveal, ("thinn", r1, 0, k1)));
        emit log_named_uint("re-registration after the premium period, main and Ethereum saved", gThin);
        emit log_named_uint("same, plus 100 chain entries, 40 fields and a website", gFat);
        assertApproxEqAbs(gFat, gThin, 2100, "the burn and the version increment do not touch the old records");
        assertEq(nft.ownerOf(fat), r2);
        assertEq(nft.owed(m2), deposit, "the old deposit went to the old main address");
        assertEq(nft.owed(m1), deposit);
        assertEq(nft.text(fat, "key1"), "");
        assertEq(nft.addr(fat, 1001), "");
        assertEq(nft.contenthash(fat), "");
    }
}

// A sale under a parent of 5 characters and under one of 63, the longest a label can be, with the registrar as
// each parent's counted minter. No call of the sale copies the parent's label.
contract SaleLabelGasTest is RecordCostBase {
    address c1 = makeAddr("controller1");
    address c2 = makeAddr("controller2");
    address p1 = makeAddr("payout1");
    address p2 = makeAddr("payout2");
    address x1 = makeAddr("subbuyer1");
    address x2 = makeAddr("subbuyer2");

    uint256 shortParent;
    uint256 longParent;
    uint256 constant PRICE = 0.001 ether;

    function setUp() public override {
        super.setUp();
        shortParent = _register("short", c1);
        longParent = _register(_repeat("a", 63), c2);
        assertEq(bytes(nft.getPageName(longParent)).length, 63);
        _shop(c1, shortParent, p1);
        _shop(c2, longParent, p2);
        vm.deal(x1, 1 ether);
        vm.deal(x2, 1 ether);
    }

    function _shop(address c, uint256 parent, address payout) internal {
        vm.startPrank(c);
        nft.setSubpageMinter(parent, address(reg));
        reg.configure(parent, payout, address(0), PRICE, true, address(0), 0, false);
        vm.stopPrank();
    }

    function test_saleCostDoesNotGrowWithParentLabel() public {
        _warm();
        uint256 gShort = _gas(
            x1, address(reg), PRICE, abi.encodeCall(reg.registerSubpage, (shortParent, "shop", PRICE, address(0)))
        );
        uint256 gLong = _gas(
            x2, address(reg), PRICE, abi.encodeCall(reg.registerSubpage, (longParent, "shop", PRICE, address(0)))
        );
        emit log_named_uint("registrar sale, parent label of 5", gShort);
        emit log_named_uint("registrar sale, parent label of 63", gLong);
        assertApproxEqAbs(gLong, gShort, 100, "the parent's label is never copied");
        assertEq(nft.getPageName(uint256(keccak256(abi.encodePacked(bytes32(longParent), keccak256("shop"))))),
            string.concat("shop.", _repeat("a", 63)));
        assertEq(reg.proceedsOf(p1), PRICE);
        assertEq(reg.proceedsOf(p2), PRICE);
    }
}

// A seller leaves a very large entry. A buyer that overwrites it pays in proportion to its size; clearRecords
// retires it at a fixed cost, and a save after the clear costs the same whatever the seller planted.
// A large data record works the same way as a large entry.
// A large text field is different: the buyer's first write starts an empty profile, unless the buyer keeps the
// seller's profile first.
contract PlantedEntryGasTest is RecordCostBase {
    address sDataSmall = makeAddr("plantDataSmall");
    address sDataBig = makeAddr("plantDataBig");
    address sDataNone = makeAddr("plantDataNone");
    address bDataSmall = makeAddr("buyerDataSmall");
    address bDataBig = makeAddr("buyerDataBig");
    address bDataNone = makeAddr("buyerDataNone");
    address sSmall = makeAddr("plantSmall");
    address sBig = makeAddr("plantBig");
    address sBig2 = makeAddr("plantBig2");
    address sNone = makeAddr("plantNone");
    address sText = makeAddr("plantText");
    address sText2 = makeAddr("plantText2");
    address sShort = makeAddr("shortText");
    address sShort2 = makeAddr("shortText2");
    address bSmall = makeAddr("buyerSmall");
    address bBig = makeAddr("buyerBig");
    address bBig2 = makeAddr("buyerBig2");
    address bNone = makeAddr("buyerNone");
    address bText = makeAddr("buyerText");
    address bText2 = makeAddr("buyerText2");
    address bShort = makeAddr("buyerShort");
    address bShort2 = makeAddr("buyerShort2");

    uint256 small;
    uint256 big;
    uint256 big2;
    uint256 none;
    uint256 bigText;
    uint256 bigText2;
    uint256 shortText;
    uint256 shortText2;
    uint256 dataSmall;
    uint256 dataBig;
    uint256 dataNone;
    uint256 plantCost;
    uint256 plantDataCost;

    uint256 constant SMALL_SLOTS = 50;
    uint256 constant BIG_SLOTS = 500;
    bytes constant BTC_ADDR = hex"0014751e76e8199196d454941c45d1b3a323f1433bd6";

    function setUp() public override {
        super.setUp();
        dataSmall = _register("data-small", sDataSmall);
        dataBig = _register("data-big", sDataBig);
        dataNone = _register("data-none", sDataNone);
        vm.prank(sDataSmall);
        nft.setData(dataSmall, "pay", _blob(SMALL_SLOTS));
        bytes memory plant = abi.encodeCall(nft.setData, (dataBig, "pay", _blob(BIG_SLOTS)));
        plantDataCost = _gas(sDataBig, address(nft), 0, plant);
        vm.prank(sDataNone);
        nft.setData(dataNone, "pay", hex"01");
        _sell(sDataSmall, bDataSmall, dataSmall);
        _sell(sDataBig, bDataBig, dataBig);
        _sell(sDataNone, bDataNone, dataNone);
        assertEq(nft.data(bytes32(dataBig), "pay"), "", "the seller's record does not count for the buyer");
        small = _register("plant-small", sSmall);
        big = _register("plant-big", sBig);
        big2 = _register("plant-big2", sBig2);
        none = _register("plant-none", sNone);
        bigText = _register("text-big", sText);
        bigText2 = _register("text-big2", sText2);
        shortText = _register("text-short", sShort);
        shortText2 = _register("text-short2", sShort2);
        bytes memory s = _blob(SMALL_SLOTS);
        bytes memory b = _blob(BIG_SLOTS);
        vm.prank(sSmall);
        nft.setAddrForCoin(small, BTC, s);
        plantCost = _gas(sBig, address(nft), 0, abi.encodeCall(nft.setAddrForCoin, (big, BTC, b)));
        vm.prank(sBig2);
        nft.setAddrForCoin(big2, BTC, b);
        vm.prank(sNone);
        nft.setAddrForCoin(none, BTC, BTC_ADDR);
        vm.prank(sText);
        nft.setText(bigText, "bio", string(b));
        vm.prank(sText2);
        nft.setText(bigText2, "bio", string(b));
        vm.prank(sShort);
        nft.setText(shortText, "bio", "hi");
        vm.prank(sShort2);
        nft.setText(shortText2, "bio", "hi");
        _sell(sSmall, bSmall, small);
        _sell(sBig, bBig, big);
        _sell(sBig2, bBig2, big2);
        _sell(sNone, bNone, none);
        _sell(sText, bText, bigText);
        _sell(sText2, bText2, bigText2);
        _sell(sShort, bShort, shortText);
        _sell(sShort2, bShort2, shortText2);
        // read here, as a read inside a test would warm the slots it measures
        assertEq(nft.addr(big, BTC), "", "the seller's entry does not count for the buyer");
        assertEq(nft.text(bigText, "bio"), "", "the seller's profile does not count for the buyer");
    }

    // bytes that fill n storage slots, none of them zero
    function _blob(uint256 n) internal pure returns (bytes memory out) {
        out = new bytes(n * 32);
        for (uint256 i; i < out.length; i += 32) out[i] = 0x01;
    }

    function _sell(address seller, address buyer, uint256 id) internal {
        vm.prank(seller);
        nft.transferFrom(seller, buyer, id);
    }

    function test_plantedLargeEntryMakesOverwriteCostlyButClearIsCheap() public {
        _warm();
        bytes memory save = abi.encodeCall(nft.setAddrForCoin, (small, BTC, BTC_ADDR));
        uint256 overSmall = _gas(bSmall, address(nft), 0, save);
        save = abi.encodeCall(nft.setAddrForCoin, (big, BTC, BTC_ADDR));
        uint256 overBig = _gas(bBig, address(nft), 0, save);
        uint256 clearBig = _gas(bBig2, address(nft), 0, abi.encodeCall(nft.clearRecords, (big2)));
        uint256 clearNone = _gas(bNone, address(nft), 0, abi.encodeCall(nft.clearRecords, (none)));
        save = abi.encodeCall(nft.setAddrForCoin, (big2, BTC, BTC_ADDR));
        uint256 afterBig = _gas(bBig2, address(nft), 0, save);
        save = abi.encodeCall(nft.setAddrForCoin, (none, BTC, BTC_ADDR));
        uint256 afterNone = _gas(bNone, address(nft), 0, save);

        emit log_named_uint("the seller plants 500 slots as a Bitcoin entry", plantCost);
        emit log_named_uint("the buyer overwrites a 50 slot entry", overSmall);
        emit log_named_uint("the buyer overwrites a 500 slot entry", overBig);
        emit log_named_uint("clearRecords over a 500 slot entry", clearBig);
        emit log_named_uint("clearRecords over a one slot entry", clearNone);
        emit log_named_uint("the Bitcoin save after the clear, 500 slots planted", afterBig);
        emit log_named_uint("the Bitcoin save after the clear, one slot planted", afterNone);

        // each slot of the seller's entry is zeroed by the overwrite: a cold write to zero is 5000 gas
        assertGe(overBig - overSmall, (BIG_SLOTS - SMALL_SLOTS) * 5000, "the overwrite grows with the entry");
        assertEq(clearBig, clearNone, "clearRecords costs the same whatever is planted");
        assertEq(afterBig, afterNone, "after the clear the save costs the ordinary price");
        assertGt(overBig, 20 * (clearBig + afterBig), "clearing first is far cheaper");
        assertLt(overBig * 3, plantCost, "the overwrite costs a fraction of what the planting cost");
        assertEq(nft.addr(big, BTC), BTC_ADDR);
        assertEq(nft.addr(big2, BTC), BTC_ADDR);
        assertEq(nft.addr(small, BTC), BTC_ADDR);
    }

    function test_plantedLargeTextCostsTheBuyerNothingUnlessKept() public {
        _warm();
        bytes memory w = abi.encodeCall(nft.setText, (bigText, "bio", "mine"));
        uint256 overBig = _gas(bText, address(nft), 0, w);
        w = abi.encodeCall(nft.setText, (shortText, "bio", "mine"));
        uint256 overShort = _gas(bShort, address(nft), 0, w);
        // keeping the seller's profile first makes the buyer write into it
        vm.prank(bText2);
        nft.keepProfile(bigText2);
        vm.prank(bShort2);
        nft.keepProfile(shortText2);
        w = abi.encodeCall(nft.setText, (bigText2, "bio", "mine"));
        uint256 keptBig = _gas(bText2, address(nft), 0, w);
        w = abi.encodeCall(nft.setText, (shortText2, "bio", "mine"));
        uint256 keptShort = _gas(bShort2, address(nft), 0, w);

        emit log_named_uint("the buyer's first field write, 500 slots planted", overBig);
        emit log_named_uint("the buyer's first field write, 2 bytes planted", overShort);
        emit log_named_uint("the same write after keepProfile, 500 slots planted", keptBig);
        emit log_named_uint("the same write after keepProfile, 2 bytes planted", keptShort);

        assertEq(overBig, overShort, "a new holder's first write starts an empty profile");
        assertGe(keptBig - keptShort, (BIG_SLOTS - 1) * 5000, "a kept profile is overwritten in place");
        assertEq(nft.text(bigText, "bio"), "mine");
        assertEq(nft.text(bigText2, "bio"), "mine");
    }

    // gas of one call made from the state the test started in, with every slot of the name contract cold, as in a
    // transaction of its own. It gives the same figure whether or not forge runs each call of a test on its own.
    function _fromStart(uint256 snap, address by, bytes memory data) internal returns (uint256) {
        vm.revertToState(snap);
        vm.cool(address(nft));
        return _gas(by, address(nft), 0, data);
    }

    // the same call on a cold contract, in the state the last call left
    function _next(address by, bytes memory data) internal returns (uint256) {
        vm.cool(address(nft));
        return _gas(by, address(nft), 0, data);
    }

    // a data record is saved in place, like an entry: the buyer's first save on the seller's key zeroes what the
    // seller left there
    function test_plantedLargeDataRecordMakesOverwriteCostlyButClearIsCheap() public {
        _warm();
        uint256 snap = vm.snapshotState();
        uint256 overSmall = _fromStart(snap, bDataSmall, abi.encodeCall(nft.setData, (dataSmall, "pay", hex"01")));
        uint256 overBig = _fromStart(snap, bDataBig, abi.encodeCall(nft.setData, (dataBig, "pay", hex"01")));
        assertEq(nft.data(bytes32(dataBig), "pay"), hex"01");
        uint256 clearBig = _fromStart(snap, bDataBig, abi.encodeCall(nft.clearRecords, (dataBig)));
        uint256 afterBig = _next(bDataBig, abi.encodeCall(nft.setData, (dataBig, "pay", hex"01")));
        assertEq(nft.data(bytes32(dataBig), "pay"), hex"01");
        uint256 clearNone = _fromStart(snap, bDataNone, abi.encodeCall(nft.clearRecords, (dataNone)));
        uint256 afterNone = _next(bDataNone, abi.encodeCall(nft.setData, (dataNone, "pay", hex"01")));
        assertEq(nft.data(bytes32(dataNone), "pay"), hex"01");

        emit log_named_uint("the seller plants 500 slots as a data record", plantDataCost);
        emit log_named_uint("the buyer overwrites a 50 slot record", overSmall);
        emit log_named_uint("the buyer overwrites a 500 slot record", overBig);
        emit log_named_uint("clearRecords over a 500 slot record", clearBig);
        emit log_named_uint("clearRecords over a one byte record", clearNone);
        emit log_named_uint("the save after the clear, 500 slots planted", afterBig);
        emit log_named_uint("the save after the clear, one byte planted", afterNone);

        // each slot of the seller's record is zeroed by the overwrite: a cold write to zero is 5000 gas
        assertGe(overBig - overSmall, (BIG_SLOTS - SMALL_SLOTS) * 5000, "the overwrite grows with the record");
        assertLt(overBig * 3, plantDataCost, "the overwrite costs a fraction of what the planting cost");
        assertEq(clearBig, clearNone, "clearRecords costs the same whatever is planted");
        assertEq(afterBig, afterNone, "after the clear the save costs the ordinary price");
    }
}

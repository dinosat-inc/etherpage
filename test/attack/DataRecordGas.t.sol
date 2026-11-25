// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {RecordCostBase} from "../unit/costs/RecordScalingGas.t.sol";

// A holder fills a page with large data records before it changes hands. No call that moves, renews or registers the
// page again reads them, so it costs no more than on a page with none. Each measurement starts from the same
// snapshot with the contract's storage cold, and two pages with no data give the spread to compare against.
contract DataRecordGasTest is RecordCostBase {
    address s1 = makeAddr("g-s1");
    address s2 = makeAddr("g-s2");
    address s3 = makeAddr("g-s3");
    address b1 = makeAddr("g-b1");
    address b2 = makeAddr("g-b2");
    address b3 = makeAddr("g-b3");
    address r1 = makeAddr("g-r1");
    address r2 = makeAddr("g-r2");
    address r3 = makeAddr("g-r3");
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    uint256 thinA;
    uint256 thinB;
    uint256 fat;
    uint256 auctionEnd;

    uint256 constant RECORDS = 20;
    uint256 constant SIZE = 2048;

    function _blob(uint256 n) internal pure returns (bytes memory out) {
        out = new bytes(n);
        for (uint256 i; i < n; i += 32) out[i] = 0x01;
    }

    function setUp() public override {
        super.setUp();
        // one page each for the buyers, so no ERC721 balance goes to or from zero in a measured call
        address[3] memory buyers = [b1, b2, b3];
        for (uint256 i; i < 3; ++i) {
            uint256 id = _register(string.concat("ballast", vm.toString(i)), s1);
            vm.prank(s1);
            nft.transferFrom(s1, buyers[i], id);
        }
        thinA = _register("thina", s1);
        thinB = _register("thinb", s2);
        fat = _register("fatty", s3);
        _basic(s1, thinA, address(0x11), address(0x12));
        _basic(s2, thinB, address(0x21), address(0x22));
        _basic(s3, fat, address(0x31), address(0x32));
        vm.startPrank(s3);
        for (uint256 i; i < RECORDS; ++i) nft.setData(fat, string.concat("key", vm.toString(i)), _blob(SIZE));
        nft.setData(fat, "", _blob(SIZE));
        vm.stopPrank();
        assertEq(nft.data(bytes32(fat), "key3").length, SIZE, "the records are stored");
        auctionEnd = nft.expiresAt(fat) + GRACE + DECAY;
        vm.warp(vm.getBlockTimestamp() + 1);
    }

    function _basic(address o, uint256 id, address main, address eth) internal {
        vm.startPrank(o);
        nft.setAddr(id, main);
        nft.setAddrForCoin(id, ETH, abi.encodePacked(eth));
        vm.stopPrank();
    }

    function _measure(address by, uint256 value, bytes memory d) internal returns (uint256 g) {
        uint256 snap = vm.snapshotState();
        _warm();
        vm.cool(address(nft));
        g = _gas(by, address(nft), value, d);
        vm.revertToState(snap);
    }

    function _absDiff(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : b - a;
    }

    function _check(string memory what, uint256 gA, uint256 gB, uint256 gF) internal {
        emit log_named_uint(string.concat(what, ", no data A"), gA);
        emit log_named_uint(string.concat(what, ", no data B"), gB);
        emit log_named_uint(string.concat(what, ", 21 data records of 2 KB"), gF);
        uint256 spread = _absDiff(gA, gB);
        assertLe(_absDiff(gF, gA), spread, "no more than the spread from A");
        assertLe(_absDiff(gF, gB), spread, "no more than the spread from B");
    }

    function test_transferCostDoesNotDependOnData() public {
        uint256 gA = _measure(s1, 0, abi.encodeCall(nft.transferFrom, (s1, b1, thinA)));
        uint256 gB = _measure(s2, 0, abi.encodeCall(nft.transferFrom, (s2, b2, thinB)));
        uint256 gF = _measure(s3, 0, abi.encodeCall(nft.transferFrom, (s3, b3, fat)));
        _check("transferFrom", gA, gB, gF);
    }

    function test_transferToDeadCostDoesNotDependOnData() public {
        uint256 gA = _measure(s1, 0, abi.encodeCall(nft.transferFrom, (s1, DEAD, thinA)));
        uint256 gB = _measure(s2, 0, abi.encodeCall(nft.transferFrom, (s2, DEAD, thinB)));
        uint256 gF = _measure(s3, 0, abi.encodeCall(nft.transferFrom, (s3, DEAD, fat)));
        _check("transferFrom to DEAD", gA, gB, gF);
    }

    function test_renewCostDoesNotDependOnData() public {
        uint256 fee = nft.getFee(5);
        vm.deal(r1, 1 ether);
        uint256 gA = _measure(r1, fee, abi.encodeCall(nft.renew, (thinA)));
        uint256 gB = _measure(r1, fee, abi.encodeCall(nft.renew, (thinB)));
        uint256 gF = _measure(r1, fee, abi.encodeCall(nft.renew, (fat)));
        _check("renew", gA, gB, gF);
    }

    function test_reRegistrationCostDoesNotDependOnData() public {
        vm.warp(auctionEnd + 1);
        bytes32 k = keccak256("k");
        bytes32 c1 = nft.makeCommitment("thina", r1, 0, k);
        bytes32 c2 = nft.makeCommitment("thinb", r2, 0, k);
        bytes32 c3 = nft.makeCommitment("fatty", r3, 0, k);
        vm.prank(r1);
        nft.commit(c1);
        vm.prank(r2);
        nft.commit(c2);
        vm.prank(r3);
        nft.commit(c3);
        vm.warp(vm.getBlockTimestamp() + 61);
        uint256 fee = nft.getFee(5);
        vm.deal(r1, 1 ether);
        vm.deal(r2, 1 ether);
        vm.deal(r3, 1 ether);
        uint256 gA = _measure(r1, fee, abi.encodeCall(nft.reveal, ("thina", r1, 0, k)));
        uint256 gB = _measure(r2, fee, abi.encodeCall(nft.reveal, ("thinb", r2, 0, k)));
        uint256 gF = _measure(r3, fee, abi.encodeCall(nft.reveal, ("fatty", r3, 0, k)));
        _check("registration after the premium period", gA, gB, gF);
    }
}

// A sale over a subpage DEAD holds costs the same whether or not large data records were left in it.
contract DataRecordSaleGasTest is RecordCostBase {
    address c = makeAddr("s-controller");
    address xA = makeAddr("s-xa");
    address xB = makeAddr("s-xb");
    address xF = makeAddr("s-xf");
    address yA = makeAddr("s-ya");
    address yB = makeAddr("s-yb");
    address yF = makeAddr("s-yf");
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 club;

    function _blob(uint256 n) internal pure returns (bytes memory out) {
        out = new bytes(n);
        for (uint256 i; i < n; i += 32) out[i] = 0x01;
    }

    function setUp() public override {
        super.setUp();
        club = _register("club", c);
        vm.startPrank(c);
        nft.setSubpageMinter(club, address(reg));
        reg.configure(club, c, address(0), 0, true, address(0), 0, false);
        uint256 a = nft.registerSubpageFor("suba", club, xA);
        uint256 b = nft.registerSubpageFor("subb", club, xB);
        uint256 f = nft.registerSubpageFor("subf", club, xF);
        vm.stopPrank();
        vm.prank(xA);
        nft.setAddr(a, address(0x97));
        vm.prank(xB);
        nft.setAddr(b, address(0x98));
        vm.startPrank(xF);
        for (uint256 i; i < 20; ++i) nft.setData(f, string.concat("key", vm.toString(i)), _blob(2048));
        nft.setAddr(f, address(0x99));
        vm.stopPrank();
        vm.prank(xA);
        nft.transferFrom(xA, DEAD, a);
        vm.prank(xB);
        nft.transferFrom(xB, DEAD, b);
        vm.prank(xF);
        nft.transferFrom(xF, DEAD, f);
        assertTrue(nft.isAvailable("subf", club));
        vm.warp(vm.getBlockTimestamp() + 1);
    }

    function _measure(address by, bytes memory d) internal returns (uint256 g) {
        uint256 snap = vm.snapshotState();
        _warm();
        vm.cool(address(nft));
        vm.cool(address(reg));
        g = _gas(by, address(reg), 0, d);
        vm.revertToState(snap);
    }

    function test_saleOverADeletedSubpageDoesNotDependOnData() public {
        uint256 gA = _measure(yA, abi.encodeCall(reg.registerSubpage, (club, "suba", 0, address(0))));
        uint256 gB = _measure(yB, abi.encodeCall(reg.registerSubpage, (club, "subb", 0, address(0))));
        uint256 gF = _measure(yF, abi.encodeCall(reg.registerSubpage, (club, "subf", 0, address(0))));
        emit log_named_uint("sale over a deleted subpage, no data A", gA);
        emit log_named_uint("sale over a deleted subpage, no data B", gB);
        emit log_named_uint("sale over a deleted subpage, 20 data records of 2 KB", gF);
        uint256 spread = gA > gB ? gA - gB : gB - gA;
        assertLe(gF > gA ? gF - gA : gA - gF, spread, "the old data records are never touched");
    }
}

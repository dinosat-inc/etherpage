// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {PageCard} from "../../src/PageCard.sol";
import {PageNFT} from "../../src/PageNFT.sol";
import {SubpageRegistrar, IPageNFT} from "../../src/SubpageRegistrar.sol";
import {PageNFTNoRecycle} from "../differential/harness/PageNFTNoRecycle.sol";
import {SubpageRegistrarNoRecycle, IPageNFTNoRecycle} from "../differential/harness/SubpageRegistrarNoRecycle.sol";

// Gas of PageNFT (B), where a subpage held by the dead address is free to mint again, against the
// PageNFTNoRecycle reference (A), where it stays taken. The same calls run on the same state. Run with
// the isolate option so each call is its own transaction, base cost included.
contract RecycleGasTest is Test {
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    PageNFT b;
    PageNFTNoRecycle a;
    SubpageRegistrar rb;
    SubpageRegistrarNoRecycle ra;
    address seller = makeAddr("seller");
    address buyer = makeAddr("buyer");
    address hot = makeAddr("hot");
    address carol = makeAddr("carol");
    uint256 pa;
    uint256 pb;

    function setUp() public {
        vm.warp(1_800_000_000);
        PageCard card = new PageCard();
        b = new PageNFT(card);
        a = new PageNFTNoRecycle(card);
        rb = new SubpageRegistrar(IPageNFT(address(b)));
        ra = new SubpageRegistrarNoRecycle(IPageNFTNoRecycle(address(a)));
        vm.deal(seller, 100 ether);
        vm.deal(buyer, 100 ether);
        pa = _reg(address(a), "club");
        pb = _reg(address(b), "club");
    }

    function _g() internal view returns (uint256) {
        return vm.lastCallGas().gasTotalUsed;
    }

    function _reg(address n, string memory label) internal returns (uint256 id) {
        bytes32 s = keccak256(abi.encode(label, n));
        bytes32 c = PageNFT(n).makeCommitment(label, seller, 0, s);
        vm.prank(seller);
        PageNFT(n).commit(c);
        vm.warp(vm.getBlockTimestamp() + 61);
        (,,, uint256 total) = PageNFT(n).quote(label);
        vm.prank(seller);
        id = PageNFT(n).reveal{value: total}(label, seller, 0, s);
    }

    function _both(bytes memory data, address who) internal returns (uint256 ga, uint256 gb, bool oka, bool okb) {
        vm.prank(who);
        (oka,) = address(a).call(data);
        ga = _g();
        vm.prank(who);
        (okb,) = address(b).call(data);
        gb = _g();
    }

    function _log(string memory what, uint256 ga, uint256 gb) internal {
        emit log_named_uint(string.concat(what, ", without the recycle bin"), ga);
        emit log_named_uint(string.concat(what, ", with the recycle bin"), gb);
    }

    function test_gas_views() public {
        vm.startPrank(seller);
        a.registerSubpageFor("held", pa, carol);
        b.registerSubpageFor("held", pb, carol);
        a.registerSubpageFor("dead", pa, DEAD);
        b.registerSubpageFor("dead", pb, DEAD);
        vm.stopPrank();
        uint256 ga;
        uint256 gb;
        a.isAvailable("fresh", pa);
        ga = _g();
        b.isAvailable("fresh", pb);
        gb = _g();
        _log("isAvailable, no record", ga, gb);
        assertTrue(a.isAvailable("held", pa) == b.isAvailable("held", pb));
        a.isAvailable("held", pa);
        ga = _g();
        b.isAvailable("held", pb);
        gb = _g();
        _log("isAvailable, live subpage held by an account", ga, gb);
        assertFalse(a.isAvailable("dead", pa));
        assertTrue(b.isAvailable("dead", pb));
        a.isAvailable("dead", pa);
        ga = _g();
        b.isAvailable("dead", pb);
        gb = _g();
        _log("isAvailable, live subpage held by DEAD (A false, B true)", ga, gb);
        a.isAvailable("club", 0);
        ga = _g();
        b.isAvailable("club", 0);
        gb = _g();
        _log("isAvailable, top-level", ga, gb);
    }

    function test_gas_mints() public {
        vm.prank(seller);
        a.setSubpageMinter(pa, hot);
        vm.prank(seller);
        b.setSubpageMinter(pb, hot);
        (uint256 ga, uint256 gb,,) = _both(abi.encodeWithSignature("registerSubpageFor(string,uint256,address)", "abcd", pa, carol), hot);
        _log("minter mint, fresh label", ga, gb);
        (ga, gb,,) = _both(abi.encodeWithSignature("registerSubpageFor(string,uint256,address)", "abcd", pa, carol), seller);
        _log("holder re-mint of a live subpage held by an account", ga, gb);
        bool oka;
        bool okb;
        (ga, gb, oka, okb) = _both(abi.encodeWithSignature("registerSubpageFor(string,uint256,address)", "abcd", pa, hot), hot);
        assertFalse(oka || okb);
        _log("minter refused over a live subpage (revert)", ga, gb);
        (ga, gb,,) = _both(abi.encodeWithSignature("registerSubpageFor(string,uint256,address)", "abcd", pa, DEAD), seller);
        _log("holder re-mint to DEAD (take back and free)", ga, gb);
        (ga, gb, oka, okb) = _both(abi.encodeWithSignature("registerSubpageFor(string,uint256,address)", "abcd", pa, carol), hot);
        assertFalse(oka);
        assertTrue(okb);
        _log("minter mint over DEAD (A refuses, B mints)", ga, gb);
        vm.prank(carol);
        b.transferFrom(carol, DEAD, uint256(keccak256(abi.encodePacked(bytes32(pb), keccak256("abcd")))));
        emit log_named_uint("subpage holder sends to DEAD, with the recycle bin", _g());
    }

    function test_gas_sales() public {
        vm.startPrank(seller);
        a.setSubpageMinter(pa, address(ra));
        b.setSubpageMinter(pb, address(rb));
        ra.configure(pa, seller, address(0), 0.01 ether, true, address(0), 0, false);
        rb.configure(pb, seller, address(0), 0.01 ether, true, address(0), 0, false);
        a.registerSubpageFor("dead", pa, DEAD);
        b.registerSubpageFor("dead", pb, DEAD);
        vm.stopPrank();
        vm.prank(buyer);
        ra.registerSubpage{value: 0.01 ether}(pa, "abcd", 0.01 ether, address(0));
        uint256 ga = _g();
        vm.prank(buyer);
        rb.registerSubpage{value: 0.01 ether}(pb, "abcd", 0.01 ether, address(0));
        uint256 gb = _g();
        _log("sale, fresh label", ga, gb);
        vm.prank(buyer);
        (bool oka,) = address(ra).call{value: 0.01 ether}(
            abi.encodeCall(SubpageRegistrarNoRecycle.registerSubpage, (pa, "dead", 0.01 ether, address(0)))
        );
        ga = _g();
        vm.prank(buyer);
        rb.registerSubpage{value: 0.01 ether}(pb, "dead", 0.01 ether, address(0));
        gb = _g();
        assertFalse(oka);
        _log("sale of a DEAD-held label (A refuses, B sells)", ga, gb);
    }
}

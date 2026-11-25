// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {PageCard} from "../../src/PageCard.sol";
import {PageNFT} from "../../src/PageNFT.sol";
import {SubpageRegistrar, IPageNFT} from "../../src/SubpageRegistrar.sol";
import {PageNFTRecycle} from "../differential/harness/PageNFTRecycle.sol";
import {SubpageRegistrarRecycle, IPageNFTRecycle} from "../differential/harness/SubpageRegistrarRecycle.sol";

// Gas of PageNFT (b), where a page held by the dead address reads as deleted, against the
// PageNFTRecycle reference (a), the same calls on the same state. Run with the isolate option so each
// call is its own transaction, base cost included.
contract DeletedGasTest is Test {
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    PageNFT b;
    PageNFTRecycle a;
    SubpageRegistrar rb;
    SubpageRegistrarRecycle ra;
    address seller = makeAddr("seller");
    address buyer = makeAddr("buyer");
    address hot = makeAddr("hot");
    address carol = makeAddr("carol");
    address dave = makeAddr("dave");
    uint256 p;

    function setUp() public {
        vm.warp(1_800_000_000);
        PageCard card = new PageCard();
        b = new PageNFT(card);
        a = new PageNFTRecycle(card);
        rb = new SubpageRegistrar(IPageNFT(address(b)));
        ra = new SubpageRegistrarRecycle(IPageNFTRecycle(address(a)));
        vm.deal(seller, 100 ether);
        vm.deal(buyer, 100 ether);
        bytes32 s = keccak256("s");
        vm.startPrank(seller);
        a.commit(a.makeCommitment("club", seller, 0, s));
        b.commit(b.makeCommitment("club", seller, 0, s));
        vm.warp(vm.getBlockTimestamp() + 61);
        (,,, uint256 total) = b.quote("club");
        p = b.reveal{value: total}("club", seller, 0, s);
        a.reveal{value: total}("club", seller, 0, s);
        a.setSubpageMinter(p, hot);
        b.setSubpageMinter(p, hot);
        vm.stopPrank();
    }

    function _g() internal view returns (uint256) {
        return vm.lastCallGas().gasTotalUsed;
    }

    function _sid(string memory l) internal view returns (uint256) {
        return uint256(keccak256(abi.encodePacked(bytes32(p), keccak256(bytes(l)))));
    }

    function _both(string memory what, address who, bytes memory data) internal {
        vm.prank(who);
        (bool oka,) = address(a).call(data);
        uint256 ga = _g();
        vm.prank(who);
        (bool okb,) = address(b).call(data);
        uint256 gb = _g();
        assertEq(oka, okb, what);
        emit log_named_uint(string.concat(what, ", recycle build"), ga);
        emit log_named_uint(string.concat(what, ", deleted rule"), gb);
        emit log_named_int(string.concat(what, ", difference"), int256(gb) - int256(ga));
    }

    function _view(string memory what, bytes memory data) internal {
        (bool oka,) = address(a).staticcall(data);
        uint256 ga = _g();
        (bool okb,) = address(b).staticcall(data);
        uint256 gb = _g();
        assertTrue(oka && okb);
        emit log_named_uint(string.concat(what, ", recycle build"), ga);
        emit log_named_uint(string.concat(what, ", deleted rule"), gb);
        emit log_named_int(string.concat(what, ", difference"), int256(gb) - int256(ga));
    }

    function _mint(string memory l, address to) internal {
        vm.startPrank(seller);
        a.registerSubpageFor(l, p, to);
        b.registerSubpageFor(l, p, to);
        vm.stopPrank();
    }

    function test_gas_writes() public {
        _both("mint of a fresh subpage by the holder", seller, abi.encodeWithSignature("registerSubpageFor(string,uint256,address)", "live", p, carol));
        _both("setAddr on a live subpage", carol, abi.encodeWithSignature("setAddr(uint256,address)", _sid("live"), dave));
        _both("setText on a live subpage", carol, abi.encodeWithSignature("setText(uint256,string,string)", _sid("live"), "url", "x"));
        _both("transfer of a live subpage between holders", carol, abi.encodeWithSignature("transferFrom(address,address,uint256)", carol, dave, _sid("live")));
        _both("transfer of a live subpage to DEAD (delete)", dave, abi.encodeWithSignature("transferFrom(address,address,uint256)", dave, DEAD, _sid("live")));
        _both("holder re-mint over a deleted subpage", seller, abi.encodeWithSignature("registerSubpageFor(string,uint256,address)", "live", p, carol));
        _both("holder re-mint of a live subpage straight to DEAD", seller, abi.encodeWithSignature("registerSubpageFor(string,uint256,address)", "live", p, DEAD));
        _both("minter mint over a deleted subpage", hot, abi.encodeWithSignature("registerSubpageFor(string,uint256,address)", "live", p, carol));
        _both("minter mint of a fresh subpage straight to DEAD", hot, abi.encodeWithSignature("registerSubpageFor(string,uint256,address)", "gone", p, DEAD));
        _both("transfer of a top-level name", seller, abi.encodeWithSignature("transferFrom(address,address,uint256)", seller, carol, p));
        _both("setAddr on a top-level name", carol, abi.encodeWithSignature("setAddr(uint256,address)", p, dave));
        _both("transfer of a top-level name to DEAD (delete)", carol, abi.encodeWithSignature("transferFrom(address,address,uint256)", carol, DEAD, p));
    }

    function test_gas_sale() public {
        vm.startPrank(seller);
        a.setSubpageMinter(p, address(ra));
        b.setSubpageMinter(p, address(rb));
        ra.configure(p, seller, address(0), 0.01 ether, true, address(0), 0, false);
        rb.configure(p, seller, address(0), 0.01 ether, true, address(0), 0, false);
        vm.stopPrank();
        _mint("dead", DEAD);
        vm.prank(buyer);
        ra.registerSubpage{value: 0.01 ether}(p, "fresh", 0.01 ether, address(0));
        uint256 ga = _g();
        vm.prank(buyer);
        rb.registerSubpage{value: 0.01 ether}(p, "fresh", 0.01 ether, address(0));
        uint256 gb = _g();
        emit log_named_int("sale of a fresh label, difference", int256(gb) - int256(ga));
        emit log_named_uint("sale of a fresh label, deleted rule", gb);
        vm.prank(buyer);
        ra.registerSubpage{value: 0.01 ether}(p, "dead", 0.01 ether, address(0));
        ga = _g();
        vm.prank(buyer);
        rb.registerSubpage{value: 0.01 ether}(p, "dead", 0.01 ether, address(0));
        gb = _g();
        emit log_named_int("sale of a deleted label, difference", int256(gb) - int256(ga));
        emit log_named_uint("sale of a deleted label, deleted rule", gb);
    }

    function test_gas_views() public {
        _mint("live", carol);
        _mint("dead", DEAD);
        _view("resolve, live subpage", abi.encodeWithSignature("resolve(uint256)", _sid("live")));
        _view("addr 60, live subpage", abi.encodeWithSignature("addr(uint256,uint256)", _sid("live"), 60));
        _view("text, live subpage", abi.encodeWithSignature("text(uint256,string)", _sid("live"), "url"));
        _view("resolve, deleted subpage", abi.encodeWithSignature("resolve(uint256)", _sid("dead")));
        _view("addr 60, deleted subpage", abi.encodeWithSignature("addr(uint256,uint256)", _sid("dead"), 60));
        _view("resolve, top-level", abi.encodeWithSignature("resolve(uint256)", p));
        _view("addr 60, top-level", abi.encodeWithSignature("addr(uint256,uint256)", p, 60));
        _view("reverseResolve, nothing set", abi.encodeWithSignature("reverseResolve(address)", carol));
        _view("tokenURI, live subpage", abi.encodeWithSignature("tokenURI(uint256)", _sid("live")));
        _view("tokenURI, deleted subpage", abi.encodeWithSignature("tokenURI(uint256)", _sid("dead")));
        _view("tokenURI, top-level", abi.encodeWithSignature("tokenURI(uint256)", p));
    }
}

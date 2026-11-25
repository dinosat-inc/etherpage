// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {Base64} from "solady/utils/Base64.sol";
import {LibString} from "solady/utils/LibString.sol";
import {PageCard} from "../../../src/PageCard.sol";
import {PageNFT} from "../../../src/PageNFT.sol";
import {SubpageRegistrar, IPageNFT} from "../../../src/SubpageRegistrar.sol";
import {PageNFTUndeleted} from "./harness/PageNFTUndeleted.sol";
import {PageNFTNoRecycleBin} from "./harness/PageNFTNoRecycleBin.sol";

// What the deleted state and the recycle bin cost on the code of record. Each figure is the code of record
// against a build that differs from it only by that feature, the same call by the same account on the same
// state. Run with the isolate option so each call is its own transaction, with cold storage.
contract DeletedStateGasTest is Test {
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    // the code of record
    PageNFT b;
    // the same without the deleted state
    PageNFTUndeleted a;
    // the same without the two DEAD conditions of the recycle bin
    PageNFTNoRecycleBin c;
    SubpageRegistrar rb;
    SubpageRegistrar ra;
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
        a = new PageNFTUndeleted(card);
        c = new PageNFTNoRecycleBin(card);
        rb = new SubpageRegistrar(IPageNFT(address(b)));
        ra = new SubpageRegistrar(IPageNFT(address(a)));
        vm.deal(seller, 100 ether);
        vm.deal(buyer, 100 ether);
        bytes32 s = keccak256("s");
        bytes32 commitment = b.makeCommitment("club", seller, 0, s);
        address[3] memory builds = [address(b), address(a), address(c)];
        for (uint256 i; i < 3; ++i) {
            vm.prank(seller);
            PageNFT(builds[i]).commit(commitment);
        }
        vm.warp(vm.getBlockTimestamp() + 61);
        (,,, uint256 total) = b.quote("club");
        for (uint256 i; i < 3; ++i) {
            vm.prank(seller);
            p = PageNFT(builds[i]).reveal{value: total}("club", seller, 0, s);
            vm.prank(seller);
            PageNFT(builds[i]).setSubpageMinter(p, hot);
        }
    }

    function _g() internal view returns (uint256) {
        return vm.lastCallGas().gasTotalUsed;
    }

    function _sid(string memory l) internal view returns (uint256) {
        return uint256(keccak256(abi.encodePacked(bytes32(p), keccak256(bytes(l)))));
    }

    function _log(string memory what, uint256 gRef, uint256 gCor) internal {
        emit log_named_uint(string.concat(what, ", reference"), gRef);
        emit log_named_uint(string.concat(what, ", code of record"), gCor);
        emit log_named_int(string.concat(what, ", difference"), int256(gCor) - int256(gRef));
    }

    // the same call by the same account on the reference and on the code of record; both must end the same way
    function _pair(string memory what, address ref, address who, bytes memory data) internal returns (bool okCor) {
        vm.prank(who);
        (bool okRef,) = ref.call(data);
        uint256 gRef = _g();
        vm.prank(who);
        (okCor,) = address(b).call(data);
        uint256 gCor = _g();
        assertEq(okCor, okRef, what);
        _log(what, gRef, gCor);
    }

    // the same view on both, returning both answers
    function _view(string memory what, address ref, bytes memory data)
        internal
        returns (bytes memory ansRef, bytes memory ansCor)
    {
        bool okRef;
        bool okCor;
        (okRef, ansRef) = ref.staticcall(data);
        uint256 gRef = _g();
        (okCor, ansCor) = address(b).staticcall(data);
        uint256 gCor = _g();
        assertTrue(okRef && okCor, what);
        _log(what, gRef, gCor);
    }

    function _same(string memory what, address ref, bytes memory data) internal {
        (bytes memory x, bytes memory y) = _view(what, ref, data);
        assertEq(y, x, string.concat(what, ": the same answer"));
    }

    function _mint(address n, string memory l, address to) internal {
        vm.prank(seller);
        PageNFT(n).registerSubpageFor(l, p, to);
    }

    function _status(bytes memory uriAnswer) internal pure returns (string memory) {
        string memory json = string(Base64.decode(LibString.slice(abi.decode(uriAnswer, (string)), 29)));
        if (LibString.contains(json, '"Status","value":"Invalid"')) return "Invalid";
        if (LibString.contains(json, '"Status","value":"Active"')) return "Active";
        return "other";
    }

    function test_gas_viewsAgainstUndeleted() public {
        address[2] memory builds = [address(a), address(b)];
        for (uint256 i; i < 2; ++i) {
            _mint(builds[i], "live", carol);
            _mint(builds[i], "dead", DEAD);
            vm.prank(carol);
            PageNFT(builds[i]).setText(_sid("live"), "url", "https://carol.example");
            vm.prank(carol);
            PageNFT(builds[i]).setContenthash(_sid("live"), hex"e3010170122029f2d17be6139079dc48696d1f582a8530eb9805b561eda517e22a892c7e3f1f");
        }
        uint256 live = _sid("live");
        uint256 dead = _sid("dead");
        address ref = address(a);
        _same("resolve, live subpage", ref, abi.encodeWithSignature("resolve(uint256)", live));
        _same("addr 60, live subpage", ref, abi.encodeWithSignature("addr(uint256,uint256)", live, 60));
        _same("text, live subpage", ref, abi.encodeWithSignature("text(uint256,string)", live, "url"));
        _same("contenthash, live subpage", ref, abi.encodeWithSignature("contenthash(uint256)", live));
        _same("isAvailable, live subpage", ref, abi.encodeWithSignature("isAvailable(string,uint256)", "live", p));

        (bytes memory x, bytes memory y) = _view("resolve, deleted subpage", ref, abi.encodeWithSignature("resolve(uint256)", dead));
        assertEq(abi.decode(x, (address)), DEAD, "the reference resolves a deleted subpage to DEAD");
        assertEq(abi.decode(y, (address)), address(0), "the code of record answers nothing");
        (x, y) = _view("addr home chain, deleted subpage", ref, abi.encodeWithSignature("addr(uint256,uint256)", dead, 0x8000000a));
        assertEq(abi.decode(x, (bytes)), abi.encodePacked(DEAD), "the reference answers DEAD as the main address");
        assertEq(abi.decode(y, (bytes)).length, 0);
        // DEAD saved no entry and no default, so even the reference answers nothing for coin type 60
        (x, y) = _view("addr 60, deleted subpage", ref, abi.encodeWithSignature("addr(uint256,uint256)", dead, 60));
        assertEq(abi.decode(x, (bytes)).length, 0);
        assertEq(abi.decode(y, (bytes)).length, 0);

        _same("resolve, top-level", ref, abi.encodeWithSignature("resolve(uint256)", p));
        _same("addr 60, top-level", ref, abi.encodeWithSignature("addr(uint256,uint256)", p, 60));
        _same("reverseResolve, nothing set", ref, abi.encodeWithSignature("reverseResolve(address)", carol));
        _same("tokenURI, live subpage", ref, abi.encodeWithSignature("tokenURI(uint256)", live));
        (x, y) = _view("tokenURI, deleted subpage", ref, abi.encodeWithSignature("tokenURI(uint256)", dead));
        assertEq(_status(x), "Active", "the reference shows a deleted subpage as Active");
        assertEq(_status(y), "Invalid", "the code of record shows it Invalid");
        _same("tokenURI, top-level", ref, abi.encodeWithSignature("tokenURI(uint256)", p));
    }

    function test_gas_writesAgainstUndeleted() public {
        address ref = address(a);
        uint256 live = _sid("live");
        assertTrue(_pair("mint of a fresh subpage by the holder", ref, seller, abi.encodeWithSignature("registerSubpageFor(string,uint256,address)", "live", p, carol)));
        assertTrue(_pair("setAddr on a live subpage", ref, carol, abi.encodeWithSignature("setAddr(uint256,address)", live, dave)));
        assertTrue(_pair("setText on a live subpage", ref, carol, abi.encodeWithSignature("setText(uint256,string,string)", live, "url", "x")));
        assertTrue(_pair("setContenthash on a live subpage", ref, carol, abi.encodeWithSignature("setContenthash(uint256,bytes)", live, hex"e301")));
        assertTrue(_pair("transfer of a live subpage between holders", ref, carol, abi.encodeWithSignature("transferFrom(address,address,uint256)", carol, dave, live)));
        assertTrue(_pair("transfer of a live subpage to DEAD (delete)", ref, dave, abi.encodeWithSignature("transferFrom(address,address,uint256)", dave, DEAD, live)));
        assertEq(b.resolve(live), address(0), "deleted on the code of record");
        assertEq(a.resolve(live), DEAD, "resolves to DEAD on the reference");
        assertTrue(_pair("holder re-mint over a deleted subpage", ref, seller, abi.encodeWithSignature("registerSubpageFor(string,uint256,address)", "live", p, carol)));
        assertTrue(_pair("holder re-mint of a live subpage straight to DEAD", ref, seller, abi.encodeWithSignature("registerSubpageFor(string,uint256,address)", "live", p, DEAD)));
        assertTrue(_pair("minter mint over a deleted subpage", ref, hot, abi.encodeWithSignature("registerSubpageFor(string,uint256,address)", "live", p, carol)));
        assertTrue(_pair("minter mint of a fresh subpage straight to DEAD", ref, hot, abi.encodeWithSignature("registerSubpageFor(string,uint256,address)", "gone", p, DEAD)));
        assertFalse(_pair("minter refused over a live subpage", ref, hot, abi.encodeWithSignature("registerSubpageFor(string,uint256,address)", "live", p, dave)));
        assertTrue(_pair("transfer of a top-level name", ref, seller, abi.encodeWithSignature("transferFrom(address,address,uint256)", seller, carol, p)));
        assertTrue(_pair("setAddr on a top-level name", ref, carol, abi.encodeWithSignature("setAddr(uint256,address)", p, dave)));
        assertTrue(_pair("transfer of a top-level name to DEAD (delete)", ref, carol, abi.encodeWithSignature("transferFrom(address,address,uint256)", carol, DEAD, p)));
        assertEq(b.resolve(p), address(0), "a top-level name is deleted too on the code of record");
        assertEq(a.resolve(p), DEAD, "resolves to DEAD on the reference");
    }

    function test_gas_saleAgainstUndeleted() public {
        vm.startPrank(seller);
        a.setSubpageMinter(p, address(ra));
        b.setSubpageMinter(p, address(rb));
        ra.configure(p, seller, address(0), 0.01 ether, true, address(0), 0, false);
        rb.configure(p, seller, address(0), 0.01 ether, true, address(0), 0, false);
        vm.stopPrank();
        _mint(address(a), "dead", DEAD);
        _mint(address(b), "dead", DEAD);
        string[2] memory labels = ["fresh", "dead"];
        for (uint256 i; i < 2; ++i) {
            vm.prank(buyer);
            ra.registerSubpage{value: 0.01 ether}(p, labels[i], 0.01 ether, address(0));
            uint256 ga = _g();
            vm.prank(buyer);
            rb.registerSubpage{value: 0.01 ether}(p, labels[i], 0.01 ether, address(0));
            uint256 gb = _g();
            _log(string.concat("sale of the label ", labels[i]), ga, gb);
            assertEq(b.ownerOf(_sid(labels[i])), buyer);
            assertEq(a.ownerOf(_sid(labels[i])), buyer);
        }
    }

    // the recycle bin: the holder read in isAvailable and in a minter's mint over a live subpage
    function test_gas_recycleBinAgainstNoRecycleBin() public {
        _mint(address(c), "live", carol);
        _mint(address(b), "live", carol);
        address ref = address(c);
        (bytes memory x, bytes memory y) =
            _view("isAvailable, live subpage", ref, abi.encodeWithSignature("isAvailable(string,uint256)", "live", p));
        assertFalse(abi.decode(x, (bool)));
        assertFalse(abi.decode(y, (bool)));
        assertFalse(_pair("minter refused over a live subpage", ref, hot, abi.encodeWithSignature("registerSubpageFor(string,uint256,address)", "live", p, dave)));
        assertEq(b.ownerOf(_sid("live")), carol);
        // over a subpage DEAD holds, only the code of record reads the label as free
        _mint(address(c), "dead", DEAD);
        _mint(address(b), "dead", DEAD);
        assertTrue(b.isAvailable("dead", p));
        assertFalse(c.isAvailable("dead", p));
    }
}

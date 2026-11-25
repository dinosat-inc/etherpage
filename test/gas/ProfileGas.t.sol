// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {PageNFT} from "../../src/PageNFT.sol";
import {PageCard} from "../../src/PageCard.sol";
import {PageNFTNoProfileReset} from "../differential/harness/PageNFTNoProfileReset.sol";

// Gas of the profile paths in PageNFT, logged as profile, and in PageNFTNoProfileReset, a reference
// without the profile reset, logged as no reset. Run with the isolate option so every call is its own
// transaction and cold storage is counted as on chain; each figure is vm.lastCallGas().gasTotalUsed.
contract ProfileGasTest is Test {
    PageNFTNoProfileReset noReset;
    PageNFT prof;
    address user = makeAddr("user");
    address bob = makeAddr("bob");
    string constant PUNK = "eip155:1/erc721:0xb47e3cd837ddf8e4c57f05d70ab865de6e193bbb/5822";

    function setUp() public {
        vm.warp(1_800_000_000);
        PageCard card = new PageCard();
        noReset = new PageNFTNoProfileReset(card);
        prof = new PageNFT(card);
        vm.deal(user, 100 ether);
        vm.deal(bob, 100 ether);
    }

    function _gas() internal view returns (uint256) {
        return vm.lastCallGas().gasTotalUsed;
    }

    function _call(address w, address from, bytes memory data) internal returns (uint256) {
        vm.prank(from);
        (bool ok,) = w.call(data);
        require(ok, "call failed");
        return _gas();
    }

    function _log(string memory tag, uint256 a, uint256 b) internal {
        emit log_named_uint(string.concat("no reset: ", tag), a);
        emit log_named_uint(string.concat("profile: ", tag), b);
    }

    function test_gas() public {
        address[2] memory ws = [address(noReset), address(prof)];
        uint256 id = prof.computeId("alpha");
        for (uint256 i; i < 2; ++i) {
            bytes32 c = PageNFT(ws[i]).makeCommitment("alpha", user, 0, bytes32(0));
            vm.prank(user);
            PageNFT(ws[i]).commit(c);
        }
        vm.warp(block.timestamp + 61);
        for (uint256 i; i < 2; ++i) {
            vm.prank(user);
            PageNFT(ws[i]).reveal{value: 0.0001 ether}("alpha", user, 0, bytes32(0));
        }
        uint256[2] memory g;
        bytes memory setAvatar = abi.encodeWithSignature("setText(uint256,string,string)", id, "avatar", PUNK);
        bytes memory setUrl = abi.encodeWithSignature("setText(uint256,string,string)", id, "url", "https://a.example");
        bytes memory setSite = abi.encodeWithSignature("setContenthash(uint256,bytes)", id, hex"e3010170122029f2d17be6139079dc48696d1f582a8530eb9805b561eda517e22a892c7e3f1f");
        for (uint256 i; i < 2; ++i) g[i] = _call(ws[i], user, setAvatar);
        _log("setText, first ever", g[0], g[1]);
        for (uint256 i; i < 2; ++i) g[i] = _call(ws[i], user, setUrl);
        _log("setText, second key", g[0], g[1]);
        for (uint256 i; i < 2; ++i) g[i] = _call(ws[i], user, setAvatar);
        _log("setText, overwrite by the same holder", g[0], g[1]);
        for (uint256 i; i < 2; ++i) g[i] = _call(ws[i], user, setSite);
        _log("setContenthash, first", g[0], g[1]);
        for (uint256 i; i < 2; ++i) g[i] = _call(ws[i], user, abi.encodeWithSignature("text(uint256,string)", id, "avatar"));
        _log("text() read as a call", g[0], g[1]);
        for (uint256 i; i < 2; ++i) g[i] = _call(ws[i], user, abi.encodeWithSignature("contenthash(uint256)", id));
        _log("contenthash() read as a call", g[0], g[1]);
        for (uint256 i; i < 2; ++i) g[i] = _call(ws[i], user, abi.encodeWithSignature("transferFrom(address,address,uint256)", user, bob, id));
        _log("transferFrom", g[0], g[1]);
        uint256 snap = vm.snapshotState();
        for (uint256 i; i < 2; ++i) g[i] = _call(ws[i], bob, abi.encodeWithSignature("setText(uint256,string,string)", id, "url", "https://b.example"));
        _log("setText, first by a new holder", g[0], g[1]);
        vm.revertToState(snap);
        g[1] = _call(address(prof), bob, abi.encodeCall(PageNFT.keepProfile, (id)));
        _log("keepProfile", 0, g[1]);
        vm.revertToState(snap);
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(PageNFT.keepProfile, (id));
        calls[1] = setUrl;
        g[1] = _call(address(prof), bob, abi.encodeCall(PageNFT.multicall, (calls)));
        bytes[] memory one = new bytes[](1);
        one[0] = setUrl;
        g[0] = _call(address(noReset), bob, abi.encodeCall(PageNFT.multicall, (one)));
        _log("multicall [keepProfile, setText] (no reset: [setText] only)", g[0], g[1]);
        for (uint256 i; i < 2; ++i) g[i] = _call(ws[i], bob, abi.encodeWithSignature("transferFrom(address,address,uint256)", bob, user, id));
        _log("transferFrom back", g[0], g[1]);
        for (uint256 i; i < 2; ++i) g[i] = _call(ws[i], user, abi.encodeWithSignature("clearRecords(uint256)", id));
        _log("clearRecords", g[0], g[1]);
    }
}

// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {PageNFT} from "../../../src/PageNFT.sol";
import {MinterBase} from "../../utils/MinterBase.sol";
import {SafeLike} from "../../utils/MinterMocks.sol";

// What a parent's holder and its counted minter can do with subpages. Neither mints once the parent is past its
// expiry. The holder takes a live subpage back from any holder, the minter only from DEAD, and after a take back
// nothing of the old records counts.
contract ParentPowersTest is MinterBase {
    uint256 constant BTC = 0;
    uint256 constant BASE = 0x80002105;
    uint256 constant DEFAULT_EVM = 0x80000000;
    bytes constant BTC_ADDR = hex"0014751e76e8199196d454941c45d1b3a323f1433bd6";
    bytes constant SITE = hex"e3010170122029f2d17be6139079dc48696d1f582a8530eb9805b561eda517e22a892c7e3f1f";

    uint256 club;

    function setUp() public override {
        super.setUp();
        club = _reg(alice, "club");
    }

    // At the parent's expiry its holder and its counted minter still mint. One second later, at the end of the
    // grace period, one second after it, at the end of the premium window and one second after that, the holder gets
    // Expired for a fresh label and over a live subpage, the minter for a fresh label, and the live subpage keeps its
    // holder.
    function test_subpageOfExpiredParentReverts() public {
        _setMinter(club, hot);
        vm.prank(alice);
        uint256 live = nft.registerSubpageFor("live", club, carol);
        uint256 t = nft.expiresAt(club);
        vm.warp(t);
        vm.prank(alice);
        nft.registerSubpage("at", club);
        vm.prank(hot);
        nft.registerSubpageFor("atm", club, carol);

        uint256[5] memory instants = [t + 1, t + 90 days, t + 90 days + 1, t + 111 days, t + 111 days + 1];
        for (uint256 i; i < instants.length; ++i) {
            vm.warp(instants[i]);
            vm.prank(alice);
            vm.expectRevert(PageNFT.Expired.selector);
            nft.registerSubpage("fresh", club);
            vm.prank(alice);
            vm.expectRevert(PageNFT.Expired.selector);
            nft.registerSubpageFor("fresh", club, carol);
            vm.prank(alice);
            vm.expectRevert(PageNFT.Expired.selector);
            nft.registerSubpageFor("live", club, alice);
            vm.prank(hot);
            vm.expectRevert(PageNFT.Expired.selector);
            nft.registerSubpageFor("fresh", club, carol);
            vm.prank(hot);
            vm.expectRevert(PageNFT.Expired.selector);
            nft.registerSubpage("fresh", club);
        }
        assertEq(nft.ownerOf(live), carol, "the live subpage keeps its holder");
        assertEq(nft.ownerOf(club), alice, "nobody registered the parent again");
    }

    // the holder of id writes a main address, an entry for coin type 60, a default for every EVM chain, a Bitcoin
    // entry, a text field and a website
    function _write(address holder, uint256 id) internal {
        vm.startPrank(holder);
        nft.setAddr(id, makeAddr("old main"));
        nft.setAddrForCoin(id, 60, abi.encodePacked(makeAddr("old eth")));
        nft.setAddrForCoin(id, DEFAULT_EVM, abi.encodePacked(makeAddr("old default")));
        nft.setAddrForCoin(id, BTC, BTC_ADDR);
        nft.setText(id, "url", "https://old");
        nft.setContenthash(id, SITE);
        nft.setData(id, "k", hex"01");
        vm.stopPrank();
    }

    // id was just minted for holder: it answers holder on the home chain and nothing on any other chain, whatever the
    // code at holder, and nothing written before counts
    function _clean(uint256 id, address holder, string memory which) internal view {
        assertEq(nft.ownerOf(id), holder, which);
        assertEq(nft.resolve(id), holder, string.concat(which, ": the main address is the holder"));
        assertEq(nft.addr(id, COIN_OP), abi.encodePacked(holder), string.concat(which, ": the home chain answer"));
        assertEq(nft.addr(id, 60), "", string.concat(which, ": no old coin type 60 entry"));
        assertEq(nft.addr(id, BASE), "", string.concat(which, ": no old default"));
        assertEq(nft.addr(id, BTC), "", string.concat(which, ": no old Bitcoin entry"));
        assertEq(nft.text(id, "url"), "", string.concat(which, ": no old text"));
        assertEq(nft.contenthash(id), "", string.concat(which, ": no old website"));
        assertEq(nft.data(bytes32(id), "k"), "", string.concat(which, ": no old data record"));
        assertEq(nft.addr(bytes32(id)), address(0), string.concat(which, ": no coin type 60 answer"));
    }

    // A subpage held by an account with no code, by a contract, by the registrar after a plain transfer and by
    // DEAD: the parent's holder takes each back, here for the account that wrote its records, and none of those
    // records counts. The counted minter gets AlreadyRegistered for the first three and mints over the one DEAD holds.
    function test_subpageReclaimFromEveryHolder() public {
        SafeLike wallet = new SafeLike(dave);
        string[4] memory labels = ["eoa", "wallet", "stuck", "gone"];
        address[4] memory writers = [carol, address(wallet), alice, bob];
        uint256[4] memory ids;
        for (uint256 i; i < 4; ++i) {
            vm.prank(alice);
            ids[i] = nft.registerSubpageFor(labels[i], club, writers[i]);
        }
        _write(carol, ids[0]);
        vm.startPrank(dave);
        wallet.exec(address(nft), 0, abi.encodeCall(PageNFT.setAddr, (ids[1], makeAddr("old main"))));
        wallet.exec(address(nft), 0, abi.encodeCall(PageNFT.setAddrForCoin, (ids[1], 60, abi.encodePacked(dave))));
        wallet.exec(address(nft), 0, abi.encodeCall(PageNFT.setAddrForCoin, (ids[1], DEFAULT_EVM, abi.encodePacked(dave))));
        wallet.exec(address(nft), 0, abi.encodeCall(PageNFT.setAddrForCoin, (ids[1], BTC, BTC_ADDR)));
        wallet.exec(address(nft), 0, abi.encodeWithSignature("setText(uint256,string,string)", ids[1], "url", "x"));
        wallet.exec(address(nft), 0, abi.encodeWithSignature("setContenthash(uint256,bytes)", ids[1], SITE));
        wallet.exec(address(nft), 0, abi.encodeCall(PageNFT.setData, (ids[1], "k", hex"01")));
        vm.stopPrank();
        assertEq(nft.addr(ids[1], 60), abi.encodePacked(dave), "the wallet's own coin type 60 entry counts");
        assertEq(nft.addr(ids[1], BASE), abi.encodePacked(dave), "and so does its default");
        _write(alice, ids[2]);
        vm.prank(alice);
        nft.transferFrom(alice, address(reg), ids[2]);
        _write(bob, ids[3]);
        vm.prank(bob);
        nft.transferFrom(bob, DEAD, ids[3]);
        assertEq(nft.ownerOf(ids[2]), address(reg));
        assertEq(nft.ownerOf(ids[3]), DEAD);

        _setMinter(club, hot);
        uint256 snap = vm.snapshotState();
        for (uint256 i; i < 3; ++i) {
            vm.prank(hot);
            vm.expectRevert(PageNFT.AlreadyRegistered.selector);
            nft.registerSubpageFor(labels[i], club, writers[i]);
        }
        vm.prank(hot);
        nft.registerSubpageFor("gone", club, bob);
        _clean(ids[3], bob, "the minter over DEAD");
        vm.revertToState(snap);

        for (uint256 i; i < 4; ++i) {
            uint256 version = nft.recordVersion(ids[i]);
            uint64 epoch = nft.epochOf(ids[i]);
            vm.prank(alice);
            nft.registerSubpageFor(labels[i], club, writers[i]);
            _clean(ids[i], writers[i], labels[i]);
            assertEq(nft.recordVersion(ids[i]), version + 1, string.concat(labels[i], ": a new record version"));
            assertEq(nft.epochOf(ids[i]), epoch + 1, string.concat(labels[i], ": a new epoch"));
        }
    }
}

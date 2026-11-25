// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {RecordCostBase} from "./RecordScalingGas.t.sol";

// Two subpages of one parent, each held by its own account with a main address and an Ethereum entry saved; the
// second also holds a hundred more chain entries, forty text fields and a website. Deleting each, a transfer to
// DEAD, costs the same: a delete reads the records it announces and writes none of them, so what a holder stored
// cannot make a delete dearer, for the holder or for anyone it hands the name to. The same holds for a pair whose
// records an earlier holder saved before handing each subpage on.
contract DeleteCostRecordsTest is RecordCostBase {
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    address owner = makeAddr("parent owner");
    address h1 = makeAddr("holder1");
    address h2 = makeAddr("holder2");
    address m1 = makeAddr("main1");
    address m2 = makeAddr("main2");
    address e1 = makeAddr("eth1");
    address e2 = makeAddr("eth2");
    address h3 = makeAddr("holder3");
    address h4 = makeAddr("holder4");

    uint256 parent;
    uint256 thin;
    uint256 fat;
    uint256 staleThin;
    uint256 staleFat;

    uint256 constant EVM_ENTRIES = 50;
    uint256 constant OTHER_ENTRIES = 50;
    uint256 constant FIELDS = 40;
    bytes constant SITE = hex"e3010170122029f2d17be6139079dc48696d1f582a8530eb9805b561eda517e22a892c7e3f1f";

    function setUp() public override {
        super.setUp();
        parent = _register("parent", owner);
        vm.startPrank(owner);
        // one more name for each holder and one already at DEAD, so no ERC721 balance goes to or from zero
        nft.registerSubpageFor("ballast1", parent, h1);
        nft.registerSubpageFor("ballast2", parent, h2);
        uint256 gone = nft.registerSubpage("ballast3", parent);
        nft.transferFrom(owner, DEAD, gone);
        nft.registerSubpageFor("ballast4", parent, h3);
        nft.registerSubpageFor("ballast5", parent, h4);
        thin = nft.registerSubpageFor("thinn", parent, h1);
        fat = nft.registerSubpageFor("fattt", parent, h2);
        staleThin = nft.registerSubpageFor("olde1", parent, h1);
        staleFat = nft.registerSubpageFor("olde2", parent, h2);
        vm.stopPrank();
        _basic(h1, thin, m1, e1);
        _basic(h2, fat, m2, e2);
        _pile(h2, fat);
        // the earlier holders save, then hand the subpages on
        _basic(h1, staleThin, m1, e1);
        _basic(h2, staleFat, m2, e2);
        _pile(h2, staleFat);
        vm.prank(h1);
        nft.transferFrom(h1, h3, staleThin);
        vm.prank(h2);
        nft.transferFrom(h2, h4, staleFat);
        assertEq(nft.text(fat, "key40"), "a profile value that fills a slot or two", "the fields are stored");
        assertEq(nft.addr(fat, 1000 + OTHER_ENTRIES), _entry(OTHER_ENTRIES), "the other chains are stored");
        assertEq(nft.contenthash(fat), SITE);
        assertEq(nft.text(thin, "key1"), "", "the thin subpage has no field");
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

    function test_deleteCostDoesNotGrowWithRecords() public {
        // both deletes start from the same state, so the DEAD balance slot is cold and unwritten for each
        _warm();
        uint256 snap = vm.snapshotState();
        uint256 gThin = _gas(h1, address(nft), 0, abi.encodeCall(nft.transferFrom, (h1, DEAD, thin)));
        assertEq(nft.ownerOf(thin), DEAD);
        vm.revertToState(snap);
        uint256 gFat = _gas(h2, address(nft), 0, abi.encodeCall(nft.transferFrom, (h2, DEAD, fat)));
        emit log_named_uint("delete, main and Ethereum saved", gThin);
        emit log_named_uint("delete, plus 100 chain entries, 40 fields and a website", gFat);
        assertEq(gFat, gThin, "a delete costs the same whatever records the subpage holds");
        assertEq(nft.ownerOf(fat), DEAD);
        assertEq(nft.resolve(fat), address(0), "the deleted subpage answers nothing");
        assertEq(nft.addr(fat, 1001), "");
        assertEq(nft.text(fat, "key1"), "");
    }

    function test_deleteCostDoesNotGrowWithAnEarlierHoldersRecords() public {
        _warm();
        uint256 snap = vm.snapshotState();
        uint256 gThin = _gas(h3, address(nft), 0, abi.encodeCall(nft.transferFrom, (h3, DEAD, staleThin)));
        assertEq(nft.ownerOf(staleThin), DEAD);
        vm.revertToState(snap);
        uint256 gFat = _gas(h4, address(nft), 0, abi.encodeCall(nft.transferFrom, (h4, DEAD, staleFat)));
        emit log_named_uint("delete, an earlier holder saved main and Ethereum", gThin);
        emit log_named_uint("delete, an earlier holder also saved 100 chain entries, 40 fields and a website", gFat);
        assertEq(gFat, gThin, "a delete costs the same whatever records an earlier holder left");
        assertEq(nft.ownerOf(staleFat), DEAD);
        assertEq(nft.resolve(staleFat), address(0));
    }
}

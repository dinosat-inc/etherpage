// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {LibString} from "solady/utils/LibString.sol";
import {RulesBase} from "../../utils/RulesBase.sol";
import {Holder721} from "../../utils/MinterMocks.sol";
import {CardReader} from "../../utils/CardReader.sol";

// The parentheses of the description show the short form of payee(id) in every case below, while the right pill of
// the card shows the code of the id whoever the payee is, and saving an address for any other chain leaves the
// metadata byte for byte the same.
contract CardPayeeTest is RulesBase {
    uint256 constant COIN_BASE = 0x80002105;

    CardReader reader;

    function setUp() public override {
        super.setUp();
        reader = new CardReader();
    }

    function _assertShowsPayee(uint256 id, address want) internal view {
        assertEq(nft.payee(id), want, "the payee");
        string memory short = card.shortAddress(want);
        assertEq(reader.read(_svg(id)).right, reader.code(bytes32(id)), "the right pill shows the code, not the payee");
        // a subpage's description goes on after the parentheses with the sentence about its parent's holder
        (, uint256 parent,,,) = nft.records(id);
        string memory tail = ')","image"';
        if (parent != 0) {
            (string memory parentLabel,,,,) = nft.records(parent);
            tail = string.concat(
                "). This subpage relies on ", parentLabel, "'s holder, who can take it away.\",\"image\""
            );
        }
        assertTrue(LibString.contains(_json(id), string.concat(" (", short, tail)), "the description shows it");
    }

    // chain entries other than the main address never change the metadata
    function _assertChainSavesChangeNothing(uint256 id, address holder) internal {
        string memory before = nft.tokenURI(id);
        vm.startPrank(holder);
        nft.setAddrForCoin(id, 60, abi.encodePacked(dave));
        nft.setAddrForCoin(id, COIN_BASE, abi.encodePacked(carol));
        nft.setAddrForCoin(id, 0, hex"0014beef");
        vm.stopPrank();
        assertEq(nft.tokenURI(id), before, "saving another chain leaves the metadata as it was");
    }

    function test_cardPayeeFollowsSaverRule() public {
        // nothing saved: the holder
        uint256 id = _buy(bob, "payeecard");
        _assertShowsPayee(id, bob);
        _assertChainSavesChangeNothing(id, bob);

        // the holder saved a main address: that address
        vm.prank(bob);
        nft.setAddr(id, carol);
        _assertShowsPayee(id, carol);
        _assertChainSavesChangeNothing(id, bob);

        // saved by an earlier holder: the holder
        vm.prank(bob);
        nft.transferFrom(bob, dave, id);
        _assertShowsPayee(id, dave);

        // a contract holder that saved nothing: that contract
        Holder721 vault = new Holder721();
        vm.prank(dave);
        nft.transferFrom(dave, address(vault), id);
        _assertShowsPayee(id, address(vault));

        // a parent whose subpages the registrar sells: a sale leaves its metadata unchanged
        uint256 club = _buy(carol, "club");
        vm.startPrank(carol);
        nft.setAddr(club, user);
        nft.setSubpageMinter(club, address(shop));
        shop.configure(club, carol, address(0), 0.001 ether, true, address(0), 0, false);
        vm.stopPrank();
        string memory parentBefore = nft.tokenURI(club);
        vm.prank(bob);
        uint256 sold = shop.registerSubpage{value: 0.001 ether}(club, "sold", 0.001 ether, address(0));
        assertEq(nft.tokenURI(club), parentBefore, "a sale never changes the parent's card");
        _assertShowsPayee(club, user);
        _assertShowsPayee(sold, bob);

        // a subpage its holder deleted, and a top level name sent to DEAD: DEAD
        vm.prank(bob);
        nft.transferFrom(bob, DEAD, sold);
        _assertShowsPayee(sold, DEAD);
        assertTrue(LibString.contains(_json(sold), '"value":"Invalid"'));
        uint256 burned = _buy(dave, "burnedname");
        vm.prank(dave);
        nft.setAddr(burned, carol);
        vm.prank(dave);
        nft.transferFrom(dave, DEAD, burned);
        _assertShowsPayee(burned, DEAD);
        assertTrue(LibString.contains(_json(burned), '"value":"Invalid"'));

        // grace, expired and a stale subpage keep the last payee from before the name went inactive
        vm.prank(carol);
        uint256 kept = nft.registerSubpageFor("kept", club, dave);
        vm.prank(dave);
        nft.setAddr(kept, relayer);
        vm.warp(nft.expiresAt(club) + 1);
        assertEq(_metaStatus(club), "Grace");
        _assertShowsPayee(club, user);
        _assertShowsPayee(kept, relayer);
        vm.warp(nft.expiresAt(club) + 90 days + 21 days + 1);
        assertEq(_metaStatus(club), "Expired");
        _assertShowsPayee(club, user);
        _assertShowsPayee(kept, relayer);
        _buy(bob, "club");
        assertEq(_metaStatus(kept), "Invalid");
        _assertShowsPayee(kept, relayer);
        _assertShowsPayee(club, bob);
    }
}

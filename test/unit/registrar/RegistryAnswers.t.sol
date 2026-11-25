// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {SubpageRegistrar, IPageNFT} from "../../../src/SubpageRegistrar.sol";

// a registry whose answers the test sets: every page has the same holder, parent, epoch and minter, every label is
// free, and each mint answers the next id
contract ScriptedRegistry {
    address public holder;
    uint256 public parent;
    uint64 public epoch;
    address public minter;
    uint256 public mints;

    function set(address h, uint256 p, uint64 e, address m) external {
        holder = h;
        parent = p;
        epoch = e;
        minter = m;
    }

    function setParent(uint256 p) external {
        parent = p;
    }

    function setEpoch(uint64 e) external {
        epoch = e;
    }

    function ownerOf(uint256) external view returns (address) {
        return holder;
    }

    function parentOf(uint256) external view returns (uint256) {
        return parent;
    }

    function epochOf(uint256) external view returns (uint64) {
        return epoch;
    }

    function subpageMinterOf(uint256) external view returns (address) {
        return minter;
    }

    function isAvailable(string calldata, uint256) external pure returns (bool) {
        return true;
    }

    function normalize(string calldata label) external pure returns (string memory) {
        return label;
    }

    function registerSubpageFor(string calldata, uint256, address) external returns (uint256) {
        return ++mints;
    }
}

// A sale checks again that the page is top level and that its epoch is the one configure saw. The PageNFT of this
// release keeps a top level page top level and never lowers an epoch, so with it these checks never meet such a
// change. Here a stand-in registry makes each change after configure: the sale refuses it with its own error, and
// goes through once the answer is back.
contract RegistryAnswersTest is Test {
    uint256 constant PAGE = 7;
    uint64 constant EPOCH = 5;

    ScriptedRegistry registry;
    SubpageRegistrar reg;

    function setUp() public {
        registry = new ScriptedRegistry();
        reg = new SubpageRegistrar(IPageNFT(address(registry)));
        registry.set(address(this), 0, EPOCH, address(reg));
        reg.configure(PAGE, address(0), address(0), 0, true, address(0), 0, false);
    }

    function _buy() internal returns (uint256) {
        return reg.registerSubpage(PAGE, "kid", 0, address(0));
    }

    // a page whose parent turns nonzero after configure is refused with ParentNotTopLevel
    function test_saleRefusesAPageThatIsNoLongerTopLevel() public {
        registry.setParent(1);
        vm.expectRevert(SubpageRegistrar.ParentNotTopLevel.selector);
        _buy();
        registry.setParent(0);
        assertEq(_buy(), 1, "sold once the page is top level again");
    }

    // an epoch below the one configure saw is refused with StaleConfig, as an epoch above it is
    function test_saleRefusesAnEpochBelowTheConfiguredOne() public {
        registry.setEpoch(EPOCH - 1);
        vm.expectRevert(SubpageRegistrar.StaleConfig.selector);
        _buy();
        registry.setEpoch(EPOCH + 1);
        vm.expectRevert(SubpageRegistrar.StaleConfig.selector);
        _buy();
        registry.setEpoch(EPOCH);
        assertEq(_buy(), 1, "sold at the epoch configure saw");
    }
}

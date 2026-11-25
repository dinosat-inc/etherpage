// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {Deploy} from "../../../script/Deploy.s.sol";
import {PageCard} from "../../../src/PageCard.sol";
import {PageNFT} from "../../../src/PageNFT.sol";
import {SubpageRegistrar} from "../../../src/SubpageRegistrar.sol";

// The deploy script, run the way forge script runs it. The test contract stands in for the deployer, because
// forge refuses a broadcast inside a pranked call. DEPLOYER and EXPECTED_NONCE belong to the whole test process,
// whose tests run in parallel, so the first test alone sets them and the chain tests pass whatever they hold.
contract DeployScriptTest is Test {
    error CheatcodeError(string message);

    uint64 internal constant NONCE = 1000;
    Deploy internal script;

    function setUp() public {
        script = new Deploy();
    }

    function test_deploysTheThreeContractsOnlyWithBothVariablesForTheDeployerAtItsNonce() public {
        assertFalse(vm.envExists("DEPLOYER"), "DEPLOYER is set in the shell that runs the tests");
        assertFalse(vm.envExists("EXPECTED_NONCE"), "EXPECTED_NONCE is set in the shell that runs the tests");
        uint256 fresh = vm.snapshotState();

        // the chain comes before either variable is read
        vm.chainId(1);
        vm.expectRevert(bytes("wrong chain"));
        script.run();

        vm.chainId(31337);
        vm.expectRevert(
            abi.encodeWithSelector(CheatcodeError.selector, 'vm.envAddress: environment variable "DEPLOYER" not found')
        );
        script.run();
        vm.setEnv("DEPLOYER", vm.toString(address(this)));
        vm.expectRevert(
            abi.encodeWithSelector(
                CheatcodeError.selector, 'vm.envUint: environment variable "EXPECTED_NONCE" not found'
            )
        );
        script.run();

        // an empty value is refused too
        vm.setEnv("EXPECTED_NONCE", "");
        _assertRunFailsReading("vm.envUint: failed parsing $EXPECTED_NONCE");
        vm.setEnv("EXPECTED_NONCE", vm.toString(uint256(NONCE)));
        vm.setEnv("DEPLOYER", "");
        _assertRunFailsReading("vm.envAddress: failed parsing $DEPLOYER");
        vm.setEnv("DEPLOYER", vm.toString(address(this)));

        // another caller at the expected nonce
        address stranger = makeAddr("stranger");
        vm.setNonce(stranger, NONCE);
        vm.expectRevert(bytes("wrong deployer or nonce"));
        vm.prank(stranger);
        script.run();

        // the sender forge uses when no raw key and no sender flag name the deployer
        vm.setNonce(DEFAULT_SENDER, NONCE);
        vm.expectRevert(bytes("wrong deployer or nonce"));
        vm.prank(DEFAULT_SENDER);
        script.run();

        // DEPLOYER naming another account while the caller is at the expected nonce
        vm.setNonce(address(this), NONCE);
        vm.setEnv("DEPLOYER", vm.toString(stranger));
        vm.expectRevert(bytes("wrong deployer or nonce"));
        script.run();
        vm.setEnv("DEPLOYER", vm.toString(address(this)));

        // the deployer one below and one above the expected nonce
        assertTrue(vm.revertToState(fresh));
        vm.setNonce(address(this), NONCE - 1);
        vm.expectRevert(bytes("wrong deployer or nonce"));
        script.run();
        vm.setNonce(address(this), NONCE + 1);
        vm.expectRevert(bytes("wrong deployer or nonce"));
        script.run();

        assertTrue(vm.revertToState(fresh));
        vm.chainId(31337);
        _assertDeploysTheThree();

        assertTrue(vm.revertToState(fresh));
        vm.chainId(10);
        _assertDeploysTheThree();
    }

    function test_refusesOtherWellKnownChains() public {
        uint64[10] memory ids = [uint64(1), 8453, 11155111, 11155420, 84532, 420, 0, 9, 11, 31338];
        for (uint256 i; i < ids.length; ++i) {
            vm.chainId(ids[i]);
            vm.expectRevert(bytes("wrong chain"));
            script.run();
        }
    }

    function testFuzz_refusesEveryOtherChain(uint64 id) public {
        vm.assume(id != 10 && id != 31337);
        vm.chainId(id);
        vm.expectRevert(bytes("wrong chain"));
        script.run();
    }

    function _assertDeploysTheThree() internal {
        vm.setNonce(address(this), NONCE);
        vm.startStateDiffRecording();
        (PageCard card, PageNFT nft, SubpageRegistrar registrar) = script.run();
        VmSafe.AccountAccess[] memory diff = vm.stopAndReturnStateDiff();

        // plain CREATE addresses of the deployer at its nonces n, n + 1 and n + 2
        assertEq(address(card), vm.computeCreateAddress(address(this), NONCE), "PageCard at nonce n");
        assertEq(address(nft), vm.computeCreateAddress(address(this), NONCE + 1), "PageNFT at nonce n + 1");
        assertEq(address(registrar), vm.computeCreateAddress(address(this), NONCE + 2), "SubpageRegistrar at n + 2");
        assertEq(address(nft.card()), address(card), "card() is the PageCard");
        assertEq(address(registrar.registry()), address(nft), "registry() is the PageNFT");
        assertEq(address(card).code, vm.getDeployedCode("PageCard.sol:PageCard"), "PageCard runs the built code");
        // each transaction of the deployer takes one nonce
        assertEq(vm.getNonce(address(this)), NONCE + 3, "three transactions");
        _assertTheScriptOnlyCreatesTheThree(diff, [address(card), address(nft), address(registrar)]);
    }

    // The steps of the script itself are the three creations from the deployer and the code size checks before
    // its calls to the cheatcode address. Deeper accesses run inside the constructors.
    function _assertTheScriptOnlyCreatesTheThree(VmSafe.AccountAccess[] memory diff, address[3] memory created)
        internal
    {
        bytes[3] memory initcode = [
            vm.getCode("PageCard.sol:PageCard"),
            abi.encodePacked(vm.getCode("PageNFT.sol:PageNFT"), abi.encode(created[0])),
            abi.encodePacked(vm.getCode("SubpageRegistrar.sol:SubpageRegistrar"), abi.encode(created[1]))
        ];
        assertTrue(diff[0].kind == VmSafe.AccountAccessKind.Call && diff[0].account == address(script), "the run call");
        uint64 inside = diff[0].depth + 1;
        uint256 creates;
        for (uint256 i = 1; i < diff.length; ++i) {
            VmSafe.AccountAccess memory a = diff[i];
            assertGe(a.depth, inside, "an access after the run");
            if (a.depth > inside) continue;
            if (a.kind == VmSafe.AccountAccessKind.Create) {
                assertLt(creates, 3, "a fourth creation");
                assertEq(a.accessor, address(this), "created by the deployer");
                assertEq(a.account, created[creates], "created in this order");
                assertEq(a.data, initcode[creates], "the built creation code and its constructor argument");
                assertEq(a.value, 0, "created with no value");
                assertFalse(a.reverted, "the creation reverted");
                ++creates;
            } else {
                assertTrue(
                    a.kind == VmSafe.AccountAccessKind.Extcodesize && a.account == VM_ADDRESS,
                    "the script touched another account"
                );
            }
        }
        assertEq(creates, 3, "three creations");
    }

    // run reverts with a cheatcode error whose message starts with prefix
    function _assertRunFailsReading(string memory prefix) internal {
        try script.run() {
            fail("the run went through");
        } catch (bytes memory err) {
            assertEq(bytes4(err), CheatcodeError.selector, "a cheatcode error");
            bytes memory body = new bytes(err.length - 4);
            for (uint256 i; i < body.length; ++i) {
                body[i] = err[i + 4];
            }
            bytes memory message = bytes(abi.decode(body, (string)));
            bytes memory head = new bytes(bytes(prefix).length);
            for (uint256 i; i < head.length && i < message.length; ++i) {
                head[i] = message[i];
            }
            assertEq(string(head), prefix, string(message));
        }
    }
}

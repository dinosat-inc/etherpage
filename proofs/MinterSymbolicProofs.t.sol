// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {MinterSymbolicTest} from "../test/unit/minter/MinterSymbolic.t.sol";

// the symbolic minter checks of the unit tests, built here so that Halmos runs them on the proofs build
contract MinterSymbolicProofsTest is MinterSymbolicTest {}

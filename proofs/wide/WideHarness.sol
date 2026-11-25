// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {PageCard} from "../../src/PageCard.sol";
import {DepositHarness} from "../DepositProofs.t.sol";

/// @notice DepositHarness plus the state writers the widened proofs need. Test harness only: every
/// PageNFT function is inherited unchanged.
contract WideHarness is DepositHarness {
    constructor(PageCard c) DepositHarness(c) {}

    function h_setPrimary(address a, uint256 id, address holder) external {
        primaryPage[a] = id;
        _primaryHolder[a] = holder;
    }

    function h_setVersion(uint256 id, uint256 v) external {
        recordVersion[id] = v;
    }

    function h_setResolved(uint256 id, address a, address saver) external {
        _resolvedAddress[id][recordVersion[id]] = a;
        _addrSaver[id][recordVersion[id]] = saver;
    }

    function h_setMinter(uint256 parentId, address m, uint64 e, address s) external {
        _subpageMinter[parentId] = SubpageMinter(m, e, s);
    }

    function h_ownerOf(uint256 id) external view returns (address) {
        return _ownerOf(id);
    }

    function h_getApproved(uint256 id) external view returns (address) {
        return _getApproved(id);
    }
}

/// @notice An account with code that takes ETH and, while it is being paid, calls back into PageNFT:
/// it withdraws again for itself and for a victim, and records whether either call went through.
/// With refuse set it rejects every payment.
contract ReentrantPayee {
    address public immutable nft;
    address public victim;
    bool public refuse;
    bool public innerSelfOk;
    bool public innerVictimOk;
    uint256 public received;

    constructor(address n) {
        nft = n;
    }

    function set(address v, bool r) external {
        victim = v;
        refuse = r;
    }

    receive() external payable {
        if (refuse) revert("no");
        received += msg.value;
        (innerSelfOk,) = nft.call(abi.encodeWithSignature("withdraw(address)", address(this)));
        (innerVictimOk,) = nft.call(abi.encodeWithSignature("withdraw(address)", victim));
    }
}

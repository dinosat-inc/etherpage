// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

import {SubpageRegistrar} from "../../src/SubpageRegistrar.sol";

// takes ETH and does nothing else, like a contract that cannot make calls
contract PlainPayout {
    receive() external payable {}
}

// the code behind HeavyPayout: its receive writes fresh storage and logs, far more than a 2300 gas stipend
contract HeavyPayoutLogic {
    event Paid(address indexed from, uint256 value);

    uint256 public received;
    uint256 public payments;
    mapping(uint256 => uint256) public slots;

    receive() external payable {
        received += msg.value;
        payments += 1;
        for (uint256 i; i < 4; ++i) slots[payments * 16 + i] = msg.value + i + 1;
        emit Paid(msg.sender, msg.value);
    }
}

// a proxy shaped like a Safe: every call, a plain ETH transfer included, runs its logic by delegatecall
contract HeavyPayout {
    address immutable logic;

    constructor(address l) {
        logic = l;
    }

    fallback() external payable {
        address l = logic;
        assembly {
            calldatacopy(0, 0, calldatasize())
            let ok := delegatecall(gas(), l, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            if iszero(ok) { revert(0, returndatasize()) }
            return(0, returndatasize())
        }
    }
}

// takes ETH until it is switched to refuse it, and can always claim its proceeds to another address
contract SwitchPayout {
    bool public refusing;

    function setRefusing(bool on) external {
        refusing = on;
    }

    function claim(SubpageRegistrar reg, address to) external returns (uint256) {
        return reg.claimProceeds(to);
    }

    receive() external payable {
        if (refusing) revert("refusing");
    }
}

// takes ETH and, while being paid, tries to claim again with claimProceedsFor for itself and for another account
// and with claimProceeds for itself; the guard refuses all three before anything is logged
contract ReenteringPayout {
    SubpageRegistrar public reg;
    address public other;
    uint256 public refused;
    uint256 public reentered;

    constructor(SubpageRegistrar r, address o) {
        reg = r;
        other = o;
    }

    function claim(address to) external returns (uint256) {
        return reg.claimProceeds(to);
    }

    receive() external payable {
        (bool a,) = address(reg).call(abi.encodeCall(SubpageRegistrar.claimProceedsFor, (address(this))));
        (bool b,) = address(reg).call(abi.encodeCall(SubpageRegistrar.claimProceedsFor, (other)));
        (bool c,) = address(reg).call(abi.encodeCall(SubpageRegistrar.claimProceeds, (address(0))));
        if (a || b || c) ++reentered;
        else ++refused;
    }
}

// burns all the gas it is given when paid
contract BurnerPayout {
    receive() external payable {
        assembly {
            invalid()
        }
    }
}

// buys subpages and has no receive, so it can only pay the exact price
contract NoChangeBuyer {
    function buy(SubpageRegistrar reg, uint256 parentId, string calldata label, address to, uint256 maxPrice)
        external
        payable
        returns (uint256)
    {
        return reg.registerSubpageFor{value: msg.value}(parentId, label, to, maxPrice, address(0));
    }

    function commit(SubpageRegistrar reg, bytes32 c) external {
        reg.commitSubpage(c);
    }

    function reveal(
        SubpageRegistrar reg,
        uint256 parentId,
        string calldata label,
        address to,
        bytes32 secret,
        uint256 maxPrice
    ) external payable returns (uint256) {
        return reg.revealSubpageFor{value: msg.value}(parentId, label, to, secret, maxPrice, address(0));
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}

// claims for many accounts in one transaction: claimAll fails as a whole when one claim fails, claimEach
// caps the gas of each claim and keeps going when one fails
contract ClaimBatcher {
    function claimAll(SubpageRegistrar reg, address[] calldata accounts) external returns (uint256 total) {
        for (uint256 i; i < accounts.length; ++i) total += reg.claimProceedsFor(accounts[i]);
    }

    function claimEach(SubpageRegistrar reg, address[] calldata accounts, uint256 gasCap)
        external
        returns (uint256[] memory paid, bytes[] memory errors)
    {
        paid = new uint256[](accounts.length);
        errors = new bytes[](accounts.length);
        for (uint256 i; i < accounts.length; ++i) {
            try reg.claimProceedsFor{gas: gasCap}(accounts[i]) returns (uint256 a) {
                paid[i] = a;
            } catch (bytes memory e) {
                errors[i] = e;
            }
        }
    }

    // takes ETH, so a payment that wrongly went to the caller would show in its balance
    receive() external payable {}
}

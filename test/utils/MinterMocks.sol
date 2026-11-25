// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

// accepts every ERC721 and every ETH payment
contract Holder721 {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    receive() external payable {}
}

// a contract that holds nothing and has no hook, like a plain contract wallet
contract NoHook {}

// a wallet shaped like a Safe: its owner makes it call anything
contract SafeLike {
    address public immutable owner;

    constructor(address o) {
        owner = o;
    }

    function exec(address to, uint256 value, bytes calldata data) external returns (bytes memory) {
        require(msg.sender == owner, "not owner");
        (bool ok, bytes memory ret) = to.call{value: value}(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        return ret;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    receive() external payable {}
}

// the code an EIP7702 account delegates to
contract Delegate7702 {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    receive() external payable {}
}

// a receiver whose hook makes one configured call and records what came back
contract HookCaller {
    address public target;
    bytes public data;
    bool public bubble;
    bool public called;
    bool public ok;
    bytes public ret;

    function arm(address t, bytes calldata d, bool b) external {
        target = t;
        data = d;
        bubble = b;
        called = false;
        ok = false;
        delete ret;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        if (target != address(0) && !called) {
            called = true;
            (bool s, bytes memory r) = target.call(data);
            ok = s;
            ret = r;
            if (!s && bubble) {
                assembly ("memory-safe") {
                    revert(add(r, 0x20), mload(r))
                }
            }
        }
        return this.onERC721Received.selector;
    }

    // lets the test drive calls from this contract as the sender
    function exec(address to, uint256 value, bytes calldata d) external returns (bytes memory) {
        (bool s, bytes memory r) = to.call{value: value}(d);
        if (!s) {
            assembly ("memory-safe") {
                revert(add(r, 0x20), mload(r))
            }
        }
        return r;
    }

    receive() external payable {}
}

// a buyer whose receive makes one configured call during the refund and records what came back
contract RefundHook {
    address public target;
    bytes public data;
    bool public ok;
    bytes public ret;
    bool public called;

    function arm(address t, bytes calldata d) external {
        target = t;
        data = d;
        called = false;
    }

    function buy(address reg, bytes calldata d, uint256 value) external returns (bytes memory) {
        (bool s, bytes memory r) = reg.call{value: value}(d);
        if (!s) {
            assembly ("memory-safe") {
                revert(add(r, 0x20), mload(r))
            }
        }
        return r;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    receive() external payable {
        if (target != address(0) && !called) {
            called = true;
            (bool s, bytes memory r) = target.call(data);
            ok = s;
            ret = r;
        }
    }
}

// a payout that cannot take ETH
contract RejectETH {
    function claim(address reg, address to) external returns (bytes memory) {
        (bool s, bytes memory r) = reg.call(abi.encodeWithSignature("claimProceeds(address)", to));
        require(s, "claim failed");
        return r;
    }
}

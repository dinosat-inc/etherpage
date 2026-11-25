// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

// An ERC20 that makes one configured call from inside transferFrom, then moves the tokens
contract ReentrantToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    address public target;
    bytes public data;
    bool public called;
    bool public ok;
    bytes public ret;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function arm(address t, bytes calldata d) external {
        target = t;
        data = d;
        called = false;
        ok = false;
        delete ret;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (target != address(0) && !called) {
            called = true;
            (bool s, bytes memory r) = target.call(data);
            ok = s;
            ret = r;
        }
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

// transferFrom returns false and moves nothing
contract FalseToken {
    function balanceOf(address) external pure returns (uint256) {
        return 0;
    }

    function transferFrom(address, address, uint256) external pure returns (bool) {
        return false;
    }
}

// transferFrom returns no data, like USDT on Ethereum mainnet
contract NoReturnToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transferFrom(address from, address to, uint256 amount) external {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

// a holder contract whose owner makes it call anything, and whose token hook can take a subpage back
contract HolderWallet {
    address public immutable owner;
    address public nft;

    constructor(address o, address n) {
        owner = o;
        nft = n;
    }

    function exec(address to, uint256 value, bytes calldata d) external returns (bytes memory) {
        require(msg.sender == owner, "not owner");
        (bool s, bytes memory r) = to.call{value: value}(d);
        if (!s) {
            assembly ("memory-safe") {
                revert(add(r, 0x20), mload(r))
            }
        }
        return r;
    }

    // called by the holder's own fee token during a sale
    function takeBack(string calldata label, uint256 parentId) external {
        (bool s, bytes memory r) =
            nft.call(abi.encodeWithSignature("registerSubpageFor(string,uint256,address)", label, parentId, address(this)));
        if (!s) {
            assembly ("memory-safe") {
                revert(add(r, 0x20), mload(r))
            }
        }
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    receive() external payable {}
}

// a fee token owned by the parent holder that takes the sold subpage back in the same transaction
contract TakeBackToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    HolderWallet public holder;
    string public label;
    uint256 public parentId;

    function set(HolderWallet h, string calldata l, uint256 p) external {
        holder = h;
        label = l;
        parentId = p;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        if (address(holder) != address(0)) holder.takeBack(label, parentId);
        return true;
    }
}

contract RevertGate {
    function balanceOf(address) external pure returns (uint256) {
        revert("no");
    }
}

// writes storage inside balanceOf, which a staticcall forbids
contract WriteGate {
    uint256 public n;

    function balanceOf(address) external returns (uint256) {
        n++;
        return type(uint256).max;
    }
}

// returns 16 bytes only
contract ShortGate {
    fallback() external {
        assembly {
            mstore(0, not(0))
            return(0, 16)
        }
    }
}

// returns 64 bytes, the first word huge
contract LongGate {
    fallback() external {
        assembly {
            mstore(0, not(0))
            mstore(32, 0)
            return(0, 64)
        }
    }
}

// burns every unit of gas it is given
contract GasBurnGate {
    fallback() external {
        assembly {
            for {} 1 {} {}
        }
    }
}

// stands in for a registrar that is hostile or broken: anyone can make it call anything
contract Hostile {
    function exec(address to, bytes calldata d) external returns (bool s, bytes memory r) {
        (s, r) = to.call(d);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}

// a buyer that rejects ETH, so any refund fails
contract RejectingBuyer {
    function buy(address reg, bytes calldata d, uint256 value) external payable returns (bytes memory) {
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
}

// sends its value to a target with SELFDESTRUCT from its constructor, which moves the balance without
// calling the target
contract ForceSend {
    constructor(address payable to) payable {
        selfdestruct(to);
    }
}

// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

// The shape of the EF desktop wallet's SimpleDelegate: receive(), no fallback, no onERC721Received, and an
// executeBatch that only the account itself may call, where the real one checks a signature. An account
// delegated to it is still run by its key, which the tests use directly.
contract SimpleDelegateLike {
    receive() external payable {}

    function executeBatch(address target, uint256 value, bytes calldata data) external {
        require(msg.sender == address(this), "self only");
        (bool ok, bytes memory ret) = target.call{value: value}(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }
}

// The shape of Kohaku's post quantum 4337 account: receive(), an empty payable fallback, and execute
// callable only by the entry point. No onERC721Received.
contract PQAccountLike {
    address public immutable entryPoint;

    constructor(address ep) payable {
        entryPoint = ep;
    }

    function execute(address target, uint256 value, bytes calldata data) external {
        require(msg.sender == entryPoint, "not entry point");
        (bool ok, bytes memory ret) = target.call{value: value}(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }

    receive() external payable {}
    fallback() external payable {}
}

// a plain token: no hook, no receive, and nothing that could ever move an NFT it holds
contract TokenLike {
    mapping(address => uint256) public balanceOf;

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

// WETH9's shape: any call with no matching function deposits and succeeds with no return data
contract WethLike {
    mapping(address => uint256) public balanceOf;

    function deposit() public payable {
        balanceOf[msg.sender] += msg.value;
    }

    receive() external payable {
        deposit();
    }

    fallback() external payable {
        deposit();
    }
}

// a hook that counts calls and, when armed, saves a main address from inside the hook (the push custody route)
contract CountingReceiver {
    address public immutable owner;
    uint256 public hookCalls;
    address public nft;
    address public saveAs;

    constructor(address o) payable {
        owner = o;
    }

    function arm(address n, address a) external {
        nft = n;
        saveAs = a;
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

    function onERC721Received(address, address, uint256 id, bytes calldata) external returns (bytes4) {
        ++hookCalls;
        if (saveAs != address(0) && msg.sender == nft) {
            (bool ok, bytes memory ret) = nft.call(abi.encodeWithSignature("setAddr(uint256,address)", id, saveAs));
            if (!ok) {
                assembly ("memory-safe") {
                    revert(add(ret, 0x20), mload(ret))
                }
            }
        }
        return this.onERC721Received.selector;
    }

    receive() external payable {}
}

// deploys PQAccountLike at a predictable address, so a name can be bought for it before it exists
contract PQFactory {
    function predict(address ep, bytes32 salt) external view returns (address) {
        bytes32 h = keccak256(
            abi.encodePacked(
                bytes1(0xff), address(this), salt,
                keccak256(abi.encodePacked(type(PQAccountLike).creationCode, abi.encode(ep)))
            )
        );
        return address(uint160(uint256(h)));
    }

    function deploy(address ep, bytes32 salt) external returns (address) {
        return address(new PQAccountLike{salt: salt}(ep));
    }
}

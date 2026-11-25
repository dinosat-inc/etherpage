// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

// The functions of PageNFT and SubpageRegistrar that L1TwinTest calls. Its list of calls encodes each entry point
// from these declarations and runs it at the deployed contracts, and its other tests call them through these too.
interface ITwinPageNFT {
    function makeCommitment(string calldata label, address owner, uint256 referrerId, bytes32 secret)
        external
        pure
        returns (bytes32);
    function commit(bytes32 commitment) external;
    function reveal(string calldata label, address owner, uint256 referrerId, bytes32 secret)
        external
        payable
        returns (uint256);
    function revealTrial(string calldata label, address owner, uint256 referrerId, bytes32 secret)
        external
        payable
        returns (uint256);
    function renew(uint256 tokenId) external payable;
    function release(uint256 tokenId) external;
    function getFee(uint256 length) external pure returns (uint256);
    function quote(string calldata label) external view returns (uint256, uint256, uint256, uint256);
    function ownerOf(uint256 id) external view returns (address);
    function balanceOf(address owner) external view returns (uint256);
    function getApproved(uint256 id) external view returns (address);
    function isApprovedForAll(address owner, address operator) external view returns (bool);
    function setSubpageMinter(uint256 parentId, address minter) external;
    function subpageMinterOf(uint256 parentId) external view returns (address);
    function registerSubpage(string calldata label, uint256 parentId) external returns (uint256);
    function registerSubpageFor(string calldata label, uint256 parentId, address to) external returns (uint256);
    function transferFrom(address from, address to, uint256 id) external payable;
    function approve(address account, uint256 id) external payable;
    function setApprovalForAll(address operator, bool approved) external;
    function setText(uint256 tokenId, string calldata key, string calldata value) external;
    function text(uint256 tokenId, string calldata key) external view returns (string memory);
    function setAddr(uint256 tokenId, address a) external;
    function setAddrForCoin(uint256 tokenId, uint256 coinType, bytes calldata a) external;
    function addr(uint256 tokenId, uint256 coinType) external view returns (bytes memory);
    function resolve(uint256 tokenId) external view returns (address);
    function payee(uint256 tokenId) external view returns (address);
    function owed(address account) external view returns (uint256);
    function depositOf(uint256 tokenId) external view returns (uint256);
    function trialPaymentOf(uint256 tokenId) external view returns (address payer, uint96 amount);
    function withdraw(address account) external returns (uint256);
    function isAvailable(string calldata label, uint256 parentId) external view returns (bool);
    function getPageName(uint256 tokenId) external view returns (string memory);
    function computeId(string calldata fullName) external pure returns (uint256);
    function epochOf(uint256 tokenId) external view returns (uint64);
    function expiresAt(uint256 tokenId) external view returns (uint256);
    function multicall(bytes[] calldata data) external returns (bytes[] memory);
}

interface ITwinRegistrar {
    function registry() external view returns (address);
    function configure(
        uint256 parentId,
        address payout,
        address feeToken,
        uint256 price,
        bool enabled,
        address gateToken,
        uint256 minGateBalance,
        bool commitReveal
    ) external;
    function disable(uint256 parentId) external;
    function config(uint256 parentId)
        external
        view
        returns (
            address controller,
            bool enabled,
            bool commitReveal,
            address feeToken,
            uint96 price,
            address gateToken,
            uint96 minGateBalance,
            address payout,
            uint64 parentEpoch
        );
    function makeSubpageCommitment(uint256 parentId, string calldata label, address to, bytes32 secret)
        external
        view
        returns (bytes32);
    function commitSubpage(bytes32 commitment) external;
    function subCommitments(bytes32 commitment) external view returns (uint256);
    function revealSubpage(uint256 parentId, string calldata label, bytes32 secret, uint256 maxPrice, address feeToken)
        external
        payable
        returns (uint256);
    function revealSubpageFor(
        uint256 parentId,
        string calldata label,
        address to,
        bytes32 secret,
        uint256 maxPrice,
        address feeToken
    ) external payable returns (uint256);
    function registerSubpage(uint256 parentId, string calldata label, uint256 maxPrice, address feeToken)
        external
        payable
        returns (uint256);
    function registerSubpageFor(uint256 parentId, string calldata label, address to, uint256 maxPrice, address feeToken)
        external
        payable
        returns (uint256);
    function claimProceeds(address to) external returns (uint256);
    function claimProceedsFor(address account) external returns (uint256);
    function proceedsOf(address account) external view returns (uint256);
}

// a plain ERC20 whose unlimited allowance never goes down, as in most tokens
contract TwinUsd {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transfer(address t, uint256 a) external returns (bool) {
        require(balanceOf[msg.sender] >= a, "balance");
        balanceOf[msg.sender] -= a;
        balanceOf[t] += a;
        return true;
    }

    function transferFrom(address f, address t, uint256 a) external returns (bool) {
        uint256 al = allowance[f][msg.sender];
        require(al >= a, "allowance");
        if (al != type(uint256).max) allowance[f][msg.sender] = al - a;
        require(balanceOf[f] >= a, "balance");
        balanceOf[f] -= a;
        balanceOf[t] += a;
        return true;
    }
}

// a token buyers must hold
contract TwinGate {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }
}

// any other code the deployer's key could put at one of the three addresses on Ethereum
contract TwinOtherCode {
    function hello() external pure returns (uint256) {
        return 42;
    }
}

// code an EIP7702 account could delegate to that creates contracts from the account itself
contract TwinFactoryDelegate {
    function make() external returns (address a) {
        a = address(new TwinOtherCode());
    }
}

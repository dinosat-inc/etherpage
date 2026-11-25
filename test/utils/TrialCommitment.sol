// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.38;

interface ICommitmentMaker {
    function makeCommitment(string calldata label, address owner, uint256 referrerId, bytes32 secret)
        external
        pure
        returns (bytes32);
}

// the trial commitment: the same values with a trial flag. makeCommitment runs first, so an invalid
// label or a self referral reverts there, and a prank set before this call is used up by it
function trialCommitment(address n, string memory label, address owner, uint256 referrerId, bytes32 secret)
    pure
    returns (bytes32)
{
    ICommitmentMaker(n).makeCommitment(label, owner, referrerId, secret);
    return trialCommitmentRaw(label, owner, referrerId, secret);
}

// the same hash without the makeCommitment call, so nothing is checked and a refused label gets a commitment too
function trialCommitmentRaw(string memory label, address owner, uint256 referrerId, bytes32 secret)
    pure
    returns (bytes32)
{
    bytes memory b = bytes(label);
    bytes memory out = new bytes(b.length);
    for (uint256 i; i < b.length; ++i) {
        bytes1 c = b[i];
        out[i] = (c >= 0x41 && c <= 0x5a) ? bytes1(uint8(c) + 32) : c;
    }
    return keccak256(abi.encode(out, owner, referrerId, secret, true));
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface ICollectionWhitelistChecker {
    function canList(uint256 _tokenId) external view returns (bool);
}

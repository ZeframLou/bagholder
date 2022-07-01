// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.14;

function min(uint256 a, uint256 b) pure returns (uint256) {
    return a < b ? a : b;
}
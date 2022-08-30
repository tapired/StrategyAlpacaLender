// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.12;

interface INative {
    function deposit() external payable;

    function decimals() external view returns (uint256);

    function withdraw(uint256) external;
}

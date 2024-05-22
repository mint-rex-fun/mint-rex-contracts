// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface ICollectionFeesCalculator {
    function creator() external view returns (address);

    function calculatePriceAndFees(
        address _buyer,
        uint256 _grossPrice
    )
        external
        view
        returns (uint256 netPrice, uint256 tradingFee, uint256 creatorFee);
}

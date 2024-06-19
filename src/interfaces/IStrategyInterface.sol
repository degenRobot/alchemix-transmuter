// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.18;

import {IStrategy} from "@tokenized-strategy/interfaces/IStrategy.sol";

interface IStrategyInterface is IStrategy {
    //TODO: Add your specific implementation interface in here.
    function claimableBalance() external view returns (uint256);   
    function unexchangedBalance() external view returns (uint256);
    function claimAndSwap(uint256 _amountClaim, uint256 _minOut) external;

}

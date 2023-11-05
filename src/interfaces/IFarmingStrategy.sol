// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

/// @dev Mostly this interface need for front-end and tests for interacting with farming strategies
interface IFarmingStrategy {
    event RewardsClaimed(uint[] amounts);

    /// @notice Index of the farm used by initialized strategy
    function farmId() external view returns (uint);

    /// @notice Strategy can earn money on farm now
    /// Some strategies can continue work and earn pool fees after ending of farm rewards.
    function canFarm() external view returns (bool);
}

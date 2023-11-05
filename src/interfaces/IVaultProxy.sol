// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

/// @dev Interface of proxy contract for a vault implementation
interface IVaultProxy {

  /// @notice Initialize vault proxy by Factory
  /// @param type_ Vault type ID string
  function initProxy(string memory type_) external;

  /// @notice Upgrade vault implementation if available and allowed
  /// Anyone can execute vault upgrade
  function upgrade() external;

  /// @notice Current vault implementation
  /// @return Address of vault implementation contract
  function implementation() external view returns (address);

  // todo change name
  /// @notice Vault type hash
  /// @return keccan256 hash of vault type ID string
  function VAULT_TYPE_HASH() external view returns (bytes32);

}

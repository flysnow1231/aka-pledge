// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @dev Wrapper so Hardhat emits an artifact for `ERC1967Proxy` deployment in TS tests.
contract UUPSProxy is ERC1967Proxy {
  constructor(address implementation, bytes memory _data) payable ERC1967Proxy(implementation, _data) {}
}

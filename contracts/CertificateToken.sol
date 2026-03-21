// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;    
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

/**
 * @dev Simple per-pool certificate token:
 * - Lenders: spToken (decimals match stable token decimals)
 * - Borrowers: jpToken (decimals match collateral token decimals)
 *
 * Minting is restricted to the lending contract.
 */
contract CertificateToken is ERC20Burnable {
  address public minter;
  uint8 private _decimals;

  constructor(
    string memory name_,
    string memory symbol_,
    address minter_,
    uint8 customDecimals_
  ) ERC20(name_, symbol_) {
    require(minter_ != address(0), "MINTER_0");
    _decimals = customDecimals_;
    minter = minter_;
  }

  function decimals() public view virtual override returns (uint8) {
    return _decimals;
  }

  function mint(address to, uint256 amount) external {
    require(msg.sender == minter, "NOT_MINTER");
    _mint(to, amount);
  }

  /**
   * @dev Burn on behalf of a user.
   * This is needed because withdraw functions are executed by the lending contract,
   * so `ERC20Burnable.burn()` would burn from the lending contract's balance.
   */
  function burnFor(address from, uint256 amount) external {
    require(from != address(0), "FROM_0");
    require(amount > 0, "AMOUNT_0");
    require(msg.sender == from || msg.sender == minter, "NOT_ALLOWED");
    _burn(from, amount);
  }
}

  
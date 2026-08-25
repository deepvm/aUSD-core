// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

contract Unit is ERC20, AccessControl {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    mapping(address => bool) public isFrozen;

    event Confiscated(address indexed from, address indexed to, uint256 value);
    event Frozen(address indexed account);
    event Unfrozen(address indexed account);

    error ZeroAddress();
    error AccountFrozen();

    constructor(address admin_) ERC20("Unit USD", "unitUSD") {
        if (admin_ == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function setFrozen(address account, bool frozen) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (account == address(0)) revert ZeroAddress();
        isFrozen[account] = frozen;
        if (frozen) {
            emit Frozen(account);
        } else {
            emit Unfrozen(account);
        }
    }

    function mint(address to, uint256 assets) external onlyRole(MINTER_ROLE) {
        _mint(to, assets);
    }

    function burn(uint256 assets) external {
        _burn(msg.sender, assets);
    }

    function burnFrom(address from, uint256 assets) external {
        _spendAllowance(from, msg.sender, assets);
        _burn(from, assets);
    }

    function confiscate(address from, address to, uint256 value) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _transfer(from, to, value);
        emit Confiscated(from, to, value);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (!hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
            if (from != address(0) && isFrozen[from]) revert AccountFrozen();
            if (to != address(0) && isFrozen[to]) revert AccountFrozen();
        }
        super._update(from, to, value);
    }
}

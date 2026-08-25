// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Unit} from "./Unit.sol";

contract StakedUnit is ERC4626 {
    using SafeERC20 for IERC20;

    event Confiscated(address indexed from, address indexed to, uint256 shares);

    error NonTransferable();
    error AccountFrozen();
    error Unauthorized();
    error VaultInsolvent();

    constructor(IERC20 asset_) ERC20("Staked unitUSD", "sunitUSD") ERC4626(asset_) {}

    function _convertToShares(uint256 assets, Math.Rounding) internal pure override returns (uint256) {
        return assets;
    }

    function _convertToAssets(uint256 shares, Math.Rounding) internal pure override returns (uint256) {
        return shares;
    }

    function _isSolvent() internal view returns (bool) {
        return totalAssets() >= totalSupply();
    }

    function maxDeposit(address receiver) public view override returns (uint256) {
        return _isSolvent() ? super.maxDeposit(receiver) : 0;
    }

    function maxMint(address receiver) public view override returns (uint256) {
        return _isSolvent() ? super.maxMint(receiver) : 0;
    }

    function maxWithdraw(address owner) public view override returns (uint256) {
        return _isSolvent() ? super.maxWithdraw(owner) : 0;
    }

    function maxRedeem(address owner) public view override returns (uint256) {
        return _isSolvent() ? super.maxRedeem(owner) : 0;
    }

    function confiscate(address from, address to, uint256 shares) external {
        Unit unit = Unit(address(asset()));
        if (!unit.hasRole(unit.DEFAULT_ADMIN_ROLE(), msg.sender)) {
            revert Unauthorized();
        }
        _burn(from, shares);
        IERC20(asset()).safeTransfer(to, shares);
        emit Confiscated(from, to, shares);
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        if (!_isSolvent()) revert VaultInsolvent();
        Unit unit = Unit(address(asset()));
        if (unit.isFrozen(caller) || unit.isFrozen(receiver)) revert AccountFrozen();
        super._deposit(caller, receiver, assets, shares);
    }

    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
    {
        if (!_isSolvent()) revert VaultInsolvent();
        Unit unit = Unit(address(asset()));
        if (unit.isFrozen(caller) || unit.isFrozen(receiver) || unit.isFrozen(owner)) revert AccountFrozen();
        super._withdraw(caller, receiver, owner, assets, shares);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            revert NonTransferable();
        }
        super._update(from, to, value);
    }
}

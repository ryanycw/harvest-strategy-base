// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.21;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";

import "../inheritance/Controllable.sol";
import "../PotPool.sol";

contract NotifyHelperGeneric is Controllable {
    using SafeERC20 for IERC20;

    event WhitelistSet(address who, bool value);

    mapping(address => bool) public alreadyNotified;
    mapping(address => bool) public whitelist;

    modifier onlyWhitelisted() {
        require(whitelist[msg.sender] || msg.sender == governance(), "Only whitelisted");
        _;
    }

    constructor(address _storage) Controllable(_storage) {
        setWhitelist(governance(), true);
    }

    function setWhitelist(address who, bool value) public onlyWhitelisted {
        whitelist[who] = value;
        emit WhitelistSet(who, value);
    }

    /**
     * Notifies all the pools, safe guarding the notification amount.
     */
    function notifyPools(uint256[] memory amounts, address[] memory pools, uint256 sum, address _token)
        public
        onlyWhitelisted
    {
        require(amounts.length == pools.length, "Amounts and pools lengths mismatch");
        for (uint256 i = 0; i < pools.length; i++) {
            alreadyNotified[pools[i]] = false;
        }

        uint256 check = 0;
        for (uint256 i = 0; i < pools.length; i++) {
            require(amounts[i] > 0, "Notify zero");
            require(!alreadyNotified[pools[i]], "Duplicate pool");
            IERC20 token = IERC20(_token);
            token.safeTransferFrom(msg.sender, pools[i], amounts[i]);
            PotPool(pools[i]).notifyTargetRewardAmount(_token, amounts[i]);
            check = check + amounts[i];
            alreadyNotified[pools[i]] = true;
        }
        require(sum == check, "Wrong check sum");
    }
}

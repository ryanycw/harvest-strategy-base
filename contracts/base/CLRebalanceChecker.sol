// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.21;

import "./inheritance/Controllable.sol";
import "./interface/ICLVault.sol";

contract CLRebalanceChecker is Controllable {
    address[] public clVaults;

    constructor(address _storage) public Controllable(_storage) {}

    function addVault(address _target) public onlyGovernance {
        clVaults.push(_target);
    }

    function addVaults(address[] memory _targets) public onlyGovernance {
        for (uint256 i = 0; i < _targets.length; i++) {
            addVault(_targets[i]);
        }
    }

    function removeVault(address _target) public onlyGovernance {
        uint256 i = getVaultIndex(_target);
        require(i != type(uint256).max, "Vault does not exists");
        uint256 lastIndex = clVaults.length - 1;

        // swap
        clVaults[i] = clVaults[lastIndex];

        // delete last element
        clVaults.pop();
    }

    function removeVaults(address[] memory _targets) public onlyGovernance {
        for (uint256 i = 0; i < _targets.length; i++) {
            removeVault(_targets[i]);
        }
    }

    // If the return value is MAX_UINT256, it means that
    // the specified vault is not in the list
    function getVaultIndex(address _target) public view returns (uint256) {
        for (uint256 i = 0; i < clVaults.length; i++) {
            if (clVaults[i] == _target) {
                return i;
            }
        }
        return type(uint256).max;
    }

    function checker() external view returns (bool canExec, bytes memory execPayload) {
        for (uint256 i = 0; i < clVaults.length; i++) {
            (canExec, execPayload) = ICLVault(clVaults[i]).checker();
            if (canExec) return (true, execPayload);
        }

        return (false, bytes("No vaults to harvest"));
    }
}

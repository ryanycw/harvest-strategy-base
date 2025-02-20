// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.21;

import {ConstantsLib} from "../libraries/ConstantsLib.sol";
import {BaseUpgradeableStrategyStorage} from "../../../base/upgradability/BaseUpgradeableStrategyStorage.sol";

abstract contract Setters {
    function _setMToken(address _target) internal {
        BaseUpgradeableStrategyStorage.setAddress(ConstantsLib.MTOKEN_SLOT, _target);
    }
}

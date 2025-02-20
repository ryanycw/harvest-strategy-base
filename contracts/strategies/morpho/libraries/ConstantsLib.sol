// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.21;

/// @title ConstantsLib
/// @author Harvest Community Foundation
/// @notice Library exposing constants.
library ConstantsLib {
    /// @dev The address of the WETH token.
    address internal constant WETH = address(0x4200000000000000000000000000000000000006);

    /// @dev The address of the Balancer bVault.
    address internal constant BVAULT = address(0xBA12222222228d8Ba445958a75a0704d566BF2C8);

    /// @dev The address of the Harvest multisig.
    address internal constant HARVEST_MSIG = address(0x97b3e5712CDE7Db13e939a188C8CA90Db5B05131);

    /// @dev The slot of the mToken.
    bytes32 internal constant MTOKEN_SLOT = 0x21e6ad38ea5ca89af03560d16f1da9e505dccbd1ec61d0683be425888164fec3;

    /// @dev The slot of the collateral factor numerator.
    bytes32 internal constant COLLATERALFACTORNUMERATOR_SLOT =
        0x129eccdfbcf3761d8e2f66393221fa8277b7623ad13ed7693a0025435931c64a;

    /// @dev The slot of the factor denominator.
    bytes32 internal constant FACTORDENOMINATOR_SLOT =
        0x4e92df66cc717205e8df80bec55fc1429f703d590a2d456b97b74f0008b4a3ee;

    /// @dev The slot of the borrow target factor numerator.
    bytes32 internal constant BORROWTARGETFACTORNUMERATOR_SLOT =
        0xa65533f4b41f3786d877c8fdd4ae6d27ada84e1d9c62ea3aca309e9aa03af1cd;

    /// @dev The slot of the fold.
    bytes32 internal constant FOLD_SLOT = 0x1841be4c16015a744c9fbf595f7c6b32d40278c16c1fc7cf2de88c6348de44ba;
}

// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.21;

/// @title ErrorsLib
/// @author Harvest Community Foundation
/// @notice Library exposing error messages.
library ErrorsLib {
    /// @notice Error message for when the mToken slot is not correct.
    error MTOKEN_SLOT_NOT_CORRECT();

    /// @notice Error message for when the collateral factor numerator slot is not correct.
    error COLLATERALFACTORNUMERATOR_SLOT_NOT_CORRECT();

    /// @notice Error message for when the factor denominator slot is not correct.
    error FACTORDENOMINATOR_SLOT_NOT_CORRECT();

    /// @notice Error message for when the borrow target factor numerator slot is not correct.
    error BORROWTARGETFACTORNUMERATOR_SLOT_NOT_CORRECT();

    /// @notice Error message for when the fold slot is not correct.
    error FOLD_SLOT_NOT_CORRECT();
}

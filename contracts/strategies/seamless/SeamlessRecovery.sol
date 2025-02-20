// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.21;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../../base/interface/IUniversalLiquidator.sol";
import "../../base/interface/IVault.sol";
import "../../base/upgradability/BaseUpgradeableStrategy.sol";
import "../../base/interface/seamless/IAToken.sol";
import "../../base/interface/seamless/IDebtToken.sol";
import "../../base/interface/seamless/IIncentivesController.sol";
import "../../base/interface/seamless/IPool.sol";
import "../../base/interface/seamless/ReserveConfiguration.sol";
import "../../base/interface/seamless/DataTypes.sol";
import "../../base/interface/seamless/IEscrowSeam.sol";
import "../../base/interface/balancer/IBVault.sol";

contract SeamlessRecovery is BaseUpgradeableStrategy {
    using SafeERC20 for IERC20;
    using ReserveConfiguration for DataTypes.ReserveConfigurationMap;

    address public constant bVault = address(0xBA12222222228d8Ba445958a75a0704d566BF2C8);
    address public constant harvestMSIG = address(0x97b3e5712CDE7Db13e939a188C8CA90Db5B05131);

    // additional storage slots (on top of BaseUpgradeableStrategy ones) are defined here
    bytes32 internal constant _ATOKEN_SLOT = 0x8cdee58637b787efaa2d78bb1da1e053a2c91e61640b32339bfbba65c00abd68;
    bytes32 internal constant _DEBT_TOKEN_SLOT = 0x29e482e0e21cdcc43d1f0a48ba975f14078bf56d1ca40ed3f48e655ac06df8cb;
    bytes32 internal constant _COLLATERALFACTORNUMERATOR_SLOT =
        0x129eccdfbcf3761d8e2f66393221fa8277b7623ad13ed7693a0025435931c64a;
    bytes32 internal constant _FACTORDENOMINATOR_SLOT =
        0x4e92df66cc717205e8df80bec55fc1429f703d590a2d456b97b74f0008b4a3ee;
    bytes32 internal constant _BORROWTARGETFACTORNUMERATOR_SLOT =
        0xa65533f4b41f3786d877c8fdd4ae6d27ada84e1d9c62ea3aca309e9aa03af1cd;
    bytes32 internal constant _FOLD_SLOT = 0x1841be4c16015a744c9fbf595f7c6b32d40278c16c1fc7cf2de88c6348de44ba;

    bool internal makingFlashDeposit;
    bool internal makingFlashWithdrawal;

    // this would be reset on each upgrade
    address[] public rewardTokens;

    constructor() public BaseUpgradeableStrategy() {
        assert(_ATOKEN_SLOT == bytes32(uint256(keccak256("eip1967.strategyStorage.aToken")) - 1));
        assert(_DEBT_TOKEN_SLOT == bytes32(uint256(keccak256("eip1967.strategyStorage.debtToken")) - 1));
        assert(
            _COLLATERALFACTORNUMERATOR_SLOT
                == bytes32(uint256(keccak256("eip1967.strategyStorage.collateralFactorNumerator")) - 1)
        );
        assert(_FACTORDENOMINATOR_SLOT == bytes32(uint256(keccak256("eip1967.strategyStorage.factorDenominator")) - 1));
        assert(
            _BORROWTARGETFACTORNUMERATOR_SLOT
                == bytes32(uint256(keccak256("eip1967.strategyStorage.borrowTargetFactorNumerator")) - 1)
        );
        assert(_FOLD_SLOT == bytes32(uint256(keccak256("eip1967.strategyStorage.fold")) - 1));
    }

    function initializeBaseStrategy(
        address _storage,
        address _underlying,
        address _vault,
        address _aToken,
        address _debtToken,
        address _rewardToken,
        uint256 _borrowTargetFactorNumerator,
        uint256 _collateralFactorNumerator,
        uint256 _factorDenominator,
        bool _fold
    ) public initializer {
        BaseUpgradeableStrategy.initialize(
            _storage, _underlying, _vault, IAToken(_aToken).getIncentivesController(), _rewardToken, harvestMSIG
        );

        require(IAToken(_aToken).UNDERLYING_ASSET_ADDRESS() == _underlying, "Underlying mismatch");
        _setAToken(_aToken);
        require(IDebtToken(_debtToken).UNDERLYING_ASSET_ADDRESS() == _underlying, "Underlying mismatch");
        _setDebtToken(_debtToken);

        require(_collateralFactorNumerator < _factorDenominator, "Num too high");
        require(_borrowTargetFactorNumerator < _collateralFactorNumerator, "Tar too high");
        _setFactorDenominator(_factorDenominator);
        setUint256(_COLLATERALFACTORNUMERATOR_SLOT, _collateralFactorNumerator);
        setUint256(_BORROWTARGETFACTORNUMERATOR_SLOT, _borrowTargetFactorNumerator);
        setBoolean(_FOLD_SLOT, _fold);
    }

    function currentSupplied() public view returns (uint256) {
        return IAToken(aToken()).balanceOf(address(this));
    }

    function currentBorrowed() public view returns (uint256) {
        return IDebtToken(debtToken()).balanceOf(address(this));
    }

    function depositArbCheck() public pure returns (bool) {
        // there's no arb here.
        return true;
    }

    function unsalvagableTokens(address token) public view returns (bool) {
        return (token == rewardToken() || token == underlying() || token == aToken() || token == debtToken());
    }

    /**
     * Exits Moonwell and transfers everything to the vault.
     */
    function withdrawAllToVault() public restricted {
        address _underlying = underlying();
        if (IERC20(_underlying).balanceOf(address(this)) > 0) {
            IERC20(_underlying).safeTransfer(vault(), IERC20(_underlying).balanceOf(address(this)));
        }
    }

    function withdrawToVault(uint256 amountUnderlying) public restricted {
        address _underlying = underlying();
        uint256 balance = IERC20(_underlying).balanceOf(address(this));
        if (amountUnderlying <= balance) {
            IERC20(_underlying).safeTransfer(vault(), amountUnderlying);
        } else {
            IERC20(_underlying).safeTransfer(vault(), balance);
        }
        return;
    }

    /**
     * Withdraws all assets, liquidates XVS, and invests again in the required ratio.
     */
    function doHardWork() public restricted {
        _claimRewards();
        _liquidateRewards();
    }

    /**
     * Salvages a token.
     */
    function salvage(address recipient, address token, uint256 amount) public onlyGovernance {
        // To make sure that governance cannot come in and take away the coins
        require(!unsalvagableTokens(token), "token is defined as not salvagable");
        IERC20(token).safeTransfer(recipient, amount);
    }

    function _claimRewards() internal {
        address _aToken = aToken();
        address incentivesController = IAToken(_aToken).getIncentivesController();
        address[] memory assets = new address[](2);
        assets[0] = _aToken;
        assets[1] = debtToken();
        if (
            IIncentivesController(incentivesController).getUserRewards(
                assets, address(this), address(0x998e44232BEF4F8B033e5A5175BDC97F2B10d5e5)
            ) > 0
        ) {
            IIncentivesController(incentivesController).claimAllRewards(assets, address(this));
        }
        if (IEscrowSeam(address(0x998e44232BEF4F8B033e5A5175BDC97F2B10d5e5)).getClaimableAmount(address(this)) > 0) {
            IEscrowSeam(address(0x998e44232BEF4F8B033e5A5175BDC97F2B10d5e5)).claim(address(this));
        }
    }

    function _liquidateRewards() internal {
        for (uint256 i; i < rewardTokens.length; i++) {
            address token = rewardTokens[i];
            uint256 balance = IERC20(token).balanceOf(address(this));
            if (balance == 0) {
                continue;
            }
            IERC20(token).safeTransfer(governance(), balance);
        }
    }

    /**
     * Returns the current balance.
     */
    function investedUnderlyingBalance() public view returns (uint256) {
        // underlying in this strategy + underlying redeemable from Radiant - debt
        return IERC20(underlying()).balanceOf(address(this)).add(currentSupplied()).sub(currentBorrowed());
    }

    // updating collateral factor
    // note 1: one should settle the loan first before calling this
    // note 2: collateralFactorDenominator is 1000, therefore, for 20%, you need 200
    function _setCollateralFactorNumerator(uint256 _numerator) public onlyGovernance {
        require(_numerator <= factorDenominator(), "Collateral factor cannot be this high");
        require(_numerator > borrowTargetFactorNumerator(), "Collateral factor should be higher than borrow target");
        setUint256(_COLLATERALFACTORNUMERATOR_SLOT, _numerator);
    }

    function collateralFactorNumerator() public view returns (uint256) {
        return getUint256(_COLLATERALFACTORNUMERATOR_SLOT);
    }

    function _setFactorDenominator(uint256 _denominator) internal {
        setUint256(_FACTORDENOMINATOR_SLOT, _denominator);
    }

    function factorDenominator() public view returns (uint256) {
        return getUint256(_FACTORDENOMINATOR_SLOT);
    }

    function setBorrowTargetFactorNumerator(uint256 _numerator) public onlyGovernance {
        require(_numerator < collateralFactorNumerator(), "Target should be lower than collateral limit");
        setUint256(_BORROWTARGETFACTORNUMERATOR_SLOT, _numerator);
    }

    function borrowTargetFactorNumerator() public view returns (uint256) {
        return getUint256(_BORROWTARGETFACTORNUMERATOR_SLOT);
    }

    function setFold(bool _fold) public onlyGovernance {
        setBoolean(_FOLD_SLOT, _fold);
    }

    function fold() public view returns (bool) {
        return getBoolean(_FOLD_SLOT);
    }

    function _setAToken(address _target) internal {
        setAddress(_ATOKEN_SLOT, _target);
    }

    function aToken() public view returns (address) {
        return getAddress(_ATOKEN_SLOT);
    }

    function _setDebtToken(address _target) internal {
        setAddress(_DEBT_TOKEN_SLOT, _target);
    }

    function debtToken() public view returns (address) {
        return getAddress(_DEBT_TOKEN_SLOT);
    }

    function finalizeUpgrade() external onlyGovernance {
        _finalizeUpgrade();
    }

    receive() external payable {}
}

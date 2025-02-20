// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.21;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import "../../base/interface/IUniversalLiquidator.sol";
import "../../base/interface/IVault.sol";
import "../../base/upgradability/BaseUpgradeableStrategy.sol";
import "../../base/interface/seamless/IAToken.sol";
import "../../base/interface/seamless/IDebtToken.sol";
import "../../base/interface/seamless/IIncentivesController.sol";
import "../../base/interface/seamless/IPool.sol";
import "../../base/interface/seamless/ReserveConfiguration.sol";
import "../../base/interface/seamless/DataTypes.sol";
import "../../base/interface/balancer/IBVault.sol";

contract SeamlessFoldStrategy is BaseUpgradeableStrategy {
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
     * The strategy invests by supplying the underlying as a collateral.
     */
    function _investAllUnderlying() internal onlyNotPausedInvesting {
        uint256 underlyingBalance = IERC20(underlying()).balanceOf(address(this));
        if (underlyingBalance > 0) {
            _supply(underlyingBalance);
        }
        if (!fold()) {
            return;
        }
        _depositWithFlashloan();
    }

    /**
     * Exits Moonwell and transfers everything to the vault.
     */
    function withdrawAllToVault() public restricted {
        address _underlying = underlying();
        _withdrawMaximum(true);
        if (IERC20(_underlying).balanceOf(address(this)) > 0) {
            IERC20(_underlying).safeTransfer(vault(), IERC20(_underlying).balanceOf(address(this)));
        }
    }

    function emergencyExit() external onlyGovernance {
        _withdrawMaximum(false);
    }

    function _withdrawMaximum(bool claim) internal {
        if (claim) {
            _claimRewards();
            _liquidateRewards();
        }
        _redeemMaximumWithFlashloan();
    }

    function withdrawToVault(uint256 amountUnderlying) public restricted {
        address _underlying = underlying();
        uint256 balance = IERC20(_underlying).balanceOf(address(this));
        if (amountUnderlying <= balance) {
            IERC20(_underlying).safeTransfer(vault(), amountUnderlying);
            return;
        }
        uint256 toRedeem = amountUnderlying.sub(balance);
        // get some of the underlying
        _redeemPartial(toRedeem);
        // transfer the amount requested (or the amount we have) back to vault()
        IERC20(_underlying).safeTransfer(vault(), amountUnderlying);
        balance = IERC20(_underlying).balanceOf(address(this));
        if (balance > 0) {
            _investAllUnderlying();
        }
    }

    /**
     * Withdraws all assets, liquidates XVS, and invests again in the required ratio.
     */
    function doHardWork() public restricted {
        _claimRewards();
        _liquidateRewards();
        _investAllUnderlying();
    }

    /**
     * Redeems `amountUnderlying` or fails.
     */
    function _redeemPartial(uint256 amountUnderlying) internal {
        address _underlying = underlying();
        uint256 balanceBefore = IERC20(_underlying).balanceOf(address(this));
        _redeemWithFlashloan(amountUnderlying, fold() ? borrowTargetFactorNumerator() : 0);
        uint256 balanceAfter = IERC20(_underlying).balanceOf(address(this));
        require(balanceAfter.sub(balanceBefore) >= amountUnderlying, "Unable to withdraw amount");
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
        IIncentivesController(incentivesController).claimAllRewards(assets, address(this));
    }

    function _liquidateRewards() internal {
        if (!sell()) {
            // Profits can be disabled for possible simplified and rapid exit
            emit ProfitsNotCollected(sell(), false);
            return;
        }
        address _rewardToken = rewardToken();
        address _universalLiquidator = universalLiquidator();
        for (uint256 i; i < rewardTokens.length; i++) {
            address token = rewardTokens[i];
            uint256 balance = IERC20(token).balanceOf(address(this));
            if (balance == 0) {
                continue;
            }
            if (token != _rewardToken) {
                IERC20(token).safeApprove(_universalLiquidator, 0);
                IERC20(token).safeApprove(_universalLiquidator, balance);
                IUniversalLiquidator(_universalLiquidator).swap(token, _rewardToken, balance, 1, address(this));
            }
        }
        uint256 rewardBalance = IERC20(_rewardToken).balanceOf(address(this));
        _notifyProfitInRewardToken(_rewardToken, rewardBalance);
        uint256 remainingRewardBalance = IERC20(_rewardToken).balanceOf(address(this));

        if (remainingRewardBalance == 0) {
            return;
        }

        address _underlying = underlying();
        if (_underlying != _rewardToken) {
            IERC20(_rewardToken).safeApprove(_universalLiquidator, 0);
            IERC20(_rewardToken).safeApprove(_universalLiquidator, remainingRewardBalance);
            IUniversalLiquidator(_universalLiquidator).swap(
                _rewardToken, _underlying, remainingRewardBalance, 1, address(this)
            );
        }
    }

    /**
     * Returns the current balance.
     */
    function investedUnderlyingBalance() public view returns (uint256) {
        // underlying in this strategy + underlying redeemable from Radiant - debt
        return IERC20(underlying()).balanceOf(address(this)).add(currentSupplied()).sub(currentBorrowed());
    }

    /**
     * Supplies to Moonwel
     */
    function _supply(uint256 amount) internal {
        if (amount == 0) {
            return;
        }
        address _underlying = underlying();
        address _pool = IAToken(aToken()).POOL();
        IERC20(_underlying).safeApprove(_pool, 0);
        IERC20(_underlying).safeApprove(_pool, amount);
        IPool(_pool).supply(_underlying, amount, address(this), 0);
    }

    /**
     * Borrows against the collateral
     */
    function _borrow(uint256 amountUnderlying) internal {
        if (amountUnderlying == 0) {
            return;
        }
        address _pool = IAToken(aToken()).POOL();
        IPool(_pool).borrow(underlying(), amountUnderlying, 2, 0, address(this));
    }

    function _redeem(uint256 amountUnderlying) internal {
        if (amountUnderlying == 0) {
            return;
        }
        address _pool = IAToken(aToken()).POOL();
        IPool(_pool).withdraw(underlying(), amountUnderlying, address(this));
    }

    function _repay(uint256 amountUnderlying) internal {
        if (amountUnderlying == 0) {
            return;
        }
        address _underlying = underlying();
        address _pool = IAToken(aToken()).POOL();
        IERC20(_underlying).safeApprove(_pool, 0);
        IERC20(_underlying).safeApprove(_pool, amountUnderlying);
        IPool(_pool).repay(_underlying, amountUnderlying, 2, address(this));
    }

    function _redeemMaximumWithFlashloan() internal {
        uint256 balance = currentSupplied().sub(currentBorrowed());

        _redeemWithFlashloan(balance, 0);
        if (currentSupplied() > 0) {
            _redeem(type(uint256).max);
        }
    }

    function _depositWithFlashloan() internal {
        address _underlying = underlying();
        uint256 _denom = factorDenominator();
        uint256 _borrowNum = borrowTargetFactorNumerator();
        uint256 borrowed = currentBorrowed();
        uint256 balance = currentSupplied().sub(borrowed);
        uint256 borrowTarget = balance.mul(_borrowNum).div(_denom.sub(_borrowNum));
        uint256 borrowDiff;
        if (borrowed > borrowTarget) {
            _redeemPartial(0);
            borrowDiff = 0;
        } else {
            borrowDiff = borrowTarget.sub(borrowed);
            uint256 borrowAvail;
            {
                address _pool = IAToken(aToken()).POOL();
                DataTypes.ReserveConfigurationMap memory reserveConfig = IPool(_pool).getConfiguration(_underlying);
                uint256 decimals = ReserveConfiguration.getDecimals(reserveConfig);
                uint256 borrowCap = ReserveConfiguration.getBorrowCap(reserveConfig).mul(10 ** decimals);
                uint256 totalBorrows = IDebtToken(debtToken()).totalSupply();
                if (totalBorrows < borrowCap) {
                    borrowAvail = borrowCap.sub(totalBorrows).sub(1);
                } else {
                    borrowAvail = 0;
                }
            }
            if (borrowDiff > borrowAvail) {
                borrowDiff = borrowAvail;
            }
        }
        uint256 balancerBalance = IERC20(_underlying).balanceOf(bVault);

        if (borrowDiff > balancerBalance) {
            _depositNoFlash(currentSupplied(), borrowed, _denom, _borrowNum);
        } else if (borrowDiff > 0) {
            address[] memory tokens = new address[](1);
            uint256[] memory amounts = new uint256[](1);
            bytes memory userData = abi.encode(0);
            tokens[0] = _underlying;
            amounts[0] = borrowDiff;
            makingFlashDeposit = true;
            IBVault(bVault).flashLoan(address(this), tokens, amounts, userData);
            makingFlashDeposit = false;
        } else {
            _supply(IERC20(_underlying).balanceOf(address(this)));
        }
    }

    function _redeemWithFlashloan(uint256 amount, uint256 borrowTargetFactorNumerator) internal {
        uint256 borrowed = currentBorrowed();
        uint256 newBorrowTarget;
        {
            uint256 oldBalance = currentSupplied().sub(borrowed);
            uint256 newBalance = oldBalance.sub(amount);
            newBorrowTarget =
                newBalance.mul(borrowTargetFactorNumerator).div(factorDenominator().sub(borrowTargetFactorNumerator));
        }
        uint256 borrowDiff;
        if (borrowed < newBorrowTarget) {
            borrowDiff = 0;
        } else {
            borrowDiff = borrowed.sub(newBorrowTarget);
        }
        address _underlying = underlying();
        uint256 balancerBalance = IERC20(_underlying).balanceOf(bVault);

        if (borrowDiff > balancerBalance) {
            _redeemNoFlash(amount, currentSupplied(), borrowed, factorDenominator(), borrowTargetFactorNumerator);
        } else if (borrowDiff > 0) {
            address[] memory tokens = new address[](1);
            uint256[] memory amounts = new uint256[](1);
            bytes memory userData = abi.encode(0);
            tokens[0] = _underlying;
            amounts[0] = borrowDiff;
            makingFlashWithdrawal = true;
            IBVault(bVault).flashLoan(address(this), tokens, amounts, userData);
            makingFlashWithdrawal = false;
            _redeem(amount);
        } else {
            _redeem(amount);
        }
    }

    function receiveFlashLoan(
        IERC20[] memory, /*tokens*/
        uint256[] memory amounts,
        uint256[] memory feeAmounts,
        bytes memory /*userData*/
    ) external {
        require(msg.sender == bVault);
        require(!makingFlashDeposit || !makingFlashWithdrawal, "Only one can be true");
        require(makingFlashDeposit || makingFlashWithdrawal, "One has to be true");
        address _underlying = underlying();
        uint256 balance = IERC20(_underlying).balanceOf(address(this));
        uint256 toRepay = amounts[0].add(feeAmounts[0]);
        if (makingFlashDeposit) {
            _supply(balance);
            _borrow(toRepay);
        } else {
            uint256 repaying;
            if (balance > currentBorrowed()) {
                repaying = type(uint256).max;
            } else {
                repaying = balance;
            }
            _repay(repaying);
            _redeem(toRepay);
        }
        IERC20(_underlying).safeTransfer(bVault, toRepay);
    }

    function _depositNoFlash(uint256 supplied, uint256 borrowed, uint256 _denom, uint256 _borrowNum) internal {
        address _underlying = underlying();
        uint256 balance = supplied.sub(borrowed);
        uint256 borrowTarget = balance.mul(_borrowNum).div(_denom.sub(_borrowNum));
        {
            address _pool = IAToken(aToken()).POOL();
            DataTypes.ReserveConfigurationMap memory reserveConfig = IPool(_pool).getConfiguration(_underlying);
            uint256 decimals = ReserveConfiguration.getDecimals(reserveConfig);
            uint256 borrowCap = ReserveConfiguration.getBorrowCap(reserveConfig).mul(10 ** decimals);
            uint256 totalBorrows = IDebtToken(debtToken()).totalSupply();
            uint256 borrowAvail;
            if (totalBorrows < borrowCap) {
                borrowAvail = borrowCap.sub(totalBorrows).sub(1);
            } else {
                borrowAvail = 0;
            }
            if (borrowTarget.sub(borrowed) > borrowAvail) {
                borrowTarget = borrowed.add(borrowAvail);
            }
        }
        while (borrowed < borrowTarget) {
            uint256 wantBorrow = borrowTarget.sub(borrowed);
            uint256 maxBorrow = supplied.mul(collateralFactorNumerator()).div(_denom).sub(borrowed);
            _borrow(Math.min(wantBorrow, maxBorrow));
            uint256 underlyingBalance = IERC20(_underlying).balanceOf(address(this));
            if (underlyingBalance > 0) {
                _supply(underlyingBalance);
            }
            borrowed = currentBorrowed();
            supplied = currentSupplied();
        }
    }

    function _redeemNoFlash(uint256 amount, uint256 supplied, uint256 borrowed, uint256 _denom, uint256 _borrowNum)
        internal
    {
        address _underlying = underlying();
        uint256 newBorrowTarget;
        {
            uint256 oldBalance = supplied.sub(borrowed);
            uint256 newBalance = oldBalance.sub(amount);
            newBorrowTarget = newBalance.mul(_borrowNum).div(_denom.sub(_borrowNum));
        }
        while (borrowed > newBorrowTarget) {
            uint256 requiredCollateral = borrowed.mul(_denom).div(collateralFactorNumerator());
            uint256 toRepay = borrowed.sub(newBorrowTarget);
            // redeem just as much as needed to repay the loan
            // supplied - requiredCollateral = max redeemable, amount + repay = needed
            uint256 toRedeem = Math.min(supplied.sub(requiredCollateral), amount.add(toRepay));
            _redeem(toRedeem);
            // now we can repay our borrowed amount
            uint256 underlyingBalance = IERC20(_underlying).balanceOf(address(this));
            _repay(Math.min(toRepay, underlyingBalance));
            // update the parameters
            supplied = currentSupplied();
            borrowed = currentBorrowed();
        }
        uint256 underlyingBalance = IERC20(_underlying).balanceOf(address(this));
        if (underlyingBalance < amount) {
            uint256 toRedeem = amount.sub(underlyingBalance);
            uint256 balance = supplied.sub(borrowed);
            // redeem the most we can redeem
            if (balance < toRedeem) {
                toRedeem = type(uint256).max;
            }
            _redeem(toRedeem);
        }
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

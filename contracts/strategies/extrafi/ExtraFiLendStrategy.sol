// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.21;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import "../../base/interface/IUniversalLiquidator.sol";
import "../../base/upgradability/BaseUpgradeableStrategy.sol";
import "../../base/interface/extrafi/ILendingPool.sol";
import "../../base/interface/extrafi/IStakingRewards.sol";

contract ExtraFiLendStrategy is BaseUpgradeableStrategy {
    using SafeERC20 for IERC20;

    address public constant weth = address(0x4200000000000000000000000000000000000006);
    address public constant harvestMSIG = address(0x97b3e5712CDE7Db13e939a188C8CA90Db5B05131);

    // additional storage slots (on top of BaseUpgradeableStrategy ones) are defined here
    bytes32 internal constant _MARKET_SLOT = 0x7e894854bb2aa938fcac0eb9954ddb51bd061fc228fb4e5b8e859d96c06bfaa0;
    bytes32 internal constant _RESERVE_ID_SLOT = 0x86aa26bf7baa3789bd8bb93af5347b4e50191118805c3e074f92814ccc798549;
    bytes32 internal constant _STORED_SUPPLIED_SLOT = 0x280539da846b4989609abdccfea039bd1453e4f710c670b29b9eeaca0730c1a2;
    bytes32 internal constant _PENDING_FEE_SLOT = 0x0af7af9f5ccfa82c3497f40c7c382677637aee27293a6243a22216b51481bd97;

    // this would be reset on each upgrade
    address[] public rewardTokens;

    constructor() public BaseUpgradeableStrategy() {
        assert(_MARKET_SLOT == bytes32(uint256(keccak256("eip1967.strategyStorage.market")) - 1));
        assert(_RESERVE_ID_SLOT == bytes32(uint256(keccak256("eip1967.strategyStorage.reserveId")) - 1));
        assert(_STORED_SUPPLIED_SLOT == bytes32(uint256(keccak256("eip1967.strategyStorage.storedSupplied")) - 1));
        assert(_PENDING_FEE_SLOT == bytes32(uint256(keccak256("eip1967.strategyStorage.pendingFee")) - 1));
    }

    function initializeBaseStrategy(
        address _storage,
        address _underlying,
        address _vault,
        address _market,
        uint256 _reserveId,
        address _rewardPool,
        address _rewardToken
    ) public initializer {
        BaseUpgradeableStrategy.initialize(_storage, _underlying, _vault, _rewardPool, _rewardToken, harvestMSIG);

        require(ILendingPool(_market).getUnderlyingTokenAddress(_reserveId) == _underlying, "Underlying mismatch");
        require(ILendingPool(_market).getStakingAddress(_reserveId) == _rewardPool, "RewardPool mismatch");
        _setMarket(_market);
        _setReserveId(_reserveId);
    }

    function currentBalance() public view returns (uint256) {
        uint256 balance = IStakingRewards(rewardPool()).balanceOf(address(this));
        uint256 exchangeRate = ILendingPool(market()).exchangeRateOfReserve(reserveId());
        return balance.mul(exchangeRate).div(1e18);
    }

    function storedBalance() public view returns (uint256) {
        return getUint256(_STORED_SUPPLIED_SLOT);
    }

    function _updateStoredBalance() internal {
        uint256 balance = currentBalance();
        setUint256(_STORED_SUPPLIED_SLOT, balance);
    }

    function totalFeeNumerator() public view returns (uint256) {
        return strategistFeeNumerator().add(platformFeeNumerator()).add(profitSharingNumerator());
    }

    function pendingFee() public view returns (uint256) {
        return getUint256(_PENDING_FEE_SLOT);
    }

    function _accrueFee() internal {
        uint256 fee;
        if (currentBalance() > storedBalance()) {
            uint256 balanceIncrease = currentBalance().sub(storedBalance());
            fee = balanceIncrease.mul(totalFeeNumerator()).div(feeDenominator());
        }
        setUint256(_PENDING_FEE_SLOT, pendingFee().add(fee));
        _updateStoredBalance();
    }

    function _handleFee() internal {
        _accrueFee();
        uint256 fee = pendingFee();
        if (fee > 100) {
            uint256 balanceIncrease = fee.mul(feeDenominator()).div(totalFeeNumerator());
            _redeem(fee);
            address _underlying = underlying();
            if (IERC20(_underlying).balanceOf(address(this)) < fee) {
                balanceIncrease =
                    IERC20(_underlying).balanceOf(address(this)).mul(feeDenominator()).div(totalFeeNumerator());
            }
            _notifyProfitInRewardToken(_underlying, balanceIncrease);
            setUint256(_PENDING_FEE_SLOT, 0);
        }
    }

    function depositArbCheck() public pure returns (bool) {
        // there's no arb here.
        return true;
    }

    function unsalvagableTokens(address token) public view returns (bool) {
        return (token == rewardToken() || token == underlying());
    }

    /**
     * The strategy invests by supplying the underlying as a collateral.
     */
    function _investAllUnderlying() internal onlyNotPausedInvesting {
        address _underlying = underlying();
        uint256 underlyingBalance = IERC20(_underlying).balanceOf(address(this));
        if (underlyingBalance > 0) {
            _supply(underlyingBalance);
        }
    }

    /**
     * Exits Moonwell and transfers everything to the vault.
     */
    function withdrawAllToVault() public restricted {
        _handleFee();
        _claimRewards();
        _liquidateRewards();
        address _underlying = underlying();
        _redeemAll();
        if (IERC20(_underlying).balanceOf(address(this)) > 0) {
            IERC20(_underlying).safeTransfer(vault(), IERC20(_underlying).balanceOf(address(this)).sub(pendingFee()));
        }
        _updateStoredBalance();
    }

    function emergencyExit() external onlyGovernance {
        _accrueFee();
        _redeemAll();
        _setPausedInvesting(true);
        _updateStoredBalance();
    }

    function continueInvesting() public onlyGovernance {
        _setPausedInvesting(false);
    }

    function withdrawToVault(uint256 amountUnderlying) public restricted {
        _accrueFee();
        address _underlying = underlying();
        uint256 balance = IERC20(_underlying).balanceOf(address(this));
        if (amountUnderlying <= balance) {
            IERC20(_underlying).safeTransfer(vault(), amountUnderlying);
            return;
        }
        uint256 toRedeem = amountUnderlying.sub(balance);
        // get some of the underlying
        _redeem(toRedeem);
        balance = IERC20(_underlying).balanceOf(address(this));
        // transfer the amount requested (or the amount we have) back to vault()
        IERC20(_underlying).safeTransfer(vault(), Math.min(amountUnderlying, balance));
        balance = IERC20(_underlying).balanceOf(address(this));
        if (balance > 0) {
            _investAllUnderlying();
        }
        _updateStoredBalance();
    }

    /**
     * Withdraws all assets, liquidates XVS, and invests again in the required ratio.
     */
    function doHardWork() public restricted {
        _handleFee();
        _claimRewards();
        _liquidateRewards();
        _investAllUnderlying();
        _updateStoredBalance();
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
        IStakingRewards(rewardPool()).claim();
    }

    function addRewardToken(address _token) public onlyGovernance {
        rewardTokens.push(_token);
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

        if (remainingRewardBalance < 1e13) {
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
        return IERC20(underlying()).balanceOf(address(this)).add(storedBalance()).sub(pendingFee());
    }

    function _supply(uint256 amount) internal {
        address _underlying = underlying();
        address _market = market();
        uint256 exchangeRate = ILendingPool(_market).exchangeRateOfReserve(reserveId());
        if (amount.mul(10) > exchangeRate.mul(10).div(1e18)) {
            IERC20(_underlying).safeApprove(_market, 0);
            IERC20(_underlying).safeApprove(_market, amount);
            ILendingPool(_market).depositAndStake(reserveId(), amount, address(this), uint16(0));
        }
    }

    function _redeem(uint256 amountUnderlying) internal {
        address _market = market();
        uint256 _reserveId = reserveId();
        uint256 exchangeRate = ILendingPool(_market).exchangeRateOfReserve(_reserveId);
        uint256 amount = amountUnderlying.mul(1e18).div(exchangeRate).add(1);
        ILendingPool(_market).unStakeAndWithdraw(_reserveId, amount, address(this), false);
    }

    function _redeemAll() internal {
        if (IStakingRewards(rewardPool()).balanceOf(address(this)) > 0) {
            ILendingPool(market()).unStakeAndWithdraw(
                reserveId(), IStakingRewards(rewardPool()).balanceOf(address(this)), address(this), false
            );
        }
    }

    function _setMarket(address _target) internal {
        setAddress(_MARKET_SLOT, _target);
    }

    function market() public view returns (address) {
        return getAddress(_MARKET_SLOT);
    }

    function _setReserveId(uint256 _target) internal {
        setUint256(_RESERVE_ID_SLOT, _target);
    }

    function reserveId() public view returns (uint256) {
        return getUint256(_RESERVE_ID_SLOT);
    }

    function finalizeUpgrade() external onlyGovernance {
        _finalizeUpgrade();
    }

    receive() external payable {}
}

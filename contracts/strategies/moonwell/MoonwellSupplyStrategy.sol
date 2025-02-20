// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.21;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../../base/interface/IUniversalLiquidator.sol";
import "../../base/interface/IVault.sol";
import "../../base/upgradability/BaseUpgradeableStrategy.sol";
import "../../base/interface/moonwell/MTokenInterfaces.sol";
import "../../base/interface/moonwell/ComptrollerInterface.sol";
import "../../base/interface/balancer/IBVault.sol";
import "../../base/interface/weth/IWETH.sol";

contract MoonwellSupplyStrategy is BaseUpgradeableStrategy {
    using SafeERC20 for IERC20;

    address public constant weth = address(0x4200000000000000000000000000000000000006);
    address public constant bVault = address(0xBA12222222228d8Ba445958a75a0704d566BF2C8);
    address public constant harvestMSIG = address(0x97b3e5712CDE7Db13e939a188C8CA90Db5B05131);

    // additional storage slots (on top of BaseUpgradeableStrategy ones) are defined here
    bytes32 internal constant _MTOKEN_SLOT = 0x21e6ad38ea5ca89af03560d16f1da9e505dccbd1ec61d0683be425888164fec3;
    bytes32 internal constant _STORED_SUPPLIED_SLOT = 0x280539da846b4989609abdccfea039bd1453e4f710c670b29b9eeaca0730c1a2;

    // this would be reset on each upgrade
    address[] public rewardTokens;

    constructor() public BaseUpgradeableStrategy() {
        assert(_MTOKEN_SLOT == bytes32(uint256(keccak256("eip1967.strategyStorage.mToken")) - 1));
        assert(_STORED_SUPPLIED_SLOT == bytes32(uint256(keccak256("eip1967.strategyStorage.storedSupplied")) - 1));
    }

    function initializeBaseStrategy(
        address _storage,
        address _underlying,
        address _vault,
        address _mToken,
        address _comptroller,
        address _rewardToken
    ) public initializer {
        BaseUpgradeableStrategy.initialize(_storage, _underlying, _vault, _comptroller, _rewardToken, harvestMSIG);

        require(MErc20Interface(_mToken).underlying() == _underlying, "Underlying mismatch");
        _setMToken(_mToken);
        address[] memory markets = new address[](1);
        markets[0] = _mToken;
        ComptrollerInterface(_comptroller).enterMarkets(markets);
    }

    function currentBalance() public returns (uint256) {
        return MTokenInterface(mToken()).balanceOfUnderlying(address(this));
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

    function pendingFee() public returns (uint256) {
        uint256 fee;
        if (currentBalance() > storedBalance()) {
            uint256 balanceIncrease = currentBalance().sub(storedBalance());
            fee = balanceIncrease.mul(totalFeeNumerator()).div(feeDenominator());
        }
        return fee;
    }

    function _handleFee() internal {
        uint256 fee = pendingFee();
        if (fee > 0) {
            uint256 balanceIncrease = currentBalance().sub(storedBalance());
            _redeem(fee);
            address _underlying = underlying();
            if (IERC20(_underlying).balanceOf(address(this)) < fee) {
                return;
            }
            _notifyProfitInRewardToken(_underlying, balanceIncrease);
            uint256 balance = IERC20(_underlying).balanceOf(address(this));
            if (balance > 0) {
                _supply(balance);
            }
        }
    }

    function depositArbCheck() public pure returns (bool) {
        // there's no arb here.
        return true;
    }

    function unsalvagableTokens(address token) public view returns (bool) {
        return (token == rewardToken() || token == underlying() || token == mToken());
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
        _redeem(currentBalance());
        if (IERC20(_underlying).balanceOf(address(this)) > 0) {
            IERC20(_underlying).safeTransfer(vault(), IERC20(_underlying).balanceOf(address(this)));
        }
        _updateStoredBalance();
    }

    function emergencyExit() external onlyGovernance {
        _handleFee();
        _redeem(currentBalance());
        _setPausedInvesting(true);
        _updateStoredBalance();
    }

    function continueInvesting() public onlyGovernance {
        _setPausedInvesting(false);
    }

    function withdrawToVault(uint256 amountUnderlying) public restricted {
        _handleFee();
        address _underlying = underlying();
        uint256 balance = IERC20(_underlying).balanceOf(address(this));
        if (amountUnderlying <= balance) {
            IERC20(_underlying).safeTransfer(vault(), amountUnderlying);
            return;
        }
        uint256 toRedeem = amountUnderlying.sub(balance);
        // get some of the underlying
        _redeem(toRedeem);
        // transfer the amount requested (or the amount we have) back to vault()
        IERC20(_underlying).safeTransfer(vault(), amountUnderlying);
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
        ComptrollerInterface(rewardPool()).claimReward();
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
        return IERC20(underlying()).balanceOf(address(this)).add(storedBalance());
    }

    /**
     * Supplies to Moonwel
     */
    function _supply(uint256 amount) internal {
        if (amount == 0) {
            return;
        }
        address _underlying = underlying();
        address _mToken = mToken();
        uint256 balance = IERC20(_underlying).balanceOf(address(this));
        if (amount < balance) {
            balance = amount;
        }
        uint256 supplyCap = ComptrollerInterface(rewardPool()).supplyCaps(_mToken);
        uint256 currentSupplied =
            MTokenInterface(_mToken).totalSupply().mul(MTokenInterface(_mToken).exchangeRateCurrent()).div(1e18);
        if (currentSupplied >= supplyCap) {
            return;
        } else if (supplyCap.sub(currentSupplied) <= balance) {
            balance = supplyCap.sub(currentSupplied).sub(2);
        }
        IERC20(_underlying).safeApprove(_mToken, 0);
        IERC20(_underlying).safeApprove(_mToken, balance);
        MErc20Interface(_mToken).mint(balance);
    }

    function _redeem(uint256 amountUnderlying) internal {
        address _mToken = mToken();
        uint256 exchangeRate = MTokenInterface(_mToken).exchangeRateCurrent();
        if (amountUnderlying <= exchangeRate.div(1e18)) {
            return;
        }
        MErc20Interface(_mToken).redeemUnderlying(amountUnderlying);
    }

    function _setMToken(address _target) internal {
        setAddress(_MTOKEN_SLOT, _target);
    }

    function mToken() public view returns (address) {
        return getAddress(_MTOKEN_SLOT);
    }

    function finalizeUpgrade() external onlyGovernance {
        _finalizeUpgrade();
    }

    receive() external payable {}
}

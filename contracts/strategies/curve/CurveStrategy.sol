//SPDX-License-Identifier: Unlicense
pragma solidity 0.8.21;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import "../../base/interface/IUniversalLiquidator.sol";
import "../../base/interface/IVault.sol";
import "../../base/upgradability/BaseUpgradeableStrategy.sol";
import "../../base/interface/curve/Gauge.sol";
import "../../base/interface/curve/ICurveDeposit_2token.sol";
import "../../base/interface/curve/ICurveDeposit_3token.sol";
import "../../base/interface/curve/ICurveDeposit_4token.sol";

import "hardhat/console.sol";

contract CurveStrategy is BaseUpgradeableStrategy {
    using SafeERC20 for IERC20;

    address public constant harvestMSIG = address(0x97b3e5712CDE7Db13e939a188C8CA90Db5B05131);

    // additional storage slots (on top of BaseUpgradeableStrategy ones) are defined here
    bytes32 internal constant _DEPOSIT_TOKEN_SLOT = 0x219270253dbc530471c88a9e7c321b36afda219583431e7b6c386d2d46e70c86;
    bytes32 internal constant _CURVE_DEPOSIT_SLOT = 0xb306bb7adebd5a22f5e4cdf1efa00bc5f62d4f5554ef9d62c1b16327cd3ab5f9;
    bytes32 internal constant _DEPOSIT_ARRAY_POSITION_SLOT =
        0xb7c50ef998211fff3420379d0bf5b8dfb0cee909d1b7d9e517f311c104675b09;
    bytes32 internal constant _NTOKENS_SLOT = 0xbb60b35bae256d3c1378ff05e8d7bee588cd800739c720a107471dfa218f74c1;

    // this would be reset on each upgrade
    address[] public rewardTokens;

    constructor() public BaseUpgradeableStrategy() {
        assert(_DEPOSIT_TOKEN_SLOT == bytes32(uint256(keccak256("eip1967.strategyStorage.depositToken")) - 1));
        assert(_CURVE_DEPOSIT_SLOT == bytes32(uint256(keccak256("eip1967.strategyStorage.curveDeposit")) - 1));
        assert(
            _DEPOSIT_ARRAY_POSITION_SLOT
                == bytes32(uint256(keccak256("eip1967.strategyStorage.depositArrayPosition")) - 1)
        );
        assert(_NTOKENS_SLOT == bytes32(uint256(keccak256("eip1967.strategyStorage.nTokens")) - 1));
    }

    function initializeBaseStrategy(
        address _storage,
        address _underlying,
        address _vault,
        address _gauge,
        address _rewardToken,
        address _depositToken,
        address _curveDeposit,
        uint256 _depositArrayPosition,
        uint256 _nTokens
    ) public initializer {
        BaseUpgradeableStrategy.initialize(_storage, _underlying, _vault, _gauge, _rewardToken, harvestMSIG);

        address _lpt = Gauge(rewardPool()).lp_token();
        require(_lpt == _underlying, "Underlying mismatch");

        require(1 < _nTokens && _nTokens < 5, "_nTokens should be 2, 3 or 4");
        require(_depositArrayPosition < _nTokens, "Deposit array position out of bounds");
        _setDepositArrayPosition(_depositArrayPosition);
        _setDepositToken(_depositToken);
        _setCurveDeposit(_curveDeposit);
        _setNTokens(_nTokens);
    }

    function depositArbCheck() public pure returns (bool) {
        return true;
    }

    function _rewardPoolBalance() internal view returns (uint256 balance) {
        balance = Gauge(rewardPool()).balanceOf(address(this));
    }

    function _emergencyExitRewardPool() internal {
        uint256 stakedBalance = _rewardPoolBalance();
        if (stakedBalance != 0) {
            _withdrawUnderlyingFromPool(stakedBalance);
        }
    }

    function _withdrawUnderlyingFromPool(uint256 amount) internal {
        if (amount > 0) {
            Gauge(rewardPool()).withdraw(amount);
        }
    }

    function _enterRewardPool() internal {
        address underlying_ = underlying();
        address rewardPool_ = rewardPool();
        uint256 entireBalance = IERC20(underlying_).balanceOf(address(this));
        IERC20(underlying_).safeApprove(rewardPool_, 0);
        IERC20(underlying_).safeApprove(rewardPool_, entireBalance);
        Gauge(rewardPool_).deposit(entireBalance);
    }

    function _investAllUnderlying() internal onlyNotPausedInvesting {
        // this check is needed, because most of the SNX reward pools will revert if
        // you try to stake(0).
        if (IERC20(underlying()).balanceOf(address(this)) > 0) {
            _enterRewardPool();
        }
    }

    /*
    *   In case there are some issues discovered about the pool or underlying asset
    *   Governance can exit the pool properly
    *   The function is only used for emergency to exit the pool
    */
    function emergencyExit() public onlyGovernance {
        _emergencyExitRewardPool();
        _setPausedInvesting(true);
    }

    /*
    *   Resumes the ability to invest into the underlying reward pools
    */
    function continueInvesting() public onlyGovernance {
        _setPausedInvesting(false);
    }

    function unsalvagableTokens(address token) public view returns (bool) {
        return (token == rewardToken() || token == underlying());
    }

    function addRewardToken(address _token) public onlyGovernance {
        rewardTokens.push(_token);
    }

    function _claimRewards() internal {
        address _rewardPool = rewardPool();
        address factory = Gauge(_rewardPool).factory();
        Mintr(factory).mint(_rewardPool);
        Gauge(_rewardPool).claim_rewards();
    }

    function _liquidateReward() internal {
        if (!sell()) {
            // Profits can be disabled for possible simplified and rapid exit
            emit ProfitsNotCollected(sell(), false);
            return;
        }

        address _rewardToken = rewardToken();
        address _universalLiquidator = universalLiquidator();
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            address token = rewardTokens[i];
            uint256 rewardBalance = IERC20(token).balanceOf(address(this));
            if (rewardBalance == 0) {
                continue;
            }
            if (token != _rewardToken) {
                IERC20(token).safeApprove(_universalLiquidator, 0);
                IERC20(token).safeApprove(_universalLiquidator, rewardBalance);
                IUniversalLiquidator(_universalLiquidator).swap(token, _rewardToken, rewardBalance, 1, address(this));
            }
        }

        uint256 rewardBalance = IERC20(_rewardToken).balanceOf(address(this));
        _notifyProfitInRewardToken(_rewardToken, rewardBalance);
        uint256 remainingRewardBalance = IERC20(_rewardToken).balanceOf(address(this));

        if (remainingRewardBalance == 0) {
            return;
        }

        address _depositToken = depositToken();
        if (_depositToken != _rewardToken) {
            IERC20(_rewardToken).safeApprove(_universalLiquidator, 0);
            IERC20(_rewardToken).safeApprove(_universalLiquidator, remainingRewardBalance);
            IUniversalLiquidator(_universalLiquidator).swap(
                _rewardToken, _depositToken, remainingRewardBalance, 1, address(this)
            );
        }

        uint256 tokenBalance = IERC20(_depositToken).balanceOf(address(this));
        if (tokenBalance > 0) {
            depositCurve(_depositToken, tokenBalance);
        }
    }

    function depositCurve(address token, uint256 balance) internal {
        address _curveDeposit = curveDeposit();

        IERC20(token).safeApprove(_curveDeposit, 0);
        IERC20(token).safeApprove(_curveDeposit, balance);

        // we can accept 1 as minimum, this will be called only by trusted roles
        uint256 minimum = 1;
        if (nTokens() == 2) {
            uint256[2] memory depositArray;
            depositArray[depositArrayPosition()] = balance;
            ICurveDeposit_2token(_curveDeposit).add_liquidity(depositArray, minimum);
        } else if (nTokens() == 3) {
            uint256[3] memory depositArray;
            depositArray[depositArrayPosition()] = balance;
            ICurveDeposit_3token(_curveDeposit).add_liquidity(depositArray, minimum);
        } else if (nTokens() == 4) {
            uint256[4] memory depositArray;
            depositArray[depositArrayPosition()] = balance;
            ICurveDeposit_4token(_curveDeposit).add_liquidity(depositArray, minimum);
        }
    }

    /*
    *   Withdraws all the asset to the vault
    */
    function withdrawAllToVault() public restricted {
        _withdrawUnderlyingFromPool(_rewardPoolBalance());
        _claimRewards();
        _liquidateReward();
        address underlying_ = underlying();
        IERC20(underlying_).safeTransfer(vault(), IERC20(underlying_).balanceOf(address(this)));
    }

    /*
    *   Withdraws all the asset to the vault
    */
    function withdrawToVault(uint256 _amount) public restricted {
        // Typically there wouldn't be any amount here
        // however, it is possible because of the emergencyExit
        address underlying_ = underlying();
        uint256 entireBalance = IERC20(underlying_).balanceOf(address(this));

        if (_amount > entireBalance) {
            // While we have the check above, we still using SafeMath below
            // for the peace of mind (in case something gets changed in between)
            uint256 needToWithdraw = _amount.sub(entireBalance);
            uint256 toWithdraw = Math.min(_rewardPoolBalance(), needToWithdraw);
            _withdrawUnderlyingFromPool(toWithdraw);
        }
        IERC20(underlying_).safeTransfer(vault(), _amount);
    }

    /*
    *   Note that we currently do not have a mechanism here to include the
    *   amount of reward that is accrued.
    */
    function investedUnderlyingBalance() external view returns (uint256) {
        if (rewardPool() == address(0)) {
            return IERC20(underlying()).balanceOf(address(this));
        }
        // Adding the amount locked in the reward pool and the amount that is somehow in this contract
        // both are in the units of "underlying"
        // The second part is needed because there is the emergency exit mechanism
        // which would break the assumption that all the funds are always inside of the reward pool
        return _rewardPoolBalance().add(IERC20(underlying()).balanceOf(address(this)));
    }

    /*
    *   Governance or Controller can claim coins that are somehow transferred into the contract
    *   Note that they cannot come in take away coins that are used and defined in the strategy itself
    */
    function salvage(address recipient, address token, uint256 amount) external onlyControllerOrGovernance {
        // To make sure that governance cannot come in and take away the coins
        require(!unsalvagableTokens(token), "token is defined as not salvagable");
        IERC20(token).safeTransfer(recipient, amount);
    }

    /*
    *   Get the reward, sell it in exchange for underlying, invest what you got.
    *   It's not much, but it's honest work.
    *
    *   Note that although `onlyNotPausedInvesting` is not added here,
    *   calling `investAllUnderlying()` affectively blocks the usage of `doHardWork`
    *   when the investing is being paused by governance.
    */
    function doHardWork() external onlyNotPausedInvesting restricted {
        _claimRewards();
        _liquidateReward();
        _investAllUnderlying();
    }

    /**
     * Can completely disable claiming UNI rewards and selling. Good for emergency withdraw in the
     * simplest possible way.
     */
    function setSell(bool s) public onlyGovernance {
        _setSell(s);
    }

    function _setDepositToken(address _address) internal {
        setAddress(_DEPOSIT_TOKEN_SLOT, _address);
    }

    function depositToken() public view returns (address) {
        return getAddress(_DEPOSIT_TOKEN_SLOT);
    }

    function _setCurveDeposit(address _address) internal {
        setAddress(_CURVE_DEPOSIT_SLOT, _address);
    }

    function curveDeposit() public view returns (address) {
        return getAddress(_CURVE_DEPOSIT_SLOT);
    }

    function _setDepositArrayPosition(uint256 _value) internal {
        setUint256(_DEPOSIT_ARRAY_POSITION_SLOT, _value);
    }

    function depositArrayPosition() public view returns (uint256) {
        return getUint256(_DEPOSIT_ARRAY_POSITION_SLOT);
    }

    function _setNTokens(uint256 _value) internal {
        setUint256(_NTOKENS_SLOT, _value);
    }

    function nTokens() public view returns (uint256) {
        return getUint256(_NTOKENS_SLOT);
    }

    function finalizeUpgrade() external onlyGovernance {
        address _rewardPool = rewardPool();
        address _crv = rewardToken();
        address _gov = governance();
        uint256 pendingCRV = Gauge(_rewardPool).claimable_reward(address(this), _crv);
        IERC20(_crv).safeTransferFrom(_gov, _rewardPool, pendingCRV);
        Gauge(_rewardPool).claim_rewards();
        IERC20(_crv).safeTransfer(_gov, pendingCRV);
        _finalizeUpgrade();
    }
}

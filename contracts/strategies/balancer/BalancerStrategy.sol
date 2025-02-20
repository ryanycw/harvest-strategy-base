//SPDX-License-Identifier: Unlicense
pragma solidity 0.8.21;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import "../../base/interface/IUniversalLiquidator.sol";
import "../../base/interface/IVault.sol";
import "../../base/upgradability/BaseUpgradeableStrategy.sol";
import "../../base/interface/balancer/IBVault.sol";
import "../../base/interface/balancer/Gauge.sol";
import "../../base/interface/balancer/IBalancerMinter.sol";

contract BalancerStrategy is BaseUpgradeableStrategy {
    using SafeERC20 for IERC20;

    address public constant weth = address(0x4200000000000000000000000000000000000006);
    address public constant harvestMSIG = address(0x97b3e5712CDE7Db13e939a188C8CA90Db5B05131);

    // additional storage slots (on top of BaseUpgradeableStrategy ones) are defined here
    bytes32 internal constant _POOLID_SLOT = 0x3fd729bfa2e28b7806b03a6e014729f59477b530f995be4d51defc9dad94810b;
    bytes32 internal constant _BVAULT_SLOT = 0x85cbd475ba105ca98d9a2db62dcf7cf3c0074b36303ef64160d68a3e0fdd3c67;
    bytes32 internal constant _DEPOSIT_TOKEN_SLOT = 0x219270253dbc530471c88a9e7c321b36afda219583431e7b6c386d2d46e70c86;

    // this would be reset on each upgrade
    address[] public rewardTokens;

    constructor() public BaseUpgradeableStrategy() {
        assert(_POOLID_SLOT == bytes32(uint256(keccak256("eip1967.strategyStorage.poolId")) - 1));
        assert(_BVAULT_SLOT == bytes32(uint256(keccak256("eip1967.strategyStorage.bVault")) - 1));
        assert(_DEPOSIT_TOKEN_SLOT == bytes32(uint256(keccak256("eip1967.strategyStorage.depositToken")) - 1));
    }

    function initializeBaseStrategy(
        address _storage,
        address _underlying,
        address _vault,
        address _rewardPool,
        address _bVault,
        bytes32 _poolID,
        address _depositToken
    ) public initializer {
        BaseUpgradeableStrategy.initialize(_storage, _underlying, _vault, _rewardPool, weth, harvestMSIG);

        (address _lpt,) = IBVault(_bVault).getPool(_poolID);
        require(_lpt == _underlying, "Underlying mismatch");

        _setPoolId(_poolID);
        _setBVault(_bVault);
        _setDepositToken(_depositToken);
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
        address rewardPool_ = rewardPool();
        Gauge(rewardPool_).withdraw(Math.min(Gauge(rewardPool_).balanceOf(address(this)), amount));
    }

    function _enterRewardPool() internal {
        address underlying_ = underlying();
        address rewardPool_ = rewardPool();
        uint256 entireBalance = IERC20(underlying_).balanceOf(address(this));
        IERC20(underlying_).safeIncreaseAllowance(rewardPool_, entireBalance);
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

    function changeDepositToken(address _depositToken) public onlyGovernance {
        _setDepositToken(_depositToken);
    }

    function _approveIfNeed(address token, address spender, uint256 amount) internal {
        uint256 allowance = IERC20(token).allowance(address(this), spender);
        if (amount > allowance) {
            IERC20(token).safeIncreaseAllowance(spender, amount);
        }
    }

    function _balancerDeposit(address tokenIn, bytes32 poolId, uint256 amountIn, uint256 minAmountOut) internal {
        address _bVault = bVault();
        (address[] memory poolTokens,,) = IBVault(_bVault).getPoolTokens(poolId);
        uint256 _nTokens = poolTokens.length;

        IAsset[] memory assets = new IAsset[](_nTokens);
        uint256[] memory amountsIn = new uint256[](_nTokens);
        for (uint256 i = 0; i < _nTokens; i++) {
            assets[i] = IAsset(poolTokens[i]);
            amountsIn[i] = poolTokens[i] == tokenIn ? amountIn : 0;
        }

        IBVault.JoinKind joinKind = IBVault.JoinKind.EXACT_TOKENS_IN_FOR_BPT_OUT;

        bytes memory userData = abi.encode(joinKind, amountsIn, minAmountOut);

        IBVault.JoinPoolRequest memory request;
        request.assets = assets;
        request.maxAmountsIn = amountsIn;
        request.userData = userData;
        request.fromInternalBalance = false;

        _approveIfNeed(tokenIn, _bVault, amountIn);
        IBVault(_bVault).joinPool(poolId, address(this), address(this), request);
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
                IERC20(token).safeIncreaseAllowance(_universalLiquidator, rewardBalance);
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
            IERC20(_rewardToken).safeIncreaseAllowance(_universalLiquidator, remainingRewardBalance);
            IUniversalLiquidator(_universalLiquidator).swap(
                _rewardToken, _depositToken, remainingRewardBalance, 1, address(this)
            );
        }

        uint256 tokenBalance = IERC20(_depositToken).balanceOf(address(this));
        if (tokenBalance > 0 && !(_depositToken == underlying())) {
            depositLP();
        }
    }

    function depositLP() internal {
        address _depositToken = depositToken();
        uint256 depositTokenBalance = IERC20(_depositToken).balanceOf(address(this));

        _balancerDeposit(_depositToken, poolId(), depositTokenBalance, 1);
    }

    /*
    *   Withdraws all the asset to the vault
    */
    function withdrawAllToVault() public restricted {
        _withdrawUnderlyingFromPool(_rewardPoolBalance());
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
            uint256 needToWithdraw = _amount - entireBalance;
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
        return _rewardPoolBalance() + IERC20(underlying()).balanceOf(address(this));
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
        address _rewardPool = rewardPool();
        IBalancerMinter(Gauge(_rewardPool).bal_pseudo_minter()).mint(_rewardPool);
        Gauge(_rewardPool).claim_rewards();
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

    /**
     * Sets the minimum amount of CRV needed to trigger a sale.
     */
    function setSellFloor(uint256 floor) public onlyGovernance {
        _setSellFloor(floor);
    }

    // masterchef rewards pool ID
    function _setPoolId(bytes32 _value) internal {
        setBytes32(_POOLID_SLOT, _value);
    }

    function poolId() public view returns (bytes32) {
        return getBytes32(_POOLID_SLOT);
    }

    function _setBVault(address _address) internal {
        setAddress(_BVAULT_SLOT, _address);
    }

    function bVault() public view returns (address) {
        return getAddress(_BVAULT_SLOT);
    }

    function _setDepositToken(address _address) internal {
        setAddress(_DEPOSIT_TOKEN_SLOT, _address);
    }

    function depositToken() public view returns (address) {
        return getAddress(_DEPOSIT_TOKEN_SLOT);
    }

    function finalizeUpgrade() external onlyGovernance {
        _finalizeUpgrade();
    }

    receive() external payable {} // this is needed for the receiving Matic
}

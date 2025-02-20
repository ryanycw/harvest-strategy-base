//SPDX-License-Identifier: Unlicense
pragma solidity 0.8.21;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import "../../base/interface/uniswap/IUniswapV2Router02.sol";
import "../../base/interface/uniswap/IUniswapV2Pair.sol";
import "../../base/interface/IUniversalLiquidator.sol";
import "../../base/interface/IVault.sol";
import "../../base/interface/IPotPool.sol";
import "../../base/upgradability/BaseUpgradeableStrategy.sol";
import "../../base/interface/baseswap/INFTPool.sol";

contract BaseSwapStrategyV2 is BaseUpgradeableStrategy {
    using SafeERC20 for IERC20;

    address public constant bswap = address(0x78a087d713Be963Bf307b18F2Ff8122EF9A63ae9);
    address public constant bsx = address(0xd5046B976188EB40f6DE40fB527F89c05b323385);
    address public constant xbsx = address(0xE4750593d1fC8E74b31549212899A72162f315Fa);
    address public constant weth = address(0x4200000000000000000000000000000000000006);
    address public constant baseRouter = address(0x327Df1E6de05895d2ab08513aaDD9313Fe505d86);
    address public constant harvestMSIG = address(0x97b3e5712CDE7Db13e939a188C8CA90Db5B05131);

    // additional storage slots (on top of BaseUpgradeableStrategy ones) are defined here
    bytes32 internal constant _POS_ID_SLOT = 0x025da88341279feed86c02593d3d75bb35ff95cb72e32ffd093929b008413de5;
    bytes32 internal constant _XBSX_VAULT_SLOT = 0x8abf1b5d63d0e5b566db8e59e38bede77f3196b7ab8c79af0e40e70cb3811690;
    bytes32 internal constant _POTPOOL_SLOT = 0x7f4b50847e7d7a4da6a6ea36bfb188c77e9f093697337eb9a876744f926dd014;

    // this would be reset on each upgrade
    address[] public rewardTokens;

    constructor() public BaseUpgradeableStrategy() {
        assert(_POS_ID_SLOT == bytes32(uint256(keccak256("eip1967.strategyStorage.posId")) - 1));
        assert(_XBSX_VAULT_SLOT == bytes32(uint256(keccak256("eip1967.strategyStorage.xBSXVault")) - 1));
        assert(_POTPOOL_SLOT == bytes32(uint256(keccak256("eip1967.strategyStorage.potPool")) - 1));
    }

    function initializeBaseStrategy(
        address _storage,
        address _underlying,
        address _vault,
        address _nftPool,
        address _xBSXVault,
        address _potPool
    ) public initializer {
        BaseUpgradeableStrategy.initialize(_storage, _underlying, _vault, _nftPool, bsx, harvestMSIG);

        (address _lpt,,,,,,,,,) = INFTPool(rewardPool()).getPoolInfo();
        require(_lpt == _underlying, "Underlying mismatch");
        setAddress(_XBSX_VAULT_SLOT, _xBSXVault);
        setAddress(_POTPOOL_SLOT, _potPool);
    }

    function depositArbCheck() public pure returns (bool) {
        return true;
    }

    function _rewardPoolBalance() internal view returns (uint256 bal) {
        if (posId() > 0) {
            (bal,,,,,,,,) = INFTPool(rewardPool()).getStakingPosition(posId());
        } else {
            bal = 0;
        }
    }

    function _emergencyExitRewardPool() internal {
        uint256 stakedBalance = _rewardPoolBalance();
        if (stakedBalance != 0) {
            INFTPool(rewardPool()).emergencyWithdraw(posId());
        }
    }

    function _withdrawUnderlyingFromPool(uint256 amount) internal {
        if (amount > 0) {
            INFTPool(rewardPool()).withdrawFromPosition(posId(), amount);
        }
        if (_rewardPoolBalance() == 0) {
            _setPosId(0);
        }
    }

    function _enterRewardPool() internal {
        address _underlying = underlying();
        address _rewardPool = rewardPool();
        uint256 entireBalance = IERC20(_underlying).balanceOf(address(this));
        IERC20(_underlying).safeIncreaseAllowance(_rewardPool, entireBalance);
        if (_rewardPoolBalance() > 0) {
            //We already have a position. Withdraw from staking, add to position, stake again.
            INFTPool(_rewardPool).addToPosition(posId(), entireBalance);
        } else {
            //We do not yet have a position. Create a position and store the position ID. Then stake.
            INFTPool(_rewardPool).createPosition(entireBalance, 0);
            uint256 newPosId = INFTPool(_rewardPool).tokenOfOwnerByIndex(address(this), 0);
            _setPosId(newPosId);
        }
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
        uint256 _posId = posId();
        if (_posId > 0) {
            INFTPool(rewardPool()).harvestPosition(_posId);
        }
    }

    function _liquidateReward(uint256 _xBSXAmount) internal {
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
        uint256 notifyBalance;
        if (_xBSXAmount > rewardBalance * 9 / 10) {
            notifyBalance = rewardBalance * 10 / 10;
        } else {
            notifyBalance = rewardBalance + _xBSXAmount;
        }
        _notifyProfitInRewardToken(_rewardToken, notifyBalance);
        uint256 remainingRewardBalance = IERC20(_rewardToken).balanceOf(address(this));
        if (remainingRewardBalance == 0) {
            _handleXBSX();
            return;
        }

        address _underlying = underlying();
        address token0 = IUniswapV2Pair(_underlying).token0();
        address token1 = IUniswapV2Pair(_underlying).token1();

        uint256 toToken0 = remainingRewardBalance / 2;
        uint256 toToken1 = remainingRewardBalance - toToken0;

        IERC20(_rewardToken).safeIncreaseAllowance(_universalLiquidator, remainingRewardBalance);

        uint256 token0Amount;
        if (token0 != _rewardToken) {
            IUniversalLiquidator(_universalLiquidator).swap(_rewardToken, token0, toToken0, 1, address(this));
            token0Amount = IERC20(token0).balanceOf(address(this));
        } else {
            // otherwise we assme token0 is weth itself
            token0Amount = toToken0;
        }

        uint256 token1Amount;
        if (token1 != _rewardToken) {
            IUniversalLiquidator(_universalLiquidator).swap(_rewardToken, token1, toToken1, 1, address(this));
            token1Amount = IERC20(token1).balanceOf(address(this));
        } else {
            token1Amount = toToken1;
        }

        // provide token1 and token2 to BaseSwap
        IERC20(token0).safeIncreaseAllowance(baseRouter, token0Amount);

        IERC20(token1).safeIncreaseAllowance(baseRouter, token1Amount);

        IUniswapV2Router02(baseRouter).addLiquidity(
            token0, token1, token0Amount, token1Amount, 1, 1, address(this), block.timestamp
        );

        _handleXBSX();
    }

    function _handleXBSX() internal {
        uint256 balance = IERC20(xbsx).balanceOf(address(this));
        if (balance == 0) return;
        address _xBSXVault = xBSXVault();
        address _potPool = potPool();

        IERC20(xbsx).safeIncreaseAllowance(_xBSXVault, balance);
        IVault(_xBSXVault).deposit(balance);

        uint256 vaultBalance = IERC20(_xBSXVault).balanceOf(address(this));
        IERC20(_xBSXVault).safeTransfer(_potPool, vaultBalance);
        IPotPool(_potPool).notifyTargetRewardAmount(_xBSXVault, vaultBalance);
    }

    /*
    *   Withdraws all the asset to the vault
    */
    function withdrawAllToVault() public restricted {
        _claimRewards();
        _withdrawUnderlyingFromPool(_rewardPoolBalance());
        uint256 xBSXReward = IERC20(xbsx).balanceOf(address(this));
        _liquidateReward(xBSXReward);
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
        _claimRewards();
        uint256 xBSXReward = IERC20(xbsx).balanceOf(address(this));
        _liquidateReward(xBSXReward);
        _investAllUnderlying();
    }

    /**
     * Can completely disable claiming UNI rewards and selling. Good for emergency withdraw in the
     * simplest possible way.
     */
    function setSell(bool s) public onlyGovernance {
        _setSell(s);
    }

    function _setPosId(uint256 _value) internal {
        setUint256(_POS_ID_SLOT, _value);
    }

    function posId() public view returns (uint256) {
        return getUint256(_POS_ID_SLOT);
    }

    function setXBSXVault(address _value) public onlyGovernance {
        require(xBSXVault() == address(0), "Hodl vault already set");
        setAddress(_XBSX_VAULT_SLOT, _value);
    }

    function xBSXVault() public view returns (address) {
        return getAddress(_XBSX_VAULT_SLOT);
    }

    function setPotPool(address _value) public onlyGovernance {
        require(potPool() == address(0), "PotPool already set");
        setAddress(_POTPOOL_SLOT, _value);
    }

    function potPool() public view returns (address) {
        return getAddress(_POTPOOL_SLOT);
    }

    bytes4 private constant _ERC721_RECEIVED = 0x150b7a02;

    function onERC721Received(address, /*operator*/ address, /*from*/ uint256, /*tokenId*/ bytes calldata /*data*/ )
        external
        pure
        returns (bytes4)
    {
        return _ERC721_RECEIVED;
    }

    function onNFTHarvest(
        address, /*operator*/
        address, /*to*/
        uint256, /*tokenId*/
        uint256, /*grailAmount*/
        uint256, /*xGrailAmount*/
        uint256 /**/
    ) external pure returns (bool) {
        return true;
    }

    function onNFTAddToPosition(
        address,
        /*operator*/
        uint256, /*tokenId*/
        uint256 /*lpAmount*/
    ) external pure returns (bool) {
        return true;
    }

    function onNFTWithdraw(address, /*operator*/ uint256, /*tokenId*/ uint256 /*lpAmount*/ )
        external
        pure
        returns (bool)
    {
        return true;
    }

    function finalizeUpgrade() external onlyGovernance {
        _setRewardToken(bsx);
        _finalizeUpgrade();
    }
}

// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.21;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "./inheritance/Governable.sol";
import "./interface/IController.sol";
import "./interface/IRewardForwarder.sol";
import "./interface/IProfitSharingReceiver.sol";
import "./interface/IStrategy.sol";
import "./interface/IUniversalLiquidator.sol";
import "./inheritance/Controllable.sol";

/**
 * @dev This contract receives rewards from strategies and is responsible for routing the reward's liquidation into
 *      specific buyback tokens and profit tokens for the DAO.
 */
contract RewardForwarder is Controllable {
    using SafeERC20 for IERC20;

    address public constant iFARM = address(0xE7798f023fC62146e8Aa1b36Da45fb70855a77Ea);

    constructor(address _storage) public Controllable(_storage) {}

    function notifyFee(address _token, uint256 _profitSharingFee, uint256 _strategistFee, uint256 _platformFee)
        external
    {
        _notifyFee(_token, _profitSharingFee, _strategistFee, _platformFee);
    }

    function _notifyFee(address _token, uint256 _profitSharingFee, uint256 _strategistFee, uint256 _platformFee)
        internal
    {
        address _controller = controller();
        address liquidator = IController(_controller).universalLiquidator();

        uint256 totalTransferAmount = _profitSharingFee + _strategistFee + _platformFee;
        require(totalTransferAmount > 0, "totalTransferAmount should not be 0");
        IERC20(_token).safeTransferFrom(msg.sender, address(this), totalTransferAmount);

        address _targetToken = IController(_controller).targetToken();

        if (_token != _targetToken) {
            IERC20(_token).safeIncreaseAllowance(liquidator, _platformFee);

            uint256 amountOutMin = 1;

            if (_platformFee > 0) {
                IUniversalLiquidator(liquidator).swap(
                    _token, _targetToken, _platformFee, amountOutMin, IController(_controller).protocolFeeReceiver()
                );
            }
        } else {
            IERC20(_targetToken).safeTransfer(IController(_controller).protocolFeeReceiver(), _platformFee);
        }

        if (_token != iFARM) {
            IERC20(_token).safeIncreaseAllowance(liquidator, _profitSharingFee + _strategistFee);

            uint256 amountOutMin = 1;

            if (_profitSharingFee > 0) {
                IUniversalLiquidator(liquidator).swap(
                    _token, iFARM, _profitSharingFee, amountOutMin, IController(_controller).profitSharingReceiver()
                );
            }
            if (_strategistFee > 0) {
                IUniversalLiquidator(liquidator).swap(
                    _token, iFARM, _strategistFee, amountOutMin, IStrategy(msg.sender).strategist()
                );
            }
        } else {
            if (_strategistFee > 0) {
                IERC20(iFARM).safeTransfer(IStrategy(msg.sender).strategist(), _strategistFee);
            }
            IERC20(iFARM).safeTransfer(IController(_controller).profitSharingReceiver(), _profitSharingFee);
        }
    }
}

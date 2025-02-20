// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.21;

import "./interface/IERC4626.sol";
import "./interface/ICLVault.sol";
import "./interface/IController.sol";
import "./interface/IUniversalLiquidator.sol";
import "./inheritance/Controllable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract CLWrapper is Controllable, ReentrancyGuard, IERC4626 {
    using SafeERC20 for IERC20;

    address internal _vault;
    address internal _asset;

    // Only smart contracts will be affected by this modifier
    modifier defense() {
        require(
            (msg.sender == tx.origin) // If it is a normal user and not smart contract,
                    // then the requirement will pass
                || !IController(controller()).greyList(msg.sender), // If it is a smart contract, then
            "grey list" // make sure that it is not on our greyList.
        );
        _;
    }

    constructor(address _storage, address __vault, bool _useToken0) public Controllable(_storage) ReentrancyGuard() {
        _vault = __vault;
        _asset = _useToken0 ? ICLVault(_vault).token0() : ICLVault(_vault).token1();
    }

    function balanceOf(address _depositor) public view returns (uint256) {
        return ICLVault(_vault).balanceOf(_depositor);
    }

    function totalSupply() public view returns (uint256) {
        return ICLVault(_vault).totalSupply();
    }

    function asset() external view override returns (address) {
        return _asset;
    }

    function vault() external view returns (address) {
        return _vault;
    }

    function totalAssets() public view override returns (uint256) {
        (uint256 amount0, uint256 amount1) = ICLVault(_vault).getCurrentTokenAmounts();
        (uint256 weight0, uint256 weight1) = ICLVault(_vault).getCurrentTokenWeights();
        uint256 _totalAssets;
        if (_asset == ICLVault(_vault).token0()) {
            if (weight0 > weight1) {
                _totalAssets = amount0 * 1e18 / weight0;
            } else {
                uint256 sqrtPrice = uint256(ICLVault(_vault).getSqrtPriceX96());
                uint256 price0In1 = sqrtPrice * sqrtPrice * 1e18 / uint256(2 ** (96 * 2));
                uint256 price1In0 = uint256(1e36) / price0In1;
                _totalAssets = amount1 * price1In0 / weight1;
            }
        } else {
            if (weight1 > weight0) {
                _totalAssets = amount1 * 1e18 / weight1;
            } else {
                uint256 sqrtPrice = uint256(ICLVault(_vault).getSqrtPriceX96());
                uint256 price0In1 = sqrtPrice * sqrtPrice * 1e18 / uint256(2 ** (96 * 2));
                _totalAssets = amount0 * price0In1 / weight0;
            }
        }
        return _totalAssets;
    }

    function assetsPerShare() external view override returns (uint256) {
        return convertToAssets(1e18);
    }

    function assetsOf(address _depositor) public view override returns (uint256) {
        return totalAssets() * balanceOf(_depositor) / totalSupply();
    }

    function maxDeposit(address /*caller*/ ) external view override returns (uint256) {
        return type(uint256).max;
    }

    function previewDeposit(uint256 _assets) public view override returns (uint256) {
        return convertToShares(_assets) * 995 / 1000;
    }

    function deposit(uint256 _assets, address _receiver) external override nonReentrant defense returns (uint256) {
        uint256 minOut = previewDeposit(_assets);
        uint256 shares = _deposit(_assets, msg.sender, _receiver, minOut);
        return shares;
    }

    function deposit(uint256 _assets, address _receiver, uint256 _minOut)
        external
        nonReentrant
        defense
        returns (uint256)
    {
        uint256 shares = _deposit(_assets, msg.sender, _receiver, _minOut);
        return shares;
    }

    function maxMint(address) external view override returns (uint256) {
        return uint256(0);
    }

    function previewMint(uint256) external view override returns (uint256) {
        revert("Use deposit");
    }

    function mint(uint256, address) external override returns (uint256) {
        revert("Use deposit");
    }

    function maxWithdraw(address) external view override returns (uint256) {
        return 0;
    }

    function previewWithdraw(uint256) external view override returns (uint256) {
        revert("Use redeem");
    }

    function withdraw(uint256, address, address) external override returns (uint256) {
        revert("Use redeem");
    }

    function maxRedeem(address _caller) external view override returns (uint256) {
        return balanceOf(_caller);
    }

    function previewRedeem(uint256 _shares) public view override returns (uint256) {
        return convertToAssets(_shares) * 995 / 1000;
    }

    function redeem(uint256 _shares, address _receiver, address _owner)
        external
        override
        nonReentrant
        defense
        returns (uint256)
    {
        uint256 minOut = previewRedeem(_shares);
        uint256 assets = _withdraw(_shares, _receiver, _owner, minOut);
        return assets;
    }

    function redeem(uint256 _shares, address _receiver, address _owner, uint256 _minOut)
        external
        nonReentrant
        defense
        returns (uint256)
    {
        uint256 assets = _withdraw(_shares, _receiver, _owner, _minOut);
        return assets;
    }

    // ========================= Conversion Functions =========================

    function convertToAssets(uint256 _shares) public view returns (uint256) {
        return totalAssets() == 0 || totalSupply() == 0 ? _shares : _shares * totalAssets() / totalSupply();
    }

    function convertToShares(uint256 _assets) public view returns (uint256) {
        return totalAssets() == 0 || totalSupply() == 0 ? _assets : _assets * totalSupply() / totalAssets();
    }

    function _swap(address tokenIn, address tokenOut, uint256 _amountIn) internal {
        address _universalLiquidator = IController(controller()).universalLiquidator();
        IERC20(tokenIn).safeIncreaseAllowance(_universalLiquidator, _amountIn);
        IUniversalLiquidator(_universalLiquidator).swap(tokenIn, tokenOut, _amountIn, 1, address(this));
    }

    function _deposit(uint256 _assets, address _sender, address _receiver, uint256 _minOut)
        internal
        returns (uint256)
    {
        IERC20(_asset).safeTransferFrom(_sender, address(this), _assets);

        bool isToken0 = _asset == ICLVault(_vault).token0();

        {
            (uint256 weight0, uint256 weight1) = ICLVault(_vault).getCurrentTokenWeights();
            if (isToken0) {
                _swap(ICLVault(_vault).token0(), ICLVault(_vault).token1(), _assets * weight1 / 1e18);
            } else {
                _swap(ICLVault(_vault).token1(), ICLVault(_vault).token0(), _assets * weight0 / 1e18);
            }
        }

        address token0 = ICLVault(_vault).token0();
        address token1 = ICLVault(_vault).token1();
        uint256 amount0 = IERC20(token0).balanceOf(address(this));
        uint256 amount1 = IERC20(token1).balanceOf(address(this));
        IERC20(token0).safeIncreaseAllowance(_vault, amount0);
        IERC20(token1).safeIncreaseAllowance(_vault, amount1);

        uint256 amountOut = ICLVault(_vault).deposit(amount0, amount1, _minOut, _receiver);

        uint256 left0 = IERC20(token0).balanceOf(address(this));
        uint256 left1 = IERC20(token1).balanceOf(address(this));
        uint256 amountIn = isToken0 ? _assets - left0 : _assets - left1;
        emit Deposit(_sender, _receiver, amountIn, amountOut);

        _transferLeftOverTo(_receiver);

        return amountOut;
    }

    function _withdraw(uint256 _shares, address _receiver, address _owner, uint256 _minOut)
        internal
        returns (uint256)
    {
        IERC20(_vault).safeTransferFrom(_owner, address(this), _shares);

        address token0 = ICLVault(_vault).token0();
        address token1 = ICLVault(_vault).token1();
        bool isToken0 = _asset == token0;

        (uint256 amount0, uint256 amount1) = ICLVault(_vault).withdraw(_shares, 1, 1);

        if (isToken0) {
            _swap(token1, token0, amount1);
        } else {
            _swap(token0, token1, amount0);
        }

        uint256 amountOut = IERC20(_asset).balanceOf(address(this));

        require(amountOut >= _minOut, "Too little received");

        emit Withdraw(msg.sender, _receiver, _owner, amountOut, _shares);
        _transferLeftOverTo(_receiver);
        return amountOut;
    }

    function _transferLeftOverTo(address _to) internal {
        address token0 = ICLVault(_vault).token0();
        address token1 = ICLVault(_vault).token0();
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));
        if (balance0 > 0) {
            IERC20(token0).safeTransfer(_to, balance0);
        }
        if (balance1 > 0) {
            IERC20(token1).safeTransfer(_to, balance1);
        }
    }
}

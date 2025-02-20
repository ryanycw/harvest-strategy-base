// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.21;
pragma experimental ABIEncoderV2;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/utils/ERC721HolderUpgradeable.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import "./interface/IStrategy.sol";
import "./interface/IController.sol";
import "./interface/IUpgradeSource.sol";
import "./inheritance/ControllableInit.sol";
import "./CLVaultStorage.sol";
import "./interface/concentrated-liquidity/INonfungiblePositionManager.sol";
import "./interface/concentrated-liquidity/IFactory.sol";
import "./interface/concentrated-liquidity/IPool.sol";
import "./interface/concentrated-liquidity/TickMath.sol";
import "./interface/concentrated-liquidity/LiquidityAmounts.sol";
import "./interface/IUniversalLiquidator.sol";

contract CLVault is ERC20Upgradeable, ERC721HolderUpgradeable, IUpgradeSource, ControllableInit, CLVaultStorage {
    using Address for address;
    using SafeERC20 for IERC20;

    /**
     * Caller has exchanged assets for shares, and transferred those shares to owner.
     *
     * MUST be emitted when tokens are deposited into the Vault via the mint and deposit methods.
     */
    event Deposit(address indexed sender, address indexed receiver, uint256 amount0, uint256 amount1, uint256 shares);

    /**
     * Caller has exchanged shares, owned by owner, for assets, and transferred those assets to receiver.
     *
     * MUST be emitted when shares are withdrawn from the Vault in ERC4626.redeem or ERC4626.withdraw methods.
     */
    event Withdraw(
        address indexed sender,
        address indexed receiver,
        address indexed owner,
        uint256 amount0,
        uint256 amount1,
        uint256 shares
    );
    event StrategyAnnounced(address newStrategy, uint256 time);
    event StrategyChanged(address newStrategy, address oldStrategy);
    event Rebalanced(uint256 oldPosId, uint256 newPosId, uint256 oldLiquidity, uint256 newLiquidity, uint256 timestamp);

    constructor() public {}

    // the function is name differently to not cause inheritance clash in truffle and allows tests
    function initializeVault(address _storage, uint256 _posId, address _posManager, uint256 _targetWidth)
        public
        initializer
    {
        ControllableInit.initialize(_storage);

        IERC721(_posManager).transferFrom(msg.sender, address(this), _posId);

        (
            ,
            ,
            address _token0,
            address _token1,
            int24 _tickSpacing,
            int24 _tickLower,
            int24 _tickUpper,
            uint256 _initialLiquidity,
            ,
            ,
            ,
        ) = INonfungiblePositionManager(_posManager).positions(_posId);

        uint256 positionWidth = uint256(int256(_tickUpper - _tickLower)) / uint256(int256(_tickSpacing));
        require(_targetWidth <= positionWidth, "Target");

        CLVaultStorage.initialize(_posId, _posManager, positionWidth, _targetWidth);

        __ERC20_init(
            string(
                abi.encodePacked("fCL_", ERC20Upgradeable(_token0).symbol(), "_", ERC20Upgradeable(_token1).symbol())
            ),
            string(
                abi.encodePacked("fCL_", ERC20Upgradeable(_token0).symbol(), "_", ERC20Upgradeable(_token1).symbol())
            )
        );

        _setToken0(_token0);
        _setToken1(_token1);
        _setTickSpacing(_tickSpacing);
        _setTickLower(_tickLower);
        _setTickUpper(_tickUpper);

        _mint(msg.sender, _initialLiquidity);
    }

    function strategy() external view returns (address) {
        return _strategy();
    }

    function token0() external view returns (address) {
        return _token0();
    }

    function token1() external view returns (address) {
        return _token1();
    }

    function posManager() external view returns (address) {
        return _posManager();
    }

    function posId() external view returns (uint256) {
        return _posId();
    }

    function targetWidth() external view returns (uint256) {
        return _targetWidth();
    }

    function setTargetWidth(uint256 _target) external onlyGovernance {
        require(_target <= _posWidth());
        _setTargetWidth(_target);
    }

    function tickLower() external view returns (int24) {
        return _tickLower();
    }

    function tickUpper() external view returns (int24) {
        return _tickUpper();
    }

    function underlyingUnit() external view returns (uint256) {
        return _underlyingUnit();
    }

    function nextImplementation() external view returns (address) {
        return _nextImplementation();
    }

    function nextImplementationTimestamp() external view returns (uint256) {
        return _nextImplementationTimestamp();
    }

    function nextImplementationDelay() public view returns (uint256) {
        return IController(controller()).nextImplementationDelay();
    }

    modifier whenStrategyDefined() {
        require(address(_strategy()) != address(0));
        _;
    }

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

    /**
     * Chooses the best strategy and re-invests. If the strategy did not change, it just calls
     * doHardWork on the current strategy. Call this through controller to claim hard rewards.
     */
    function doHardWork() external nonReentrant whenStrategyDefined onlyControllerOrGovernance {
        if (_shouldRebalance()) {
            rebalanceCurrentTick(_posWidth());
        }
        // ensure that new funds are invested too
        invest();
        IStrategy(_strategy()).doHardWork();
    }

    /* Returns the current underlying (e.g., DAI's) balance together with
    * the invested amount (if DAI is invested elsewhere by the strategy).
    */
    function underlyingBalanceWithInvestment() public view returns (uint256) {
        // note that the liquidity is not a token, so there is no local balance added
        (,,,,,,, uint128 liquidity,,,,) = INonfungiblePositionManager(_posManager()).positions(_posId());
        return liquidity;
    }

    function getPricePerFullShare() external view returns (uint256) {
        return totalSupply() == 0
            ? _underlyingUnit()
            : _underlyingUnit() * underlyingBalanceWithInvestment() / totalSupply();
    }

    /* get the user's share (in underlying)
    */
    function underlyingBalanceWithInvestmentForHolder(address holder) external view returns (uint256) {
        if (totalSupply() == 0) {
            return 0;
        }
        return underlyingBalanceWithInvestment() * balanceOf(holder) / totalSupply();
    }

    function nextStrategy() external view returns (address) {
        return _nextStrategy();
    }

    function nextStrategyTimestamp() external view returns (uint256) {
        return _nextStrategyTimestamp();
    }

    function canUpdateStrategy(address __strategy) public view returns (bool) {
        bool isStrategyNotSetYet = _strategy() == address(0);
        bool hasTimelockPassed = block.timestamp > _nextStrategyTimestamp() && _nextStrategyTimestamp() != 0;
        return isStrategyNotSetYet || (__strategy == _nextStrategy() && hasTimelockPassed);
    }

    /**
     * Indicates that the strategy update will happen in the future
     */
    function announceStrategyUpdate(address _strategy) external onlyControllerOrGovernance {
        // records a new timestamp
        uint256 when = block.timestamp + nextImplementationDelay();
        _setNextStrategyTimestamp(when);
        _setNextStrategy(_strategy);
        emit StrategyAnnounced(_strategy, when);
    }

    /**
     * Finalizes (or cancels) the strategy update by resetting the data
     */
    function finalizeStrategyUpdate() public onlyControllerOrGovernance {
        _setNextStrategyTimestamp(0);
        _setNextStrategy(address(0));
    }

    function setStrategy(address __strategy) external onlyControllerOrGovernance {
        require(canUpdateStrategy(__strategy), "timelock");
        require(__strategy != address(0));
        require(IStrategy(__strategy).vault() == address(this), "vault");

        emit StrategyChanged(__strategy, _strategy());
        if (address(__strategy) != address(_strategy())) {
            if (address(_strategy()) != address(0)) {
                // if the original strategy (no underscore) is defined
                IStrategy(_strategy()).withdrawAllToVault(true);
            }
            _setStrategy(__strategy);
        }
        finalizeStrategyUpdate();
    }

    function invest() internal whenStrategyDefined {
        address _posManager = _posManager();
        uint256 _posId = _posId();
        bool nftInVault = INonfungiblePositionManager(_posManager).ownerOf(_posId) == address(this);
        if (nftInVault) {
            IERC721(_posManager).transferFrom(address(this), _strategy(), _posId);
        }
    }

    /*
    * Allows for depositing the underlying asset in exchange for shares.
    * Approval is assumed.
    */
    function deposit(uint256 amount0, uint256 amount1, uint256 amountOutMin, address receiver)
        external
        nonReentrant
        defense
        returns (uint256 minted)
    {
        minted = _deposit(amount0, amount1, amountOutMin, msg.sender, receiver);
    }

    function withdraw(uint256 shares, uint256 amount0OutMin, uint256 amount1OutMin)
        external
        nonReentrant
        defense
        returns (uint256 amount0, uint256 amount1)
    {
        (amount0, amount1) = _withdraw(shares, amount0OutMin, amount1OutMin, msg.sender, msg.sender);
    }

    function withdrawAll(bool compound) public onlyControllerOrGovernance whenStrategyDefined {
        IStrategy(_strategy()).withdrawAllToVault(compound);
    }

    function _deposit(uint256 amount0, uint256 amount1, uint256 amountOutMin, address sender, address beneficiary)
        internal
        returns (uint256)
    {
        require(beneficiary != address(0), "address(0)");

        if (_strategy() != address(0)) {
            IStrategy(_strategy()).withdrawAllToVault(true);
        }

        address _token0 = _token0();
        address _token1 = _token1();
        IERC20(_token0).safeTransferFrom(sender, address(this), amount0);
        IERC20(_token1).safeTransferFrom(sender, address(this), amount1);

        uint256 liquidityBefore = underlyingBalanceWithInvestment();

        address _posManager = _posManager();
        IERC20(_token0).safeIncreaseAllowance(_posManager, amount0);
        IERC20(_token1).safeIncreaseAllowance(_posManager, amount1);

        (uint128 _liquidity,,) = INonfungiblePositionManager(_posManager).increaseLiquidity(
            INonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId: _posId(),
                amount0Desired: amount0,
                amount1Desired: amount1,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp
            })
        );

        uint256 toMint =
            totalSupply() == 0 ? uint256(_liquidity) : uint256(_liquidity) * totalSupply() / liquidityBefore;

        require(toMint >= amountOutMin, "slippage");

        _mint(beneficiary, toMint);
        emit Deposit(sender, beneficiary, amount0, amount1, toMint);

        _transferLeftOverTo(beneficiary);
        if (_strategy() != address(0)) {
            invest();
            IStrategy(_strategy()).doHardWork();
        }
        return toMint;
    }

    function _withdraw(
        uint256 numberOfShares,
        uint256 amount0OutMin,
        uint256 amount1OutMin,
        address receiver,
        address owner
    ) internal returns (uint256, uint256) {
        require(totalSupply() > 0);
        require(numberOfShares > 0, "!0");

        if (_strategy() != address(0)) {
            IStrategy(_strategy()).withdrawAllToVault(false);
        }

        uint128 liquidityShare = uint128(underlyingBalanceWithInvestment() * numberOfShares / totalSupply());

        if (msg.sender != owner) {
            uint256 currentAllowance = allowance(owner, msg.sender);
            if (currentAllowance != type(uint256).max) {
                require(currentAllowance >= numberOfShares, "ERC20: transfer amount exceeds allowance");
                _approve(owner, msg.sender, currentAllowance - numberOfShares);
            }
        }

        _burn(owner, numberOfShares);

        (uint256 received0, uint256 received1) = _removeFromPosition(liquidityShare, amount0OutMin, amount1OutMin);

        _transferLeftOverTo(receiver);
        emit Withdraw(msg.sender, receiver, owner, received0, received1, numberOfShares);

        if (_strategy() != address(0)) {
            invest();
            IStrategy(_strategy()).doHardWork();
        }
        return (received0, received1);
    }

    function _removeFromPosition(uint128 liquidityAmount, uint256 amount0Min, uint256 amount1Min)
        internal
        returns (uint256, uint256)
    {
        address _posManager = _posManager();
        uint256 _posId = _posId();
        // withdraw liquidity from the NFT
        (uint256 _receivedToken0, uint256 _receivedToken1) = INonfungiblePositionManager(_posManager).decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: _posId,
                liquidity: liquidityAmount,
                amount0Min: amount0Min,
                amount1Min: amount1Min,
                deadline: block.timestamp
            })
        );
        // collect the amount fetched above
        INonfungiblePositionManager(_posManager).collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: _posId,
                recipient: address(this),
                amount0Max: uint128(_receivedToken0), // collect all token0 accounted for the liquidity
                amount1Max: uint128(_receivedToken1) // collect all token1 accounted for the liquidity
            })
        );
        return (_receivedToken0, _receivedToken1);
    }

    /**
     * @dev Handles transferring the leftovers
     */
    function _transferLeftOverTo(address _to) internal {
        address _token0 = _token0();
        address _token1 = _token1();
        uint256 balance0 = IERC20(_token0).balanceOf(address(this));
        uint256 balance1 = IERC20(_token1).balanceOf(address(this));
        if (balance0 > 0) {
            IERC20(_token0).safeTransfer(_to, balance0);
        }
        if (balance1 > 0) {
            IERC20(_token1).safeTransfer(_to, balance1);
        }
    }

    function sweepDust() external onlyControllerOrGovernance {
        _transferLeftOverTo(governance());
    }

    function getPoolSlot0() internal view returns (uint160, int24, uint16, uint16, uint16, bool) {
        address factory = INonfungiblePositionManager(_posManager()).factory();
        address poolAddr = IFactory(factory).getPool(_token0(), _token1(), _tickSpacing());
        return IPool(poolAddr).slot0();
    }

    /**
     * @dev Convenience getter for the current sqrtPriceX96 of the Uniswap pool.
     */
    function getSqrtPriceX96() public view returns (uint160 sqrtPriceX96) {
        (sqrtPriceX96,,,,,) = getPoolSlot0();
    }

    function getCurrentTick() public view returns (int24 currenTick) {
        (, currenTick,,,,) = getPoolSlot0();
    }

    function inRange() public view returns (bool _inRange) {
        uint160 currentSqrtPrice = getSqrtPriceX96();
        uint160 lowerSqrtPrice = TickMath.getSqrtRatioAtTick(_tickLower());
        uint160 upperSqrtPrice = TickMath.getSqrtRatioAtTick(_tickUpper());
        _inRange = lowerSqrtPrice < currentSqrtPrice && currentSqrtPrice < upperSqrtPrice;
    }

    function getCurrentTokenAmounts() public view returns (uint256 amount0, uint256 amount1) {
        (amount0, amount1) = LiquidityAmounts.getAmountsForLiquidity(
            getSqrtPriceX96(),
            TickMath.getSqrtRatioAtTick(_tickLower()),
            TickMath.getSqrtRatioAtTick(_tickUpper()),
            uint128(underlyingBalanceWithInvestment())
        );
    }

    function getCurrentTokenWeights() public view returns (uint256 weight0, uint256 weight1) {
        (weight0, weight1) = _getWeightsForTickLimits(_tickLower(), _tickUpper());
    }

    function _shouldRebalance() internal view returns (bool shouldRebalance) {
        if (_posWidth() == _targetWidth()) {
            shouldRebalance = !inRange();
        } else {
            int256 middleTick = (int256(_tickLower()) + int256(_tickUpper())) / 2;
            int256 currentTick = int256(getCurrentTick());
            uint256 diff =
                middleTick > currentTick ? uint256(middleTick - currentTick) : uint256(currentTick - middleTick);
            uint256 maxDiff = _targetWidth() * uint256(int256(_tickSpacing())) / 2;

            shouldRebalance = diff > maxDiff;
        }
    }

    function checker() external view returns (bool canExec, bytes memory execPayload) {
        canExec = _shouldRebalance();
        execPayload = abi.encodeWithSelector(IController.doHardWork.selector, address(this));
    }

    function rebalanceCurrentTick(uint256 _posWidth) public onlyControllerOrGovernance {
        uint256 oldLiquidity = underlyingBalanceWithInvestment();
        uint256 oldPosId = _posId();
        int24 currentTick = getCurrentTick();

        (int24 tickLowerNew, int24 tickUpperNew) = _getNewTickLimits(currentTick, int24(int256(_posWidth)));
        if (tickLowerNew == _tickLower() && tickUpperNew == _tickUpper()) {
            return;
        }

        (uint256 newWeight0, uint256 newWeight1) = _getWeightsForTickLimits(tickLowerNew, tickUpperNew);
        (uint256 currentWeight0, uint256 currentWeight1) = getCurrentTokenWeights();

        if (_strategy() != address(0)) {
            IStrategy(_strategy()).withdrawAllToVault(false);
        }

        _removeFromPosition(uint128(underlyingBalanceWithInvestment()), 0, 0);
        INonfungiblePositionManager(_posManager()).burn(oldPosId);

        if (currentWeight0 > newWeight0) {
            bool zeroForOne = true;
            uint256 toSwap = IERC20(_token0()).balanceOf(address(this)) * (currentWeight0 - newWeight0) / currentWeight0;
            if (toSwap > 0) {
                _swap(zeroForOne, toSwap);
            }
        } else {
            bool zeroForOne = false;
            uint256 toSwap = IERC20(_token1()).balanceOf(address(this)) * (currentWeight1 - newWeight1) / currentWeight1;
            if (toSwap > 0) {
                _swap(zeroForOne, toSwap);
            }
        }

        uint256 tokenId = _createNewPosition(tickLowerNew, tickUpperNew);

        _setPosId(tokenId);
        _setTickLower(tickLowerNew);
        _setTickUpper(tickUpperNew);
        _setPosWidth(_posWidth);
        if (_posWidth < _targetWidth()) {
            _setTargetWidth(_posWidth);
        }

        if (_strategy() != address(0)) {
            _transferLeftOverTo(_strategy());
        } else {
            _transferLeftOverTo(governance());
        }

        emit Rebalanced(oldPosId, tokenId, oldLiquidity, underlyingBalanceWithInvestment(), block.timestamp);
    }

    function _createNewPosition(int24 _tickLower, int24 _tickUpper) internal returns (uint256 tokenId) {
        address _token0 = _token0();
        address _token1 = _token1();
        uint256 amount0 = IERC20(_token0).balanceOf(address(this));
        uint256 amount1 = IERC20(_token1).balanceOf(address(this));
        address _posManager = _posManager();
        IERC20(_token0).safeIncreaseAllowance(_posManager, amount0);
        IERC20(_token1).safeIncreaseAllowance(_posManager, amount1);

        (tokenId,,,) = INonfungiblePositionManager(_posManager).mint(
            INonfungiblePositionManager.MintParams({
                token0: _token0,
                token1: _token1,
                tickSpacing: _tickSpacing(),
                tickLower: _tickLower,
                tickUpper: _tickUpper,
                amount0Desired: amount0,
                amount1Desired: amount1,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(this),
                deadline: block.timestamp,
                sqrtPriceX96: 0
            })
        );
    }

    function _swap(bool _zeroForOne, uint256 _amountIn) internal {
        address _token0 = _token0();
        address _token1 = _token1();
        address _universalLiquidator = IController(controller()).universalLiquidator();
        if (_zeroForOne) {
            IERC20(_token0).safeIncreaseAllowance(_universalLiquidator, _amountIn);
            IUniversalLiquidator(_universalLiquidator).swap(_token0, _token1, _amountIn, 1, address(this));
        } else {
            IERC20(_token1).safeIncreaseAllowance(_universalLiquidator, _amountIn);
            IUniversalLiquidator(_universalLiquidator).swap(_token1, _token0, _amountIn, 1, address(this));
        }
    }

    function _getWeightsForTickLimits(int24 _tickLower, int24 _tickUpper)
        internal
        view
        returns (uint256 weight0, uint256 weight1)
    {
        uint256 sqrtPrice = uint256(getSqrtPriceX96());
        uint256 price0In1 = sqrtPrice * sqrtPrice * 1e18 / (uint256(2 ** (96 * 2)));
        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            getSqrtPriceX96(),
            TickMath.getSqrtRatioAtTick(_tickLower),
            TickMath.getSqrtRatioAtTick(_tickUpper),
            uint128(1e18)
        );

        uint256 totalBalanceIn1 = amount0 * price0In1 / 1e18 + amount1;
        weight0 = amount0 * price0In1 / totalBalanceIn1;
        weight1 = amount1 * 1e18 / totalBalanceIn1;
        if (weight0 == 0) {
            weight1 = 1e18;
        }
        if (weight1 == 0) {
            weight0 = 1e18;
        }
        uint256 totalWeight = weight0 + weight1;
        if (totalWeight != 1e18) {
            weight0 = weight0 * 1e18 / totalWeight;
            weight1 = 1e18 - weight0;
        }
    }

    function _getNewTickLimits(int24 middle, int24 _posWidth)
        internal
        view
        returns (int24 tickLowerNew, int24 tickUpperNew)
    {
        int24 _tickSpacing = _tickSpacing();

        int24 middleTickTrunc;
        uint160 currentSqrtPrice = getSqrtPriceX96();
        uint160 tickSqrtPrice = TickMath.getSqrtRatioAtTick(middle / _tickSpacing * _tickSpacing);
        if (currentSqrtPrice > tickSqrtPrice) {
            middleTickTrunc = middle / _tickSpacing;
        } else {
            middleTickTrunc = middle / _tickSpacing - 1;
        }

        int24 tickLowerNewTrunc;
        if (_posWidth == 1) {
            tickLowerNewTrunc = middleTickTrunc;
        } else {
            tickLowerNewTrunc = middleTickTrunc - _posWidth / 2;
        }
        int24 tickUpperNewTrunc = tickLowerNewTrunc + _posWidth;

        tickLowerNew = tickLowerNewTrunc * _tickSpacing;
        tickUpperNew = tickUpperNewTrunc * _tickSpacing;
    }

    /**
     * Schedules an upgrade for this vault's proxy.
     */
    function scheduleUpgrade(address impl) public onlyGovernance {
        _setNextImplementation(impl);
        _setNextImplementationTimestamp(block.timestamp + nextImplementationDelay());
    }

    function shouldUpgrade() external view override returns (bool, address) {
        return (
            _nextImplementationTimestamp() != 0 && block.timestamp > _nextImplementationTimestamp()
                && _nextImplementation() != address(0),
            _nextImplementation()
        );
    }

    function finalizeUpgrade() external override onlyGovernance {
        _setNextImplementation(address(0));
        _setNextImplementationTimestamp(0);
    }
}

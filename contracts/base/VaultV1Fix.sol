// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.21;

import {IERC4626} from "./interface/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import "./interface/IStrategy.sol";
import "./interface/IVault.sol";
import "./interface/IController.sol";
import "./interface/IUpgradeSource.sol";
import "./inheritance/ControllableInit.sol";
import "./VaultStorage.sol";

contract VaultV1Fix is ERC20Upgradeable, IUpgradeSource, ControllableInit, VaultStorage {
    using Address for address;
    using SafeERC20 for IERC20;

    event Invest(uint256 amount);
    event StrategyAnnounced(address newStrategy, uint256 time);
    event StrategyChanged(address newStrategy, address oldStrategy);

    constructor() {}

    // the function is name differently to not cause inheritance clash in truffle and allows tests
    function initializeVault(
        address _storage,
        address _underlying,
        uint256 _toInvestNumerator,
        uint256 _toInvestDenominator
    ) public initializer {
        require(_toInvestNumerator <= _toInvestDenominator, "cannot invest more than 100%");
        require(_toInvestDenominator != 0, "cannot divide by 0");

        __ERC20_init(
            string(abi.encodePacked("FARM_", ERC20Upgradeable(_underlying).symbol())),
            string(abi.encodePacked("f", ERC20Upgradeable(_underlying).symbol()))
        );

        ControllableInit.initialize(_storage);

        uint256 underlyingUnit = 10 ** uint256(ERC20Upgradeable(address(_underlying)).decimals());
        VaultStorage.initialize(_underlying, _toInvestNumerator, _toInvestDenominator, underlyingUnit);
    }

    function strategy() public view returns (address) {
        return _strategy();
    }

    function underlying() public view returns (address) {
        return _underlying();
    }

    function underlyingUnit() public view returns (uint256) {
        return _underlyingUnit();
    }

    function vaultFractionToInvestNumerator() public view returns (uint256) {
        return _vaultFractionToInvestNumerator();
    }

    function vaultFractionToInvestDenominator() public view returns (uint256) {
        return _vaultFractionToInvestDenominator();
    }

    function nextImplementation() public view returns (address) {
        return _nextImplementation();
    }

    function nextImplementationTimestamp() public view returns (uint256) {
        return _nextImplementationTimestamp();
    }

    function nextImplementationDelay() public view returns (uint256) {
        return IController(controller()).nextImplementationDelay();
    }

    function setInvestOnDeposit(bool value) external onlyGovernance {
        _setInvestOnDeposit(value);
    }

    function investOnDeposit() public view returns (bool) {
        return _investOnDeposit();
    }

    modifier whenStrategyDefined() {
        require(address(strategy()) != address(0), "Strategy must be defined");
        _;
    }

    // Only smart contracts will be affected by this modifier
    modifier defense() {
        require(
            (msg.sender == tx.origin) // If it is a normal user and not smart contract,
                    // then the requirement will pass
                || !IController(controller()).greyList(msg.sender), // If it is a smart contract, then
            "This smart contract has been grey listed" // make sure that it is not on our greyList.
        );
        _;
    }

    /**
     * Chooses the best strategy and re-invests. If the strategy did not change, it just calls
     * doHardWork on the current strategy. Call this through controller to claim hard rewards.
     */
    function doHardWork() external whenStrategyDefined onlyControllerOrGovernance {
        // ensure that new funds are invested too
        invest();
        IStrategy(strategy()).doHardWork();
    }

    /*
    * Returns the cash balance across all users in this contract.
    */
    function underlyingBalanceInVault() public view returns (uint256) {
        return IERC20(underlying()).balanceOf(address(this));
    }

    /* Returns the current underlying (e.g., DAI's) balance together with
    * the invested amount (if DAI is invested elsewhere by the strategy).
    */
    function underlyingBalanceWithInvestment() public view returns (uint256) {
        if (address(strategy()) == address(0)) {
            // initial state, when not set
            return underlyingBalanceInVault();
        }
        return underlyingBalanceInVault() + (IStrategy(strategy()).investedUnderlyingBalance());
    }

    function getPricePerFullShare() public view returns (uint256) {
        return
            totalSupply() == 0 ? underlyingUnit() : underlyingUnit() * underlyingBalanceWithInvestment() / totalSupply();
    }

    /* get the user's share (in underlying)
    */
    function underlyingBalanceWithInvestmentForHolder(address holder) external view returns (uint256) {
        if (totalSupply() == 0) {
            return 0;
        }
        return underlyingBalanceWithInvestment() * balanceOf(holder) / totalSupply();
    }

    function nextStrategy() public view returns (address) {
        return _nextStrategy();
    }

    function nextStrategyTimestamp() public view returns (uint256) {
        return _nextStrategyTimestamp();
    }

    function canUpdateStrategy(address _strategy) public view returns (bool) {
        bool isStrategyNotSetYet = strategy() == address(0);
        bool hasTimelockPassed = block.timestamp > nextStrategyTimestamp() && nextStrategyTimestamp() != 0;
        return isStrategyNotSetYet || (_strategy == nextStrategy() && hasTimelockPassed);
    }

    /**
     * Indicates that the strategy update will happen in the future
     */
    function announceStrategyUpdate(address _strategy) public onlyControllerOrGovernance {
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

    function setStrategy(address _strategy) public onlyControllerOrGovernance {
        require(canUpdateStrategy(_strategy), "The strategy exists and switch timelock did not elapse yet");
        require(_strategy != address(0), "new _strategy cannot be empty");
        require(
            IStrategy(_strategy).underlying() == address(underlying()),
            "Vault underlying must match Strategy underlying"
        );
        require(IStrategy(_strategy).vault() == address(this), "the strategy does not belong to this vault");

        emit StrategyChanged(_strategy, strategy());
        if (address(_strategy) != address(strategy())) {
            if (address(strategy()) != address(0)) {
                // if the original strategy (no underscore) is defined
                IERC20(underlying()).approve(address(strategy()), 0);
                IStrategy(strategy()).withdrawAllToVault();
            }
            _setStrategy(_strategy);
            IERC20(underlying()).approve(address(strategy()), type(uint256).max);
        }
        finalizeStrategyUpdate();
    }

    function setVaultFractionToInvest(uint256 numerator, uint256 denominator) external onlyGovernance {
        require(denominator > 0, "denominator must be greater than 0");
        require(numerator <= denominator, "denominator must be greater than or equal to the numerator");
        _setVaultFractionToInvestNumerator(numerator);
        _setVaultFractionToInvestDenominator(denominator);
    }

    function rebalance() external onlyControllerOrGovernance {
        withdrawAll();
        invest();
    }

    function availableToInvestOut() public view returns (uint256) {
        uint256 wantInvestInTotal =
            underlyingBalanceWithInvestment() * vaultFractionToInvestNumerator() / vaultFractionToInvestDenominator();

        uint256 alreadyInvested = IStrategy(strategy()).investedUnderlyingBalance();
        if (alreadyInvested >= wantInvestInTotal) {
            return 0;
        } else {
            uint256 remainingToInvest = wantInvestInTotal - alreadyInvested;
            return remainingToInvest <= underlyingBalanceInVault()
                // TODO: we think that the "else" branch of the ternary operation is not
                // going to get hit
                ? remainingToInvest
                : underlyingBalanceInVault();
        }
    }

    function invest() internal whenStrategyDefined {
        uint256 availableAmount = availableToInvestOut();
        if (availableAmount > 0) {
            IERC20(underlying()).safeTransfer(address(strategy()), availableAmount);
            emit Invest(availableAmount);
        }
    }

    /*
    * Allows for depositing the underlying asset in exchange for shares.
    * Approval is assumed.
    */
    function deposit(uint256 amount) external nonReentrant defense returns (uint256 minted) {
        minted = _deposit(amount, msg.sender, msg.sender);
    }

    /*
    * Allows for depositing the underlying asset in exchange for shares
    * assigned to the holder.
    * This facilitates depositing for someone else (using DepositHelper)
    */
    function depositFor(uint256 amount, address holder) public nonReentrant defense returns (uint256 minted) {
        minted = _deposit(amount, msg.sender, holder);
    }

    function withdraw(uint256 shares) external nonReentrant defense returns (uint256 amtUnderlying) {
        amtUnderlying = _withdraw(shares, msg.sender, msg.sender);
    }

    function withdrawAll() public onlyControllerOrGovernance whenStrategyDefined {
        IStrategy(strategy()).withdrawAllToVault();
    }

    function _deposit(uint256 amount, address sender, address beneficiary) internal returns (uint256) {
        require(amount > 0, "Cannot deposit 0");
        require(beneficiary != address(0), "holder must be defined");

        if (address(strategy()) != address(0)) {
            require(IStrategy(strategy()).depositArbCheck(), "Too much arb");
        }

        IERC20(underlying()).safeTransferFrom(sender, address(this), amount);

        if (investOnDeposit()) {
            invest();
            IStrategy(strategy()).doHardWork();
        }

        uint256 toMint =
            totalSupply() == 0 ? amount : amount * totalSupply() / (underlyingBalanceWithInvestment() - amount);
        _mint(beneficiary, toMint);

        // update the contribution amount for the beneficiary
        emit IERC4626.Deposit(sender, beneficiary, amount, toMint);
        return toMint;
    }

    function _withdraw(uint256 numberOfShares, address receiver, address owner) internal returns (uint256) {
        require(totalSupply() > 0, "Vault has no shares");
        require(numberOfShares > 0, "numberOfShares must be greater than 0");
        uint256 totalSupply = totalSupply();

        address sender = msg.sender;
        if (sender != owner) {
            uint256 currentAllowance = allowance(owner, sender);
            if (currentAllowance != type(uint256).max) {
                require(currentAllowance >= numberOfShares, "ERC20: transfer amount exceeds allowance");
                _approve(owner, sender, currentAllowance - numberOfShares);
            }
        }
        _burn(owner, numberOfShares);

        uint256 underlyingAmountToWithdraw = underlyingBalanceWithInvestment() * numberOfShares / totalSupply;
        if (underlyingAmountToWithdraw > underlyingBalanceInVault()) {
            // withdraw everything from the strategy to accurately check the share value
            if (numberOfShares == totalSupply) {
                IStrategy(strategy()).withdrawAllToVault();
            } else {
                uint256 missing = underlyingAmountToWithdraw - underlyingBalanceInVault();
                IStrategy(strategy()).withdrawToVault(missing);
            }
            // recalculate to improve accuracy
            underlyingAmountToWithdraw =
                Math.min(underlyingBalanceWithInvestment() * numberOfShares / totalSupply, underlyingBalanceInVault());
        }

        IERC20(underlying()).safeTransfer(receiver, underlyingAmountToWithdraw);

        // update the withdrawal amount for the holder
        emit IERC4626.Withdraw(sender, receiver, owner, underlyingAmountToWithdraw, numberOfShares);
        return underlyingAmountToWithdraw;
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
            nextImplementationTimestamp() != 0 && block.timestamp > nextImplementationTimestamp()
                && nextImplementation() != address(0),
            nextImplementation()
        );
    }

    function finalizeUpgrade() external override onlyGovernance {
        _setNextImplementation(address(0));
        _setNextImplementationTimestamp(0);
    }

    function decimals() public view virtual override returns (uint8) {
        return ERC20Upgradeable(_underlying).decimals();
    }
}

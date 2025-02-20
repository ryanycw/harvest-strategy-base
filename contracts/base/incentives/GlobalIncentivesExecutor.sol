// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.21;

import "../inheritance/Controllable.sol";
import "../interface/IGlobalIncentivesHelper.sol";

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";

contract GlobalIncentivesExecutor is Controllable {
    mapping(address => bool) public notifier;
    mapping(address => bool) public changer;

    address[] public tokens;
    uint256[] public totals;
    address public globalIncentivesHelper;
    uint256 public mostRecentWeeksEmissionTimestamp;

    event ChangerSet(address indexed account, bool value);
    event NotifierSet(address indexed account, bool value);

    modifier onlyChanger() {
        require(changer[msg.sender] || msg.sender == governance(), "Only changer");
        _;
    }

    modifier onlyNotifier() {
        require(notifier[msg.sender] || msg.sender == governance(), "Only notifier");
        _;
    }

    constructor(address _storage, address _globalIncentivesHelper) public Controllable(_storage) {
        globalIncentivesHelper = _globalIncentivesHelper;
    }

    function updateData(address[] calldata _tokens, uint256[] calldata _totals, uint256 baseTimestamp)
        external
        onlyChanger
    {
        tokens = _tokens;
        totals = _totals;
        if (baseTimestamp > 0) {
            // 0 means "do not reset"
            mostRecentWeeksEmissionTimestamp = baseTimestamp;
        } else {
            require(mostRecentWeeksEmissionTimestamp > 0, "you have to configure mostRecentWeeksEmissionTimestamp");
        }
    }

    function execute() external onlyNotifier {
        require(mostRecentWeeksEmissionTimestamp > 0, "mostRecentWeeksEmissionTimestamp was never configured");
        require(mostRecentWeeksEmissionTimestamp + (1 weeks) <= block.timestamp, "too early");
        for (uint256 i = 0; i < tokens.length; i++) {
            uint256 globalIncentivesHelperBalance = IERC20(tokens[i]).balanceOf(globalIncentivesHelper);
            require(globalIncentivesHelperBalance >= totals[i], "not enough balance");
        }
        mostRecentWeeksEmissionTimestamp = mostRecentWeeksEmissionTimestamp + (1 weeks);
        IGlobalIncentivesHelper(globalIncentivesHelper).notifyPools(tokens, totals, mostRecentWeeksEmissionTimestamp);
    }

    /// Returning the governance
    function transferGovernance(address target, address newStorage) external onlyGovernance {
        Governable(target).setStorage(newStorage);
    }

    /// The governance configures whitelists
    function setChanger(address who, bool value) external onlyGovernance {
        changer[who] = value;
        emit ChangerSet(who, value);
    }

    /// The governance configures whitelists
    function setNotifier(address who, bool value) external onlyGovernance {
        notifier[who] = value;
        emit NotifierSet(who, value);
    }
}

// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.21;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

contract CLVaultStorage is Initializable {
    bytes32 internal constant _STRATEGY_SLOT = 0xf1a169aa0f736c2813818fdfbdc5755c31e0839c8f49831a16543496b28574ea;
    bytes32 internal constant _TOKEN0_SLOT = 0x79a9ec80eae65602abfc43e4e7c9bf1ac70bbea530cd445f041dff218e6fcc46;
    bytes32 internal constant _TOKEN1_SLOT = 0x212adbc75c59ced7d534d662f6756f8ca81c23dd71f420016802caeecf2b4480;
    bytes32 internal constant _POS_ID_SLOT = 0xcac2a2b8ceeeafefb2148deaa91228172c726053b541e1b2f21a8b5a13690e37;
    bytes32 internal constant _POS_MANAGER_SLOT = 0x854680fb1da618abdf66ae3cb2fd403d849aec90034a6d8b3fd65fce65359c5a;
    bytes32 internal constant _POS_WIDTH_SLOT = 0xabac5d119f6bf94e6c799323fbaed472fc0f9d185c90ab3abb85be2e533db395;
    bytes32 internal constant _TARGET_WIDTH_SLOT = 0x9f43958f93320a028cf3ca962209d579ad24eed2c6a21b2cafb888745f11d6b7;
    bytes32 internal constant _TICK_UPPER_SLOT = 0x25b0d50e306b99e27d41d56e836c7a68b8976a7066b7ba51e22e0dbcc7f960da;
    bytes32 internal constant _TICK_LOWER_SLOT = 0x97d0853e434cd90e097e89bd1e5df075d931c7dfc04cf142779986efce0ec1f9;
    bytes32 internal constant _TICK_SPACING_SLOT = 0xfa5cd416162d7465a01d1be89e13b1dabf1a47ae42a5bec0e3a9c815500f6eea;
    bytes32 internal constant _UNDERLYING_UNIT_SLOT = 0xa66bc57d4b4eed7c7687876ca77997588987307cb13ecc23f5e52725192e5fff;
    bytes32 internal constant _NEXT_IMPLEMENTATION_SLOT =
        0xb1acf527cd7cd1668b30e5a9a1c0d845714604de29ce560150922c9d8c0937df;
    bytes32 internal constant _NEXT_IMPLEMENTATION_TIMESTAMP_SLOT =
        0x3bc747f4b148b37be485de3223c90b4468252967d2ea7f9fcbd8b6e653f434c9;
    bytes32 internal constant _NEXT_STRATEGY_SLOT = 0xcd7bd9250b0e02f3b13eccf8c73ef5543cb618e0004628f9ca53b65fbdbde2d0;
    bytes32 internal constant _NEXT_STRATEGY_TIMESTAMP_SLOT =
        0x5d2b24811886ad126f78c499d71a932a5435795e4f2f6552f0900f12d663cdcf;
    bytes32 internal constant _PAUSED_SLOT = 0xf1cf856d03630b74791fc293cfafd739932a5a075b02d357fb7a726a38777930;

    /**
     * @dev Storage slot with the address of the current implementation.
     * This is the keccak-256 hash of "eip1967.proxy.implementation" subtracted by 1, and is
     * validated in the constructor.
     */
    bytes32 internal constant _IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    constructor() public {
        assert(_STRATEGY_SLOT == bytes32(uint256(keccak256("eip1967.vaultStorage.strategy")) - 1));
        assert(_TOKEN0_SLOT == bytes32(uint256(keccak256("eip1967.vaultStorage.token0")) - 1));
        assert(_TOKEN1_SLOT == bytes32(uint256(keccak256("eip1967.vaultStorage.token1")) - 1));
        assert(_POS_ID_SLOT == bytes32(uint256(keccak256("eip1967.vaultStorage.posId")) - 1));
        assert(_POS_MANAGER_SLOT == bytes32(uint256(keccak256("eip1967.vaultStorage.posManager")) - 1));
        assert(_POS_WIDTH_SLOT == bytes32(uint256(keccak256("eip1967.vaultStorage.posWidth")) - 1));
        assert(_TARGET_WIDTH_SLOT == bytes32(uint256(keccak256("eip1967.vaultStorage.targetWidth")) - 1));
        assert(_TICK_UPPER_SLOT == bytes32(uint256(keccak256("eip1967.vaultStorage.tickUpper")) - 1));
        assert(_TICK_LOWER_SLOT == bytes32(uint256(keccak256("eip1967.vaultStorage.tickLower")) - 1));
        assert(_TICK_SPACING_SLOT == bytes32(uint256(keccak256("eip1967.vaultStorage.tickSpacing")) - 1));
        assert(_UNDERLYING_UNIT_SLOT == bytes32(uint256(keccak256("eip1967.vaultStorage.underlyingUnit")) - 1));
        assert(_NEXT_IMPLEMENTATION_SLOT == bytes32(uint256(keccak256("eip1967.vaultStorage.nextImplementation")) - 1));
        assert(
            _NEXT_IMPLEMENTATION_TIMESTAMP_SLOT
                == bytes32(uint256(keccak256("eip1967.vaultStorage.nextImplementationTimestamp")) - 1)
        );
        assert(_NEXT_STRATEGY_SLOT == bytes32(uint256(keccak256("eip1967.vaultStorage.nextStrategy")) - 1));
        assert(
            _NEXT_STRATEGY_TIMESTAMP_SLOT
                == bytes32(uint256(keccak256("eip1967.vaultStorage.nextStrategyTimestamp")) - 1)
        );
        assert(_PAUSED_SLOT == bytes32(uint256(keccak256("eip1967.vaultStorage.paused")) - 1));
    }

    function initialize(uint256 _posID, address _posManager, uint256 _posWidth, uint256 _targetWidth)
        public
        initializer
    {
        _setPosId(_posID);
        _setPosManager(_posManager);
        _setPosWidth(_posWidth);
        _setTargetWidth(_targetWidth);
        _setUnderlyingUnit(1e18);
        _setNextStrategyTimestamp(0);
        _setNextStrategy(address(0));
    }

    function _setStrategy(address _address) internal {
        setAddress(_STRATEGY_SLOT, _address);
    }

    function _strategy() internal view returns (address) {
        return getAddress(_STRATEGY_SLOT);
    }

    function _setToken0(address _address) internal {
        setAddress(_TOKEN0_SLOT, _address);
    }

    function _token0() internal view returns (address) {
        return getAddress(_TOKEN0_SLOT);
    }

    function _setToken1(address _address) internal {
        setAddress(_TOKEN1_SLOT, _address);
    }

    function _token1() internal view returns (address) {
        return getAddress(_TOKEN1_SLOT);
    }

    function _setPosId(uint256 _posId) internal {
        setUint256(_POS_ID_SLOT, _posId);
    }

    function _posId() internal view returns (uint256) {
        return getUint256(_POS_ID_SLOT);
    }

    function _setPosManager(address _address) internal {
        setAddress(_POS_MANAGER_SLOT, _address);
    }

    function _posManager() internal view returns (address) {
        return getAddress(_POS_MANAGER_SLOT);
    }

    function _setPosWidth(uint256 _value) internal {
        setUint256(_POS_WIDTH_SLOT, _value);
    }

    function _posWidth() internal view returns (uint256) {
        return getUint256(_POS_WIDTH_SLOT);
    }

    function _setTargetWidth(uint256 _value) internal {
        setUint256(_TARGET_WIDTH_SLOT, _value);
    }

    function _targetWidth() internal view returns (uint256) {
        return getUint256(_TARGET_WIDTH_SLOT);
    }

    function _setTickUpper(int24 _tick) internal {
        setInt24(_TICK_UPPER_SLOT, _tick);
    }

    function _tickUpper() internal view returns (int24) {
        return getInt24(_TICK_UPPER_SLOT);
    }

    function _setTickLower(int24 _tick) internal {
        setInt24(_TICK_LOWER_SLOT, _tick);
    }

    function _tickLower() internal view returns (int24) {
        return getInt24(_TICK_LOWER_SLOT);
    }

    function _setTickSpacing(int24 _fee) internal {
        setInt24(_TICK_SPACING_SLOT, _fee);
    }

    function _tickSpacing() internal view returns (int24) {
        return getInt24(_TICK_SPACING_SLOT);
    }

    function _setUnderlyingUnit(uint256 _value) internal {
        setUint256(_UNDERLYING_UNIT_SLOT, _value);
    }

    function _underlyingUnit() internal view returns (uint256) {
        return getUint256(_UNDERLYING_UNIT_SLOT);
    }

    function _setNextImplementation(address _address) internal {
        setAddress(_NEXT_IMPLEMENTATION_SLOT, _address);
    }

    function _nextImplementation() internal view returns (address) {
        return getAddress(_NEXT_IMPLEMENTATION_SLOT);
    }

    function _setNextImplementationTimestamp(uint256 _value) internal {
        setUint256(_NEXT_IMPLEMENTATION_TIMESTAMP_SLOT, _value);
    }

    function _nextImplementationTimestamp() internal view returns (uint256) {
        return getUint256(_NEXT_IMPLEMENTATION_TIMESTAMP_SLOT);
    }

    function _setNextStrategy(address _value) internal {
        setAddress(_NEXT_STRATEGY_SLOT, _value);
    }

    function _nextStrategy() internal view returns (address) {
        return getAddress(_NEXT_STRATEGY_SLOT);
    }

    function _setNextStrategyTimestamp(uint256 _value) internal {
        setUint256(_NEXT_STRATEGY_TIMESTAMP_SLOT, _value);
    }

    function _nextStrategyTimestamp() internal view returns (uint256) {
        return getUint256(_NEXT_STRATEGY_TIMESTAMP_SLOT);
    }

    function _implementation() internal view returns (address) {
        return getAddress(_IMPLEMENTATION_SLOT);
    }

    function _paused() internal view returns (bool) {
        return getBoolean(_PAUSED_SLOT);
    }

    function _setPaused(bool _value) internal {
        setBoolean(_PAUSED_SLOT, _value);
    }

    function setBoolean(bytes32 slot, bool _value) internal {
        setUint256(slot, _value ? 1 : 0);
    }

    function getBoolean(bytes32 slot) internal view returns (bool) {
        return (getUint256(slot) == 1);
    }

    function setAddress(bytes32 slot, address _address) internal {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            sstore(slot, _address)
        }
    }

    function setUint256(bytes32 slot, uint256 _value) internal {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            sstore(slot, _value)
        }
    }

    function setInt24(bytes32 slot, int24 _value) internal {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            sstore(slot, _value)
        }
    }

    function setUint24(bytes32 slot, uint24 _value) internal {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            sstore(slot, _value)
        }
    }

    function getAddress(bytes32 slot) internal view returns (address str) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            str := sload(slot)
        }
    }

    function getUint256(bytes32 slot) internal view returns (uint256 str) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            str := sload(slot)
        }
    }

    function getInt24(bytes32 slot) internal view returns (int24 str) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            str := sload(slot)
        }
    }

    function getUint24(bytes32 slot) internal view returns (uint24 str) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            str := sload(slot)
        }
    }

    uint256[50] private ______gap;
}

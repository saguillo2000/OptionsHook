// SPDX-License-Identifier: MIT

// Layout of Contract:
// version
// imports
// interfaces, libraries, contracts
// errors
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// view & pure functions

pragma solidity ^0.8.26;

import {BalanceDelta, toBalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {BeforeSwapDelta, toBeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

/// @title A title that should describe the contract/interface
/// @author The name of the author
/// @notice Explain to an end user what this does
/// @dev Explain to a developer any extra details
contract OptionsHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    error OptionsHook__ThisIsAnError();
    error OptionsHook_StatusInvalid();
    error OptionsHook_NotYourOption();

    // NOTE: ---------------------------------------------------------
    // state variables should typically be unique to a pool
    // a single hook contract should be able to service multiple pools
    // ---------------------------------------------------------------

    // We are going to make an option with timestamp
    struct OptionInfo {
        uint256 nonce;
        address recipientAddress;
        address assetTypeIn;
        uint256 assetAmountIn;
        address assetTypeOut;
        uint256 assetAmountOut;
        address owner;
        uint256 fee;
        uint256 timestampExpiration;
    }

    enum OptionStatus {
        PLACED,
        RESERVED,
        COMPLETED,
        EXPIRED,
        DROPPED
    }

    bytes internal constant ZERO_BYTES = bytes("");

    mapping(address asset => mapping(uint256 nonce => OptionInfo)) public options; // storage of options
    mapping(address asset => mapping(uint256 nonce => OptionStatus)) public optionStatus; // status of the options
    // mapping(address owner => mapping(uint256 nonce => OptionInfo)) public optionsToExecute; // nonce for the options

    // mapping(address owner => uint256) public traderNonce; // nonce for the options
    mapping(address asset => uint256) public optionNonce; // nonce for the options

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // -----------------------------------------------
    // NOTE: see IHooks.sol for function documentation
    // -----------------------------------------------

    function beforeSwap(
        address,
        PoolKey calldata _key,
        IPoolManager.SwapParams calldata _params,
        bytes calldata _hookData
    ) external override returns (bytes4, BeforeSwapDelta, uint24) {
        (uint8 hookCase, OptionInfo memory option) = abi.decode(_hookData, (uint8, OptionInfo));

        if (hookCase == 1) {
            Currency input = _params.zeroForOne ? _key.currency0 : _key.currency1;

            placeNewOption(option);

            poolManager.take(input, address(this), uint256(-_params.amountSpecified));
        }

        if (hookCase == 2) {
            validateOptionStatus(option, OptionStatus.PLACED);
            if (_params.amountSpecified != int256(option.assetAmountOut)){
                revert OptionsHook__ThisIsAnError();
            }

            Currency output = _params.zeroForOne ? _key.currency1 : _key.currency0;
            OptionInfo storage option = options[option.assetTypeIn][option.nonce];

            bookOption(option);

            poolManager.take(output, address(this), uint256(_params.amountSpecified));
        } else {
            revert OptionsHook__ThisIsAnError();
        }

        return (BaseHook.beforeSwap.selector, toBeforeSwapDelta(-int128(_params.amountSpecified), 0), 0);
    }

    function placeNewOption(OptionInfo memory option) internal {
        uint256 nonce = optionNonce[option.assetTypeIn];
        options[option.assetTypeIn][nonce] = option;
        optionStatus[option.assetTypeIn][nonce] = OptionStatus.PLACED;

        unchecked {
            optionNonce[option.assetTypeIn]++;
        }
    }

    function bookOption(OptionInfo memory option) internal {
        option.owner = msg.sender;
        optionStatus[option.assetTypeIn][option.nonce] = OptionStatus.RESERVED;
    }

    function handleExecuteOption(address asset, uint256 nonce) private {
        OptionInfo storage option = options[asset][nonce];

        validateOptionStatus(option, OptionStatus.RESERVED);
        if (option.owner != msg.sender){
            revert OptionsHook_NotYourOption();
        }

        IERC20(option.assetTypeIn).transfer(option.recipientAddress, option.assetAmountIn);
    }

    function validateOptionStatus(OptionInfo memory option, OptionStatus requiredStatus)
        private
        view{
        if (
            optionStatus[option.assetTypeIn][option.nonce] == requiredStatus
                || option.timestampExpiration < block.timestamp
        ) {
            revert OptionsHook_StatusInvalid();
        }
    }
}

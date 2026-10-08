// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @notice Immutable launch protection for one SIMDTEST/IMD pool.
/// @dev All fees remain inside PoolManager and are donated to the currently in-range LPs.
contract SIMDTESTHook {
    using SafeCast for int256;

    address public constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 ether;
    uint256 public constant MAX_BUY = TOTAL_SUPPLY / 100;
    uint24 public constant LP_FEE = 12_500;
    int24 public constant TICK_SPACING = 60;
    uint256 public constant FEE_DENOMINATOR = 1_000_000;
    uint256 public constant INITIAL_FEE = 300_000;
    uint256 public constant ANTI_SNIPE_BLOCKS = 10;
    uint256 public constant BUY_LIMIT_DURATION = 1 hours;

    IPoolManager public immutable poolManager;
    address public immutable token;
    PoolId public immutable poolId;
    bool public immutable pairedIsCurrency0;

    bool public opened;
    uint256 public openingBlock;
    uint256 public openingTimestamp;

    error OnlyPoolManager();
    error InvalidDeployment();
    error WrongPool();
    error AlreadyOpened();
    error NotOpened();
    error MaxBuyExceeded(uint256 purchased, uint256 maximum);
    error PartialFillWithSpecifiedFee();
    error SwapAmountTooLarge();

    event PoolOpened(PoolId indexed id, uint256 blockNumber, uint256 timestamp);
    event AntiSnipeDonation(PoolId indexed id, uint256 rate, uint256 amountIMD);

    constructor(IPoolManager manager_, address token_) {
        if (address(manager_).code.length == 0 || token_.code.length == 0 || token_ == IMD) {
            revert InvalidDeployment();
        }
        if (IERC20Metadata(token_).totalSupply() != TOTAL_SUPPLY || IERC20Metadata(token_).decimals() != 18) {
            revert InvalidDeployment();
        }
        poolManager = manager_;
        token = token_;
        pairedIsCurrency0 = IMD < token_;
        poolId = PoolKey({
            currency0: Currency.wrap(IMD < token_ ? IMD : token_),
            currency1: Currency.wrap(IMD < token_ ? token_ : IMD),
            fee: LP_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(this))
        }).toId();
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        _;
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory permissions) {
        permissions.beforeInitialize = true;
        permissions.beforeSwap = true;
        permissions.afterSwap = true;
        permissions.beforeSwapReturnDelta = true;
        permissions.afterSwapReturnDelta = true;
    }

    /// @dev The factory must deploy and initialize atomically, then seed before allowing swaps.
    function beforeInitialize(address, PoolKey calldata key, uint160) external onlyPoolManager returns (bytes4) {
        _checkPool(key);
        if (opened) revert AlreadyOpened();
        opened = true;
        openingBlock = block.number;
        openingTimestamp = block.timestamp;
        emit PoolOpened(poolId, block.number, block.timestamp);
        return IHooks.beforeInitialize.selector;
    }

    /// @notice Rate in millionths: opening block 30%, then 27%, ..., 3%, and zero at B+10.
    function antiSnipeFee() public view returns (uint256) {
        if (!opened) return 0;
        uint256 elapsed = block.number - openingBlock;
        return elapsed >= ANTI_SNIPE_BLOCKS ? 0 : INITIAL_FEE * (ANTI_SNIPE_BLOCKS - elapsed) / ANTI_SNIPE_BLOCKS;
    }

    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _checkOpenPool(key);
        uint256 rate = antiSnipeFee();
        uint256 fee;
        if (rate != 0 && _pairIsSpecified(params)) {
            fee = _specifiedFee(params.amountSpecified, rate);
        }
        // Positive delta credits the hook, debits the swapper, and adjusts the core swap amount.
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(int256(fee).toInt128(), 0), 0);
    }

    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, int128) {
        _checkOpenPool(key);
        bool buy = params.zeroForOne == pairedIsCurrency0;
        int128 tokenDelta = pairedIsCurrency0 ? delta.amount1() : delta.amount0();
        if (buy && block.timestamp - openingTimestamp < BUY_LIMIT_DURATION && tokenDelta > int256(MAX_BUY)) {
            revert MaxBuyExceeded(uint256(int256(tokenDelta)), MAX_BUY);
        }

        uint256 rate = antiSnipeFee();
        if (rate == 0) return (IHooks.afterSwap.selector, 0);

        int128 pairDelta = pairedIsCurrency0 ? delta.amount0() : delta.amount1();
        bool specified = _pairIsSpecified(params);
        uint256 fee;
        if (specified) {
            fee = _specifiedFee(params.amountSpecified, rate);
            // v4 cannot return a specified-currency refund from afterSwap. Revert atomically
            // rather than charge an upfront fee on unfilled input/output at a price limit.
            if (fee != 0 && int256(pairDelta) != params.amountSpecified + int256(fee)) {
                revert PartialFillWithSpecifiedFee();
            }
        } else if (buy && pairDelta < 0) {
            // Exact-output buy: gross up actual IMD input, including the pool's own LP fee.
            fee = uint256(-int256(pairDelta)) * rate / (FEE_DENOMINATOR - rate);
        } else if (!buy && pairDelta > 0) {
            // Exact-input sell: withhold a fraction of actual IMD output.
            fee = uint256(int256(pairDelta)) * rate / FEE_DENOMINATOR;
        }

        int128 feeDelta = int256(fee).toInt128();
        if (fee != 0) {
            // donate creates a negative hook delta; the swap return delta cancels it in the
            // SAME unlock. No take, transfer, approval, conversion, or ERC-6909 claim is needed.
            poolManager.donate(key, pairedIsCurrency0 ? fee : 0, pairedIsCurrency0 ? 0 : fee, "");
            emit AntiSnipeDonation(poolId, rate, fee);
        }
        return (IHooks.afterSwap.selector, specified ? int128(0) : feeDelta);
    }

    function _pairIsSpecified(IPoolManager.SwapParams calldata params) private view returns (bool) {
        return (params.amountSpecified < 0) == (params.zeroForOne == pairedIsCurrency0);
    }

    function _specifiedFee(int256 amount, uint256 rate) private pure returns (uint256 fee) {
        // Bound before negation/multiplication and before converting to v4's int128 deltas.
        if (amount < -int256(type(int128).max) || amount > int256(type(int128).max)) {
            revert SwapAmountTooLarge();
        }
        if (amount < 0) {
            fee = uint256(-amount) * rate / FEE_DENOMINATOR;
        } else {
            fee = uint256(amount) * rate / (FEE_DENOMINATOR - rate);
            if (uint256(amount) + fee > uint256(uint128(type(int128).max))) revert SwapAmountTooLarge();
        }
    }

    function _checkPool(PoolKey calldata key) private view {
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(poolId)) revert WrongPool();
    }

    function _checkOpenPool(PoolKey calldata key) private view {
        _checkPool(key);
        if (!opened) revert NotOpened();
    }
}

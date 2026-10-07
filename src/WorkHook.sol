// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {WorkersNFT, IWorkToken, WorkTokenOps} from "./WorkersNFT.sol";

// Self-contained, ABI-compatible subset of the Uniswap v4 core types and interfaces.
// https://github.com/Uniswap/v4-core/tree/v4.0.0/src
type Currency is address;
type BalanceDelta is int256;
type BeforeSwapDelta is int256;

struct PoolKey {
    Currency currency0;
    Currency currency1;
    uint24 fee;
    int24 tickSpacing;
    IHooks hooks;
}

struct SwapParams {
    bool zeroForOne;
    int256 amountSpecified;
    uint160 sqrtPriceLimitX96;
}

interface IHooks {
    function beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96) external returns (bytes4);
    function afterInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96, int24 tick)
        external
        returns (bytes4);
    function beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        external
        returns (bytes4, BeforeSwapDelta, uint24);
    function afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external returns (bytes4, int128);
}

interface IPoolManager {
    function unlock(bytes calldata data) external returns (bytes memory);
    function swap(PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        external
        returns (BalanceDelta);
    function sync(Currency currency) external;
    function take(Currency currency, address to, uint256 amount) external;
    function settle() external payable returns (uint256);
    function extsload(bytes32 slot) external view returns (bytes32);
}

library Hooks {
    struct Permissions {
        bool beforeInitialize;
        bool afterInitialize;
        bool beforeAddLiquidity;
        bool afterAddLiquidity;
        bool beforeRemoveLiquidity;
        bool afterRemoveLiquidity;
        bool beforeSwap;
        bool afterSwap;
        bool beforeDonate;
        bool afterDonate;
        bool beforeSwapReturnDelta;
        bool afterSwapReturnDelta;
        bool afterAddLiquidityReturnDelta;
        bool afterRemoveLiquidityReturnDelta;
    }
}

/// @notice WORK/IMD fees and TWAP-protected buybacks for one immutable v4 pool.
/// @dev Deploy using CREATE2 with the low 14 address bits equal to REQUIRED_HOOK_FLAGS.
contract WorkHook is IHooks {
    using WorkTokenOps for address;

    address public constant IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    address public constant B = 0xc9EAFE33A510a3a3d95A94c4f85AdaF6a3EA12a0;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint24 public constant POOL_FEE = 12_500;
    uint256 public constant MAX_FEE_BPS = 875;
    uint256 public constant MIN_STAKER_SHARE_BPS = 9000;
    uint256 public constant TWAP_WINDOW = 30 minutes;
    uint256 public constant BUYBACK_SLIPPAGE_BPS = 100;
    uint256 public constant OBSERVATION_CAPACITY = 2048;
    uint160 public constant REQUIRED_HOOK_FLAGS = 0x30cc;
    uint160 public constant MIN_SQRT_PRICE = 4295128739;
    uint160 public constant MAX_SQRT_PRICE = 1461446703485210103287273052203988822378723970342;

    IPoolManager public immutable poolManager;
    address public immutable token;
    address public immutable owner;
    int24 public immutable tickSpacing;
    WorkersNFT public immutable workers;
    bool public immutable imdIsCurrency0;
    uint256 public feeBps = 75;
    uint256 public stakerShareBps = 10_000;
    bool public initialized;
    bytes32 public poolId;
    PoolKey public poolKey;

    // At most one observation per second. 2048 slots retain more than the 1800s window,
    // even on Nitro with many L2 blocks per second. Same-second swaps update only the tick.
    struct Observation {
        uint64 timestamp;
        int96 cumulative;
        int24 tick;
    }
    Observation[2048] public observations;
    uint256 public observationIndex;
    uint256 public observationCount;
    uint256 private _entered;
    uint256 private _buybackInput;
    uint256 private _buybackMinimum;

    event FeeChanged(uint256 oldBps, uint256 newBps);
    event StakerShareChanged(uint256 oldBps, uint256 newBps);
    event PoolRegistered(bytes32 indexed poolId);
    event FeeDistributed(uint256 total, uint256 stakers, uint256 beneficiary);
    event BuybackExecuted(uint256 imdIn, uint256 workOut, uint256 minimumOut);
    event Swept(address indexed token, uint256 amount);

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner");
        _;
    }

    modifier onlyManager() {
        require(msg.sender == address(poolManager), "Only PoolManager");
        _;
    }

    modifier nonReentrant() {
        require(_entered == 0, "Reentrancy");
        _entered = 1;
        _;
        _entered = 0;
    }

    constructor(IPoolManager manager, address token_, address owner_, int24 tickSpacing_) {
        require(
            address(manager).code.length != 0 && token_.code.length != 0 && token_ != IMD && owner_ != address(0),
            "Bad setup"
        );
        require(tickSpacing_ > 0 && tickSpacing_ <= 32767, "Bad tick spacing");
        require(uint160(address(this)) & 0x3fff == REQUIRED_HOOK_FLAGS, "Wrong hook address flags");
        poolManager = manager;
        token = token_;
        owner = owner_;
        tickSpacing = tickSpacing_;
        imdIsCurrency0 = IMD < token_;
        workers = new WorkersNFT(token_, owner_, address(this));
    }

    function getHookPermissions() external pure returns (Hooks.Permissions memory permissions) {
        permissions.beforeInitialize = true;
        permissions.afterInitialize = true;
        permissions.beforeSwap = true;
        permissions.afterSwap = true;
        permissions.beforeSwapReturnDelta = true;
        permissions.afterSwapReturnDelta = true;
    }

    function setFeeBps(uint256 bps) external onlyOwner {
        require(bps <= MAX_FEE_BPS, "Fee exceeds 8.75%");
        emit FeeChanged(feeBps, bps);
        feeBps = bps;
    }

    function setStakerShareBps(uint256 bps) external onlyOwner {
        require(bps >= MIN_STAKER_SHARE_BPS && bps <= 10_000, "Share out of range");
        emit StakerShareChanged(stakerShareBps, bps);
        stakerShareBps = bps;
    }

    function _validateKey(PoolKey calldata key) private view {
        require(
            Currency.unwrap(key.currency0) == (imdIsCurrency0 ? IMD : token)
                && Currency.unwrap(key.currency1) == (imdIsCurrency0 ? token : IMD) && key.fee == POOL_FEE
                && key.tickSpacing == tickSpacing && address(key.hooks) == address(this),
            "Wrong pool"
        );
    }

    function _checkPool(PoolKey calldata key) private view {
        require(initialized && keccak256(abi.encode(key)) == poolId, "Unknown pool");
    }

    function beforeInitialize(address, PoolKey calldata key, uint160) external view onlyManager returns (bytes4) {
        require(!initialized, "Already initialized");
        _validateKey(key);
        return IHooks.beforeInitialize.selector;
    }

    function afterInitialize(address, PoolKey calldata key, uint160, int24 tick) external onlyManager returns (bytes4) {
        require(!initialized, "Already initialized");
        _validateKey(key);
        initialized = true;
        poolKey = key;
        poolId = keccak256(abi.encode(key));
        observations[0] = Observation(uint64(block.timestamp), 0, tick);
        observationCount = 1;
        emit PoolRegistered(poolId);
        return IHooks.afterInitialize.selector;
    }

    /// @dev Positive specified delta takes IMD from exact-input buys or grosses up exact-output
    /// sells. When IMD is unspecified its ACTUAL pool delta is charged in afterSwap instead.
    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        onlyManager
        nonReentrant
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _checkPool(key);
        uint256 fee;
        if (_imdSpecified(params)) {
            uint256 specified = _absolute(params.amountSpecified);
            require(specified <= uint256(uint128(type(int128).max)), "Swap too large");
            fee = specified * feeBps / 10_000;
            require(specified + fee <= uint256(uint128(type(int128).max)), "Delta too large");
            _collectFee(fee);
        }
        return (IHooks.beforeSwap.selector, BeforeSwapDelta.wrap(int256(fee << 128)), 0);
    }

    function afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        onlyManager
        nonReentrant
        returns (bytes4, int128)
    {
        _checkPool(key);
        _recordTick(_spotTick());
        int128 imdDelta = _imdDelta(delta);
        if (_imdSpecified(params)) {
            uint256 specified = _absolute(params.amountSpecified);
            uint256 specifiedFee = specified * feeBps / 10_000;
            uint256 expected = params.amountSpecified < 0 ? specified - specifiedFee : specified + specifiedFee;
            // v4 cannot refund a specified delta from afterSwap. Reject partial fills so a
            // restrictive price limit or empty pool cannot charge fees on unexecuted volume.
            require(_absolute(int256(imdDelta)) == expected, "Partial IMD fill");
            return (IHooks.afterSwap.selector, 0);
        }
        uint256 fee = _absolute(int256(imdDelta)) * feeBps / 10_000;
        _collectFee(fee);
        return (IHooks.afterSwap.selector, int128(int256(fee)));
    }

    function _imdSpecified(SwapParams calldata params) private view returns (bool) {
        bool specifiedIsCurrency0 = (params.amountSpecified < 0) == params.zeroForOne;
        return specifiedIsCurrency0 == imdIsCurrency0;
    }

    function _imdDelta(BalanceDelta delta) private view returns (int128) {
        return imdIsCurrency0 ? int128(BalanceDelta.unwrap(delta) >> 128) : int128(BalanceDelta.unwrap(delta));
    }

    function _workDelta(BalanceDelta delta) private view returns (int128) {
        return imdIsCurrency0 ? int128(BalanceDelta.unwrap(delta)) : int128(BalanceDelta.unwrap(delta) >> 128);
    }

    function _absolute(int256 value) private pure returns (uint256) {
        require(value != type(int256).min, "Invalid amount");
        return uint256(value < 0 ? -value : value);
    }

    function _collectFee(uint256 amount) private {
        if (amount == 0) return;
        poolManager.take(Currency.wrap(IMD), address(this), amount);
        _distributeFee(amount);
    }

    function _distributeFee(uint256 amount) private {
        uint256 stakerPart;
        if (workers.mintEnded() && workers.totalWeight() != 0) {
            stakerPart = amount * stakerShareBps / 10_000;
        }
        if (stakerPart != 0) {
            IMD.send(address(workers), stakerPart);
            workers.notifyHookFees(stakerPart);
        }
        IMD.send(B, amount - stakerPart);
        emit FeeDistributed(amount, stakerPart, amount - stakerPart);
    }

    /// @dev v4 StateLibrary layout: pools mapping at slot 6, tick in slot0 bits 160..183.
    function _spotTick() private view returns (int24) {
        return int24(uint24(uint256(poolManager.extsload(keccak256(abi.encode(poolId, uint256(6))))) >> 160));
    }

    function _recordTick(int24 tick) private {
        Observation memory previous = observations[observationIndex];
        if (previous.timestamp == block.timestamp) {
            observations[observationIndex].tick = tick;
            return;
        }
        int96 cumulative =
            previous.cumulative + int96(previous.tick) * int96(uint96(block.timestamp - previous.timestamp));
        observationIndex = (observationIndex + 1) % OBSERVATION_CAPACITY;
        observations[observationIndex] = Observation(uint64(block.timestamp), cumulative, tick);
        if (observationCount < OBSERVATION_CAPACITY) observationCount++;
    }

    /// @notice Anyone can checkpoint an otherwise idle pool without changing its price.
    function pokeOracle() external {
        require(initialized, "Not initialized");
        _recordTick(_spotTick());
    }

    function _observationAt(uint256 logicalIndex) private view returns (Observation memory) {
        uint256 oldest = observationCount == OBSERVATION_CAPACITY ? (observationIndex + 1) % OBSERVATION_CAPACITY : 0;
        return observations[(oldest + logicalIndex) % OBSERVATION_CAPACITY];
    }

    function _cumulativeAt(uint256 timestamp) private view returns (int256) {
        Observation memory first = _observationAt(0);
        require(timestamp >= first.timestamp, "TWAP warming up");
        uint256 low;
        uint256 high = observationCount - 1;
        while (low < high) {
            uint256 mid = (low + high + 1) / 2;
            if (_observationAt(mid).timestamp <= timestamp) low = mid;
            else high = mid - 1;
        }
        Observation memory point = _observationAt(low);
        return int256(point.cumulative) + int256(point.tick) * int256(timestamp - point.timestamp);
    }

    function twapTick() public view returns (int24) {
        require(initialized && block.timestamp >= TWAP_WINDOW, "TWAP unavailable");
        int256 difference = _cumulativeAt(block.timestamp) - _cumulativeAt(block.timestamp - TWAP_WINDOW);
        int256 average = difference / int256(TWAP_WINDOW);
        if (difference < 0 && difference % int256(TWAP_WINDOW) != 0) average--;
        return int24(average);
    }

    /// @notice Quote in raw token units; both WORK and the specified IMD have 18 decimals.
    function quoteAtTick(int24 tick, uint256 imdAmount) public view returns (uint256) {
        uint160 sqrtPrice = WorkPriceMath.sqrtPriceAtTick(tick);
        if (sqrtPrice <= type(uint128).max) {
            uint256 ratioX192 = uint256(sqrtPrice) * sqrtPrice;
            return imdIsCurrency0
                ? WorkPriceMath.mulDiv(imdAmount, ratioX192, 1 << 192)
                : WorkPriceMath.mulDiv(imdAmount, 1 << 192, ratioX192);
        }
        uint256 ratio = WorkPriceMath.mulDiv(sqrtPrice, sqrtPrice, 1 << 64);
        return imdIsCurrency0
            ? WorkPriceMath.mulDiv(imdAmount, ratio, 1 << 128)
            : WorkPriceMath.mulDiv(imdAmount, 1 << 128, ratio);
    }

    function minimumBuybackOutput(uint256 amount) public view returns (uint256) {
        require(amount != 0 && amount <= workers.MAX_BUYBACK(), "Invalid buyback amount");
        uint256 input = amount - amount * feeBps / 10_000;
        uint256 quote = quoteAtTick(twapTick(), input);
        // Account for the LP fee, then tolerate at most 1% price impact relative to the TWAP.
        return WorkPriceMath.mulDiv(
            WorkPriceMath.mulDiv(quote, 1_000_000 - POOL_FEE, 1_000_000), 10_000 - BUYBACK_SLIPPAGE_BPS, 10_000
        );
    }

    function executeBuyback(uint256 amount) external nonReentrant returns (uint256 workOut) {
        require(msg.sender == address(workers) && initialized, "Only workers");
        uint256 minimum = minimumBuybackOutput(amount);
        require(minimum != 0, "Zero minimum output");
        require(IWorkToken(IMD).balanceOf(address(this)) >= amount, "Unfunded buyback");
        uint256 fee = amount * feeBps / 10_000;
        _buybackInput = amount - fee;
        _buybackMinimum = minimum;
        // PoolManager skips callbacks when the hook itself swaps. Charge the same buy fee and
        // update the oracle explicitly; no caller-controlled data can obtain this exemption.
        _distributeFee(fee);
        _recordTick(_spotTick());
        workOut = abi.decode(poolManager.unlock(""), (uint256));
        require(_buybackInput == 0, "Missing unlock callback");
        _buybackMinimum = 0;
        emit BuybackExecuted(amount, workOut, minimum);
    }

    function unlockCallback(bytes calldata) external onlyManager returns (bytes memory) {
        uint256 input = _buybackInput;
        require(_entered != 0 && input != 0, "Unexpected unlock");
        _buybackInput = 0;
        BalanceDelta delta = poolManager.swap(
            poolKey,
            SwapParams({
                zeroForOne: imdIsCurrency0,
                amountSpecified: -int256(input),
                sqrtPriceLimitX96: imdIsCurrency0 ? MIN_SQRT_PRICE + 1 : MAX_SQRT_PRICE - 1
            }),
            ""
        );
        int128 paid = _imdDelta(delta);
        int128 received = _workDelta(delta);
        require(paid == -int256(input) && received > 0, "Incomplete buyback");
        uint256 output = uint256(uint128(received));
        require(output >= _buybackMinimum, "TWAP minimum not met");
        poolManager.sync(Currency.wrap(IMD));
        IMD.send(address(poolManager), input);
        require(poolManager.settle() == input, "Bad settlement");
        poolManager.take(Currency.wrap(token), DEAD, output);
        _recordTick(_spotTick());
        return abi.encode(output);
    }

    function sweep(address asset) external nonReentrant returns (uint256 amount) {
        // All fee distributions and buybacks settle atomically. The guard prevents a sweep
        // during those operations; idle hook balances have no corresponding user liabilities.
        amount = IWorkToken(asset).balanceOf(address(this));
        asset.send(B, amount);
        emit Swept(asset, amount);
    }
}

library WorkPriceMath {
    /// @dev Computes sqrt(1.0001^tick) in Q96 by binary exponentiation in Q128.
    /// The base is floor(2^128 / sqrt(1.0001)); intermediate products stay below 2^256.
    function sqrtPriceAtTick(int24 tick) internal pure returns (uint160) {
        require(tick >= -887272 && tick <= 887272, "Tick out of range");
        uint256 n = uint256(tick < 0 ? -int256(tick) : int256(tick));
        uint256 ratio = 1 << 128;
        uint256 base = 0xfffcb933bd6fad37aa2d162d1a594001;
        while (n != 0) {
            if (n & 1 != 0) ratio = ratio * base >> 128;
            n >>= 1;
            if (n != 0) base = base * base >> 128;
        }
        if (tick > 0) ratio = type(uint256).max / ratio;
        return uint160((ratio >> 32) + (ratio & 0xffffffff == 0 ? 0 : 1));
    }

    /*
     * mulDiv is adapted from Uniswap v4 FullMath, credit Remco Bloemen, MIT license.
     * https://github.com/Uniswap/v4-core/blob/v4.0.0/src/libraries/FullMath.sol
     * Copyright (c) Uniswap Labs and Remco Bloemen.
     * Permission is hereby granted, free of charge, to any person obtaining a copy of this
     * software and associated documentation files (the "Software"), to deal in the Software
     * without restriction, including without limitation the rights to use, copy, modify,
     * merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
     * permit persons to whom the Software is furnished to do so, subject to the following
     * conditions: The above copyright notice and this permission notice shall be included
     * in all copies or substantial portions of the Software. THE SOFTWARE IS PROVIDED "AS
     * IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO
     * THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
     * NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR
     * ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
     * OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
     * OTHER DEALINGS IN THE SOFTWARE.
     */
    function mulDiv(uint256 a, uint256 b, uint256 denominator) internal pure returns (uint256 result) {
        unchecked {
            uint256 low = a * b;
            uint256 high;
            assembly ("memory-safe") {
                let mm := mulmod(a, b, not(0))
                high := sub(sub(mm, low), lt(mm, low))
            }
            require(denominator > high, "mulDiv overflow");
            if (high == 0) return low / denominator;
            assembly ("memory-safe") {
                let remainder := mulmod(a, b, denominator)
                high := sub(high, gt(remainder, low))
                low := sub(low, remainder)
            }
            uint256 twos = (0 - denominator) & denominator;
            assembly ("memory-safe") {
                denominator := div(denominator, twos)
                low := div(low, twos)
                twos := add(div(sub(0, twos), twos), 1)
            }
            low |= high * twos;
            uint256 inverse = (3 * denominator) ^ 2;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            result = low * inverse;
        }
    }
}

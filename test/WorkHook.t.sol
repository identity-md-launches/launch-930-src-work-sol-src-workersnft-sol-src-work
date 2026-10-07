// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Work} from "src/Work.sol";
import {WorkersNFT, IWorkToken} from "src/WorkersNFT.sol";
import {
    WorkHook,
    WorkPriceMath,
    IPoolManager,
    IHooks,
    Hooks,
    PoolKey,
    SwapParams,
    Currency,
    BalanceDelta,
    BeforeSwapDelta
} from "src/WorkHook.sol";
import {WorkTestBase} from "test/Work.t.sol";
import {WorkersFixture, TestIMD} from "test/WorkersNFT.t.sol";

// Offline v4 boundary model: packed signed deltas, positive hook fee deltas,
// slot-6 tick reads, unlock callbacks, sync/settle, and hook-initiated callback exemption.
// It models settlement, not concentrated-liquidity price discovery. A live fork remains owed.
contract TestPoolManager is IPoolManager {
    address public constant IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    WorkHook public hook;
    int24 public tick;
    uint256 public outputBps = 9900;
    uint256 public shortInput;
    bool public badSettlement;
    bool public omitCallback;
    bool public attemptReentry;
    bool public reentryBlocked;
    bool private unlocked;
    uint256 private syncedBalance;
    uint256 private owedInput;
    uint256 private owedOutput;
    uint256 public totalTakenIMD;

    function configure(WorkHook hook_) external {
        hook = hook_;
    }

    function setTick(int24 value) external {
        tick = value;
    }

    function faults(uint256 outBps, uint256 short_, bool bad, bool omit, bool reenter) external {
        outputBps = outBps;
        shortInput = short_;
        badSettlement = bad;
        omitCallback = omit;
        attemptReentry = reenter;
    }

    function initialize(PoolKey memory key, int24 initialTick) external {
        tick = initialTick;
        require(
            hook.beforeInitialize(msg.sender, key, uint160(1 << 96)) == IHooks.beforeInitialize.selector,
            "before init selector"
        );
        require(
            hook.afterInitialize(msg.sender, key, uint160(1 << 96), initialTick) == IHooks.afterInitialize.selector,
            "after init selector"
        );
    }

    function packed(int128 imdDelta, int128 workDelta) public view returns (BalanceDelta) {
        int128 a = hook.imdIsCurrency0() ? imdDelta : workDelta;
        int128 b = hook.imdIsCurrency0() ? workDelta : imdDelta;
        return BalanceDelta.wrap((int256(a) << 128) | int256(uint256(uint128(b))));
    }

    function trade(PoolKey memory key, SwapParams memory params, int128 imdDelta, int128 workDelta, bytes memory data)
        external
        returns (uint256 charged)
    {
        uint256 beforeTaken = totalTakenIMD;
        (bytes4 beforeSelector, BeforeSwapDelta beforeDelta, uint24 lpOverride) =
            hook.beforeSwap(msg.sender, key, params, data);
        require(beforeSelector == IHooks.beforeSwap.selector && lpOverride == 0, "before swap ABI");
        (bytes4 afterSelector, int128 afterDelta) =
            hook.afterSwap(msg.sender, key, params, packed(imdDelta, workDelta), data);
        require(afterSelector == IHooks.afterSwap.selector, "after swap ABI");
        require(int128(BeforeSwapDelta.unwrap(beforeDelta)) == 0, "unexpected unspecified delta");
        int128 specifiedFee = int128(BeforeSwapDelta.unwrap(beforeDelta) >> 128);
        require(specifiedFee >= 0 && afterDelta >= 0, "negative fee delta");
        charged = uint256(uint128(specifiedFee)) + uint256(uint128(afterDelta));
        require(totalTakenIMD - beforeTaken == charged, "unbalanced hook fee");
    }

    function extsload(bytes32 slot) external view returns (bytes32) {
        require(slot == keccak256(abi.encode(hook.poolId(), uint256(6))), "wrong v4 storage slot");
        return bytes32(uint256(uint24(tick)) << 160 | uint256(1 << 96));
    }

    function unlock(bytes calldata data) external returns (bytes memory result) {
        require(msg.sender == address(hook) && !unlocked, "bad unlock");
        if (omitCallback) return abi.encode(uint256(1));
        unlocked = true;
        result = hook.unlockCallback(data);
        require(owedInput == 0 && owedOutput == 0, "unsettled currencies");
        unlocked = false;
    }

    function swap(PoolKey calldata key, SwapParams calldata params, bytes calldata) external returns (BalanceDelta) {
        require(unlocked && msg.sender == address(hook), "locked");
        require(address(key.hooks) == msg.sender && params.amountSpecified < 0, "buyback direction");
        require(params.zeroForOne == hook.imdIsCurrency0(), "wrong currency direction");
        require(
            params.sqrtPriceLimitX96 == (params.zeroForOne ? hook.MIN_SQRT_PRICE() + 1 : hook.MAX_SQRT_PRICE() - 1),
            "price limit"
        );
        uint256 input = uint256(-params.amountSpecified) - shortInput;
        uint256 output = input * outputBps / 10_000;
        owedInput = input;
        owedOutput = output;
        return packed(-int128(int256(input)), int128(int256(output)));
    }

    function sync(Currency currency) external {
        require(unlocked && Currency.unwrap(currency) == IMD, "bad sync");
        syncedBalance = IWorkToken(IMD).balanceOf(address(this));
    }

    function settle() external payable returns (uint256 paid) {
        require(unlocked, "locked");
        paid = IWorkToken(IMD).balanceOf(address(this)) - syncedBalance;
        require(paid == owedInput, "wrong payment");
        owedInput = 0;
        if (badSettlement) return paid - 1;
    }

    function take(Currency currency, address to, uint256 amount) external {
        require(msg.sender == address(hook), "only hook");
        address asset = Currency.unwrap(currency);
        if (asset == IMD) {
            totalTakenIMD += amount;
        } else {
            require(unlocked && amount == owedOutput, "wrong output");
            owedOutput = 0;
        }
        if (attemptReentry) {
            (bool ok,) = address(hook).call(abi.encodeCall(hook.sweep, (asset)));
            require(!ok, "reentrant sweep succeeded");
            reentryBlocked = true;
        }
        require(IWorkToken(asset).transfer(to, amount), "transfer failed");
    }
}

abstract contract HookFixture is WorkersFixture {
    WorkHook internal hook;
    TestPoolManager internal manager;
    PoolKey internal key;

    function _deployHook(bool highToken) internal {
        _environment();
        // Exercise both currency orders with actual Work runtime and real constructor-created NFT.
        if (highToken) {
            address high = address(uint160(type(uint160).max - 100));
            vm.etch(high, address(work).code);
            work = Work(high);
        }
        manager = new TestPoolManager();
        bytes32 initHash = keccak256(
            abi.encodePacked(
                type(WorkHook).creationCode, abi.encode(IPoolManager(address(manager)), address(work), B, int24(60))
            )
        );
        uint256 salt;
        while (true) {
            address predicted = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(salt), initHash))))
            );
            if (uint160(predicted) & 0x3fff == 0x30cc) break;
            ++salt;
        }
        hook = new WorkHook{salt: bytes32(salt)}(IPoolManager(address(manager)), address(work), B, 60);
        manager.configure(hook);
        nft = hook.workers();
        _allow(ALICE);
        _allow(BOB);
        _allow(CAROL);
        key = PoolKey(
            Currency.wrap(hook.imdIsCurrency0() ? IMD : address(work)),
            Currency.wrap(hook.imdIsCurrency0() ? address(work) : IMD),
            12_500,
            60,
            IHooks(address(hook))
        );
        imd.mint(address(manager), 1e30);
    }

    function _initialize(int24 tick) internal {
        manager.initialize(key, tick);
    }

    function _params(bool specifiedIMD, bool exactInput, uint256 amount) internal view returns (SwapParams memory) {
        bool zeroForOne = exactInput == (specifiedIMD == hook.imdIsCurrency0());
        return SwapParams(zeroForOne, exactInput ? -int256(amount) : int256(amount), uint160(1 << 96));
    }

    function _trade(uint256 amount, bool specifiedIMD, bool exactInput, bytes memory data) internal returns (uint256) {
        uint256 fee = amount * hook.feeBps() / 10_000;
        uint256 poolIMD = specifiedIMD ? (exactInput ? amount - fee : amount + fee) : amount;
        bool imdInput = specifiedIMD == exactInput;
        return manager.trade(
            key,
            _params(specifiedIMD, exactInput, amount),
            imdInput ? -int128(int256(poolIMD)) : int128(int256(poolIMD)),
            imdInput ? int128(1 ether) : -int128(1 ether),
            data
        );
    }
}

/// forge-config: default.fuzz.runs = 1000
contract WorkHookTest is HookFixture {
    event FeeChanged(uint256 oldBps, uint256 newBps);
    event StakerShareChanged(uint256 oldBps, uint256 newBps);
    event FeeDistributed(uint256 total, uint256 stakers, uint256 beneficiary);

    function setUp() public {
        _deployHook(false);
    }

    function test_ConstructorDeploysWorkersAndExactPermissionBits() public view {
        eq(nft.work(), address(work));
        eq(nft.owner(), B);
        eq(nft.hook(), address(hook));
        eq(address(hook.poolManager()), address(manager));
        eq(hook.owner(), B);
        eq(uint160(address(hook)) & 0x3fff, hook.REQUIRED_HOOK_FLAGS());
        eq(hook.feeBps(), 75);
        eq(hook.stakerShareBps(), 10_000);
        Hooks.Permissions memory p = hook.getHookPermissions();
        yes(
            p.beforeInitialize && p.afterInitialize && p.beforeSwap && p.afterSwap && p.beforeSwapReturnDelta
                && p.afterSwapReturnDelta
        );
        yes(
            !p.beforeAddLiquidity && !p.afterAddLiquidity && !p.beforeRemoveLiquidity && !p.afterRemoveLiquidity
                && !p.beforeDonate && !p.afterDonate && !p.afterAddLiquidityReturnDelta
                && !p.afterRemoveLiquidityReturnDelta
        );
    }

    function test_InitializationAndCallbackAccessControl() public {
        vm.expectRevert(bytes("Only PoolManager"));
        hook.beforeInitialize(ALICE, key, uint160(1 << 96));
        vm.expectRevert(bytes("Only PoolManager"));
        hook.afterInitialize(ALICE, key, uint160(1 << 96), 0);
        vm.expectRevert(bytes("Only PoolManager"));
        hook.unlockCallback("");
        vm.expectRevert(bytes("Not initialized"));
        hook.pokeOracle();
        SwapParams memory params = _params(true, true, 1 ether);
        vm.expectRevert(bytes("Only PoolManager"));
        hook.beforeSwap(ALICE, key, params, "");
        vm.expectRevert(bytes("Only PoolManager"));
        hook.afterSwap(ALICE, key, params, BalanceDelta.wrap(0), "");
        vm.expectRevert(bytes("Unknown pool"));
        manager.trade(key, params, 0, 0, "");
        PoolKey memory bad = key;
        bad.fee = 3000;
        vm.expectRevert(bytes("Wrong pool"));
        manager.initialize(bad, 0);
        bad = key;
        bad.tickSpacing = 10;
        vm.expectRevert(bytes("Wrong pool"));
        manager.initialize(bad, 0);
        bad = key;
        bad.currency0 = Currency.wrap(ALICE);
        vm.expectRevert(bytes("Wrong pool"));
        manager.initialize(bad, 0);
        _initialize(0);
        eq(hook.poolId(), keccak256(abi.encode(key)));
        vm.expectRevert(bytes("Already initialized"));
        manager.initialize(key, 0);
        vm.expectRevert(bytes("Unexpected unlock"));
        vm.prank(address(manager));
        hook.unlockCallback("");
        vm.expectRevert(bytes("Only workers"));
        hook.executeBuyback(1 ether);
    }

    function test_OwnerBoundsAndEvents() public {
        vm.expectRevert(bytes("Only owner"));
        hook.setFeeBps(0);
        vm.expectRevert(bytes("Only owner"));
        hook.setStakerShareBps(9000);
        vm.expectEmit(false, false, false, true, address(hook));
        emit FeeChanged(75, 875);
        vm.prank(B);
        hook.setFeeBps(875);
        eq(hook.feeBps(), 875);
        vm.expectEmit(false, false, false, true, address(hook));
        emit StakerShareChanged(10_000, 9000);
        vm.prank(B);
        hook.setStakerShareBps(9000);
        eq(hook.stakerShareBps(), 9000);
        vm.expectRevert(bytes("Fee exceeds 8.75%"));
        vm.prank(B);
        hook.setFeeBps(876);
        vm.expectRevert(bytes("Share out of range"));
        vm.prank(B);
        hook.setStakerShareBps(8999);
        vm.expectRevert(bytes("Share out of range"));
        vm.prank(B);
        hook.setStakerShareBps(10_001);
        vm.prank(B);
        hook.setFeeBps(0);
        _initialize(0);
        eq(_trade(1 ether, true, true, ""), 0);
    }

    function testFuzz_FeesAllSwapDirections(uint256 raw, uint256 bps, bool specifiedIMD, bool exactInput) public {
        uint256 amount = bound(raw, 1, 1e26);
        bps = bound(bps, 0, 875);
        vm.prank(B);
        hook.setFeeBps(bps);
        _initialize(0);
        uint256 fee = amount * bps / 10_000;
        uint256 before = imd.balanceOf(B);
        eq(_trade(amount, specifiedIMD, exactInput, abi.encode(address(hook), true)), fee);
        eq(imd.balanceOf(B) - before, fee);
        eq(imd.balanceOf(address(hook)), 0);
        eq(nft.stakerReserve(), 0);
    }

    function testFuzz_PostMintHookSplit(uint256 raw, uint256 share) public {
        uint256 amount = bound(raw, 1, 1e26);
        share = bound(share, 9000, 10_000);
        uint256 id = _mint(ALICE);
        _stake(ALICE, id, 7);
        _initialize(0);
        uint256 before = imd.balanceOf(B);
        uint256 fee = amount * 75 / 10_000;
        _trade(amount, true, true, "");
        eq(imd.balanceOf(B) - before, fee);
        eq(nft.stakerReserve(), 0);
        _end();
        vm.prank(B);
        hook.setStakerShareBps(share);
        before = imd.balanceOf(B);
        uint256 reward = fee * share / 10_000;
        if (fee != 0) {
            vm.expectEmit(false, false, false, true, address(hook));
            emit FeeDistributed(fee, reward, fee - reward);
        }
        _trade(amount, false, true, "");
        eq(nft.stakerReserve(), reward);
        eq(imd.balanceOf(B) - before, fee - reward);
        vm.prank(ALICE);
        eq(nft.claimIMD(), reward);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vm.prank(ALICE);
        nft.unstake(id);
        before = imd.balanceOf(B);
        _trade(amount, true, false, "");
        eq(imd.balanceOf(B) - before, fee);
    }

    function test_PartialSpecifiedFillRevertsAtomicallyAndUnspecifiedChargesActual() public {
        _initialize(0);
        uint256 before = imd.balanceOf(B);
        SwapParams memory params = _params(true, true, 1 ether);
        vm.expectRevert(bytes("Partial IMD fill"));
        manager.trade(key, params, -0.5 ether, 1 ether, "");
        eq(imd.balanceOf(B), before);
        eq(manager.totalTakenIMD(), 0);
        params = _params(false, true, 10 ether);
        eq(manager.trade(key, params, 0.5 ether, -10 ether, ""), 0.00375 ether);
    }

    function test_InvalidIntAmountsAndForeignPoolRevert() public {
        _initialize(0);
        SwapParams memory params = _params(true, true, 1);
        params.amountSpecified = type(int256).min;
        vm.expectRevert(bytes("Invalid amount"));
        manager.trade(key, params, 0, 0, "");
        params.amountSpecified = -int256(uint256(uint128(type(int128).max)) + 1);
        vm.expectRevert(bytes("Swap too large"));
        manager.trade(key, params, 0, 0, "");
        params.amountSpecified = -int256(type(int128).max);
        vm.expectRevert(bytes("Delta too large"));
        manager.trade(key, params, 0, 0, "");
        params = _params(true, true, 1);
        PoolKey memory bad = key;
        bad.fee = 1;
        vm.expectRevert(bytes("Unknown pool"));
        manager.trade(bad, params, 0, 0, "");
    }

    function test_TwapWarmupWeightedTicksNegativeRoundingAndSameSecond() public {
        _initialize(100);
        uint256 start = vm.getBlockTimestamp();
        vm.expectRevert(bytes("TWAP warming up"));
        hook.twapTick();
        vm.warp(start + 900);
        manager.setTick(-101);
        hook.pokeOracle();
        uint256 count = hook.observationCount();
        manager.setTick(-100);
        hook.pokeOracle();
        eq(hook.observationCount(), count);
        vm.warp(start + 1800);
        require(hook.twapTick() == 0, "weighted tick");
        vm.warp(start + 1801);
        require(hook.twapTick() == -1, "negative rounds down");
        // A spot jump does not rewrite the elapsed price history.
        manager.setTick(5000);
        hook.pokeOracle();
        require(hook.twapTick() == -1, "spot manipulation");
    }

    function test_OracleRingWrapKeepsThirtyMinutes() public {
        _initialize(12);
        uint256 start = vm.getBlockTimestamp();
        for (uint256 i = 1; i <= 2050; ++i) {
            vm.warp(start + i);
            hook.pokeOracle();
        }
        eq(hook.observationCount(), 2048);
        eq(hook.observationIndex(), 2);
        require(hook.twapTick() == 12, "ring history");
    }

    function testFuzz_QuoteAndMinimumAtParity(uint256 raw, uint256 bps) public {
        uint256 amount = bound(raw, 1, 100 ether);
        bps = bound(bps, 0, 875);
        vm.prank(B);
        hook.setFeeBps(bps);
        _initialize(0);
        vm.warp(vm.getBlockTimestamp() + 1800);
        eq(hook.quoteAtTick(0, amount), amount);
        uint256 net = amount - amount * bps / 10_000;
        eq(hook.minimumBuybackOutput(amount), (net * 987500 / 1_000_000) * 9900 / 10_000);
        vm.expectRevert(bytes("Invalid buyback amount"));
        hook.minimumBuybackOutput(0);
        vm.expectRevert(bytes("Invalid buyback amount"));
        hook.minimumBuybackOutput(100 ether + 1);
    }

    function test_BuybackSettlesAndBurnsWorkWithFeesAndReentryProtection() public {
        uint256 id = _mint(ALICE);
        _stake(ALICE, id, 7);
        _end();
        _initialize(0);
        vm.prank(B);
        work.transfer(address(manager), 100 ether);
        vm.warp(vm.getBlockTimestamp() + 1800);
        uint256 amount = nft.buybackBalance();
        uint256 fee = amount * 75 / 10_000;
        uint256 expected = (amount - fee) * 9900 / 10_000;
        uint256 before = imd.balanceOf(address(manager));
        manager.faults(9900, 0, false, false, true);
        eq(nft.buyback(amount), expected);
        eq(work.balanceOf(hook.DEAD()), expected);
        eq(nft.buybackBalance(), 0);
        eq(imd.balanceOf(address(manager)) - before, amount - fee);
        eq(nft.stakerReserve(), fee);
        eq(imd.balanceOf(address(hook)), 0);
        eq(work.balanceOf(address(hook)), 0);
        yes(manager.reentryBlocked());
    }

    function test_BuybackSlippagePartialAndMissingSettlementRollback() public {
        _mint(ALICE);
        _initialize(0);
        vm.prank(B);
        work.transfer(address(manager), 100 ether);
        uint256 amount = nft.buybackBalance();
        vm.expectRevert(bytes("TWAP warming up"));
        nft.buyback(amount);
        vm.warp(vm.getBlockTimestamp() + 1800);
        uint256 bBefore = imd.balanceOf(B);
        manager.faults(1, 0, false, false, false);
        vm.expectRevert(bytes("TWAP minimum not met"));
        nft.buyback(amount);
        manager.faults(9900, 1, false, false, false);
        vm.expectRevert(bytes("Incomplete buyback"));
        nft.buyback(amount);
        manager.faults(9900, 0, true, false, false);
        vm.expectRevert(bytes("Bad settlement"));
        nft.buyback(amount);
        manager.faults(9900, 0, false, true, false);
        vm.expectRevert(bytes("Missing unlock callback"));
        nft.buyback(amount);
        eq(nft.buybackBalance(), amount);
        yes(!nft.hasBoughtBack());
        eq(imd.balanceOf(B), bBefore);
        eq(imd.balanceOf(address(hook)), 0);
    }

    function test_FeeTransferFailureRollsBackAndReentrantSweepIsRejected() public {
        _initialize(0);
        SwapParams memory params = _params(true, true, 1 ether);
        imd.configure(0, false, true, false);
        vm.expectRevert(bytes("transfer failed"));
        manager.trade(key, params, -0.9925 ether, 1 ether, "");
        eq(manager.totalTakenIMD(), 0);
        eq(imd.balanceOf(B), 0);
        imd.configure(0, false, false, false);
        manager.faults(9900, 0, false, false, true);
        eq(_trade(1 ether, true, true, ""), 0.0075 ether);
        yes(manager.reentryBlocked());
        eq(imd.balanceOf(B), 0.0075 ether);
        eq(imd.balanceOf(address(hook)), 0);
    }

    function test_HookStraysGoOnlyToB() public {
        imd.mint(address(hook), 123);
        vm.prank(B);
        work.transfer(address(hook), 456);
        uint256 before = work.balanceOf(B);
        vm.prank(ALICE);
        eq(hook.sweep(IMD), 123);
        eq(imd.balanceOf(B), 123);
        vm.prank(ALICE);
        eq(hook.sweep(address(work)), 456);
        eq(work.balanceOf(B), before + 456);
    }
}

/// forge-config: default.fuzz.runs = 1000
contract WorkHookReverseOrderTest is HookFixture {
    function setUp() public {
        _deployHook(true);
        _initialize(0);
    }

    function testFuzz_ReverseCurrencyOrdering(uint256 raw, bool specified, bool input) public {
        yes(hook.imdIsCurrency0());
        uint256 amount = bound(raw, 1, 1e25);
        uint256 fee = amount * 75 / 10_000;
        eq(_trade(amount, specified, input, ""), fee);
        eq(imd.balanceOf(B), fee);
        eq(hook.quoteAtTick(0, amount), amount);
        yes(hook.quoteAtTick(100, amount) >= amount);
        yes(hook.quoteAtTick(-100, amount) <= amount);
    }
}

/// forge-config: default.fuzz.runs = 1000
contract WorkPriceMathTest is WorkTestBase {
    function test_TickKnownVectorsAndBounds() public {
        eq(WorkPriceMath.sqrtPriceAtTick(0), 79228162514264337593543950336);
        eq(WorkPriceMath.sqrtPriceAtTick(-1), 79224201403219477170569942574);
        eq(WorkPriceMath.sqrtPriceAtTick(1), 79232123823359799118286999568);
        eq(WorkPriceMath.sqrtPriceAtTick(-887272), 4295128739);
        vm.expectRevert(bytes("Tick out of range"));
        this.sqrt(887273);
        vm.expectRevert(bytes("Tick out of range"));
        this.sqrt(-887273);
    }

    function sqrt(int24 tick) external pure returns (uint160) {
        return WorkPriceMath.sqrtPriceAtTick(tick);
    }

    function divide(uint256 a, uint256 b, uint256 denominator) external pure returns (uint256) {
        return WorkPriceMath.mulDiv(a, b, denominator);
    }

    function testFuzz_MulDivAgainstNonOverflowingProduct(uint128 a, uint128 b, uint128 d) public pure {
        uint256 denominator = d == 0 ? 1 : d;
        eq(WorkPriceMath.mulDiv(a, b, denominator), uint256(a) * b / denominator);
    }

    function test_FullWidthProductAndOverflow() public {
        eq(WorkPriceMath.mulDiv(type(uint256).max, type(uint256).max, type(uint256).max), type(uint256).max);
        eq(WorkPriceMath.mulDiv(1 << 200, 1 << 100, 1 << 100), 1 << 200);
        vm.expectRevert(bytes("mulDiv overflow"));
        this.divide(type(uint256).max, 2, 1);
        vm.expectRevert(bytes("mulDiv overflow"));
        this.divide(1, 1, 0);
    }

    function testFuzz_PricesMonotonicAcrossTickRange(int24 raw) public pure {
        int24 tick = int24(int256(bound(uint256(int256(raw) + 8388608), 0, 1774543)) - 887272);
        yes(WorkPriceMath.sqrtPriceAtTick(tick + 1) > WorkPriceMath.sqrtPriceAtTick(tick));
    }
}

contract WorkHookHandler is HookFixture {
    uint256 public totalFees;
    uint256 public beneficiaryFees;
    uint256 public stakerFees;
    uint256 public claimed;
    uint256 public spent;
    uint256 public burnedWork;
    uint256 public swept;
    uint256 public initialBeneficiary;
    uint256 public initialBuyback;
    uint256 public workerId;
    bool public ended;

    constructor() {
        _deployHook(false);
        workerId = _mint(ALICE);
        _stake(ALICE, workerId, 7);
        _initialize(0);
        vm.prank(B);
        work.transfer(address(manager), 1000 ether);
        initialBeneficiary = imd.balanceOf(B);
        initialBuyback = nft.buybackBalance();
    }

    function contractsUnderTest() external view returns (WorkHook, WorkersNFT, Work) {
        return (hook, nft, work);
    }

    function trade(uint256 raw, bool specified, bool input) external {
        uint256 amount = bound(raw, 1, 1e23);
        uint256 fee = amount * hook.feeBps() / 10_000;
        _account(fee);
        eq(_trade(amount, specified, input, abi.encode(raw)), fee);
    }

    function _account(uint256 fee) private {
        uint256 reward = nft.mintEnded() && nft.totalWeight() != 0 ? fee * hook.stakerShareBps() / 10_000 : 0;
        totalFees += fee;
        stakerFees += reward;
        beneficiaryFees += fee - reward;
    }

    function ownerParameters(uint256 bps, uint256 share) external {
        vm.startPrank(B);
        hook.setFeeBps(bound(bps, 0, 875));
        hook.setStakerShareBps(bound(share, 9000, 10_000));
        vm.stopPrank();
    }

    function endMint() external {
        if (!ended) {
            vm.prank(B);
            nft.endMint();
            ended = true;
        }
    }

    function timeAndOracle(uint256 elapsed) external {
        vm.warp(vm.getBlockTimestamp() + bound(elapsed, 0, 14 days));
        hook.pokeOracle();
    }

    function stakeOrUnstake() external {
        if (nft.ownerOf(workerId) == ALICE) {
            vm.prank(ALICE);
            nft.stake(workerId, 7);
        } else {
            (, uint64 unlock,) = nft.stakes(workerId);
            if (vm.getBlockTimestamp() >= unlock) {
                vm.prank(ALICE);
                nft.unstake(workerId);
            }
        }
    }

    function claim() external {
        vm.prank(ALICE);
        claimed += nft.claimIMD();
    }

    function buyback(uint256 raw) external {
        (uint64 first,,) = hook.observations(0);
        uint256 available = nft.buybackBalance();
        if (
            available == 0 || vm.getBlockTimestamp() < first + 1800
                || (nft.hasBoughtBack() && vm.getBlockTimestamp() < nft.lastBuyback() + 60)
        ) return;
        // At parity at least 100 wei avoids a rounded-to-zero TWAP minimum.
        if (available < 100) return;
        uint256 amount = bound(raw, 100, available);
        _account(amount * hook.feeBps() / 10_000);
        spent += amount;
        burnedWork += nft.buyback(amount);
    }

    function donateAndSweep(uint256 raw) external {
        uint256 amount = bound(raw, 0, 1e20);
        imd.mint(address(hook), amount);
        eq(hook.sweep(IMD), amount);
        swept += amount;
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 50
/// forge-config: default.invariant.fail-on-revert = true
contract WorkHookInvariantTest is WorkTestBase {
    WorkHookHandler internal handler;
    WorkHook internal hook;
    WorkersNFT internal nft;
    Work internal work;

    function setUp() public {
        handler = new WorkHookHandler();
        (hook, nft, work) = handler.contractsUnderTest();
    }

    function targetContracts() external view returns (address[] memory targets) {
        targets = new address[](1);
        targets[0] = address(handler);
    }

    function invariant_FeesSettleWithoutStrandingOrSpendingReserves() public view {
        eq(TestIMD(IMD).balanceOf(address(hook)), 0);
        eq(work.balanceOf(address(hook)), 0);
        eq(handler.totalFees(), handler.beneficiaryFees() + handler.stakerFees());
        eq(TestIMD(IMD).balanceOf(B), handler.initialBeneficiary() + handler.beneficiaryFees() + handler.swept());
        eq(nft.stakerReserve() + handler.claimed(), handler.stakerFees());
        eq(nft.buybackBalance() + handler.spent(), handler.initialBuyback());
        eq(TestIMD(IMD).balanceOf(address(nft)), nft.stakerReserve() + nft.buybackBalance());
        eq(work.balanceOf(hook.DEAD()), handler.burnedWork());
        yes(nft.pendingIMD(ALICE) <= nft.stakerReserve());
        yes(hook.feeBps() <= 875 && hook.stakerShareBps() >= 9000 && hook.stakerShareBps() <= 10_000);
        if (handler.ended()) yes(nft.mintEnded());
    }
}

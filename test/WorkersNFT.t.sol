// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Work} from "src/Work.sol";
import {WorkersNFT, IWorkersReceiver} from "src/WorkersNFT.sol";
import {WorkTestBase} from "test/Work.t.sol";

// IMD stand-in includes transfer failure, taxed receipts, and no-return ERC20 modes.
contract TestIMD {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public taxBps;
    bool public stopped;
    bool public falseReturn;
    bool public noReturn;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function configure(uint256 tax, bool stop, bool badReturn, bool emptyReturn) external {
        taxBps = tax;
        stopped = stop;
        falseReturn = badReturn;
        noReturn = emptyReturn;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        return _move(msg.sender, to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (allowance[from][msg.sender] != type(uint256).max) allowance[from][msg.sender] -= amount;
        return _move(from, to, amount);
    }

    function _move(address from, address to, uint256 amount) private returns (bool) {
        require(!stopped, "IMD paused");
        if (falseReturn) return false;
        balanceOf[from] -= amount;
        balanceOf[to] += amount - amount * taxBps / 10_000;
        if (noReturn) {
            assembly { return(0, 0) }
        }
        return true;
    }
}

contract TestArbSys {
    uint256 public number;
    bool public missing;

    function setNumber(uint256 n) external {
        number = n;
    }

    function setMissing(bool value) external {
        missing = value;
    }

    function arbBlockNumber() external view returns (uint256) {
        return number;
    }

    function arbBlockHash(uint256 n) external view returns (bytes32) {
        require(n < number && number - n <= 256, "ArbSys range");
        return missing ? bytes32(0) : keccak256(abi.encode("Nitro block", n));
    }
}

contract TestBuyback {
    bool public fail;
    uint256 public received;

    function setFail(bool value) external {
        fail = value;
    }

    function executeBuyback(uint256 amount) external returns (uint256) {
        require(!fail, "Swap failed");
        received += amount;
        return amount * 2;
    }
}

abstract contract WorkersFixture is WorkTestBase {
    Work internal work;
    WorkersNFT internal nft;
    TestIMD internal imd;
    TestArbSys internal arb;
    TestBuyback internal buybackHook;

    function _environment() internal {
        vm.chainId(4663);
        vm.warp(1_000_000);
        vm.roll(100);
        vm.etch(IMD, type(TestIMD).runtimeCode);
        imd = TestIMD(IMD);
        vm.etch(address(0x64), type(TestArbSys).runtimeCode);
        arb = TestArbSys(address(0x64));
        _setL2(1000);
        vm.prank(B);
        work = new Work();
    }

    function _deployNFT() internal {
        _environment();
        buybackHook = new TestBuyback();
        nft = new WorkersNFT(address(work), B, address(buybackHook));
        _allow(ALICE);
        _allow(BOB);
        _allow(CAROL);
    }

    function _setL2(uint256 number) internal {
        arb.setNumber(number);
        // Foundry implements ArbSys calls specially; explicit mocks keep L2 distinct from L1.
        vm.mockCall(address(0x64), abi.encodeWithSignature("arbBlockNumber()"), abi.encode(number));
    }

    function _allow(address actor) internal {
        imd.mint(actor, 1_000_000 ether);
        vm.prank(actor);
        imd.approve(address(nft), type(uint256).max);
    }

    function _solve(address miner, uint256 anchor, uint256 start, bool oc)
        internal
        view
        returns (uint256 nonce, bytes32 hash)
    {
        bytes32 challenge = keccak256(abi.encode(nft.anchorHash(anchor), nft.prevWork()));
        uint256 target = nft.currentTarget();
        if (oc) target >>= 4;
        bytes32 domain = nft.DOMAIN();
        nonce = start;
        while (true) {
            hash = keccak256(abi.encode(domain, uint256(4663), address(nft), challenge, miner, nonce));
            if (uint256(hash) < target) return (nonce, hash);
            unchecked {
                ++nonce;
            }
        }
    }

    function _mint(address miner) internal returns (uint256 id) {
        return _mintSeed(miner, 0);
    }

    function _mintSeed(address miner, uint256 seed) internal returns (uint256 id) {
        _setL2(arb.number() + 1);
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 10);
        uint256 anchor = arb.number() - 1;
        (uint256 nonce,) = _solve(miner, anchor, seed, false);
        vm.prank(miner);
        id = nft.mint(anchor, nonce);
    }

    function _fund() internal {
        vm.startPrank(B);
        work.approve(address(nft), 150_000_000 ether);
        nft.fundPools();
        vm.stopPrank();
    }

    function _end() internal {
        vm.prank(B);
        nft.endMint();
    }

    function _stake(address actor, uint256 id, uint256 days_) internal {
        vm.prank(actor);
        nft.stake(id, days_);
    }
}

/// forge-config: default.fuzz.runs = 1000
contract WorkersNFTTest is WorkersFixture {
    event CapChanged(uint256 oldCap, uint256 newCap);
    event PriceScaleChanged(uint256 oldBps, uint256 newBps);
    event FloorChanged(int256 oldAdjustment, int256 newAdjustment);
    event ActivationFeeChanged(uint256 oldFee, uint256 newFee);
    event RoyaltyChanged(uint256 oldBps, uint256 newBps);
    event BaseURIChanged(string uri);
    event BatchMetadataUpdate(uint256 fromTokenId, uint256 toTokenId);
    event MetadataUpdate(uint256 tokenId);

    function setUp() public {
        _deployNFT();
    }

    function testFuzz_WorkHashDomainAndThreshold(address miner, uint256 nonce, uint256 age) public {
        age = bound(age, 1, 250);
        uint256 anchor = arb.number() - age;
        bytes32 expected = keccak256(
            abi.encode(
                nft.DOMAIN(),
                uint256(4663),
                address(nft),
                keccak256(abi.encode(nft.anchorHash(anchor), nft.prevWork())),
                miner,
                nonce
            )
        );
        eq(nft.workHash(miner, anchor, nonce), expected);
        yes(nft.checkWork(miner, anchor, nonce) == (uint256(expected) < nft.currentTarget()));
        vm.chainId(4664);
        yes(nft.workHash(miner, anchor, nonce) != expected);
    }

    function test_WorkRejectsBadNonceStaleMissingAndFutureAnchors() public {
        uint256 anchor = arb.number() - 1;
        uint256 nonce;
        while (nft.checkWork(ALICE, anchor, nonce)) ++nonce;
        vm.expectRevert(bytes("Insufficient work"));
        vm.prank(ALICE);
        nft.mint(anchor, nonce);
        uint256 current = arb.number();
        vm.expectRevert(bytes("Stale anchor"));
        nft.anchorHash(current - 251);
        vm.expectRevert(bytes("Stale anchor"));
        nft.anchorHash(current);
        vm.expectRevert(bytes("Stale anchor"));
        nft.anchorHash(current + 1);
        arb.setMissing(true);
        vm.expectRevert(bytes("Missing anchor"));
        nft.anchorHash(anchor);
        eq(nft.minted(), 0);
        eq(nft.buybackBalance(), 0);
    }

    function test_L2BlockLimitAndProofCannotBeReplayedOrStolen() public {
        uint256 anchor = arb.number() - 1;
        (uint256 nonce, bytes32 hash) = _solve(ALICE, anchor, 0, false);
        // Find a solution that is not also, by coincidence, a solution for Bob.
        while (nft.checkWork(BOB, anchor, nonce)) (nonce, hash) = _solve(ALICE, anchor, nonce + 1, false);
        vm.expectRevert(bytes("Insufficient work"));
        vm.prank(BOB);
        nft.mint(anchor, nonce);
        vm.prank(ALICE);
        nft.mint(anchor, nonce);
        eq(nft.prevWork(), hash);
        vm.roll(vm.getBlockNumber() + 1); // L1 block movement alone must not permit minting.
        vm.expectRevert(bytes("One mint per L2 block"));
        vm.prank(BOB);
        nft.mint(anchor, nonce);
        _setL2(arb.number() + 1);
        yes(nft.workHash(ALICE, anchor, nonce) != hash);
        (uint256 next,) = _solve(BOB, anchor, 0, false);
        vm.prank(BOB);
        nft.mint(anchor, next);
        eq(nft.minted(), 2);
    }

    function testFuzz_IdPickingUsesWholeRemainingPool(uint256 seed) public {
        vm.prank(B);
        nft.setCap(4);
        uint256[4] memory picked;
        for (uint256 i; i < 4; ++i) {
            _setL2(arb.number() + 1);
            vm.warp(vm.getBlockTimestamp() + 10);
            uint256 anchor = arb.number() - 1;
            (uint256 nonce, bytes32 hash) = _solve(ALICE, anchor, seed, false);
            uint256 remaining = 3333 - i;
            uint256 index = uint256(hash) % remaining;
            uint256 expected = nft.pool(index);
            uint256 last = nft.pool(remaining - 1);
            vm.prank(ALICE);
            uint256 id = nft.mint(anchor, nonce);
            eq(id, expected);
            yes(id >= 1 && id <= 3333);
            for (uint256 j; j < i; ++j) {
                yes(id != picked[j]);
            }
            picked[i] = id;
            if (index < remaining - 1) eq(nft.pool(index), last);
            eq(nft.overclocked(id) ? 1 : 0, uint256(hash) < (nft.currentTarget() >> 4) ? 1 : 0);
        }
        yes(nft.mintEnded());
        eq(nft.mintEndSupply(), 4);
        vm.expectRevert(bytes("Pool index out of range"));
        nft.pool(3333 - 4);
        uint256 staleAnchor = arb.number() - 1;
        vm.expectRevert(bytes("Mint unavailable"));
        vm.prank(ALICE);
        nft.mint(staleAnchor, 0);
    }

    function test_MetadataOverclockAndUpdates() public {
        uint256 anchor = arb.number() - 1;
        (uint256 nonce,) = _solve(ALICE, anchor, 0, true);
        vm.prank(ALICE);
        uint256 id = nft.mint(anchor, nonce);
        yes(nft.overclocked(id));
        eq(nft.tokenURI(id), string.concat(nft.baseURI(), "oc/", vm.toString(id), ".json"));
        uint256 normal = _mint(BOB);
        eq(
            nft.tokenURI(normal),
            string.concat(nft.baseURI(), nft.overclocked(normal) ? "oc/" : "", vm.toString(normal), ".json")
        );
        vm.expectEmit(false, false, false, true, address(nft));
        emit BaseURIChanged("ipfs://new/");
        vm.expectEmit(false, false, false, true, address(nft));
        emit BatchMetadataUpdate(1, 3333);
        vm.prank(B);
        nft.setBaseURI("ipfs://new/");
        eq(nft.tokenURI(id), string.concat("ipfs://new/oc/", vm.toString(id), ".json"));
        yes(nft.supportsInterface(0x49064906) && nft.supportsInterface(0x2a55205a));
        yes(!nft.supportsInterface(0xffffffff));
        vm.expectRevert(bytes("Unknown worker"));
        nft.tokenURI(0);
    }

    function testFuzz_RetargetEightMintsAndIdleRecovery(uint256 rawElapsed) public {
        uint256 elapsed = bound(rawElapsed, 0, 1000);
        uint256 start = vm.getBlockTimestamp();
        uint256 initial = nft.currentTarget();
        for (uint256 i; i < 8; ++i) {
            vm.warp(start + elapsed * (i + 1) / 8);
            _setL2(arb.number() + 1);
            uint256 anchor = arb.number() - 1;
            (uint256 nonce,) = _solve(ALICE, anchor, 0, false);
            vm.prank(ALICE);
            nft.mint(anchor, nonce);
            if (i < 7) eq(nft.difficultyTarget(), initial);
        }
        uint256 boundedElapsed = elapsed < 20 ? 20 : (elapsed > 320 ? 320 : elapsed);
        uint256 expected = initial / 80 * boundedElapsed + (initial % 80) * boundedElapsed / 80;
        if (expected > initial) expected = initial;
        eq(nft.difficultyTarget(), expected);
        vm.warp(vm.getBlockTimestamp() + 299);
        eq(nft.currentTarget(), expected);
        vm.warp(vm.getBlockTimestamp() + 1);
        eq(nft.currentTarget(), expected > initial / 2 ? initial : expected * 2);
        vm.warp(vm.getBlockTimestamp() + 300 * 256);
        eq(nft.currentTarget(), initial);
    }

    function testFuzz_MintSplitConservesIMD(uint256 scale, uint256 lockChoice) public {
        scale = bound(scale, 5000, 10_000);
        vm.prank(B);
        nft.setPriceScaleBps(scale);
        uint256 price = nft.mintPrice();
        uint256 bBefore = imd.balanceOf(B);
        uint256 id = _mint(ALICE);
        eq(nft.buybackBalance(), price - price / 10);
        eq(nft.stakerReserve(), 0);
        uint256[3] memory locks = [uint256(7), 14, 30];
        _stake(ALICE, id, locks[lockChoice % 3]);
        uint256 before = imd.balanceOf(BOB);
        _mint(BOB);
        eq(before - imd.balanceOf(BOB), price);
        eq(imd.balanceOf(B) - bBefore, 2 * (price / 10));
        eq(nft.stakerReserve(), price * 65 / 100);
        eq(imd.balanceOf(address(nft)), nft.stakerReserve() + nft.buybackBalance());
        vm.prank(ALICE);
        uint256 paid = nft.claimIMD();
        yes(paid <= price * 65 / 100);
        yes(price * 65 / 100 - paid <= 1);
    }

    function test_PaymentFailuresRollBackProofPoolAndBalances() public {
        uint256 anchor = arb.number() - 1;
        (uint256 nonce, bytes32 hash) = _solve(ALICE, anchor, 0, false);
        uint256 index = uint256(hash) % 3333;
        uint256 expectedId = nft.pool(index);
        for (uint256 mode; mode < 3; ++mode) {
            imd.configure(mode == 0 ? 100 : 0, mode == 1, mode == 2, false);
            vm.expectRevert();
            vm.prank(ALICE);
            nft.mint(anchor, nonce);
            eq(nft.minted(), 0);
            eq(nft.pool(index), expectedId);
            eq(nft.prevWork(), bytes32(0));
            eq(nft.buybackBalance(), 0);
            eq(imd.balanceOf(address(nft)), 0);
        }
        imd.configure(0, false, false, true);
        vm.prank(ALICE);
        eq(nft.mint(anchor, nonce), expectedId);
    }

    function testFuzz_WeightedClaimsConserveReserve(uint256 raw) public {
        uint256 a = _mint(ALICE);
        uint256 b = _mint(BOB);
        _end();
        _stake(ALICE, a, 7);
        _stake(BOB, b, 30);
        uint256 amount = bound(raw, 5, 1e27);
        imd.mint(address(nft), amount);
        vm.prank(address(buybackHook));
        nft.notifyHookFees(amount);
        uint256 dueA = nft.pendingIMD(ALICE);
        uint256 dueB = nft.pendingIMD(BOB);
        yes(dueA + dueB <= amount);
        yes(amount - dueA - dueB <= 1);
        yes(dueB >= 4 * dueA && dueB <= 4 * dueA + 3);
        vm.prank(BOB);
        eq(nft.claimIMD(), dueB);
        vm.prank(ALICE);
        eq(nft.claimIMD(), dueA);
        vm.prank(ALICE);
        eq(nft.claimIMD(), 0);
        eq(imd.balanceOf(address(nft)), nft.stakerReserve() + nft.buybackBalance());
    }

    function test_LateStakeCannotClaimPriorFeesAndUnstakeKeepsCredit() public {
        uint256 a = _mint(ALICE);
        uint256 b = _mint(BOB);
        _end();
        _stake(ALICE, a, 7);
        imd.mint(address(nft), 10 ether);
        vm.prank(address(buybackHook));
        nft.notifyHookFees(10 ether);
        _stake(BOB, b, 30);
        eq(nft.pendingIMD(BOB), 0);
        eq(nft.pendingIMD(ALICE), 10 ether);
        imd.mint(address(nft), 5 ether);
        vm.prank(address(buybackHook));
        nft.notifyHookFees(5 ether);
        eq(nft.pendingIMD(ALICE), 11 ether);
        eq(nft.pendingIMD(BOB), 4 ether);
        vm.warp(vm.getBlockTimestamp() + 30 days);
        vm.prank(ALICE);
        nft.unstake(a);
        vm.prank(BOB);
        nft.unstake(b);
        eq(nft.totalWeight(), 0);
        vm.prank(BOB);
        eq(nft.claimIMD(), 4 ether);
        vm.prank(ALICE);
        eq(nft.claimIMD(), 11 ether);
        eq(nft.stakerReserve(), 0);
    }

    function test_EscrowClearsApprovalsAndExitNeedsNoReceiverOrIMDTransfer() public {
        uint256 id = _mint(ALICE);
        vm.prank(ALICE);
        nft.approve(BOB, id);
        _stake(ALICE, id, 7);
        eq(nft.ownerOf(id), address(nft));
        eq(nft.holderOf(id), ALICE);
        eq(nft.getApproved(id), address(0));
        vm.expectRevert(bytes("Not authorized"));
        vm.prank(BOB);
        nft.transferFrom(address(nft), BOB, id);
        vm.expectRevert(bytes("Locked or not staker"));
        vm.prank(ALICE);
        nft.unstake(id);
        vm.warp(vm.getBlockTimestamp() + 7 days - 1);
        vm.expectRevert(bytes("Locked or not staker"));
        vm.prank(ALICE);
        nft.unstake(id);
        vm.warp(vm.getBlockTimestamp() + 1);
        imd.configure(0, true, false, false);
        vm.prank(B);
        nft.pause();
        vm.prank(ALICE);
        nft.unstake(id);
        eq(nft.ownerOf(id), ALICE);
        eq(nft.totalWeight(), 0);
        vm.prank(ALICE);
        nft.transferFrom(ALICE, BOB, id);
        eq(nft.ownerOf(id), BOB);
    }

    function test_BadStakeAndUnauthorizedRewards() public {
        uint256 id = _mint(ALICE);
        vm.expectRevert(bytes("Bad lock"));
        vm.prank(ALICE);
        nft.stake(id, 0);
        vm.expectRevert(bytes("Not holder"));
        vm.prank(BOB);
        nft.stake(id, 7);
        vm.expectRevert(bytes("Invalid hook fee"));
        nft.notifyHookFees(1);
        _end();
        _stake(ALICE, id, 14);
        vm.expectRevert(bytes("Unfunded fee"));
        vm.prank(address(buybackHook));
        nft.notifyHookFees(1);
        vm.expectRevert(bytes("Not holder or staker"));
        vm.prank(BOB);
        nft.claimWork(one(id));
        vm.expectRevert(bytes("Not an unstaked holder"));
        vm.prank(ALICE);
        nft.burn(id);
    }

    function test_ActivationPaymentOwnershipAndDuplicateClaims() public {
        uint256 id = _mint(ALICE);
        vm.expectRevert(bytes("Cannot activate"));
        vm.prank(ALICE);
        nft.activate(id);
        _end();
        _fund();
        vm.expectRevert(bytes("Cannot activate"));
        vm.prank(BOB);
        nft.activate(id);
        uint256 before = imd.balanceOf(B);
        vm.prank(ALICE);
        nft.activate(id);
        eq(imd.balanceOf(B) - before, 0.15 ether);
        vm.expectRevert(bytes("Cannot activate"));
        vm.prank(ALICE);
        nft.activate(id);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        uint256[] memory ids = new uint256[](2);
        ids[0] = id;
        ids[1] = id;
        vm.prank(ALICE);
        eq(nft.claimWork(ids), 12_500_000 ether);
        vm.prank(ALICE);
        eq(nft.claimWork(one(id)), 0);
        eq(nft.claimWork(new uint256[](0)), 0);
        eq(nft.miningPaid(), 12_500_000 ether);
    }

    function testFuzz_AccrualFollowsTokenAndStaker(uint256 elapsed) public {
        elapsed = bound(elapsed, 0, 7 days);
        uint256 a = _mint(ALICE);
        uint256 b = _mint(BOB);
        _end();
        _fund();
        vm.prank(ALICE);
        nft.activate(a);
        vm.prank(BOB);
        nft.activate(b);
        _stake(BOB, b, 30);
        vm.warp(vm.getBlockTimestamp() + elapsed);
        uint256 scheduled = 12_500_000 ether * elapsed / 7 days;
        vm.prank(ALICE);
        nft.transferFrom(ALICE, CAROL, a);
        yes(nft.activated(a));
        eq(nft.pendingWork(a), scheduled / 2);
        vm.expectRevert(bytes("Not holder or staker"));
        vm.prank(ALICE);
        nft.claimWork(one(a));
        vm.prank(CAROL);
        eq(nft.claimWork(one(a)), scheduled / 2);
        vm.prank(BOB);
        eq(nft.claimWork(one(b)), scheduled / 2);
        eq(nft.miningCarry(), scheduled % 2);
        eq(work.balanceOf(address(nft)), nft.miningPool() + nft.burnPool());
    }

    function test_CarryWithoutActiveWorkerAndWhilePaused() public {
        uint256 a = _mint(ALICE);
        uint256 b = _mint(BOB);
        _end();
        _fund();
        uint256 end = nft.mintEndTime();
        vm.warp(end + 1 days);
        nft.updateMining();
        uint256 carry = uint256(12_500_000 ether) / 7;
        eq(nft.miningCarry(), carry);
        eq(nft.miningAllocated(), 0);
        vm.prank(B);
        nft.pause();
        vm.prank(ALICE);
        nft.activate(a);
        vm.warp(end + 1 days + 12 hours);
        nft.updateMining();
        eq(nft.pendingWork(a), 0);
        yes(nft.miningCarry() > carry);
        vm.prank(BOB); // activation is allowed during pause, but accrual is not.
        nft.activate(b);
        vm.prank(B);
        nft.unpause();
        uint256 scheduled = nft.scheduledWork(vm.getBlockTimestamp());
        eq(nft.pendingWork(a), scheduled / 2);
        eq(nft.pendingWork(b), scheduled / 2);
        eq(nft.miningCarry(), scheduled % 2);
    }

    function test_AllErasAndRemainderPreservesUnclaimedWork() public {
        uint256 id = _mint(ALICE);
        _end();
        _fund();
        vm.prank(ALICE);
        nft.activate(id);
        uint256 elapsed;
        for (uint256 era; era < 8; ++era) {
            elapsed += 7 days << era;
            eq(nft.scheduledWork(nft.mintEndTime() + elapsed), (era + 1) * 12_500_000 ether);
            eq(
                nft.scheduledWork(nft.mintEndTime() + elapsed - 1),
                (era + 1) * 12_500_000 ether - (12_500_000 ether + (7 days << era) - 1) / (7 days << era)
            );
        }
        vm.expectRevert(bytes("Schedule not finished"));
        vm.prank(B);
        nft.releaseMiningRemainder();
        vm.warp(nft.mintEndTime() + elapsed);
        vm.prank(B);
        eq(nft.releaseMiningRemainder(), 0);
        eq(nft.miningPool(), 100_000_000 ether);
        vm.prank(ALICE);
        eq(nft.claimWork(one(id)), 100_000_000 ether);
        vm.expectRevert(bytes("Remainder unavailable"));
        vm.prank(B);
        nft.releaseMiningRemainder();
    }

    function test_NoActiveWorkersRemainderAndLateFunding() public {
        uint256 id = _mint(ALICE);
        _end();
        vm.prank(ALICE);
        nft.activate(id);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.expectRevert(bytes("Mining pool not funded"));
        vm.prank(ALICE);
        nft.claimWork(one(id));
        eq(nft.workDebt(id), 0);
        _fund();
        vm.prank(ALICE);
        yes(nft.claimWork(one(id)) > 0);
        vm.prank(ALICE);
        nft.burn(id);
        vm.warp(nft.mintEndTime() + nft.MINING_DURATION());
        uint256 before = work.balanceOf(B);
        vm.prank(B);
        uint256 remainder = nft.releaseMiningRemainder();
        yes(remainder > 0);
        eq(work.balanceOf(B) - before, remainder);
        eq(nft.miningPool(), 0);
    }

    function test_BurnFixedPayoutAndStopsEarning() public {
        uint256 a = _mint(ALICE);
        uint256 b = _mint(BOB);
        uint256 c = _mint(CAROL);
        _end();
        _fund();
        vm.prank(ALICE);
        nft.activate(a);
        vm.prank(BOB);
        nft.activate(b);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        uint256 payout = uint256(50_000_000 ether) / 3;
        eq(nft.burnPerWorker(), payout);
        vm.prank(ALICE);
        nft.burn(a);
        eq(work.balanceOf(ALICE), payout + 6_250_000 ether);
        eq(nft.activeWorkers(), 1);
        eq(nft.totalSupply(), 2);
        eq(nft.mintEndSupply(), 3);
        vm.expectRevert(bytes("Unknown worker"));
        nft.ownerOf(a);
        vm.expectRevert(bytes("Unknown worker"));
        vm.prank(ALICE);
        nft.burn(a);
        vm.prank(B);
        nft.pause();
        vm.prank(CAROL);
        nft.burn(c);
        eq(work.balanceOf(CAROL), payout);
        vm.warp(nft.mintEndTime() + 21 days);
        vm.prank(BOB);
        nft.burn(b);
        eq(work.balanceOf(BOB), payout + 18_750_000 ether);
        eq(nft.burnPool(), 50_000_000 ether % 3);
        eq(nft.activeWorkers(), 0);
        eq(nft.totalSupply(), 0);
    }

    function testFuzz_BuybackBoundsCooldownAndRollback(uint256 raw) public {
        _mint(ALICE);
        uint256 available = nft.buybackBalance();
        uint256 amount = bound(raw, 1, available);
        buybackHook.setFail(true);
        vm.expectRevert(bytes("Swap failed"));
        nft.buyback(amount);
        eq(nft.buybackBalance(), available);
        yes(!nft.hasBoughtBack());
        eq(imd.balanceOf(address(buybackHook)), 0);
        buybackHook.setFail(false);
        eq(nft.buyback(amount), amount * 2);
        eq(nft.buybackBalance(), available - amount);
        vm.expectRevert(bytes("Buyback amount out of range"));
        nft.buyback(0);
        vm.expectRevert(bytes("Buyback amount out of range"));
        nft.buyback(100 ether + 1);
        vm.expectRevert(bytes("Buyback amount out of range"));
        nft.buyback(available - amount + 1);
        if (available > amount) {
            vm.expectRevert(bytes("Buyback cooldown"));
            nft.buyback(1);
            vm.warp(vm.getBlockTimestamp() + 59);
            vm.expectRevert(bytes("Buyback cooldown"));
            nft.buyback(1);
            vm.warp(vm.getBlockTimestamp() + 1);
            nft.buyback(1);
        }
    }

    function test_PauseScopeAndFullUnpausedCooldown() public {
        uint256 id = _mint(ALICE);
        _stake(ALICE, id, 7);
        vm.prank(B);
        nft.pause();
        uint256 start = vm.getBlockTimestamp();
        uint256 anchor = arb.number() - 1;
        vm.expectRevert(bytes("Mint unavailable"));
        vm.prank(BOB);
        nft.mint(anchor, 0);
        vm.expectRevert(bytes("Pause cooldown"));
        vm.prank(B);
        nft.pause();
        _end();
        _fund();
        vm.prank(ALICE);
        nft.activate(id);
        vm.prank(ALICE);
        eq(nft.claimIMD(), 0);
        vm.warp(start + 12 hours);
        vm.prank(B);
        nft.unpause();
        vm.warp(start + 36 hours - 1);
        vm.expectRevert(bytes("Pause cooldown"));
        vm.prank(B);
        nft.pause();
        vm.warp(start + 36 hours);
        vm.prank(B);
        nft.pause();
        vm.warp(start + 60 hours);
        yes(!nft.paused());
        vm.expectRevert(bytes("Pause cooldown"));
        vm.prank(B);
        nft.pause();
        vm.warp(start + 84 hours);
        vm.prank(B);
        nft.pause();
    }

    function testFuzz_SweepCannotSpendAnyReserve(uint256 donation) public {
        donation = bound(donation, 0, 1e24);
        uint256 id = _mint(ALICE);
        _stake(ALICE, id, 7);
        _mint(BOB);
        _fund();
        imd.mint(address(nft), donation);
        vm.prank(B);
        work.transfer(address(nft), donation);
        uint256 imdBefore = imd.balanceOf(B);
        uint256 workBefore = work.balanceOf(B);
        eq(nft.sweepable(IMD), donation);
        eq(nft.sweep(IMD), donation);
        eq(imd.balanceOf(B) - imdBefore, donation);
        eq(nft.sweep(address(work)), donation);
        eq(work.balanceOf(B) - workBefore, donation);
        eq(imd.balanceOf(address(nft)), nft.stakerReserve() + nft.buybackBalance());
        eq(work.balanceOf(address(nft)), nft.miningPool() + nft.burnPool());
        eq(nft.sweep(IMD), 0);
        eq(nft.sweep(address(work)), 0);
        TestIMD stray = new TestIMD();
        stray.mint(address(nft), donation);
        eq(nft.sweep(address(stray)), donation);
        eq(stray.balanceOf(B), donation);
    }

    function test_OwnerBoundsEventsAndPermanentCap() public {
        vm.expectEmit(false, false, false, true, address(nft));
        emit CapChanged(3333, 2);
        vm.prank(B);
        nft.setCap(2);
        vm.expectRevert(bytes("Cap can only decrease"));
        vm.prank(B);
        nft.setCap(3);
        _mint(ALICE);
        vm.expectRevert(bytes("Cap can only decrease"));
        vm.prank(B);
        nft.setCap(0);
        vm.prank(B);
        nft.setCap(1);
        yes(nft.mintEnded());
        vm.expectRevert(bytes("Mint already ended"));
        vm.prank(B);
        nft.endMint();
        vm.expectEmit(false, false, false, true, address(nft));
        emit PriceScaleChanged(10_000, 5000);
        vm.prank(B);
        nft.setPriceScaleBps(5000);
        eq(nft.priceScaleBps(), 5000);
        vm.expectEmit(false, false, false, true, address(nft));
        emit FloorChanged(0, 2);
        vm.prank(B);
        nft.setFloorAdjustment(2);
        eq(nft.floorBits(), 10);
        vm.expectEmit(false, false, false, true, address(nft));
        emit ActivationFeeChanged(0.15 ether, 0);
        vm.prank(B);
        nft.setActivationFee(0);
        eq(nft.activationFee(), 0);
        vm.expectEmit(false, false, false, true, address(nft));
        emit RoyaltyChanged(500, 1000);
        vm.prank(B);
        nft.setRoyaltyBps(1000);
        eq(nft.royaltyBps(), 1000);
        vm.startPrank(B);
        vm.expectRevert(bytes("Price scale out of range"));
        nft.setPriceScaleBps(4999);
        vm.expectRevert(bytes("Price scale out of range"));
        nft.setPriceScaleBps(10_001);
        vm.expectRevert(bytes("Floor out of range"));
        nft.setFloorAdjustment(-3);
        vm.expectRevert(bytes("Floor out of range"));
        nft.setFloorAdjustment(3);
        vm.expectRevert(bytes("Activation fee exceeds cap"));
        nft.setActivationFee(0.5 ether + 1);
        vm.expectRevert(bytes("Royalty exceeds 10%"));
        nft.setRoyaltyBps(1001);
        vm.stopPrank();
    }

    function test_AllAdminFunctionsRejectNonOwnerAndFundingOnlyB() public {
        bytes[] memory calls = new bytes[](10);
        calls[0] = abi.encodeCall(nft.setCap, (1));
        calls[1] = abi.encodeCall(nft.endMint, ());
        calls[2] = abi.encodeCall(nft.pause, ());
        calls[3] = abi.encodeCall(nft.unpause, ());
        calls[4] = abi.encodeCall(nft.setBaseURI, ("bad"));
        calls[5] = abi.encodeCall(nft.setRoyaltyBps, (0));
        calls[6] = abi.encodeCall(nft.setActivationFee, (0));
        calls[7] = abi.encodeCall(nft.setPriceScaleBps, (5000));
        calls[8] = abi.encodeCall(nft.setFloorAdjustment, (0));
        calls[9] = abi.encodeCall(nft.releaseMiningRemainder, ());
        for (uint256 i; i < calls.length; ++i) {
            vm.prank(ALICE);
            (bool ok, bytes memory reason) = address(nft).call(calls[i]);
            yes(!ok);
            eq(keccak256(reason), keccak256(abi.encodeWithSignature("Error(string)", "Only owner")));
        }
        vm.expectRevert(bytes("Funding unavailable"));
        nft.fundPools();
        vm.expectRevert(bytes("Token transfer failed"));
        vm.prank(B);
        nft.fundPools();
        yes(!nft.poolsFunded());
        _fund();
        vm.expectRevert(bytes("Funding unavailable"));
        vm.prank(B);
        nft.fundPools();
    }

    function testFuzz_RoyaltyFullUintRange(uint256 sale, uint256 bps) public {
        bps = bound(bps, 0, 1000);
        vm.prank(B);
        nft.setRoyaltyBps(bps);
        (address receiver, uint256 amount) = nft.royaltyInfo(1, sale);
        eq(receiver, B);
        yes(amount <= sale / 10); // at most ten percent, including uint256.max
        eq(amount, sale / 10_000 * bps + sale % 10_000 * bps / 10_000);
    }
}

// All positions are created through actual PoW mints. No accounting/storage is injected.
contract WorkersHandler is WorkersFixture {
    uint256[] public ids;
    uint256 public rewardDeposits;
    uint256 public imdClaimed;
    uint256 public buybackDeposits;
    uint256 public buybackSpent;
    uint256 public remainderReleased;
    uint256 public previousCap = 12;
    bool public everEnded;

    constructor() {
        _deployNFT();
        _fund();
        vm.prank(B);
        nft.setCap(12);
        _mintAccounted(ALICE, 0);
        _mintAccounted(BOB, 1);
        _mintAccounted(CAROL, 2);
    }

    function workers() external view returns (WorkersNFT) {
        return nft;
    }

    function token() external view returns (Work) {
        return work;
    }

    function count() external view returns (uint256) {
        return ids.length;
    }

    function actor(uint256 n) public pure returns (address) {
        return n % 3 == 0 ? ALICE : n % 3 == 1 ? BOB : CAROL;
    }

    function _mintAccounted(address who, uint256 seed) private {
        uint256 price = nft.mintPrice();
        uint256 reward = nft.totalWeight() == 0 ? 0 : price * 65 / 100;
        rewardDeposits += reward;
        buybackDeposits += price - price * 10 / 100 - reward;
        ids.push(_mintSeed(who, seed));
        if (nft.mintEnded()) everEnded = true;
    }

    function mint(uint256 who, uint256 seed) external {
        if (!nft.mintEnded() && !nft.paused()) _mintAccounted(actor(who), seed);
    }

    function moveTime(uint256 elapsed) external {
        vm.warp(vm.getBlockTimestamp() + bound(elapsed, 0, 400 days));
        vm.roll(vm.getBlockNumber() + 1);
        _setL2(arb.number() + 1);
        nft.updateMining();
    }

    function endOrLowerCap(uint256 raw, bool end) external {
        if (nft.mintEnded()) return;
        uint256 newCap = bound(raw, nft.minted(), nft.cap());
        vm.prank(B);
        if (end) nft.endMint();
        else nft.setCap(newCap);
        yes(nft.cap() <= previousCap);
        previousCap = nft.cap();
        if (nft.mintEnded()) everEnded = true;
    }

    function _live(uint256 raw) private view returns (uint256 id, address holder) {
        id = ids[raw % ids.length];
        try nft.ownerOf(id) returns (address found) {
            holder = found;
        } catch {
            holder = address(0);
        }
    }

    function stakeOrUnstake(uint256 raw, uint256 lockChoice) external {
        (uint256 id, address holder) = _live(raw);
        if (holder == address(0)) return;
        if (holder == address(nft)) {
            (address staker, uint64 unlock,) = nft.stakes(id);
            if (vm.getBlockTimestamp() >= unlock) {
                vm.prank(staker);
                nft.unstake(id);
            }
        } else {
            uint256[3] memory locks = [uint256(7), 14, 30];
            vm.prank(holder);
            nft.stake(id, locks[lockChoice % 3]);
        }
    }

    function activateOrClaim(uint256 raw, bool activate_) external {
        (uint256 id, address holder) = _live(raw);
        if (holder == address(0)) return;
        holder = nft.holderOf(id);
        if (activate_ && nft.mintEnded() && !nft.activated(id)) {
            vm.prank(holder);
            nft.activate(id);
        } else {
            vm.prank(holder);
            nft.claimWork(one(id));
        }
    }

    function transfer(uint256 raw, uint256 who) external {
        (uint256 id, address holder) = _live(raw);
        if (holder == address(0) || holder == address(nft)) return;
        vm.prank(holder);
        nft.transferFrom(holder, actor(who), id);
    }

    function burn(uint256 raw) external {
        (uint256 id, address holder) = _live(raw);
        if (!nft.mintEnded() || holder == address(0) || holder == address(nft)) return;
        vm.prank(holder);
        nft.burn(id);
    }

    function feeAndClaim(uint256 raw, uint256 who, bool claim) external {
        if (claim) {
            vm.prank(actor(who));
            imdClaimed += nft.claimIMD();
        } else if (nft.mintEnded() && nft.totalWeight() != 0) {
            uint256 amount = bound(raw, 0, 1e24);
            imd.mint(address(nft), amount);
            vm.prank(address(buybackHook));
            nft.notifyHookFees(amount);
            rewardDeposits += amount;
        }
    }

    function buyback(uint256 raw) external {
        uint256 available = nft.buybackBalance();
        if (available == 0 || (nft.hasBoughtBack() && vm.getBlockTimestamp() < nft.lastBuyback() + 60)) return;
        uint256 amount = bound(raw, 1, available < 100 ether ? available : 100 ether);
        nft.buyback(amount);
        buybackSpent += amount;
    }

    function pauseOrUnpause(bool stop) external {
        if (stop && !nft.paused() && vm.getBlockTimestamp() >= nft.nextPauseAt()) {
            vm.prank(B);
            nft.pause();
        }
        if (!stop && nft.paused()) {
            vm.prank(B);
            nft.unpause();
        }
    }

    function donateAndSweep(uint256 raw) external {
        uint256 amount = bound(raw, 0, 1e20);
        imd.mint(address(nft), amount);
        vm.prank(B);
        work.transfer(address(nft), amount);
        eq(nft.sweep(IMD), amount);
        eq(nft.sweep(address(work)), amount);
    }

    function releaseRemainder() external {
        if (
            nft.mintEnded() && !nft.miningClosed() && !nft.paused()
                && vm.getBlockTimestamp() >= nft.mintEndTime() + nft.MINING_DURATION()
        ) {
            vm.prank(B);
            remainderReleased += nft.releaseMiningRemainder();
        }
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 50
/// forge-config: default.invariant.fail-on-revert = true
contract WorkersNFTInvariantTest is WorkTestBase {
    WorkersHandler internal handler;
    WorkersNFT internal nft;
    Work internal work;

    function setUp() public {
        handler = new WorkersHandler();
        nft = handler.workers();
        work = handler.token();
    }

    function targetContracts() external view returns (address[] memory targets) {
        targets = new address[](1);
        targets[0] = address(handler);
    }

    function invariant_ReservesCoverAllLiabilitiesAndConserveDeposits() public view {
        eq(TestIMD(IMD).balanceOf(address(nft)), nft.stakerReserve() + nft.buybackBalance());
        eq(work.balanceOf(address(nft)), nft.miningPool() + nft.burnPool());
        eq(nft.stakerReserve() + handler.imdClaimed(), handler.rewardDeposits());
        eq(nft.buybackBalance() + handler.buybackSpent(), handler.buybackDeposits());
        eq(nft.miningPool() + nft.miningPaid() + handler.remainderReleased(), 100_000_000 ether);
        eq(nft.burnPool() + nft.burned() * nft.burnPerWorker(), 50_000_000 ether);
        yes(nft.miningPaid() <= nft.miningAllocated());
        yes(nft.miningAllocated() <= 100_000_000 ether);
        yes(nft.pendingIMD(ALICE) + nft.pendingIMD(BOB) + nft.pendingIMD(CAROL) <= nft.stakerReserve());
    }

    function invariant_EscrowWeightsSupplyAndActivationAgree() public view {
        uint256 weight;
        uint256 active;
        uint256 live;
        uint256 pending;
        for (uint256 i; i < handler.count(); ++i) {
            uint256 id = handler.ids(i);
            try nft.ownerOf(id) returns (address holder) {
                ++live;
                if (nft.activated(id)) ++active;
                (address staker,, uint8 w) = nft.stakes(id);
                if (holder == address(nft)) {
                    yes(staker != address(0));
                    yes(w == 1 || w == 2 || w == 4);
                    weight += w;
                } else {
                    eq(staker, address(0));
                    eq(w, 0);
                }
                pending += nft.pendingWork(id);
            } catch {}
        }
        eq(weight, nft.totalWeight());
        eq(active, nft.activeWorkers());
        eq(live, nft.totalSupply());
        eq(nft.totalWeight(), nft.weightOf(ALICE) + nft.weightOf(BOB) + nft.weightOf(CAROL));
        yes(pending <= nft.miningPool());
        yes(nft.minted() <= nft.cap());
        if (handler.everEnded()) yes(nft.mintEnded());
        eq(nft.totalSupply() + nft.burned(), handler.count());
    }
}

// Synthetic boundary states are confined to testing the epoch views and amount guard.
// All reserve and lifecycle invariants above use the unmodified production contract.
contract WorkersBoundaryHarness is WorkersNFT {
    constructor(address token, address owner_, address hook_) WorkersNFT(token, owner_, hook_) {}

    function epochState(uint256 count) external {
        minted = count;
    }

    function buybackState(uint256 amount) external {
        buybackBalance = amount;
    }
}

contract WorkersReceiverProbe is IWorkersReceiver {
    WorkersNFT public immutable nft;
    bool public accepting = true;
    bool public probe;
    bool public guarded;

    constructor(WorkersNFT nft_) {
        nft = nft_;
    }

    function configure(bool accept_, bool probe_) external {
        accepting = accept_;
        probe = probe_;
    }

    function stake(uint256 id) external {
        nft.stake(id, 7);
    }

    function exit(uint256 id) external {
        nft.unstake(id);
    }

    function onERC721Received(address, address, uint256 id, bytes calldata) external returns (bytes4) {
        require(accepting, "Receiver disabled");
        if (probe) {
            (bool a, bytes memory ra) = address(nft).call(abi.encodeCall(nft.stake, (id, 7)));
            (bool b, bytes memory rb) = address(nft).call(abi.encodeCall(nft.sweep, (nft.IMD())));
            (bool c, bytes memory rc) = address(nft).call(abi.encodeCall(nft.mint, (1, 0)));
            bytes32 expected = keccak256(abi.encodeWithSignature("Error(string)", "Reentrancy"));
            guarded =
                !a && !b && !c && keccak256(ra) == expected && keccak256(rb) == expected && keccak256(rc) == expected;
        }
        return IWorkersReceiver.onERC721Received.selector;
    }
}

/// forge-config: default.fuzz.runs = 1000
contract WorkersNFTBoundaryTest is WorkersFixture {
    function setUp() public {
        _deployNFT();
    }

    function testFuzz_EpochPricesFloorsAndScale(uint256 count, uint256 scale, uint256 adjustment) public {
        count = bound(count, 0, 3333);
        scale = bound(scale, 5000, 10_000);
        int256 shift = int256(bound(adjustment, 0, 4)) - 2;
        WorkersBoundaryHarness harness = new WorkersBoundaryHarness(address(work), B, address(buybackHook));
        harness.epochState(count);
        vm.startPrank(B);
        harness.setFloorAdjustment(shift);
        harness.setPriceScaleBps(scale);
        vm.stopPrank();
        uint256 e = count >= 2960 ? 8 : count / 370;
        uint256[9] memory prices = [
            uint256(0.25 ether), 0.5 ether, 0.75 ether, 1.25 ether, 1.75 ether, 2.5 ether, 3.25 ether, 4 ether, 5 ether
        ];
        eq(harness.epoch(), e);
        eq(harness.mintPrice(), prices[e] * scale / 10_000);
        eq(harness.floorBits(), uint256(int256(8 + e) + shift));
        eq(harness.maxTarget(), type(uint256).max >> uint256(int256(8 + e) + shift));
        yes(harness.mintPrice() <= 5 ether);
        yes(harness.currentTarget() <= harness.maxTarget());
    }

    function testFuzz_BuybackMaximumBoundary(uint256 raw) public {
        WorkersBoundaryHarness harness = new WorkersBoundaryHarness(address(work), B, address(buybackHook));
        harness.buybackState(200 ether);
        imd.mint(address(harness), 200 ether);
        uint256 amount = bound(raw, 1, 100 ether);
        eq(harness.buyback(amount), amount * 2);
        eq(harness.buybackBalance(), 200 ether - amount);
        vm.warp(vm.getBlockTimestamp() + 60);
        vm.expectRevert(bytes("Buyback amount out of range"));
        harness.buyback(100 ether + 1);
        eq(harness.buyback(100 ether), 200 ether);
    }

    function test_ReceiverReentrancyRejectedAndUnsafeMintAtomic() public {
        WorkersReceiverProbe receiver = new WorkersReceiverProbe(nft);
        _allow(address(receiver));
        uint256 anchor = arb.number() - 1;
        (uint256 nonce,) = _solve(address(receiver), anchor, 0, false);
        receiver.configure(false, false);
        vm.expectRevert(bytes("Receiver disabled"));
        vm.prank(address(receiver));
        nft.mint(anchor, nonce);
        eq(nft.minted(), 0);
        eq(nft.buybackBalance(), 0);
        eq(imd.balanceOf(B), 0);
        receiver.configure(true, true);
        vm.prank(address(receiver));
        uint256 id = nft.mint(anchor, nonce);
        yes(receiver.guarded());
        eq(nft.ownerOf(id), address(receiver));
        eq(nft.totalWeight(), 0);
        receiver.configure(true, false);
        receiver.stake(id);
        receiver.configure(false, false);
        imd.configure(0, true, false, false);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        receiver.exit(id);
        eq(nft.ownerOf(id), address(receiver));
        eq(nft.totalWeight(), 0);
    }

    function test_ERC721TransferFailuresAreAtomicAndPlainTransferAllowed() public {
        uint256 id = _mint(ALICE);
        WorkersReceiverProbe receiver = new WorkersReceiverProbe(nft);
        receiver.configure(false, false);
        vm.expectRevert(bytes("Receiver disabled"));
        vm.prank(ALICE);
        nft.safeTransferFrom(ALICE, address(receiver), id);
        eq(nft.ownerOf(id), ALICE);
        eq(nft.balanceOf(address(receiver)), 0);
        vm.expectRevert(bytes("Bad transfer"));
        vm.prank(ALICE);
        nft.transferFrom(ALICE, address(nft), id);
        vm.expectRevert(bytes("Bad transfer"));
        vm.prank(ALICE);
        nft.transferFrom(ALICE, address(0), id);
        vm.expectRevert(bytes("Not authorized"));
        vm.prank(BOB);
        nft.transferFrom(ALICE, BOB, id);
        vm.prank(ALICE);
        nft.approve(BOB, id);
        vm.prank(BOB);
        nft.transferFrom(ALICE, address(receiver), id);
        eq(nft.ownerOf(id), address(receiver));
        eq(nft.getApproved(id), address(0));
    }

    function test_PauseFreezesNewAccrualButAllowsExistingClaimAndActivationRollback() public {
        uint256 a = _mint(ALICE);
        uint256 b = _mint(BOB);
        _end();
        _fund();
        vm.prank(ALICE);
        nft.activate(a);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.prank(B);
        nft.pause();
        uint256 earned = nft.pendingWork(a);
        imd.configure(0, false, true, false);
        vm.expectRevert(bytes("Token transfer failed"));
        vm.prank(BOB);
        nft.activate(b);
        yes(!nft.activated(b));
        eq(nft.activeWorkers(), 1);
        imd.configure(0, false, false, false);
        vm.warp(vm.getBlockTimestamp() + 12 hours);
        eq(nft.pendingWork(a), earned);
        vm.prank(ALICE);
        eq(nft.claimWork(one(a)), earned);
        eq(nft.pendingWork(a), 0);
        vm.warp(vm.getBlockTimestamp() + 12 hours);
        nft.updateMining();
        yes(nft.pendingWork(a) > 0);
        eq(nft.miningCarry(), 0);
    }

    function test_ZeroMintAndZeroCapEndPermanently() public {
        vm.prank(B);
        nft.setCap(0);
        yes(nft.mintEnded());
        eq(nft.mintEndSupply(), 0);
        eq(nft.burnPerWorker(), 0);
        _fund();
        vm.warp(nft.mintEndTime() + nft.MINING_DURATION());
        vm.prank(B);
        eq(nft.releaseMiningRemainder(), 100_000_000 ether);
        eq(nft.burnPool(), 50_000_000 ether);
        vm.expectRevert(bytes("Cap can only decrease"));
        vm.prank(B);
        nft.setCap(1);
    }
}

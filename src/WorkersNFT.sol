// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IWorkToken {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @dev Optional ERC20 returns are supported; transfers into reserves must arrive in full.
library WorkTokenOps {
    function send(address token, address to, uint256 amount) internal {
        if (amount != 0) _call(token, abi.encodeCall(IWorkToken.transfer, (to, amount)));
    }

    function pull(address token, address from, uint256 amount) internal {
        if (amount == 0) return;
        uint256 beforeBalance = IWorkToken(token).balanceOf(address(this));
        _call(token, abi.encodeCall(IWorkToken.transferFrom, (from, address(this), amount)));
        require(IWorkToken(token).balanceOf(address(this)) == beforeBalance + amount, "Short transfer");
    }

    function _call(address token, bytes memory data) private {
        require(token.code.length != 0, "Not a token");
        (bool ok, bytes memory result) = token.call(data);
        require(ok && (result.length == 0 || abi.decode(result, (bool))), "Token transfer failed");
    }
}

interface IWorkersReceiver {
    function onERC721Received(address operator, address from, uint256 id, bytes calldata data) external returns (bytes4);
}

interface IWorkBuyback {
    function executeBuyback(uint256 amount) external returns (uint256 workOut);
}

/// @dev Nitro's block.number is an L1 number. Both PoW block checks use ArbSys instead.
interface IWorkArbSys {
    function arbBlockNumber() external view returns (uint256);
    function arbBlockHash(uint256 blockNumber) external view returns (bytes32);
}

/// @notice Immutable PoW collection, staking escrow and separately reserved IMD/WORK pools.
/// @dev Owner can only change the explicitly bounded parameters below. B is never changeable.
contract WorkersNFT {
    using WorkTokenOps for address;

    string public constant name = "Workers";
    string public constant symbol = "WORKERS";
    address public constant IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    address public constant B = 0xc9EAFE33A510a3a3d95A94c4f85AdaF6a3EA12a0;
    address public constant ARBSYS = address(0x64);
    uint256 public constant MAX_SUPPLY = 3333;
    uint256 public constant MINING_ALLOCATION = 100_000_000 ether;
    uint256 public constant BURN_ALLOCATION = 50_000_000 ether;
    uint256 public constant ERA_EMISSION = 12_500_000 ether;
    uint256 public constant MINING_DURATION = 7 days * 255;
    uint256 public constant REWARD_PRECISION = 1e27;
    uint256 public constant MAX_BUYBACK = 100 ether;
    uint256 public constant BUYBACK_INTERVAL = 60;
    uint256 public constant MAX_PAUSE = 1 days;
    uint256 public constant PAUSE_COOLDOWN = 1 days;
    uint256 public constant BASE_FLOOR_BITS = 8;
    uint256 public constant RETARGET_MINTS = 8;
    uint256 public constant TARGET_SECONDS = 10;
    uint256 public constant IDLE_SECONDS = 300;
    bytes32 public constant DOMAIN = keccak256("WorkersNFT.PoW.v1");

    address public immutable work;
    address public immutable owner;
    address public immutable hook;
    string public baseURI = "ipfs://bafybeibmkvtnptsqztdvsm5sh3avormdnfyarbxpgdlcj6bmg37qchhqve/";
    uint256 public cap = MAX_SUPPLY;
    uint256 public minted;
    uint256 public burned;
    bool public mintEnded;
    uint256 public mintEndTime;
    uint256 public mintEndSupply;
    uint256 public priceScaleBps = 10_000;
    uint256 public activationFee = 0.15 ether;
    uint256 public royaltyBps = 500;
    int256 public floorAdjustment;
    uint256 public difficultyTarget;
    bytes32 public prevWork;
    uint256 public lastMintBlock;
    uint256 public lastMintTime;
    uint256 public retargetTime;
    uint256 public pausedUntil;
    uint256 public nextPauseAt;

    mapping(uint256 => address) private _owners;
    mapping(address => uint256) private _balances;
    mapping(uint256 => address) private _approvals;
    mapping(address => mapping(address => bool)) public isApprovedForAll;
    mapping(uint256 => uint256) private _pool;
    mapping(uint256 => bool) public overclocked;
    mapping(uint256 => bool) public activated;
    mapping(uint256 => uint256) public workDebt;

    struct Stake {
        address staker;
        uint64 unlockTime;
        uint8 weight;
    }
    mapping(uint256 => Stake) public stakes;
    uint256 public totalWeight;
    mapping(address => uint256) public weightOf;
    mapping(address => uint256) public imdDebt;
    mapping(address => uint256) public imdCredit;
    uint256 public accIMDPerWeight;
    uint256 public stakerReserve;
    uint256 public buybackBalance;
    uint256 public lastBuyback;
    bool public hasBoughtBack;

    bool public poolsFunded;
    uint256 public miningPool;
    uint256 public burnPool;
    uint256 public burnPerWorker;
    uint256 public activeWorkers;
    uint256 public accWorkPerWorker;
    uint256 public miningScheduled;
    uint256 public miningCarry;
    uint256 public miningAllocated;
    uint256 public miningPaid;
    bool public miningClosed;
    uint256 private _entered;

    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event Approval(address indexed owner, address indexed approved, uint256 indexed tokenId);
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);
    event MetadataUpdate(uint256 tokenId);
    event BatchMetadataUpdate(uint256 fromTokenId, uint256 toTokenId);
    event CapChanged(uint256 oldCap, uint256 newCap);
    event MintEnded(uint256 timestamp, uint256 supply, uint256 burnPerWorker);
    event PauseStarted(uint256 until, uint256 nextPauseAt);
    event PauseEnded(uint256 nextPauseAt);
    event PriceScaleChanged(uint256 oldBps, uint256 newBps);
    event FloorChanged(int256 oldAdjustment, int256 newAdjustment);
    event ActivationFeeChanged(uint256 oldFee, uint256 newFee);
    event RoyaltyChanged(uint256 oldBps, uint256 newBps);
    event BaseURIChanged(string uri);
    event Mined(address indexed miner, uint256 indexed id, bytes32 workHash, uint256 target, bool overclocked);
    event Retargeted(uint256 oldTarget, uint256 newTarget, uint256 elapsed);
    event MintPayment(uint256 stakers, uint256 buyback, uint256 beneficiary);
    event Staked(address indexed staker, uint256 indexed id, uint256 weight, uint256 unlockTime);
    event Unstaked(address indexed staker, uint256 indexed id);
    event IMDClaimed(address indexed staker, uint256 amount);
    event HookFeesReceived(uint256 amount);
    event PoolsFunded(uint256 mining, uint256 burning);
    event Activated(uint256 indexed id);
    event WorkAccrued(uint256 amount, uint256 carry);
    event WorkClaimed(address indexed holder, uint256 amount);
    event WorkerBurned(uint256 indexed id, uint256 payout);
    event MiningRemainderReleased(uint256 amount);
    event Buyback(uint256 imdIn, uint256 workOut);
    event Swept(address indexed token, uint256 amount);

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner");
        _;
    }

    modifier nonReentrant() {
        require(_entered == 0, "Reentrancy");
        _entered = 1;
        _;
        _entered = 0;
    }

    constructor(address token, address owner_, address hook_) {
        require(token.code.length != 0 && token != IMD && owner_ != address(0) && hook_ != address(0), "Bad setup");
        work = token;
        owner = owner_;
        hook = hook_;
        difficultyTarget = type(uint256).max >> BASE_FLOOR_BITS;
        lastMintTime = block.timestamp;
        retargetTime = block.timestamp;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == 0x01ffc9a7 || interfaceId == 0x80ac58cd || interfaceId == 0x5b5e139f
            || interfaceId == 0x2a55205a || interfaceId == 0x49064906;
    }

    function balanceOf(address account) external view returns (uint256) {
        require(account != address(0), "Zero owner");
        return _balances[account];
    }

    function ownerOf(uint256 id) public view returns (address account) {
        account = _owners[id];
        require(account != address(0), "Unknown worker");
    }

    function totalSupply() external view returns (uint256) {
        return minted - burned;
    }

    function getApproved(uint256 id) external view returns (address) {
        ownerOf(id);
        return _approvals[id];
    }

    function approve(address to, uint256 id) external {
        address holder = ownerOf(id);
        require(msg.sender == holder || isApprovedForAll[holder][msg.sender], "Not authorized");
        require(to != holder, "Self approval");
        _approvals[id] = to;
        emit Approval(holder, to, id);
    }

    function setApprovalForAll(address operator, bool approved) external {
        require(operator != msg.sender, "Self approval");
        isApprovedForAll[msg.sender][operator] = approved;
        emit ApprovalForAll(msg.sender, operator, approved);
    }

    function transferFrom(address from, address to, uint256 id) public {
        address holder = ownerOf(id);
        require(
            msg.sender == holder || _approvals[id] == msg.sender || isApprovedForAll[holder][msg.sender],
            "Not authorized"
        );
        require(holder == from && to != address(0) && to != address(this), "Bad transfer");
        _transfer(from, to, id);
    }

    function safeTransferFrom(address from, address to, uint256 id) external {
        safeTransferFrom(from, to, id, "");
    }

    function safeTransferFrom(address from, address to, uint256 id, bytes memory data) public {
        transferFrom(from, to, id);
        _checkReceiver(from, to, id, data);
    }

    function _transfer(address from, address to, uint256 id) private {
        delete _approvals[id];
        _balances[from]--;
        _balances[to]++;
        _owners[id] = to;
        emit Transfer(from, to, id);
    }

    function _checkReceiver(address from, address to, uint256 id, bytes memory data) private {
        if (to.code.length != 0) {
            require(
                IWorkersReceiver(to).onERC721Received(msg.sender, from, id, data)
                    == IWorkersReceiver.onERC721Received.selector,
                "Unsafe receiver"
            );
        }
    }

    function tokenURI(uint256 id) external view returns (string memory) {
        ownerOf(id);
        return string.concat(baseURI, overclocked[id] ? "oc/" : "", _decimal(id), ".json");
    }

    function _decimal(uint256 n) private pure returns (string memory) {
        uint256 digits;
        for (uint256 v = n; v != 0; v /= 10) {
            digits++;
        }
        bytes memory result = new bytes(digits);
        while (digits != 0) {
            result[--digits] = bytes1(uint8(48 + n % 10));
            n /= 10;
        }
        return string(result);
    }

    function royaltyInfo(uint256, uint256 salePrice) external view returns (address, uint256) {
        // Quotient/remainder form also works when salePrice is near uint256.max.
        return (B, salePrice / 10_000 * royaltyBps + salePrice % 10_000 * royaltyBps / 10_000);
    }

    function setBaseURI(string calldata uri) external onlyOwner {
        baseURI = uri;
        emit BaseURIChanged(uri);
        emit BatchMetadataUpdate(1, MAX_SUPPLY);
    }

    function setRoyaltyBps(uint256 bps) external onlyOwner {
        require(bps <= 1000, "Royalty exceeds 10%");
        emit RoyaltyChanged(royaltyBps, bps);
        royaltyBps = bps;
    }

    function setActivationFee(uint256 fee) external onlyOwner {
        require(fee <= 0.5 ether, "Activation fee exceeds cap");
        emit ActivationFeeChanged(activationFee, fee);
        activationFee = fee;
    }

    function setPriceScaleBps(uint256 bps) external onlyOwner {
        require(bps >= 5000 && bps <= 10_000, "Price scale out of range");
        emit PriceScaleChanged(priceScaleBps, bps);
        priceScaleBps = bps;
    }

    function setFloorAdjustment(int256 adjustment) external onlyOwner {
        require(adjustment >= -2 && adjustment <= 2, "Floor out of range");
        emit FloorChanged(floorAdjustment, adjustment);
        floorAdjustment = adjustment;
        uint256 limit = maxTarget();
        if (difficultyTarget > limit) difficultyTarget = limit;
    }

    function setCap(uint256 newCap) external onlyOwner {
        require(newCap <= cap && newCap >= minted, "Cap can only decrease");
        emit CapChanged(cap, newCap);
        cap = newCap;
        if (minted == newCap && !mintEnded) _endMint();
    }

    function endMint() external onlyOwner {
        require(!mintEnded, "Mint already ended");
        _endMint();
    }

    function _endMint() private {
        mintEnded = true;
        mintEndTime = block.timestamp;
        mintEndSupply = minted;
        // The fixed allocation can be funded later, but burns cannot spend unfunded reserves.
        burnPerWorker = minted == 0 ? 0 : BURN_ALLOCATION / minted;
        emit MintEnded(block.timestamp, minted, burnPerWorker);
    }

    function paused() public view returns (bool) {
        return block.timestamp < pausedUntil;
    }

    function pause() external onlyOwner {
        require(!paused() && block.timestamp >= nextPauseAt, "Pause cooldown");
        _updateMining();
        pausedUntil = block.timestamp + MAX_PAUSE;
        nextPauseAt = pausedUntil + PAUSE_COOLDOWN;
        emit PauseStarted(pausedUntil, nextPauseAt);
    }

    function unpause() external onlyOwner {
        require(paused(), "Not paused");
        pausedUntil = block.timestamp;
        nextPauseAt = block.timestamp + PAUSE_COOLDOWN;
        _updateMining();
        emit PauseEnded(nextPauseAt);
    }

    /// @notice Epochs 0..7 have 370 mints; epoch 8 has the final 373.
    function epoch() public view returns (uint256) {
        return minted / 370 < 8 ? minted / 370 : 8;
    }

    function epochPrice(uint256 e) public pure returns (uint256) {
        require(e < 9, "Bad epoch");
        uint256[9] memory prices = [
            uint256(0.25 ether), 0.5 ether, 0.75 ether, 1.25 ether, 1.75 ether, 2.5 ether, 3.25 ether, 4 ether, 5 ether
        ];
        return prices[e];
    }

    function mintPrice() public view returns (uint256) {
        return epochPrice(epoch()) * priceScaleBps / 10_000;
    }

    function floorBits() public view returns (uint256) {
        return uint256(int256(BASE_FLOOR_BITS + epoch()) + floorAdjustment);
    }

    function maxTarget() public view returns (uint256) {
        return type(uint256).max >> floorBits();
    }

    /// @notice Each completed 300-second idle interval doubles the target, capped by the epoch floor.
    function currentTarget() public view returns (uint256) {
        uint256 limit = maxTarget();
        uint256 shifts = (block.timestamp - lastMintTime) / IDLE_SECONDS;
        if (shifts >= 256 || difficultyTarget > (limit >> shifts)) return limit;
        uint256 value = difficultyTarget << shifts;
        return value > limit ? limit : value;
    }

    function anchorHash(uint256 anchor) public view returns (bytes32 hash) {
        uint256 current = IWorkArbSys(ARBSYS).arbBlockNumber();
        require(anchor < current && current - anchor <= 250, "Stale anchor");
        hash = IWorkArbSys(ARBSYS).arbBlockHash(anchor);
        require(hash != bytes32(0), "Missing anchor");
    }

    function workHash(address miner, uint256 anchor, uint256 nonce) public view returns (bytes32) {
        return keccak256(
            abi.encode(
                DOMAIN, block.chainid, address(this), keccak256(abi.encode(anchorHash(anchor), prevWork)), miner, nonce
            )
        );
    }

    function checkWork(address miner, uint256 anchor, uint256 nonce) external view returns (bool) {
        return uint256(workHash(miner, anchor, nonce)) < currentTarget();
    }

    /// @notice Virtual swap-and-pop array of ALL 3333 IDs, even when the mint cap is lowered.
    function pool(uint256 index) public view returns (uint256) {
        require(index < MAX_SUPPLY - minted, "Pool index out of range");
        uint256 id = _pool[index];
        return id == 0 ? index + 1 : id;
    }

    function mint(uint256 anchor, uint256 nonce) external nonReentrant returns (uint256 id) {
        require(!mintEnded && !paused() && minted < cap, "Mint unavailable");
        uint256 currentBlock = IWorkArbSys(ARBSYS).arbBlockNumber();
        require(minted == 0 || currentBlock != lastMintBlock, "One mint per L2 block");
        bytes32 hash = workHash(msg.sender, anchor, nonce);
        uint256 target = currentTarget();
        require(uint256(hash) < target, "Insufficient work");
        uint256 price = mintPrice();
        uint256 remaining = MAX_SUPPLY - minted;
        uint256 index = uint256(hash) % remaining;
        id = pool(index);
        _pool[index] = pool(remaining - 1);
        delete _pool[remaining - 1];
        minted++;
        lastMintBlock = currentBlock;
        lastMintTime = block.timestamp;
        prevWork = hash;
        difficultyTarget = target;
        if (minted % RETARGET_MINTS == 0) {
            uint256 elapsed = block.timestamp - retargetTime;
            uint256 bounded = elapsed < 20 ? 20 : (elapsed > 320 ? 320 : elapsed);
            uint256 adjusted = target / 80 * bounded + target % 80 * bounded / 80;
            difficultyTarget = adjusted == 0 ? 1 : adjusted;
            retargetTime = block.timestamp;
            if (difficultyTarget > maxTarget()) difficultyTarget = maxTarget();
            emit Retargeted(target, difficultyTarget, elapsed);
        }
        if (difficultyTarget > maxTarget()) difficultyTarget = maxTarget();
        overclocked[id] = uint256(hash) < (target >> 4);
        _owners[id] = msg.sender;
        _balances[msg.sender]++;
        emit Transfer(address(0), msg.sender, id);
        emit Mined(msg.sender, id, hash, target, overclocked[id]);
        if (minted == cap) _endMint();

        IMD.pull(msg.sender, price);
        uint256 stakerPart = price * 65 / 100;
        uint256 beneficiaryPart = price * 10 / 100;
        uint256 buybackPart = price - stakerPart - beneficiaryPart;
        if (totalWeight == 0) {
            buybackPart += stakerPart;
            stakerPart = 0;
        } else {
            _addIMD(stakerPart);
        }
        buybackBalance += buybackPart;
        emit MintPayment(stakerPart, buybackPart, beneficiaryPart);
        IMD.send(B, beneficiaryPart);
        _checkReceiver(address(0), msg.sender, id, "");
    }

    function stake(uint256 id, uint256 lockDays) external nonReentrant {
        require(ownerOf(id) == msg.sender, "Not holder");
        require(lockDays == 7 || lockDays == 14 || lockDays == 30, "Bad lock");
        uint8 weight = lockDays == 7 ? 1 : (lockDays == 14 ? 2 : 4);
        _settleIMD(msg.sender);
        weightOf[msg.sender] += weight;
        totalWeight += weight;
        uint256 unlockTime = block.timestamp + lockDays * 1 days;
        stakes[id] = Stake(msg.sender, uint64(unlockTime), weight);
        _transfer(msg.sender, address(this), id);
        emit Staked(msg.sender, id, weight, unlockTime);
    }

    function unstake(uint256 id) external nonReentrant {
        Stake memory position = stakes[id];
        require(position.staker == msg.sender && block.timestamp >= position.unlockTime, "Locked or not staker");
        _settleIMD(msg.sender);
        weightOf[msg.sender] -= position.weight;
        totalWeight -= position.weight;
        delete stakes[id];
        // Deliberately no receiver callback or automatic ERC20 claim: escrow exit stays available.
        _transfer(address(this), msg.sender, id);
        emit Unstaked(msg.sender, id);
    }

    function _addIMD(uint256 amount) private {
        stakerReserve += amount;
        accIMDPerWeight += amount * REWARD_PRECISION / totalWeight;
    }

    /// @dev Only the immutable hook can notify, after transferring the funds. This callback must also
    /// work during a buyback; it changes no stake weights and cannot spend any reserved tokens.
    function notifyHookFees(uint256 amount) external {
        require(msg.sender == hook && mintEnded && totalWeight != 0, "Invalid hook fee");
        require(IWorkToken(IMD).balanceOf(address(this)) >= stakerReserve + buybackBalance + amount, "Unfunded fee");
        _addIMD(amount);
        emit HookFeesReceived(amount);
    }

    function pendingIMD(address account) public view returns (uint256) {
        return imdCredit[account] + weightOf[account] * (accIMDPerWeight - imdDebt[account]) / REWARD_PRECISION;
    }

    function _settleIMD(address account) private {
        imdCredit[account] = pendingIMD(account);
        imdDebt[account] = accIMDPerWeight;
    }

    function claimIMD() external nonReentrant returns (uint256 amount) {
        _settleIMD(msg.sender);
        amount = imdCredit[msg.sender] < stakerReserve ? imdCredit[msg.sender] : stakerReserve;
        imdCredit[msg.sender] -= amount;
        stakerReserve -= amount;
        IMD.send(msg.sender, amount);
        emit IMDClaimed(msg.sender, amount);
    }

    function buyback(uint256 amount) external nonReentrant returns (uint256 workOut) {
        require(amount != 0 && amount <= MAX_BUYBACK && amount <= buybackBalance, "Buyback amount out of range");
        require(!hasBoughtBack || block.timestamp >= lastBuyback + BUYBACK_INTERVAL, "Buyback cooldown");
        buybackBalance -= amount;
        hasBoughtBack = true;
        lastBuyback = block.timestamp;
        IMD.send(hook, amount);
        workOut = IWorkBuyback(hook).executeBuyback(amount);
        emit Buyback(amount, workOut);
    }

    function fundPools() external nonReentrant {
        require(msg.sender == B && !poolsFunded && !miningClosed, "Funding unavailable");
        poolsFunded = true;
        miningPool = MINING_ALLOCATION;
        burnPool = BURN_ALLOCATION;
        work.pull(B, MINING_ALLOCATION + BURN_ALLOCATION);
        emit PoolsFunded(MINING_ALLOCATION, BURN_ALLOCATION);
    }

    function holderOf(uint256 id) public view returns (address) {
        address holder = ownerOf(id);
        return holder == address(this) ? stakes[id].staker : holder;
    }

    function activate(uint256 id) external nonReentrant {
        require(mintEnded && holderOf(id) == msg.sender && !activated[id], "Cannot activate");
        _updateMining();
        activated[id] = true;
        workDebt[id] = accWorkPerWorker;
        activeWorkers++;
        _updateMining();
        IMD.pull(msg.sender, activationFee);
        IMD.send(B, activationFee);
        emit Activated(id);
        emit MetadataUpdate(id);
    }

    /// @notice Cumulative schedule avoids losing fractional emission on frequent updates.
    function scheduledWork(uint256 timestamp) public view returns (uint256 total) {
        if (!mintEnded || timestamp <= mintEndTime) return 0;
        uint256 elapsed = timestamp - mintEndTime;
        for (uint256 k; k < 8; k++) {
            uint256 duration = 7 days << k;
            if (elapsed < duration) return total + ERA_EMISSION * elapsed / duration;
            total += ERA_EMISSION;
            elapsed -= duration;
        }
    }

    function updateMining() external {
        _updateMining();
    }

    function _updateMining() private {
        if (!mintEnded || miningClosed) return;
        uint256 scheduled = scheduledWork(block.timestamp);
        miningCarry += scheduled - miningScheduled;
        miningScheduled = scheduled;
        if (paused() || activeWorkers == 0) return;
        uint256 increment = miningCarry / activeWorkers;
        if (increment != 0) {
            uint256 distributed = increment * activeWorkers;
            miningCarry -= distributed;
            miningAllocated += distributed;
            accWorkPerWorker += increment;
            emit WorkAccrued(distributed, miningCarry);
        }
    }

    function pendingWork(uint256 id) external view returns (uint256) {
        ownerOf(id);
        if (!activated[id]) return 0;
        uint256 accumulator = accWorkPerWorker;
        if (!miningClosed && !paused() && activeWorkers != 0) {
            accumulator += (miningCarry + scheduledWork(block.timestamp) - miningScheduled) / activeWorkers;
        }
        return accumulator - workDebt[id];
    }

    function claimWork(uint256[] calldata ids) external nonReentrant returns (uint256 amount) {
        _updateMining();
        for (uint256 i; i < ids.length; i++) {
            uint256 id = ids[i];
            require(holderOf(id) == msg.sender, "Not holder or staker");
            amount += _claimWorker(id);
        }
        _payWork(msg.sender, amount);
    }

    function _claimWorker(uint256 id) private returns (uint256 amount) {
        if (activated[id]) {
            amount = accWorkPerWorker - workDebt[id];
            workDebt[id] = accWorkPerWorker;
        }
    }

    function _payWork(address to, uint256 amount) private {
        require(amount <= miningPool, "Mining pool not funded");
        miningPaid += amount;
        miningPool -= amount;
        work.send(to, amount);
        emit WorkClaimed(to, amount);
    }

    function burn(uint256 id) external nonReentrant {
        require(mintEnded && ownerOf(id) == msg.sender, "Not an unstaked holder");
        require(poolsFunded && burnPerWorker <= burnPool, "Burn pool not funded");
        _updateMining();
        uint256 earned = _claimWorker(id);
        if (activated[id]) {
            activeWorkers--;
            activated[id] = false;
        }
        delete _approvals[id];
        delete _owners[id];
        _balances[msg.sender]--;
        burned++;
        burnPool -= burnPerWorker;
        emit Transfer(msg.sender, address(0), id);
        emit WorkerBurned(id, burnPerWorker);
        _payWork(msg.sender, earned);
        work.send(msg.sender, burnPerWorker);
    }

    /// @notice After all eight eras, close the schedule and return only UNASSIGNED mining funds.
    /// Accrued but unclaimed WORK remains reserved forever. If workers exist, carried emissions
    /// are distributed before closing; otherwise the unassigned carry is part of the remainder.
    function releaseMiningRemainder() external onlyOwner nonReentrant returns (uint256 amount) {
        require(mintEnded && block.timestamp >= mintEndTime + MINING_DURATION && !paused(), "Schedule not finished");
        require(poolsFunded && !miningClosed, "Remainder unavailable");
        _updateMining();
        miningClosed = true;
        miningCarry = 0;
        amount = miningPool - (miningAllocated - miningPaid);
        miningPool -= amount;
        work.send(B, amount);
        emit MiningRemainderReleased(amount);
    }

    function sweepable(address token) public view returns (uint256) {
        uint256 reserved;
        if (token == IMD) reserved = stakerReserve + buybackBalance;
        if (token == work) reserved = miningPool + burnPool;
        uint256 balance = IWorkToken(token).balanceOf(address(this));
        return balance > reserved ? balance - reserved : 0;
    }

    function sweep(address token) external nonReentrant returns (uint256 amount) {
        amount = sweepable(token);
        token.send(B, amount);
        emit Swept(token, amount);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Work} from "src/Work.sol";

// Minimal Foundry interface keeps the suite runnable offline without adding dependencies.
interface WorkVm {
    function prank(address) external;
    function startPrank(address) external;
    function stopPrank() external;
    function warp(uint256) external;
    function roll(uint256) external;
    function chainId(uint256) external;
    function etch(address, bytes calldata) external;
    function mockCall(address, bytes calldata, bytes calldata) external;
    function store(address, bytes32, bytes32) external;
    function expectRevert() external;
    function expectRevert(bytes calldata) external;
    function expectEmit(bool, bool, bool, bool, address) external;
    function getBlockTimestamp() external view returns (uint256);
    function getBlockNumber() external view returns (uint256);
    function toString(uint256) external pure returns (string memory);
}

abstract contract WorkTestBase {
    WorkVm internal constant vm = WorkVm(address(uint160(uint256(keccak256("hevm cheat code")))));
    address internal constant B = 0xc9EAFE33A510a3a3d95A94c4f85AdaF6a3EA12a0;
    address internal constant IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    address internal constant ALICE = address(0xa11ce);
    address internal constant BOB = address(0xb0b);
    address internal constant CAROL = address(0xca401);

    function eq(uint256 a, uint256 b) internal pure {
        require(a == b, "uint mismatch");
    }

    function eq(address a, address b) internal pure {
        require(a == b, "address mismatch");
    }

    function eq(bytes32 a, bytes32 b) internal pure {
        require(a == b, "hash mismatch");
    }

    function eq(string memory a, string memory b) internal pure {
        require(keccak256(bytes(a)) == keccak256(bytes(b)), "string mismatch");
    }

    function yes(bool value) internal pure {
        require(value, "assertion failed");
    }

    function bound(uint256 n, uint256 low, uint256 high) internal pure returns (uint256) {
        if (n >= low && n <= high) return n;
        return low + n % (high - low + 1);
    }

    function one(uint256 id) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = id;
    }
}

/// forge-config: default.fuzz.runs = 1000
contract WorkTest is WorkTestBase {
    Work internal token;
    event Transfer(address indexed from, address indexed to, uint256 amount);

    function setUp() public {
        vm.prank(B);
        token = new Work();
    }

    function test_NoArgumentLaunchAndAllocation() public {
        eq(token.name(), "Work");
        eq(token.symbol(), "WORK");
        eq(token.decimals(), 18);
        eq(token.totalSupply(), 1_000_000_000 ether);
        eq(token.balanceOf(B), token.totalSupply());
        vm.startPrank(B);
        token.transfer(ALICE, 100_000_000 ether);
        token.transfer(BOB, 700_000_000 ether);
        vm.stopPrank();
        eq(token.balanceOf(B), 200_000_000 ether);
    }

    function testFuzz_AllowanceAndTransfersConserveSupply(uint256 raw, bool infinite) public {
        uint256 amount = bound(raw, 0, token.totalSupply());
        vm.prank(B);
        token.approve(ALICE, infinite ? type(uint256).max : amount);
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(B, BOB, amount);
        vm.prank(ALICE);
        token.transferFrom(B, BOB, amount);
        eq(token.allowance(B, ALICE), infinite ? type(uint256).max : 0);
        eq(token.balanceOf(B) + token.balanceOf(BOB), token.totalSupply());
        vm.prank(BOB);
        token.transfer(BOB, amount);
        eq(token.balanceOf(BOB), amount);
        vm.prank(BOB);
        token.transfer(B, amount);
        eq(token.balanceOf(B), token.totalSupply());
    }

    function test_RevertsAreAtomicAndNoExtraMintOrUpgradeEntryPoints() public {
        vm.prank(B);
        token.approve(ALICE, 5);
        vm.expectRevert();
        vm.prank(ALICE);
        token.transferFrom(B, BOB, 6);
        eq(token.allowance(B, ALICE), 5);
        eq(token.balanceOf(BOB), 0);
        vm.expectRevert();
        vm.prank(ALICE);
        token.transfer(BOB, 1);
        vm.expectRevert(bytes("Zero address"));
        vm.prank(B);
        token.transfer(address(0), 1);
        vm.expectRevert(bytes("Zero spender"));
        token.approve(address(0), 1);
        (bool minted,) = address(token).call(abi.encodeWithSignature("mint(address,uint256)", ALICE, 1));
        (bool upgraded,) = address(token).call(abi.encodeWithSignature("upgradeTo(address)", ALICE));
        yes(!minted && !upgraded);
        eq(token.balanceOf(B), token.totalSupply());
    }
}

contract WorkTransferHandler is WorkTestBase {
    Work public immutable token;
    address[4] public actors = [B, ALICE, BOB, CAROL];

    constructor(Work token_) {
        token = token_;
    }

    function transfer(uint256 from, uint256 to, uint256 raw) external {
        address sender = actors[from % 4];
        address receiver = actors[to % 4];
        uint256 amount = bound(raw, 0, token.balanceOf(sender));
        vm.prank(sender);
        token.transfer(receiver, amount);
    }

    function delegatedTransfer(uint256 from, uint256 to, uint256 raw, bool infinite) external {
        address sender = actors[from % 4];
        address receiver = actors[to % 4];
        uint256 amount = bound(raw, 0, token.balanceOf(sender));
        vm.prank(sender);
        token.approve(address(this), infinite ? type(uint256).max : amount);
        token.transferFrom(sender, receiver, amount);
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 50
/// forge-config: default.invariant.fail-on-revert = true
contract WorkInvariantTest is WorkTestBase {
    Work internal token;
    WorkTransferHandler internal handler;

    function setUp() public {
        vm.prank(B);
        token = new Work();
        handler = new WorkTransferHandler(token);
    }

    function targetContracts() external view returns (address[] memory targets) {
        targets = new address[](1);
        targets[0] = address(handler);
    }

    function invariant_FixedSupplyAndNoLostBalances() public view {
        eq(token.totalSupply(), 1_000_000_000 ether);
        eq(
            token.balanceOf(B) + token.balanceOf(ALICE) + token.balanceOf(BOB) + token.balanceOf(CAROL),
            token.totalSupply()
        );
        eq(token.balanceOf(address(0)), 0);
    }
}

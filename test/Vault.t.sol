// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/Vault.sol";

contract VaultTest is Test {
    using SafeERC20 for IERC20;

    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    IERC20 public usdt;
    IStargatePool public lpToken;
    IERC20 public stgToken;
    IStargateRouter public stargateRouter;
    IStargateFarm public stargateFarm;
    uint256 public poolId;
    uint256 public farmId;

    Vault public vault;

    function setUp() public {
        usdt = IERC20(0xdAC17F958D2ee523a2206206994597C13D831ec7);
        lpToken = IStargatePool(0x38EA452219524Bb87e18dE1C24D3bB59510BD783);
        stgToken = IERC20(0xAf5191B0De278C7286d6C7CC6ab6BB8A73bA2Cd6);
        stargateRouter = IStargateRouter(0x8731d54E9D02c286767d56ac03e8037C07e01e98);
        stargateFarm = IStargateFarm(0xB0D502E938ed5f4df2E681fE6E419ff29631d62b);
        poolId = 2;
        farmId = 1;

        vault = new Vault(
            "USDT Vault",
            "vUSDT",
            usdt,
            lpToken,
            stgToken,
            stargateRouter,
            stargateFarm,
            poolId,
            farmId
        );

        deal(address(usdt), alice, 10_000 * 1e6);
        deal(address(usdt), bob, 10_000 * 1e6);
        assertEq(usdt.balanceOf(alice), 10_000 * 1e6);
        assertEq(usdt.balanceOf(bob), 10_000 * 1e6);
    }

    function deposit(uint256 amount) public {
        usdt.safeApprove(address(vault), 0);
        usdt.safeApprove(address(vault), amount);
        vault.deposit(amount, alice);
    }

    function testTotalAssets() public {
        uint256 totalAssets = vault.totalAssets();
        assertEq(totalAssets, 0);
    }

    function testDeposit() public {
        startHoax(alice);

        uint256 amount = 10_000 * 1e6;
        deposit(amount);
        assertEq(usdt.balanceOf(alice), 0);
        assertEq(vault.balanceOf(alice), amount);
        assertApproxEqAbs(vault.totalAssets(), amount, 1);

        vm.stopPrank();
    }

    function testWithdraw() public {
        startHoax(alice);

        uint256 amount = 10_000 * 1e6;
        deposit(amount);

        skip(10 days);

        uint256 withdrawAmount = amount / 2;
        vault.withdraw(withdrawAmount, alice, alice);
        assertApproxEqAbs(usdt.balanceOf(alice), withdrawAmount, 1);
        assertApproxEqAbs(vault.balanceOf(alice), amount - withdrawAmount, 1);
        assertApproxEqAbs(vault.totalAssets(), amount - withdrawAmount, 1);

        vm.stopPrank();
    }
}

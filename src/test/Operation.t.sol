// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/console.sol";
import {Setup, ERC20, IStrategyInterface} from "./utils/Setup.sol";

contract OperationTest is Setup {
    function setUp() public virtual override {
        super.setUp();
    }

    function test_setupStrategyOK() public {
        console.log("address of strategy", address(strategy));
        assertTrue(address(0) != address(strategy));
        assertEq(strategy.asset(), address(asset));
        assertEq(strategy.management(), management);
        assertEq(strategy.performanceFeeRecipient(), performanceFeeRecipient);
        assertEq(strategy.keeper(), keeper);
        // TODO: add additional check on strat params
    }

    function test_claim_and_swap(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);
        console.log("Amount deposited:", _amount);
        console.log("Total Assets:", strategy.totalAssets());
        console.log("Claimable:", strategy.claimableBalance());
        console.log("Unexchanged Balance:", strategy.unexchangedBalance());
        console.log("Exchangable Balance:", transmuter.getExchangedBalance(address(strategy)));
        console.log("Total Unexchanged:", transmuter.totalUnexchanged());
        console.log("Total Buffered:", transmuter.totalBuffered());

        assertApproxEq(strategy.totalAssets(), _amount, _amount / 500);
        vm.roll(1);

        deployMockYieldToken();
        console.log("Deployed Mock Yield Token");
        addMockYieldToken();
        console.log("Added Mock Yield Token");
        depositToAlchemist(_amount);
        console.log("Deposited to Alchemist");
        airdropToMockYield(_amount / 2);
        console.log("Airdropped to Mock Yield");


        /*
        airdrop(underlying, address(transmuterKeeper), _amount);
        vm.prank(transmuterKeeper);
        underlying.approve(address(transmuterBuffer), _amount);
        */

        vm.prank(whale);
        asset.transfer(user2, _amount);

        vm.prank(user2);
        asset.approve(address(transmuter), _amount);
        
        vm.prank(user2);
        transmuter.deposit(_amount /2 , user2);

        vm.roll(1);
        harvestMockYield();

        vm.prank(address(transmuterKeeper));
        transmuterBuffer.exchange(address(underlying));

        //Note : link to Transmuter tests https://github.com/alchemix-finance/v2-foundry/blob/reward-collector-fix/test/TransmuterV2.spec.ts
        skip(7 days);
        vm.roll(5);

        vm.prank(user2);
        transmuter.deposit(_amount /2 , user2);

        vm.prank(address(transmuterKeeper));
        transmuterBuffer.exchange(address(underlying));

        console.log("Skip 7 days");
        console.log("Claimable:", strategy.claimableBalance());
        console.log("Unexchanged Balance:", strategy.unexchangedBalance());
        console.log("Exchangable Balance:", transmuter.getExchangedBalance(address(strategy)));
        console.log("Total Unexchanged:", transmuter.totalUnexchanged());
        console.log("Total Buffered:", transmuter.totalBuffered());

        assertGt(strategy.claimableBalance(), 0, "!claimableBalance");
        assertEq(strategy.totalAssets(), _amount);
        uint256 claimable = strategy.claimableBalance();

        // we do this as oracle needs swap to be done recently
        //smallCurveSwap();

        skip(1 seconds);
        vm.roll(1);

        vm.prank(keeper);
        strategy.claimAndSwap(claimable, claimable * 108 / 100);
        // check balances post swap
        console.log("Claimable:", strategy.claimableBalance());
        console.log("Unexchanged Balance:", strategy.unexchangedBalance());
        console.log("Exchangable Balance:", transmuter.getExchangedBalance(address(strategy)));
        console.log("Total Unexchanged:", transmuter.totalUnexchanged());
        console.log("Total Assets in Strategy:", strategy.totalAssets());
        console.log("Free Assets in Strategy:", asset.balanceOf(address(strategy)));
        console.log("Underlying in Strategy:", underlying.balanceOf(address(strategy)));

        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.report();

        assertEq(strategy.claimableBalance(), 0, "!claimableBalance");
        assertGt(strategy.totalAssets(), _amount, "!totalAssets");

    }


    function test_operation(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        assertApproxEq(strategy.totalAssets(), _amount, _amount / 500);

        // Earn Interest
        skip(1 days);

        // Report profit
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.report();

        // // Check return Values
        // assertGe(profit, 0, "!profit");
        // assertEq(loss, 0, "!loss");

        skip(strategy.profitMaxUnlockTime());

        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        assertGe(
            asset.balanceOf(user),
            balanceBefore + _amount,
            ""
        );
    }

    function test_profitableReport(
        uint256 _amount,
        uint16 _profitFactor
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);
        _profitFactor = uint16(bound(uint256(_profitFactor), 10, MAX_BPS));

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

        // Earn Interest
        skip(1 days);

        // TODO: implement logic to simulate earning interest.
        uint256 toAirdrop = (_amount * _profitFactor) / MAX_BPS;
        airdrop(asset, address(strategy), toAirdrop);

        // Report profit
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.report();

        // Check return Values
        assertGe(profit, toAirdrop, "!profit");
        assertEq(loss, 0, "!loss");

        skip(strategy.profitMaxUnlockTime());

        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_amount, user, user);
        console.log("Amount:", _amount);
        assertGe(
            asset.balanceOf(user),
            balanceBefore + _amount,
            "!final balance"
        );
    }

    function test_profitableReport_withFees(
        uint256 _amount,
        uint16 _profitFactor
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);
        _profitFactor = uint16(bound(uint256(_profitFactor), 10, MAX_BPS));

        // Set protocol fee to 0 and perf fee to 10%
        setFees(0, 1_000);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

        // Earn Interest
        skip(1 days);

        // TODO: implement logic to simulate earning interest.
        uint256 toAirdrop = (_amount * _profitFactor) / MAX_BPS;
        airdrop(asset, address(strategy), toAirdrop);

        // Report profit
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.report();

        // Check return Values
        assertGe(profit, toAirdrop, "!profit");
        assertEq(loss, 0, "!loss");

        skip(strategy.profitMaxUnlockTime());

        // Get the expected fee
        uint256 expectedShares = (profit * 1_000) / MAX_BPS;

        assertEq(strategy.balanceOf(performanceFeeRecipient), expectedShares);

        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        console.log("Amount:", _amount);
        assertGe(
            asset.balanceOf(user),
            balanceBefore + _amount,
            "!final balance"
        );

        vm.prank(performanceFeeRecipient);
        strategy.redeem(
            expectedShares,
            performanceFeeRecipient,
            performanceFeeRecipient
        );

        checkStrategyTotals(strategy, 0, 0, 0);

        assertGe(
            asset.balanceOf(performanceFeeRecipient),
            expectedShares,
            "!perf fee out"
        );
    }

    function test_tendTrigger(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        (bool trigger, ) = strategy.tendTrigger();
        assertTrue(!trigger);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        (trigger, ) = strategy.tendTrigger();
        assertTrue(!trigger);

        // Skip some time
        skip(1 days);

        (trigger, ) = strategy.tendTrigger();
        assertTrue(!trigger);

        vm.prank(keeper);
        strategy.report();

        (trigger, ) = strategy.tendTrigger();
        assertTrue(!trigger);

        // Unlock Profits
        skip(strategy.profitMaxUnlockTime());

        (trigger, ) = strategy.tendTrigger();
        assertTrue(!trigger);

        vm.prank(user);
        strategy.redeem(_amount, user, user);

        (trigger, ) = strategy.tendTrigger();
        assertTrue(!trigger);
    }
}

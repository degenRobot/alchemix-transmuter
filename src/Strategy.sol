// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.18;

import {BaseStrategy, ERC20} from "@tokenized-strategy/BaseStrategy.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ITransmuter} from "./interfaces/ITransmuter.sol";
import {ICurveStableSwapNG} from "./interfaces/ICurve.sol";

// Import interfaces for many popular DeFi projects, or add your own!
//import "../interfaces/<protocol>/<Interface>.sol";

/**
 * The `TokenizedStrategy` variable can be used to retrieve the strategies
 * specific storage data your contract.
 *
 *       i.e. uint256 totalAssets = TokenizedStrategy.totalAssets()
 *
 * This can not be used for write functions. Any TokenizedStrategy
 * variables that need to be updated post deployment will need to
 * come from an external call from the strategies specific `management`.
 */

// NOTE: To implement permissioned functions you can use the onlyManagement, onlyEmergencyAuthorized and onlyKeepers modifiers

contract Strategy is BaseStrategy {
    using SafeERC20 for ERC20;

    ITransmuter public transmuter;
    ICurveStableSwapNG public curvePool;
    int128 public assetIndex;
    int128 public underlyingIndex;

    // Target % of reserves to keep liquid for withdrawals 
    uint256 public targetReserve = 0;
    uint256 public slippageContraint = 9600;
    uint256 public bps = 10000;

    // since the asset is ALETH, we need to set the underlying to WETH
    ERC20 public underlying; 
    bool public useOracle;

    // 0 = Curve, 1 = Velo, 2 = Ramses 
    uint public routerType;

    constructor(
        address _asset,
        address _transmuter,
        uint _routerType,
        bool _useOracle,
        string memory _name
    ) BaseStrategy(_asset, _name) {
        transmuter = ITransmuter(0x03323143a5f0D0679026C2a9fB6b0391e4D64811);
        require(transmuter.syntheticToken() == _asset, "Asset does not match transmuter synthetic token");
        routerType = _routerType;
        useOracle = _useOracle;
        underlying = ERC20(transmuter.underlyingToken());
        _initStrategy();
    }

    function _initStrategy() internal {
        curvePool = ICurveStableSwapNG(0x8eFD02a0a40545F32DbA5D664CbBC1570D3FedF6);

        assetIndex = 0;
        underlyingIndex = 1;

        asset.safeApprove(address(transmuter), type(uint256).max);
        underlying.safeApprove(address(curvePool), type(uint256).max);
        
    }

    /**
     * @dev Can deploy up to '_amount' of 'asset' in the yield source.
     *
     * This function is called at the end of a {deposit} or {mint}
     * call. Meaning that unless a whitelist is implemented it will
     * be entirely permissionless and thus can be sandwiched or otherwise
     * manipulated.
     *
     * @param _amount The amount of 'asset' that the strategy can attempt
     * to deposit in the yield source.
     */
    function _deployFunds(uint256 _amount) internal override {

        uint256 totalAssets = balanceDeployed() + asset.balanceOf(address(this));
        uint256 targetReserveAmount = totalAssets * targetReserve / bps;

        if (targetReserveAmount < (asset.balanceOf(address(this)))) {
            uint256 amountToDeposit = asset.balanceOf(address(this)) - targetReserveAmount;
            transmuter.deposit(amountToDeposit, address(this));
        }
    }

    function claimAndSwap(uint256 _amountClaim, uint256 _minOut) external onlyKeepers {
        transmuter.claim(_amountClaim, address(this));
        _swapUnderlyingToAsset(_amountClaim, _minOut);
        transmuter.deposit(asset.balanceOf(address(this)), address(this));
    }


    function _swapUnderlyingToAsset(uint256 _amount, uint256 minOut) internal {
        // TODO : we swap WETH to ALETH -> need to check that price is better than 1:1 
        // uint256 oraclePrice = 1e18 * 101 / 100;
        require(minOut > _amount, "minOut too low");

        if (useOracle) {
            uint256 oraclePrice = curvePool.price_oracle(0);
            uint256 minDy = (_amount * oraclePrice / 1e18) * slippageContraint / bps;
            if (minDy < _amount) {
                minDy = _amount;
            }
            require(minOut > minDy, "minDy too low");

        }

        uint256 underlyingBalance = underlying.balanceOf(address(this));
        require(underlyingBalance >= _amount, "not enough underlying balance");
        curvePool.exchange(underlyingIndex, assetIndex, _amount, minOut, address(this));
        
        }

    }

    /**
     * @dev Should attempt to free the '_amount' of 'asset'.
     *
     * NOTE: The amount of 'asset' that is already loose has already
     * been accounted for.
     *
     * This function is called during {withdraw} and {redeem} calls.
     * Meaning that unless a whitelist is implemented it will be
     * entirely permissionless and thus can be sandwiched or otherwise
     * manipulated.
     *
     * Should not rely on asset.balanceOf(address(this)) calls other than
     * for diff accounting purposes.
     *
     * Any difference between `_amount` and what is actually freed will be
     * counted as a loss and passed on to the withdrawer. This means
     * care should be taken in times of illiquidity. It may be better to revert
     * if withdraws are simply illiquid so not to realize incorrect losses.
     *
     * @param _amount, The amount of 'asset' to be freed.
     */
    function _freeFunds(uint256 _amount) internal override {
        uint256 totalAvailabe = transmuter.getUnexchangedBalance(address(this)) + asset.balanceOf(address(this));
        if (_amount > totalAvailabe) {
            transmuter.withdraw(totalAvailabe, address(this));
        } else {
            transmuter.withdraw(_amount, address(this));
        }
    }


    function balanceDeployed() public view returns (uint256) {
        return transmuter.getUnexchangedBalance(address(this)) + underlying.balanceOf(address(this)) + asset.balanceOf(address(this));
    }

    /**
     * @dev Internal function to harvest all rewards, redeploy any idle
     * funds and return an accurate accounting of all funds currently
     * held by the Strategy.
     *
     * This should do any needed harvesting, rewards selling, accrual,
     * redepositing etc. to get the most accurate view of current assets.
     *
     * NOTE: All applicable assets including loose assets should be
     * accounted for in this function.
     *
     * Care should be taken when relying on oracles or swap values rather
     * than actual amounts as all Strategy profit/loss accounting will
     * be done based on this returned value.
     *
     * This can still be called post a shutdown, a strategist can check
     * `TokenizedStrategy.isShutdown()` to decide if funds should be
     * redeployed or simply realize any profits/losses.
     *
     * @return _totalAssets A trusted and accurate account for the total
     * amount of 'asset' the strategy currently holds including idle funds.
     */
    function _harvestAndReport()
        internal
        override
        returns (uint256 _totalAssets)
    {

        uint256 claimable = transmuter.getClaimableBalance(address(this));

        if (claimable > 0) {
            // transmuter.claim(claimable, address(this));
        }

        // NOTE : we can do this in harvest or can do seperately in tend 
        // if (underlying.balanceOf(address(this)) > 0) {
        //     _swapUnderlyingToAsset(underlying.balanceOf(address(this)));
        // }
        
        uint256 unexchanged = transmuter.getUnexchangedBalance(address(this));

        // NOTE : possible some dormant WETH that isn't swapped yet 
        uint256 underlyingBalance = underlying.balanceOf(address(this));

        _totalAssets = unexchanged + asset.balanceOf(address(this)) + underlyingBalance;
    }

    /*//////////////////////////////////////////////////////////////
                    OPTIONAL TO OVERRIDE BY STRATEGIST
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Gets the max amount of `asset` that can be withdrawn.
     * @dev Defaults to an unlimited amount for any address. But can
     * be overridden by strategists.
     *
     * This function will be called before any withdraw or redeem to enforce
     * any limits desired by the strategist. This can be used for illiquid
     * or sandwichable strategies.
     *
     *   EX:
     *       return asset.balanceOf(yieldSource);
     *
     * This does not need to take into account the `_owner`'s share balance
     * or conversion rates from shares to assets.
     *
     * @param . The address that is withdrawing from the strategy.
     * @return . The available amount that can be withdrawn in terms of `asset`
     */

    function availableWithdrawLimit(
        address /*_owner*/
    ) public view override returns (uint256) {
        // NOTE: Withdraw limitations such as liquidity constraints should be accounted for HERE
        //  rather than _freeFunds in order to not count them as losses on withdraws.

        // TODO: If desired implement withdraw limit logic and any needed state variables.

        // EX:
        // if(yieldSource.notShutdown()) {
        //    return asset.balanceOf(address(this)) + asset.balanceOf(yieldSource);
        // }
        // NOTE : claimable balance can only be included if we are actually allowing swaps to happen on withdrawals
        //uint256 claimable = transmuter.getClaimableBalance(address(this));
        
        return asset.balanceOf(address(this)) + transmuter.getUnexchangedBalance(address(this));
    }

    function claimableBalance() public view returns (uint256) {
        return transmuter.getClaimableBalance(address(this));
    }

    function unexchangedBalance() public view returns (uint256) {
        return transmuter.getUnexchangedBalance(address(this));
    }
    

    /**
     * @notice Gets the max amount of `asset` that an address can deposit.
     * @dev Defaults to an unlimited amount for any address. But can
     * be overridden by strategists.
     *
     * This function will be called before any deposit or mints to enforce
     * any limits desired by the strategist. This can be used for either a
     * traditional deposit limit or for implementing a whitelist etc.
     *
     *   EX:
     *      if(isAllowed[_owner]) return super.availableDepositLimit(_owner);
     *
     * This does not need to take into account any conversion rates
     * from shares to assets. But should know that any non max uint256
     * amounts may be converted to shares. So it is recommended to keep
     * custom amounts low enough as not to cause overflow when multiplied
     * by `totalSupply`.
     *
     * @param . The address that is depositing into the strategy.
     * @return . The available amount the `_owner` can deposit in terms of `asset`
     *
    function availableDepositLimit(
        address _owner
    ) public view override returns (uint256) {
        TODO: If desired Implement deposit limit logic and any needed state variables .
        
        EX:    
            uint256 totalAssets = TokenizedStrategy.totalAssets();
            return totalAssets >= depositLimit ? 0 : depositLimit - totalAssets;
    }
    */

    /**
     * @dev Optional function for strategist to override that can
     *  be called in between reports.
     *
     * If '_tend' is used tendTrigger() will also need to be overridden.
     *
     * This call can only be called by a permissioned role so may be
     * through protected relays.
     *
     * This can be used to harvest and compound rewards, deposit idle funds,
     * perform needed position maintenance or anything else that doesn't need
     * a full report for.
     *
     *   EX: A strategy that can not deposit funds without getting
     *       sandwiched can use the tend when a certain threshold
     *       of idle to totalAssets has been reached.
     *
     * This will have no effect on PPS of the strategy till report() is called.
     *
     * @param _totalIdle The current amount of idle funds that are available to deploy.
     *
    function _tend(uint256 _totalIdle) internal override {}
    */

    /**
     * @dev Optional trigger to override if tend() will be used by the strategy.
     * This must be implemented if the strategy hopes to invoke _tend().
     *
     * @return . Should return true if tend() should be called by keeper or false if not.
     *
    function _tendTrigger() internal view override returns (bool) {}
    */

    /**
     * @dev Optional function for a strategist to override that will
     * allow management to manually withdraw deployed funds from the
     * yield source if a strategy is shutdown.
     *
     * This should attempt to free `_amount`, noting that `_amount` may
     * be more than is currently deployed.
     *
     * NOTE: This will not realize any profits or losses. A separate
     * {report} will be needed in order to record any profit/loss. If
     * a report may need to be called after a shutdown it is important
     * to check if the strategy is shutdown during {_harvestAndReport}
     * so that it does not simply re-deploy all funds that had been freed.
     *
     * EX:
     *   if(freeAsset > 0 && !TokenizedStrategy.isShutdown()) {
     *       depositFunds...
     *    }
     *
     * @param _amount The amount of asset to attempt to free.
     *
    function _emergencyWithdraw(uint256 _amount) internal override {
        TODO: If desired implement simple logic to free deployed funds.

        EX:
            _amount = min(_amount, aToken.balanceOf(address(this)));
            _freeFunds(_amount);
    }

    */
}

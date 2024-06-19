// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.18;

import "forge-std/console.sol";
import {ExtendedTest} from "./ExtendedTest.sol";

import {Strategy, ERC20} from "../../Strategy.sol";
import {IStrategyInterface} from "../../interfaces/IStrategyInterface.sol";
import {IWhitelist} from "../../interfaces/IWhitelist.sol";

// Inherit the events so they can be checked if desired.
import {IEvents} from "@tokenized-strategy/interfaces/IEvents.sol";

import {ITransmuter} from "../../interfaces/ITransmuter.sol";
import {ITransmuterBuffer} from "../../interfaces/ITransmuterBuffer.sol";
import {IAlchemist} from "../../interfaces/IAlchemist.sol";

import {YieldTokenMock} from "../../mock/YieldTokenMock.sol";
import {TokenAdapterMock} from "../../mock/TokenAdapterMock.sol";

import {ICurveStableSwapNG} from "../../interfaces/ICurve.sol";


interface IFactory {
    function governance() external view returns (address);

    function set_protocol_fee_bps(uint16) external;

    function set_protocol_fee_recipient(address) external;
}

contract Setup is ExtendedTest, IEvents {
    // Contract instances that we will use repeatedly.
    ERC20 public asset;
    // Underlying ERC20 of AL Token -> we will use this to interact with transmuter to allow exchanges
    // I.e. as per : https://github.com/alchemix-finance/v2-foundry/blob/reward-collector-fix/test/TransmuterV2.spec.ts
    ERC20 public underlying;
    IStrategyInterface public strategy;
    IWhitelist public whitelist;

    ITransmuter public transmuter;
    ITransmuterBuffer public transmuterBuffer;
    IAlchemist public alchemist;

    mapping(string => address) public tokenAddrs;

    // Addresses for different roles we will use repeatedly.
    address public user = address(10);
    address public user2 = address(9);
    address public keeper = address(4);
    address public management = address(1);
    address public mockYieldToken;
    address public yieldToken = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;

    address public performanceFeeRecipient = address(3);
    address public buffer = 0xbc2FB245594a68c927C930FBE2d00680A8C90B9e;
    address public whale = 0xBD28e1B15EcbE72706A445f77bd17FCd8Fe6f652;
    address public transmuterKeeper;

    // Address of the real deployed Factory
    address public factory;

    // Integer variables that will be used repeatedly.
    uint256 public decimals;
    uint256 public MAX_BPS = 10_000;

    // Fuzz from $0.01 of 1e6 stable coins up to 1 trillion of a 1e18 coin
    uint256 public maxFuzzAmount = 1e19;
    uint256 public minFuzzAmount = 1e17;

    // Default profit max unlock time is set for 10 days
    uint256 public profitMaxUnlockTime = 10 days;

    function setUp() public virtual {
        _setTokenAddrs();

        // Set asset
        asset = ERC20(0x0100546F2cD4C9D97f798fFC9755E47865FF7Ee6);
        underlying = ERC20(tokenAddrs["WETH"]);

        // Set decimals
        decimals = asset.decimals();

        // Deploy strategy and set variables
        
        transmuter = ITransmuter(0x03323143a5f0D0679026C2a9fB6b0391e4D64811);
        transmuterBuffer = ITransmuterBuffer(0xbc2FB245594a68c927C930FBE2d00680A8C90B9e);
        alchemist = IAlchemist(0x062Bf725dC4cDF947aa79Ca2aaCCD4F385b13b5c);
        transmuterKeeper = 0x9e2b6378ee8ad2A4A95Fe481d63CAba8FB0EBBF9;

        strategy = IStrategyInterface(setUpStrategy());

        // whitelist hte strategy
        whitelist = IWhitelist(0x211C74DB951c161c5A379363716EbDca5125EF59);
        vm.prank(whitelist.owner());
        whitelist.add(address(strategy));

        vm.prank(whitelist.owner());
        whitelist.add(user2);

        factory = strategy.FACTORY();

        // label all the used addresses for traces
        vm.label(keeper, "keeper");
        vm.label(factory, "factory");
        vm.label(address(asset), "asset");
        vm.label(management, "management");
        vm.label(address(strategy), "strategy");
        vm.label(performanceFeeRecipient, "performanceFeeRecipient");
    }

    function setUpStrategy() public returns (address) {
        // we save the strategy as a IStrategyInterface to give it the needed interface
        IStrategyInterface _strategy = IStrategyInterface(
            address(new Strategy(
                address(asset),
                address(transmuter),
                0,
                true,
                "Tokenized Strategy"))
        );

        // set keeper
        _strategy.setKeeper(keeper);
        // set treasury
        _strategy.setPerformanceFeeRecipient(performanceFeeRecipient);
        // set management of the strategy
        _strategy.setPendingManagement(management);

        vm.prank(management);
        _strategy.acceptManagement();

        return address(_strategy);
    }

    function depositIntoStrategy(
        IStrategyInterface _strategy,
        address _user,
        uint256 _amount
    ) public {
        vm.prank(_user);
        asset.approve(address(_strategy), _amount);

        vm.prank(_user);
        _strategy.deposit(_amount, _user);
    }

    function mintAndDepositIntoStrategy(
        IStrategyInterface _strategy,
        address _user,
        uint256 _amount
    ) public {
        //airdrop(asset, _user, _amount);
        vm.prank(whale);
        asset.transfer(_user, _amount);
        
        depositIntoStrategy(_strategy, _user, _amount);
    }

    // For checking the amounts in the strategy
    function checkStrategyTotals(
        IStrategyInterface _strategy,
        uint256 _totalAssets,
        uint256 _totalDebt,
        uint256 _totalIdle
    ) public {
        uint256 _assets = _strategy.totalAssets();
        uint256 _balance = ERC20(_strategy.asset()).balanceOf(
            address(_strategy)
        );
        uint256 _idle = _balance > _assets ? _assets : _balance;
        uint256 _debt = _assets - _idle;
        assertEq(_assets, _totalAssets, "!totalAssets");
        assertEq(_debt, _totalDebt, "!totalDebt");
        assertEq(_idle, _totalIdle, "!totalIdle");
        assertEq(_totalAssets, _totalDebt + _totalIdle, "!Added");
    }

    function airdrop(ERC20 _asset, address _to, uint256 _amount) public {
        uint256 balanceBefore = _asset.balanceOf(_to);
        deal(address(_asset), _to, balanceBefore + _amount);
    }

    function setFees(uint16 _protocolFee, uint16 _performanceFee) public {
        address gov = IFactory(factory).governance();

        // Need to make sure there is a protocol fee recipient to set the fee.
        vm.prank(gov);
        IFactory(factory).set_protocol_fee_recipient(gov);

        vm.prank(gov);
        IFactory(factory).set_protocol_fee_bps(_protocolFee);

        vm.prank(management);
        strategy.setPerformanceFee(_performanceFee);
    }

    function _setTokenAddrs() internal {
        tokenAddrs["WBTC"] = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
        tokenAddrs["YFI"] = 0x0bc529c00C6401aEF6D220BE8C6Ea1667F6Ad93e;
        tokenAddrs["WETH"] = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
        tokenAddrs["LINK"] = 0x514910771AF9Ca656af840dff83E8264EcF986CA;
        tokenAddrs["USDT"] = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
        tokenAddrs["DAI"] = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
        tokenAddrs["USDC"] = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    }

    function deployMockYieldToken() public {
        mockYieldToken = address(
            new YieldTokenMock("Mock Yield Token", "MYT", underlying)
        );
    }

    function addMockYieldToken() public {

        address adapter = address(new TokenAdapterMock(mockYieldToken));

        vm.prank(transmuterKeeper);
        alchemist.addYieldToken(mockYieldToken, IAlchemist.YieldTokenConfig(adapter, 1,  type(uint256).max, 1));

        vm.prank(transmuterKeeper);
        alchemist.setYieldTokenEnabled(mockYieldToken, true);
    }

    function depositToAlchemist(uint256 _amount) public {
        airdrop(underlying, user2, _amount);
        vm.prank(user2);
        underlying.approve(address(alchemist), _amount);

        address _whitelist = alchemist.whitelist();
        address owner = IWhitelist(_whitelist).owner();

        vm.prank(owner);
        IWhitelist(_whitelist).add(user2);

        vm.prank(user2);
        alchemist.depositUnderlying(mockYieldToken, _amount, user2, 0);

        //vm.prank(user2);
        //alchemist.mint(_amount * 7 / 10, user2);

    }

    function airdropToMockYield(uint256 _amount) public {
        airdrop(underlying, mockYieldToken, _amount);
    }

    function harvestMockYield() public {
        vm.prank(transmuterKeeper);
        alchemist.harvest(mockYieldToken, 0);
    }

    function smallCurveSwap() public {

        uint256 smallAmount = 1e10;

        airdrop(underlying, user2, smallAmount);
        address curvePool = 0x8eFD02a0a40545F32DbA5D664CbBC1570D3FedF6;
        vm.prank(user2);
        underlying.approve(curvePool, smallAmount);

        ICurveStableSwapNG(curvePool).exchange(1, 0, smallAmount, 0, address(this));

    }


}

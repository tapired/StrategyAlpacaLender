// SPDX-License-Identifier: AGPL-3.0
// Feel free to change the license, but this is what we use

pragma solidity ^0.8.12;
pragma experimental ABIEncoderV2;

// These are the core Yearn libraries
import {BaseStrategy, StrategyParams} from "@yearnvaults/contracts/BaseStrategy.sol";

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20Metadata} from "@yearnvaults/contracts/yToken.sol";

import {IibToken} from "../interfaces/alpaca/IibToken.sol";
import {IFairLaunch} from "../interfaces/alpaca/IFairLaunch.sol"; // a.k.a masterchef
import {ITradeFactory} from "../interfaces/ySwaps/ITradeFactory.sol";
import {INative} from "../interfaces/native/INative.sol";
import {IAggregatorV3} from "../interfaces/chainlink/IAggregatorV3.sol";

contract Strategy is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;

    IibToken public ibToken;
    uint256 public farmId;
    IFairLaunch public alpacaFarm =
        IFairLaunch(0x838B7F64Fa89d322C563A6f904851A13a164f84C);

    // reward token
    IERC20 public constant ALPACA_TOKEN =
        IERC20(0xaD996A45fd2373ed0B10Efa4A8eCB9de445A4302);

    // to differentiate the want since withdrawals on wftm pools unwraps the wftm which the process
    // of withdrawing is different than other assets
    IERC20 public constant WFTM =
        IERC20(0x21be370D5312f44cB42ce377BC9b8a0cEF1A4C83);

    // want/usd price feed, setted at constructor
    // if setted as address(0) it will default to 1e18 (DAI/USDC/USDT cases)
    IAggregatorV3 private immutable WANT_PRICE_FEED;

    // alpaca/usd price feed
    IAggregatorV3 private constant ALPACA_PRICE_FEED =
        IAggregatorV3(0x95d3FFf86A754AB81A7c59FcaB1468A2076f8C9b);

    // keeper stuff
    // 18 decimal dolar value (like DAI)
    uint256 public harvestProfitMin; // minimum size in dolars (18 decimals) that we want to harvest
    uint256 public harvestProfitMax; // maximum size in dolars (18 decimals) that we want to harvest
    uint256 public creditThreshold; // amount of credit in underlying tokens that will automatically trigger a harvest
    uint256 public lastTimeETA; // what was the estimated total assets at the latest harvest (FOR KEEPERS LOGIC)
    bool internal forceHarvestTriggerOnce; // only set this to true when we want to trigger our keepers to harvest for us

    address public tradeFactory = address(0);

    constructor(
        address _vault,
        address _ibToken,
        uint256 _farmId,
        address _WANT_PRICE_FEED
    ) BaseStrategy(_vault) {
        require(
            IibToken(_ibToken).token() == address(want),
            "IB token underlying is not want"
        );
        require(
            address(alpacaFarm.stakingToken(_farmId)) == address(_ibToken),
            "Wrong ID"
        );

        ibToken = IibToken(_ibToken);
        farmId = _farmId;

        WANT_PRICE_FEED = IAggregatorV3(_WANT_PRICE_FEED);
        harvestProfitMin = 100 * 1e18; // every 100$ harvest, remember alpaca-wftm pool is not big to absorve big swaps so we swap often rather than bulk
        harvestProfitMax = 300 * 1e18; // 300$ is max
        creditThreshold = 10_000 * 1e18;
        maxReportDelay = 10 days; // 10 days in seconds, if we hit this then harvestTrigger = True

        IERC20(want).safeApprove(_ibToken, type(uint256).max);
        IERC20(_ibToken).safeApprove(address(alpacaFarm), type(uint256).max);
    }

    // ******** OVERRIDE THESE METHODS FROM BASE CONTRACT ************

    function name() external view override returns (string memory) {
        return
            string(
                abi.encodePacked(
                    "StrategyAlpacaLender",
                    IERC20Metadata(address(want)).symbol()
                )
            );
    }

    function balanceOfWant() public view returns (uint256) {
        return want.balanceOf(address(this));
    }

    function balanceOfLP() public view returns (uint256) {
        return IERC20(address(ibToken)).balanceOf(address(this));
    }

    function balanceOfLPInFarm() public view returns (uint256) {
        return alpacaFarm.userInfo(farmId, address(this)).amount;
    }

    function getVirtualPrice() public view returns (uint256) {
        return (ibToken.totalToken() * 1e18) / ibToken.totalSupply(); // 18 decimal precision
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        uint256 farmingBal = (balanceOfLPInFarm() * getVirtualPrice()) / 1e18;
        uint256 idleBal = (balanceOfLP() * getVirtualPrice()) / 1e18;
        return farmingBal + idleBal + balanceOfWant();
    }

    function pendingALPACA() public view returns (uint256) {
        return alpacaFarm.pendingAlpaca(farmId, address(this));
    }

    // return 18 decimal 1 want token price in terms of USD
    // if price feed address is 0 this will default return 1e18 (DAI/USDC/USDT cases)
    function getWantToUSD() public view returns (uint256) {
        if (address(WANT_PRICE_FEED) == address(0)) return 1e18;
        (
            ,
            /*uint80 roundID*/
            int256 price, /*uint startedAt*/ /*uint timeStamp*/ /*uint80 answeredInRound*/
            ,
            ,

        ) = WANT_PRICE_FEED.latestRoundData();
        uint256 decimals = WANT_PRICE_FEED.decimals();
        return uint256(price) * 10**(18 - decimals);
    }

    // return 18 decimal 1 alpaca price in terms of USD
    function getAlpacaToUSD() public view returns (uint256) {
        (
            ,
            /*uint80 roundID*/
            int256 price, /*uint startedAt*/ /*uint timeStamp*/ /*uint80 answeredInRound*/
            ,
            ,

        ) = ALPACA_PRICE_FEED.latestRoundData();
        uint256 decimals = ALPACA_PRICE_FEED.decimals();
        return uint256(price) * 10**(18 - decimals);
    }

    // 18 decimal dolar value of profits
    function claimableProfitInUSD() public view returns (uint256) {
        uint256 alpacasToUSD = (getAlpacaToUSD() * pendingALPACA()) / 1e18; // 18 decimal
        uint256 swapFeeProfitsToUSD = estimatedTotalAssets() - lastTimeETA; // if underflow then dont harvest its too soon

        swapFeeProfitsToUSD = (swapFeeProfitsToUSD * getWantToUSD()) / 1e18; // in USD
        return swapFeeProfitsToUSD + alpacasToUSD;
    }

    /* ========== KEEP3RS ========== */
    // use this to determine when to harvest
    function harvestTrigger(uint256 callCostinEth)
        public
        view
        override
        returns (bool)
    {
        // Should not trigger if strategy is not active (no assets and no debtRatio). This means we don't need to adjust keeper job.
        if (!isActive()) {
            return false;
        }

        // harvest if we have a profit to claim at our upper limit without considering gas price
        uint256 claimableProfit = claimableProfitInUSD();
        if (claimableProfit > harvestProfitMax) {
            return true;
        }

        // check if the base fee gas price is higher than we allow. if it is, block harvests.
        // if (!isBaseFeeAcceptable()) {
        //     return false;
        // }

        // trigger if we want to manually harvest, but only if our gas price is acceptable
        if (forceHarvestTriggerOnce) {
            return true;
        }

        // harvest if we have a sufficient profit to claim, but only if our gas price is acceptable
        if (claimableProfit > harvestProfitMin) {
            return true;
        }

        StrategyParams memory params = vault.strategies(address(this));
        // harvest no matter what once we reach our maxDelay
        if ((block.timestamp - params.lastReport) > maxReportDelay) {
            return true;
        }

        // harvest our credit if it's above our threshold
        if (vault.creditAvailable() > creditThreshold) {
            return true;
        }

        // otherwise, we don't harvest
        return false;
    }

    // Min profit to start checking for harvests if gas is good, max will harvest no matter gas (both in USDT, 6 decimals). Credit threshold is in want token, and will trigger a harvest if credit is large enough. check earmark to look at convex's booster.
    function setHarvestTriggerParams(
        uint256 _harvestProfitMin,
        uint256 _harvestProfitMax,
        uint256 _creditThreshold
    ) external onlyVaultManagers {
        harvestProfitMin = _harvestProfitMin;
        harvestProfitMax = _harvestProfitMax;
        creditThreshold = _creditThreshold;
    }

    function prepareReturn(uint256 _debtOutstanding)
        internal
        override
        returns (
            uint256 _profit,
            uint256 _loss,
            uint256 _debtPayment
        )
    {
        require(tradeFactory != address(0), "Trade factory must be set.");

        uint256 debt = vault.strategies(address(this)).totalDebt;
        uint256 assets = estimatedTotalAssets();
        if (debt > assets) {
            _loss = debt - assets;
        } else {
            _profit = assets - debt;
        }

        uint256 toLiquidate = _debtOutstanding + _profit;
        if (toLiquidate > 0) {
            (uint256 _amountFreed, uint256 _withdrawalLoss) = liquidatePosition(
                toLiquidate
            );
            _debtPayment = Math.min(_debtOutstanding, _amountFreed);
            _loss = _loss + _withdrawalLoss;
        }

        lastTimeETA = estimatedTotalAssets(); // for keepers

        // net out PnL
        if (_profit > _loss) {
            unchecked {
                _profit = _profit - _loss;
            }
            _loss = 0;
        } else {
            unchecked {
                _loss = _loss - _profit;
            }
            _profit = 0;
        }
    }

    function adjustPosition(uint256 _debtOutstanding) internal override {
        uint256 wantBalance = balanceOfWant();
        if (wantBalance > _debtOutstanding) {
            // supply to the pool get more ib tokens
            uint256 toDeposit = wantBalance - _debtOutstanding;
            ibToken.deposit(toDeposit);
        }
        uint256 ibTokenBal = balanceOfLP();
        if (ibTokenBal > 0) {
            // stake ib Tokens to earn ALPACA
            alpacaFarm.deposit(address(this), farmId, ibTokenBal);
        }
    }

    function claimRewards() external onlyVaultManagers {
        if (pendingALPACA() > 0) {
            alpacaFarm.harvest(farmId);
        } else {
            revert("No rewards to claim");
        }
    }

    function liquidatePosition(uint256 _amountNeeded)
        internal
        override
        returns (uint256 _liquidatedAmount, uint256 _loss)
    {
        uint256 wantBalance = balanceOfWant();
        if (wantBalance > _amountNeeded) {
            // if there is enough free want, let's use it
            return (_amountNeeded, 0);
        }

        // we need to free funds
        uint256 amountRequired = _amountNeeded - wantBalance;
        _withdrawSome(amountRequired);
        uint256 freeAssets = balanceOfWant();
        if (_amountNeeded > freeAssets) {
            _liquidatedAmount = freeAssets;
            unchecked {
                _loss = _amountNeeded - _liquidatedAmount;
            }
        } else {
            _liquidatedAmount = _amountNeeded;
        }
    }

    function _withdrawSome(uint256 _amountWant) internal {
        uint256 actualWithdrawn = Math.min(
            (_amountWant * 1e18) / getVirtualPrice(),
            balanceOfLPInFarm()
        );
        alpacaFarm.withdraw(address(this), farmId, actualWithdrawn);

        // when we withdraw from ib we got unwrapped version of the native token
        if (want == WFTM) {
            uint256 ftmBalance = address(this).balance;
            ibToken.withdraw(actualWithdrawn);
            ftmBalance = address(this).balance - ftmBalance;
            INative(address(want)).deposit{value: ftmBalance}();
        } else {
            uint256 wantBal = balanceOfWant();
            ibToken.withdraw(actualWithdrawn);
            wantBal = balanceOfWant() - wantBal;
        }
    }

    function liquidateAllPositions() internal override returns (uint256) {
        alpacaFarm.withdraw(address(this), farmId, balanceOfLPInFarm());
        ibToken.withdraw(balanceOfLP());

        if (want == WFTM) {
            uint256 ftmBalance = address(this).balance;
            INative(address(want)).deposit{value: ftmBalance}();
        }
        return want.balanceOf(address(this));
    }

    function prepareMigration(address _newStrategy) internal override {
        uint256 lpBalFarming = balanceOfLPInFarm();
        if (lpBalFarming > 0) {
            // withdraw unstakes all LP
            alpacaFarm.withdraw(address(this), farmId, lpBalFarming);
        }
        // take the rewards with us
        alpacaFarm.harvest(farmId);
        ALPACA_TOKEN.safeTransfer(
            _newStrategy,
            ALPACA_TOKEN.balanceOf(address(this))
        );
        IERC20(address(ibToken)).safeTransfer(_newStrategy, balanceOfLP());
    }

    function protectedTokens()
        internal
        view
        override
        returns (address[] memory)
    // solhint-disable-next-line no-empty-blocks
    {

    }

    /**
     * @notice
     *  Provide an accurate conversion from `_amtInWei` (denominated in wei)
     *  to `want` (using the native decimal characteristics of `want`).
     * @dev
     *  Care must be taken when working with decimals to assure that the conversion
     *  is compatible. As an example:
     *
     *      given 1e17 wei (0.1 ETH) as input, and want is USDC (6 decimals),
     *      with USDC/ETH = 1800, this should give back 1800000000 (180 USDC)
     *
     * @param _amtInWei The amount (in wei/1e-18 ETH) to convert to `want`
     * @return The amount in `want` of `_amtInEth` converted to `want`
     **/
    function ethToWant(uint256 _amtInWei)
        public
        view
        virtual
        override
        returns (uint256)
    {
        // TODO create an accurate price oracle
        return _amtInWei;
    }

    // ----------------- YSWAPS FUNCTIONS ---------------------

    function setTradeFactory(address _tradeFactory) external onlyGovernance {
        if (tradeFactory != address(0)) {
            _removeTradeFactoryPermissions();
        }

        // approve and set up trade factory
        ALPACA_TOKEN.safeApprove(_tradeFactory, type(uint256).max);
        ITradeFactory tf = ITradeFactory(_tradeFactory);
        tf.enable(address(ALPACA_TOKEN), address(want));
        tradeFactory = _tradeFactory;
    }

    function removeTradeFactoryPermissions() external onlyEmergencyAuthorized {
        _removeTradeFactoryPermissions();
    }

    function _removeTradeFactoryPermissions() internal {
        ALPACA_TOKEN.safeApprove(tradeFactory, 0);
        tradeFactory = address(0);
    }

    receive() external payable {}
}

from brownie import Contract, Wei
from zrx_swap import zrx_swap
import brownie

import pytest
import eth_utils

def test_profitable_harvest(
    chain,
    token,
    vault,
    strategy,
    user,
    strategist,
    amount,
    RELATIVE_APPROX,
    trade_factory,
    ymechs_safe,
    prepare_trade_factory,
    alpaca_token,
    zrx_swapper,
    gov
):

    # Deposit to the vault
    user_balance_before = token.balanceOf(user)
    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})
    assert token.balanceOf(vault.address) == amount

    # harvest
    chain.sleep(1)
    chain.mine(1)
    strategy.harvest({"from": strategist})
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount

    # make profit
    chain.sleep(86400 * 5)
    chain.mine(1)

    yswap(chain, strategy, token, zrx_swapper, alpaca_token, ymechs_safe, gov, prepare_trade_factory, trade_factory)

    tx = strategy.harvest({"from": strategist})
    print(tx.events)
    assert tx.events["Harvested"]["profit"] > 0
    print(strategy.estimatedTotalAssets())


def test_remove_trade_factory_token(strategy, gov, trade_factory, alpaca_token, prepare_trade_factory):
    assert strategy.tradeFactory() == trade_factory.address
    assert alpaca_token.allowance(strategy.address, trade_factory.address) > 0

    strategy.removeTradeFactoryPermissions({"from": gov})

    assert strategy.tradeFactory() != trade_factory.address
    assert alpaca_token.allowance(strategy.address, trade_factory.address) == 0

def test_harvest_reverts_without_trade_factory(strategy, gov, user, vault, token, chain, amount):
    # Deposit to the vault
    user_balance_before = token.balanceOf(user)
    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})
    assert token.balanceOf(vault.address) == amount

    # harvest
    chain.sleep(1)
    chain.mine(1)
    with brownie.reverts("Trade factory must be set."):
        strategy.harvest()

###################################################################################################


def yswap(chain, strategy, token, zrx_swapper, alpaca_token, ymechs_safe, gov, prepare_trade_factory, trade_factory):
    strategy.claimRewards({"from":gov})
    # locked profit
    chain.sleep(86400)
    chain.mine(1)

    token_in = alpaca_token
    token_out = token
    receiver = strategy.address
    amount_in = token_in.balanceOf(strategy)
    assert (amount_in > 0)

    asyncTradeExecutionDetails = [strategy, token_in, token_out, amount_in, 1]
    swap_data = zrx_swap.getDefaultQuote(str(token), str(alpaca_token), amount_in)

    trade_factory.execute["tuple,address,bytes"](
        asyncTradeExecutionDetails,
        zrx_swapper.address,
        swap_data,
        {"from": ymechs_safe}
    )

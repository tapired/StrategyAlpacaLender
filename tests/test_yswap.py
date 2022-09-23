from brownie import Contract, Wei
import brownie
from eth_abi import encode_single, encode_abi
from brownie.convert import to_bytes
from eth_abi.packed import encode_abi_packed
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
    unirouter,
    gov,
    multicall_swapper
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
    chain.mine(100)
    print(strategy.estimatedTotalAssets())

    yswap(
        chain,
        strategy,
        token,
        unirouter,
        alpaca_token,
        ymechs_safe,
        gov,
        prepare_trade_factory,
        trade_factory,
        multicall_swapper
    )

    tx = strategy.harvest({"from": strategist})
    assert tx.events["Harvested"]["profit"] > 0
    print(strategy.estimatedTotalAssets())

def test_remove_trade_factory_token(
    strategy, gov, trade_factory, alpaca_token, prepare_trade_factory
):
    assert strategy.tradeFactory() == trade_factory.address
    assert alpaca_token.allowance(strategy.address, trade_factory.address) > 0

    strategy.removeTradeFactoryPermissions({"from": gov})

    assert strategy.tradeFactory() != trade_factory.address
    assert alpaca_token.allowance(strategy.address, trade_factory.address) == 0


def test_harvest_reverts_without_trade_factory(
    strategy, gov, user, vault, token, chain, amount
):
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


def yswap(
    chain,
    strategy,
    token,
    unirouter,
    alpaca_token,
    ymechs_safe,
    gov,
    prepare_trade_factory,
    trade_factory,
    multicall_swapper
):
    strategy.claimRewards({"from": gov})

    token_in = alpaca_token
    token_out = token
    receiver = strategy.address
    amount_in = token_in.balanceOf(strategy)
    assert amount_in > 0

    asyncTradeExecutionDetails = [strategy, token_in, token_out, amount_in, 1]
    optimizations = [["uint8"], [5]]
    a = optimizations[0]
    b = optimizations[1]

    calldata = token_in.approve.encode_input(unirouter, amount_in)
    t = createTx(token_in, calldata)
    a = a + t[0]
    b = b + t[1]

    path = [token_in.address, token_out.address]
    calldata = unirouter.swapExactTokensForTokens.encode_input(
        amount_in, 0, path, multicall_swapper, 2 ** 256 - 1
    )
    t = createTx(unirouter, calldata)
    a = a + t[0]
    b = b + t[1]

    expectedOut = unirouter.getAmountsOut(amount_in, path)[1]

    calldata = token_out.transfer.encode_input(receiver, expectedOut)
    t = createTx(token_out, calldata)
    a = a + t[0]
    b = b + t[1]

    transaction = encode_abi_packed(a, b)

    trade_factory.execute["tuple,address,bytes"](
        asyncTradeExecutionDetails,
        multicall_swapper.address,
        transaction,
        {"from": ymechs_safe},
    )

def createTx(to, data):
    inBytes = eth_utils.to_bytes(hexstr=data)
    return [["address", "uint256", "bytes"], [to.address, len(inBytes), inBytes]]

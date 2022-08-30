import pytest
from brownie import config
from brownie import Contract


@pytest.fixture
def gov(accounts):
    yield accounts.at("0xFEB4acf3df3cDEA7399794D0869ef76A6EfAff52", force=True)


@pytest.fixture
def user(accounts):
    yield accounts[0]


@pytest.fixture
def rewards(accounts):
    yield accounts[1]


@pytest.fixture
def guardian(accounts):
    yield accounts[2]


@pytest.fixture
def management(accounts):
    yield accounts[3]


@pytest.fixture
def strategist(accounts):
    yield accounts[4]


@pytest.fixture
def keeper(accounts):
    yield accounts[5]


@pytest.fixture
def token():
    token_address = "0x21be370D5312f44cB42ce377BC9b8a0cEF1A4C83"  # WFTM
    yield Contract(token_address)


@pytest.fixture
def amount(accounts, token, user):
    amount = 10_000 * 10 ** token.decimals()
    # In order to get some funds for the token you are about to use,
    # it impersonate an exchange address to use it's funds.
    reserve = accounts.at("0x431e81E5dfB5A24541b5Ff8762bDEF3f32F96354", force=True)
    token.transfer(user, amount, {"from": reserve})
    yield amount


# @pytest.fixture
# def weth():
#     token_address = "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2"
#     yield Contract(token_address)

@pytest.fixture
def ib_token():
    ib_token_address = "0xc1018f4Bba361A1Cc60407835e156595e92EF7Ad" #ibFTM
    yield Contract(ib_token_address)

@pytest.fixture
def alpaca_token():
    alpaca_token_address = '0xaD996A45fd2373ed0B10Efa4A8eCB9de445A4302'
    yield Contract(alpaca_token_address)

@pytest.fixture
def want_price_feed():
    want_price_feed_address = '0xf4766552D15AE4d256Ad41B6cf2933482B0680dc'
    yield Contract(want_price_feed_address)


# @pytest.fixture
# def weth_amout(user, weth):
#     weth_amout = 10 ** weth.decimals()
#     user.transfer(weth, weth_amout)
#     yield weth_amout


@pytest.fixture
def vault(pm, gov, rewards, guardian, management, token):
    Vault = pm(config["dependencies"][0]).Vault
    vault = guardian.deploy(Vault)
    vault.initialize(token, gov, rewards, "", "", guardian, management)
    vault.setDepositLimit(2 ** 256 - 1, {"from": gov})
    vault.setManagement(management, {"from": gov})
    yield vault


@pytest.fixture
def strategy(strategist, keeper, vault, Strategy, gov, ib_token, want_price_feed):
    strategy = strategist.deploy(Strategy, vault, ib_token, 1, want_price_feed)
    strategy.setKeeper(keeper)
    vault.addStrategy(strategy, 10_000, 0, 2 ** 256 - 1, 1_000, {"from": gov})
    yield strategy


#### YSWAP THINGS ###
@pytest.fixture
def trade_factory():
    yield Contract("0xD3f89C21719Ec5961a3E6B0f9bBf9F9b4180E9e9")


@pytest.fixture
def ymechs_safe():
    yield Contract("0x9f2A061d6fEF20ad3A656e23fd9C814b75fd5803")

@pytest.fixture
def zrx_swapper():
    yield Contract('0x0a94017DF3f8981Da97D79c28b103bAbDa0D67C7')

@pytest.fixture
def prepare_trade_factory(strategy, trade_factory, ymechs_safe, gov):
    trade_factory.grantRole(
    trade_factory.STRATEGY(),
    strategy.address,
    {"from": ymechs_safe, "gas_price": "0 gwei"},
    )
    strategy.setTradeFactory(trade_factory.address, {"from": gov})
#########

@pytest.fixture(scope="session")
def RELATIVE_APPROX():
    yield 1e-5

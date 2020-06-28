const FiatToken = artifacts.require("FiatTokenV1");
const dTokenAddresses = artifacts.require("dTokenAddresses");
const LendingPoolCore = artifacts.require("AaveLendingPoolCoreMock");
const LendPool = artifacts.require("AaveLendPoolMock");
const aTokenMock = artifacts.require("aTokenMock");
const AaveHandler = artifacts.require("AaveHandler");
const truffleAssert = require("truffle-assertions");
const BN = require("bn.js");
const UINT256_MAX = new BN(2).pow(new BN(256)).sub(new BN(1));
const BASE = new BN(10).pow(new BN(18));

describe("AaveHandlerMock contract", function () {
  let owner, account1, account2, account3, account4;
  let USDC, aUSDC;
  let handler;
  let dtoken_addresses;
  let mock_dtoken = "0x0000000000000000000000000000000000000001";

  before(async function () {
    [
      owner,
      account1,
      account2,
      account3,
      account4,
    ] = await web3.eth.getAccounts();
  });

  async function resetContracts() {
    dtoken_addresses = await dTokenAddresses.new();
    USDC = await FiatToken.new("USDC", "USDC", "USD", 6, owner, owner, owner, {
      from: owner,
    });

    // Deploys Aave system
    lending_pool_core = await LendingPoolCore.new();
    aUSDC = await aTokenMock.new(
      "aUSDC",
      "aUSDC",
      USDC.address,
      lending_pool_core.address
    );
    await lending_pool_core.setReserveATokenAddress(
      USDC.address,
      aUSDC.address
    );
    lending_pool = await LendPool.new(lending_pool_core.address);

    handler = await AaveHandler.new(
      dtoken_addresses.address,
      lending_pool.address,
      lending_pool_core.address
    );

    await handler.approve(USDC.address);

    await dtoken_addresses.setdTokensRelation([USDC.address], [mock_dtoken]);
    await handler.enableTokens([USDC.address]);
  }

  describe("Deployment", function () {
    it("Should deployed and only initialized once", async function () {
      await resetContracts();

      await truffleAssert.reverts(
        handler.initialize(
          dtoken_addresses.address,
          lending_pool.address,
          lending_pool_core.address,
          {
            from: owner,
          }
        ),
        "initialize: Already initialized!"
      );
    });
  });

  describe("setdTokens", function () {
    it("Should only allow auth to set dTokens", async function () {
      let new_dtoken_addresses = await dTokenAddresses.new();
      await handler.setdTokens(new_dtoken_addresses.address);

      await truffleAssert.reverts(
        handler.setdTokens(new_dtoken_addresses.address, {
          from: account1,
        }),
        "ds-auth-unauthorized"
      );
    });

    it("Should not allow set dTokens with the same address", async function () {
      await truffleAssert.reverts(
        handler.setdTokens(await handler.dTokens()),
        "setdTokens: The same dToken mapping contract address!"
      );
    });
  });

  describe("disableToken/enableToken", function () {
    before(async function () {
      await resetContracts();
    });

    it("Should only allow auth to disable token", async function () {
      await handler.disableTokens([USDC.address]);
      assert.equal(await handler.tokenIsEnabled(USDC.address), false);

      await truffleAssert.reverts(
        handler.disableTokens([USDC.address], {
          from: account1,
        }),
        "ds-auth-unauthorized"
      );
    });

    it("Should not allow to disable token already disabled", async function () {
      await truffleAssert.reverts(
        handler.disableTokens([USDC.address]),
        "disableToken: Has been disabled!"
      );
    });

    it("Should only allow auth to enable token", async function () {
      await handler.enableTokens([USDC.address]);
      assert.equal(await handler.tokenIsEnabled(USDC.address), true);

      await truffleAssert.reverts(
        handler.enableTokens([USDC.address], {
          from: account1,
        }),
        "ds-auth-unauthorized"
      );
    });

    it("Should not allow to enable token already enabled", async function () {
      await truffleAssert.reverts(
        handler.enableTokens([USDC.address]),
        "enableToken: Has been enabled!"
      );
    });
  });

  describe("setLendingPoolCore", async function () {
    before(async function () {
      await resetContracts();
    });

    it("Should only allow auth to setLendingPoolCore", async function () {
      await handler.setLendingPoolCore(lending_pool_core.address);

      await truffleAssert.reverts(
        handler.setLendingPoolCore(lending_pool_core.address, {
          from: account1,
        }),
        "ds-auth-unauthorized"
      );
    });
  });

  describe("setLendingPool", async function () {
    before(async function () {
      await resetContracts();
    });

    it("Should only allow auth to setLendingPool", async function () {
      await handler.setLendingPool(lending_pool.address);

      await truffleAssert.reverts(
        handler.setLendingPool(lending_pool.address, {
          from: account1,
        }),
        "ds-auth-unauthorized"
      );
    });
  });

  describe("approve", async function () {
    before(async function () {
      await resetContracts();
    });

    it("Should only allow auth to approve", async function () {
      await handler.approve(USDC.address);
      let allowance = await USDC.allowance(handler.address, mock_dtoken);
      assert.equal(allowance.eq(UINT256_MAX), true);

      await truffleAssert.reverts(
        handler.approve(USDC.address, {
          from: account1,
        }),
        "ds-auth-unauthorized"
      );
    });
  });

  describe("deposit", function () {
    before(async function () {
      await resetContracts();
      await handler.approve(USDC.address);
    });

    it("Should only allow auth to deposit", async function () {
      let amount = await handler.deposit(USDC.address, 1000e6);

      //TODO: Check return value from transaction
      //console.log(JSON.stringify(amount));
      //assert.equal(amount.eq(new BN(1000e6)), true);

      await truffleAssert.reverts(
        handler.deposit(USDC.address, 1000e6, {
          from: account1,
        }),
        "ds-auth-unauthorized"
      );
    });

    it("Should not deposit with disabled token", async function () {
      await truffleAssert.reverts(
        handler.deposit(mock_dtoken, 1000e6),
        "deposit: Token is disabled!"
      );
    });

    it("Should not deposit when paused", async function () {
      await handler.pause();
      await truffleAssert.reverts(
        handler.deposit(USDC.address, 1000e6),
        "whenNotPaused: paused"
      );

      await handler.unpause();
    });

    it("Should not deposit 0 amount", async function () {
      await truffleAssert.reverts(
        handler.deposit(USDC.address, 0),
        "deposit: Deposit amount should be greater than 0!"
      );
    });

    it("!! TODO: Should not be able to reenter", async function () {});

    it("Check the actual deposit amount with some interest", async function () {
      let iteration = 20;
      for (let i = 0; i < iteration; i++) {
        let amount = new BN(123456789);
        await USDC.allocateTo(handler.address, amount);

        // Mock some interest, so the exchange rate would change
        await aUSDC.updateBalance(BASE.div(new BN("10")));

        let balanceBefore = await handler.getBalance(USDC.address);

        await handler.deposit(USDC.address, amount);

        let balanceAfter = await handler.getBalance(USDC.address);
        let changed = balanceAfter.sub(balanceBefore);

        //TODO: Check return value from transaction
        //console.log(balanceBefore.toString(), balanceAfter.toString());
        assert.equal(changed.toString(), amount.toString());
      }
    });
  });

  describe("withdraw", function () {
    beforeEach(async function () {
      await resetContracts();
      await USDC.allocateTo(handler.address, 100000e6, {
        from: owner,
      });
      await handler.deposit(USDC.address, 10000e6);
    });

    it("Should only allow auth to withdraw", async function () {
      let amount = await handler.withdraw(USDC.address, 10000e6);

      //TODO: Check returen value from transaction
      //console.log(JSON.stringify(amount));
      //assert.equal(amount.eq(new BN(1000e6)), true);

      await truffleAssert.reverts(
        handler.withdraw(USDC.address, 1000e6, {
          from: account1,
        }),
        "ds-auth-unauthorized"
      );
    });

    it("Should not withdraw with disabled token", async function () {
      await truffleAssert.reverts(
        handler.withdraw(mock_dtoken, 1000e6),
        "withdraw: Do not support token!"
      );
    });

    it("Should not withdraw when paused", async function () {
      await handler.pause();
      await truffleAssert.reverts(
        handler.withdraw(USDC.address, 1000e6),
        "whenNotPaused: paused"
      );
    });

    it("Should not withdraw 0 amount", async function () {
      await truffleAssert.reverts(
        handler.withdraw(USDC.address, 0),
        "withdraw: Withdraw amount should be greater than 0!"
      );
    });

    it("!! TODO: Should not be able to reenter", async function () {});

    it("Check the actual withdraw amount with some interest", async function () {
      let iteration = 20;
      for (let i = 0; i < iteration; i++) {
        let amount = new BN(123456789);

        // Mock some interest, so the exchange rate would change
        await aUSDC.updateBalance(BASE.div(new BN("10")));

        let balanceBefore = await handler.getBalance(USDC.address);

        await handler.withdraw(USDC.address, amount);

        let balanceAfter = await handler.getBalance(USDC.address);
        let changed = balanceBefore.sub(balanceAfter);

        //TODO: Check return value from transaction
        //console.log(balanceBefore.toString(), balanceAfter.toString());
        assert.equal(changed.toString(), amount.toString());
      }
    });
  });

  describe("getBalance", function () {
    beforeEach(async function () {
      await resetContracts();
      await USDC.allocateTo(handler.address, 100000e6, {
        from: owner,
      });
      await handler.deposit(USDC.address, 100000e6);
    });

    it("Should get some balance", async function () {
      let balance = await handler.getBalance(USDC.address);
      assert.equal(balance.toString(), 100000e6);
    });
  });

  describe("getUnderlyingBalance", function () {
    beforeEach(async function () {
      await resetContracts();
      await USDC.allocateTo(handler.address, 100000e6, {
        from: owner,
      });
      await handler.deposit(USDC.address, 100000e6);
    });

    it("Should get underlying balance", async function () {
      // Mock 10% interest, so the underlying balance would grow
      await aUSDC.updateBalance(BASE.div(new BN("10")));

      let balance = await handler.getBalance(USDC.address);
      assert.equal(balance.toString(), 110000e6);
    });
  });

  describe("getLiquidity", function () {
    beforeEach(async function () {
      await resetContracts();
      await USDC.allocateTo(handler.address, 100000e6, {
        from: owner,
      });
      await handler.deposit(USDC.address, 100000e6);
    });

    it("Should get some liquidity", async function () {
      let balance = await handler.getLiquidity(USDC.address);
      assert.equal(balance.toString(), 100000e6);
    });
  });

  describe("getRealBalance", function () {
    beforeEach(async function () {
      await resetContracts();
      await handler.deposit(USDC.address, 1000e6);
    });

    it("Should get some real balance", async function () {
      let balance = await handler.getRealBalance(USDC.address);

      //TODO: Check returen value from transaction
      //console.log(JSON.stringify(balance));
      //assert.equal(balance.eq(new BN(1000e6)), true);
    });
  });

  describe("getRealLiquidity", function () {
    beforeEach(async function () {
      await resetContracts();
      await USDC.allocateTo(handler.address, 100000e6, {
        from: owner,
      });
      await handler.deposit(USDC.address, 100000e6);
    });

    it("Should get real liquidity", async function () {
      let realLiquidity = await handler.getRealLiquidity(USDC.address);
      assert.equal(realLiquidity.toString(), 100000e6);
    });
  });

  describe("getaToken", function () {
    beforeEach(async function () {
      await resetContracts();
    });

    it("Should get the corresponding atoken", async function () {
      let atoken = await handler.getaToken(USDC.address);
      assert.equal(atoken, aUSDC.address);
    });
  });
});

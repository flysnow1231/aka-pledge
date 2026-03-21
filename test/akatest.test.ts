import { expect } from "chai";
import hre from "hardhat";
import { encodeFunctionData, parseUnits } from "viem";

describe("FixedRateDexLendingStateMachineUpgradeable", function () {
    async function latestTs(networkHelpers: any): Promise<bigint> {
        return BigInt(await networkHelpers.time.latest());
    }

    async function increaseToTs(networkHelpers: any, ts: bigint) {
        await networkHelpers.time.increaseTo(Number(ts));
    }

    async function deployFixture() {
        const connection = await hre.network.connect();
        const { viem, networkHelpers } = connection;

        const [admin, lender1, lender2, borrower1, borrower2, other] =
            await viem.getWalletClients();

        const lendToken = await viem.deployContract("MockERC20", [
            "USD Stable",
            "USDS",
            18,
        ]);

        const collateralToken = await viem.deployContract("MockERC20", [
            "Wrapped BTC",
            "WBTC",
            8,
        ]);

        const oracle = await viem.deployContract("MockOracle");
        const router = await viem.deployContract("MockUniswapV2Router");

        // 1 WBTC = 100,000 USDS
        const priceX18 = parseUnits("100000", 18);

        await oracle.write.setPrice([collateralToken.address, priceX18], {
            account: admin.account,
        });

        // await router.write.setPrice([collateralToken.address, priceX18], {
        //   account: admin.account,
        // });

        await lendToken.write.mint(
            [router.address, parseUnits("10000000", 18)],
            { account: admin.account }
          );
        // mint funds
        await lendToken.write.mint(
            [lender1.account.address, parseUnits("1000000", 18)],
            {
                account: admin.account,
            }
        );

        await lendToken.write.mint(
            [lender2.account.address, parseUnits("1000000", 18)],
            {
                account: admin.account,
            }
        );

        await collateralToken.write.mint(
            [borrower1.account.address, 10n * 10n ** 8n],
            {
                account: admin.account,
            }
        );

        await collateralToken.write.mint(
            [borrower2.account.address, 10n * 10n ** 8n],
            {
                account: admin.account,
            }
        );

        // deploy implementation
        const impl = await viem.deployContract(
            "AkaPledge"
        );

        const artifact = await hre.artifacts.readArtifact(
            "AkaPledge"
        );

        const initData = encodeFunctionData({
            abi: artifact.abi,
            functionName: "initialize",
            args: [admin.account.address],
        });

        // deploy proxy
        const proxy = await viem.deployContract("TestERC1967Proxy", [
            impl.address,
            initData,
        ]);

        const pledgeContract = await viem.getContractAt(
            "AkaPledge",
            proxy.address
        );

        return {
            viem,
            networkHelpers,
            admin,
            lender1,
            lender2,
            borrower1,
            borrower2,
            other,
            lendToken,
            collateralToken,
            oracle,
            router,
            pledgeContract,
            priceX18,
        };
    }

    async function createPool(env: Awaited<ReturnType<typeof deployFixture>>) {
        const now = await latestTs(env.networkHelpers);
        const settleTime = now + 3600n;
        const executionEndTime = settleTime + 30n * 24n * 3600n;

        await env.pledgeContract.write.createPool(
            [
                {
                    lendToken: env.lendToken.address,
                    collateralToken: env.collateralToken.address,
                    oracle: env.oracle.address,
                    router: env.router.address,
                    settleTime,
                    executionEndTime,
                    fixedInterestRateBps: 1000n, // 10% APR
                    collateralRatioBps: 15000n, // 150%
                    liquidationThresholdBps: 12000n, // 120%
                    protocolFeeBps: 1000n, // interest fee 10%
                    slippageBps: 500n, // 5%
                    spName: "SP Token",
                    spSymbol: "SP",
                    jpName: "JP Token",
                    jpSymbol: "JP",
                },
            ],
            {
                account: env.admin.account,
            }
        );

        return { poolId: 0n, settleTime, executionEndTime };
    }

    it("should initialize correctly through proxy", async function () {
        const { pledgeContract, admin } = await deployFixture();
        expect((await pledgeContract.read.admin()).toLowerCase())
            .to.equal(admin.account.address.toLowerCase());
    });

    it("should settle to UNDONE when only lender deposits", async function () {
        const env = await deployFixture();
        const { poolId, settleTime } = await createPool(env);

        const lendAmount = parseUnits("10000", 18);

        await env.lendToken.write.approve([env.pledgeContract.address, lendAmount], {
            account: env.lender1.account,
        });

        await env.pledgeContract.write.depositLend([poolId, lendAmount], {
            account: env.lender1.account,
        });

        await increaseToTs(env.networkHelpers, settleTime + 1n);

        await env.pledgeContract.write.settle([poolId], {
            account: env.admin.account,
        });

        expect(await env.pledgeContract.read.getPoolStage([poolId])).to.equal(1); // UNDONE

        const before = await env.lendToken.read.balanceOf([
            env.lender1.account.address,
        ]);

        await env.pledgeContract.write.refundLend([poolId], {
            account: env.lender1.account,
        });

        const after = await env.lendToken.read.balanceOf([
            env.lender1.account.address,
        ]);
        expect(after - before).to.equal(lendAmount);
    });


    it("should settle to EXECUTION ", async function () {
        const env = await deployFixture();
        const { poolId, settleTime } = await createPool(env);

        // lender deposits 100,000 stable
        const lendAmount = parseUnits("100000", 18);

        await env.lendToken.write.approve([env.pledgeContract.address, lendAmount], {
            account: env.lender1.account,
        });

        await env.pledgeContract.write.depositLend([poolId, lendAmount], {
            account: env.lender1.account,
        });

        // borrower deposits 1 WBTC = 100,000 stable value
        // with 150% collateral ratio, max loan = 66,666.666...
        const collAmount = 1n * 10n ** 8n;

        await env.collateralToken.write.approve([env.pledgeContract.address, collAmount], {
            account: env.borrower1.account,
        });

        await env.pledgeContract.write.depositBorrow([poolId, collAmount], {
            account: env.borrower1.account,
        });

        await increaseToTs(env.networkHelpers, settleTime + 1n);

        await env.pledgeContract.write.settle([poolId], {
            account: env.admin.account,
        });

        const stage = await env.pledgeContract.read.getPoolStage([poolId])
        expect(stage).to.equal(2); // EXECUTION
        console.log("after settle, stage is EXECUTION", stage);

        const totals = await env.pledgeContract.read.getPoolTotals([poolId]);
        const matchedPrincipal = totals[2];
        const unmatchedLendTotal = totals[4];
        const unmatchedCollateralTotal = totals[5];
        console.log("after settle, totals:", totals);
        expect(matchedPrincipal).to.be.gt(0);
        expect(unmatchedLendTotal).to.be.gt(0);
        expect(unmatchedCollateralTotal).to.gt(0);
    });



    it("should settle to EXECUTION and allow lender/borrower claim + refund", async function () {
        const env = await deployFixture();
        const { poolId, settleTime } = await createPool(env);

        // lender deposits 100,000 stable
        const lendAmount = parseUnits("100000", 18);

        await env.lendToken.write.approve([env.pledgeContract.address, lendAmount], {
            account: env.lender1.account,
        });

        await env.pledgeContract.write.depositLend([poolId, lendAmount], {
            account: env.lender1.account,
        });

        // borrower deposits 1 WBTC = 100,000 stable value
        // with 150% collateral ratio, max loan = 66,666.666...
        const collAmount = 1n * 10n ** 8n;

        await env.collateralToken.write.approve([env.pledgeContract.address, collAmount], {
            account: env.borrower1.account,
        });

        await env.pledgeContract.write.depositBorrow([poolId, collAmount], {
            account: env.borrower1.account,
        });

        await increaseToTs(env.networkHelpers, settleTime + 1n);

        await env.pledgeContract.write.settle([poolId], {
            account: env.admin.account,
        });
        const stage = await env.pledgeContract.read.getPoolStage([poolId])
        expect(stage).to.equal(2); // EXECUTION
        console.log("stage", stage);

        const totals = await env.pledgeContract.read.getPoolTotals([poolId]);
        const matchedPrincipal = totals[2];
        const unmatchedLendTotal = totals[4];
        const unmatchedCollateralTotal = totals[5];

        expect(Number(matchedPrincipal)).to.be.gt(0);
        expect(Number(unmatchedLendTotal)).to.be.gt(0);
        expect(Number(unmatchedCollateralTotal)).to.gt(0);

        // lender refund unmatched
        const lenderStableBefore = await env.lendToken.read.balanceOf([
            env.lender1.account.address,
        ]);
        await env.pledgeContract.write.refundLend([poolId], {
            account: env.lender1.account,
        });

        const lenderStableAfter = await env.lendToken.read.balanceOf([
            env.lender1.account.address,
        ]);

        expect(lenderStableAfter - lenderStableBefore).to.equal(unmatchedLendTotal);

        // lender claim SP
        await env.pledgeContract.write.claimLend([poolId], {
            account: env.lender1.account,
        });

        // borrower claim loan + JP
        const borrowerStableBefore = await env.lendToken.read.balanceOf([
            env.borrower1.account.address,
        ]);

        await env.pledgeContract.write.claimBorrow([poolId], {
            account: env.borrower1.account,
        });

        const borrowerStableAfter = await env.lendToken.read.balanceOf([
            env.borrower1.account.address,
        ]);

        expect(borrowerStableAfter - borrowerStableBefore).to.equal(matchedPrincipal);

        const certBalances = await env.pledgeContract.read.getUserCertificateBalances([
            poolId,
            env.borrower1.account.address,
        ]);

        expect(certBalances[1]).to.be.gt(0); // jp balance
    });

    it("should finish and allow lender / borrower withdraw", async function () {
        const env = await deployFixture();
        const { poolId, settleTime, executionEndTime } = await createPool(env);

        // lender deposits 100k
        const lendAmount = parseUnits("100000", 18);

        await env.lendToken.write.approve([env.pledgeContract.address, lendAmount], {
            account: env.lender1.account,
        });

        await env.pledgeContract.write.depositLend([poolId, lendAmount], {
            account: env.lender1.account,
        });

        // borrower deposits 2 WBTC
        const collAmount = 2n * 10n ** 8n;
        await env.collateralToken.write.approve([env.pledgeContract.address, collAmount], {
            account: env.borrower1.account,
        });

        await env.pledgeContract.write.depositBorrow([poolId, collAmount], {
            account: env.borrower1.account,
        });

        await increaseToTs(env.networkHelpers, settleTime + 1n);

        await env.pledgeContract.write.settle([poolId], {
            account: env.admin.account,
        });

        await env.pledgeContract.write.claimBorrow([poolId], {
            account: env.borrower1.account,
        });

        await env.pledgeContract.write.refundBorrow([poolId], {
            account: env.borrower1.account,
        });

        await env.pledgeContract.write.claimLend([poolId], {
            account: env.lender1.account,
        });

        const stage = await env.pledgeContract.read.getPoolStage([poolId]);

        const borrowerData = await env.pledgeContract.read.getUserBorrowerData([poolId, env.lender1.account.address]);
        const poolInfo = await env.pledgeContract.read.getPoolTotals([poolId]);
        console.log("should finish. after settle, poolInfo:", poolInfo);
        console.log("should finish. after settle, borrowerData:", borrowerData);

        // 到期
        await increaseToTs(env.networkHelpers, executionEndTime + 1n);

        const path = [env.collateralToken.address, env.lendToken.address] as const;

        //设置dex wbtc价格
        await env.router.write.setPrice([env.collateralToken.address, 
            env.lendToken.address, parseUnits("90000", 18)],
            {
                account: env.admin.account,
            });
        //设置预言机wbtc价格
        await env.oracle.write.setPrice([env.collateralToken.address, parseUnits("90000", 18)], {
            account: env.admin.account,
        });
       
        const routerStableBal = await env.lendToken.read.balanceOf([env.router.address]);
        console.log("routerStableBal", routerStableBal.toString());
        //finish
        await env.pledgeContract.write.finish([poolId, executionEndTime + 1000n, [env.collateralToken.address, env.lendToken.address], 0n], {
            account: env.admin.account,
        });

        expect(await env.pledgeContract.read.getPoolStage([poolId])).to.equal(3); // FINISH
        // lender withdraw
        const lenderBefore = await env.lendToken.read.balanceOf([
            env.lender1.account.address,
        ]);
        
        console.log("lenderBefore", lenderBefore.toString());   

        await env.pledgeContract.write.withdrawLend([poolId], {
            account: env.lender1.account,
        });

        const lenderAfter = await env.lendToken.read.balanceOf([
            env.lender1.account.address,
        ]);
        console.log("lenderAfter", lenderAfter.toString());
       
        expect(lenderAfter - lenderBefore).to.be.gt(0);

        // borrower withdraw remaining collateral / stable surplus
        const borrowerCollBefore = await env.collateralToken.read.balanceOf([
            env.borrower1.account.address,
        ]);
        console.log("borrowerCollBefore", borrowerCollBefore.toString());

        const borrowerStableBefore = await env.lendToken.read.balanceOf([
            env.borrower1.account.address,
        ]);
        console.log("borrowerStableBefore", borrowerStableBefore.toString()); 


        await env.pledgeContract.write.withdrawBorrow([poolId], {
            account: env.borrower1.account,
        });

        const borrowerCollAfter = await env.collateralToken.read.balanceOf([
            env.borrower1.account.address,
        ]);
        console.log("borrowerCollAfter", borrowerCollAfter.toString());

        const borrowerStableAfter = await env.lendToken.read.balanceOf([
            env.borrower1.account.address,
        ]);
    
        console.log("borrowerStableAfter", borrowerStableAfter.toString());   
       
        expect(
            borrowerCollAfter - borrowerCollBefore > 0 ||
            borrowerStableAfter - borrowerStableBefore > 0
        ).to.equal(true);
    });

      it("should liquidate when collateral ratio falls below threshold", async function () {
        const env = await deployFixture();
        const { poolId, settleTime } = await createPool(env);

        // lender deposits 100k
        const lendAmount = parseUnits("100000", 18);

        await env.lendToken.write.approve([env.pledgeContract.address, lendAmount], {
          account: env.lender1.account,
        });

        await env.pledgeContract.write.depositLend([poolId, lendAmount], {
          account: env.lender1.account,
        });

        // borrower deposits 1 WBTC
        const collAmount = 1n * 10n ** 8n;

        await env.collateralToken.write.approve([env.pledgeContract.address, collAmount], {
          account: env.borrower1.account,
        });

        await env.pledgeContract.write.depositBorrow([poolId, collAmount], {
          account: env.borrower1.account,
        });

        await increaseToTs(env.networkHelpers, settleTime + 1n);

        await env.pledgeContract.write.settle([poolId], {
          account: env.admin.account,
        });

        await env.pledgeContract.write.refundLend([poolId], {
          account: env.lender1.account,
        });

        await env.pledgeContract.write.claimLend([poolId], {
          account: env.lender1.account,
        });

        await env.pledgeContract.write.claimBorrow([poolId], {
          account: env.borrower1.account,
        });

        // 价格暴跌：1 WBTC = 70,000
        const lowPrice = parseUnits("70000", 18);

        await env.oracle.write.setPrice([env.collateralToken.address, lowPrice], {
          account: env.admin.account,
        });

        await env.router.write.setPrice([env.collateralToken.address, env.lendToken.address, lowPrice], {
          account: env.admin.account,
        });

        const now = await latestTs(env.networkHelpers);
        const path = [env.collateralToken.address, env.lendToken.address] as const;

        await env.pledgeContract.write.liquidate([poolId, now + 1000n, [...path], 0n], {
          account: env.admin.account,
        });

        expect(await env.pledgeContract.read.getPoolStage([poolId])).to.equal(4); // LIQUIDATION

        const lenderBefore = await env.lendToken.read.balanceOf([
          env.lender1.account.address,
        ]);

        await env.pledgeContract.write.withdrawLend([poolId], {
          account: env.lender1.account,
        });

        const lenderAfter = await env.lendToken.read.balanceOf([
          env.lender1.account.address,
        ]);

        expect(Number(lenderAfter) - Number(lenderBefore)).to.be.gt(0);
      });

      it("should revert when non-admin tries to create pool", async function () {
        const env = await deployFixture();
        const now = await latestTs(env.networkHelpers);

        let reverted = false;

        try {
          await env.pledgeContract.write.createPool(
            [
              {
                lendToken: env.lendToken.address,
                collateralToken: env.collateralToken.address,
                oracle: env.oracle.address,
                router: env.router.address,
                settleTime: now + 1000n,
                executionEndTime: now + 2000n,
                fixedInterestRateBps: 1000n,
                collateralRatioBps: 15000n,
                liquidationThresholdBps: 12000n,
                protocolFeeBps: 1000n,
                slippageBps: 500n,
                spName: "SP Token",
                spSymbol: "SP",
                jpName: "JP Token",
                jpSymbol: "JP",
              },
            ],
            {
              account: env.other.account,
            }
          );
        } catch (e: any) {
          reverted = true;
          expect(String(e)).to.include("NOT_ADMIN");
        }

        expect(reverted).to.equal(true);
      });
});
import { getEnv } from "./common.js";
import { parseUnits } from "viem";

async function main() {

  const env = await getEnv();
  const lender1 = env.admin;
  const borrower1 = env.user2;

  const now = Math.floor(Date.now() / 1000);

  const settleTime = BigInt(now + 200);
  const executionEndTime = BigInt(now + 600);

  const params = [
    env.lendToken.address,
    env.collateralToken.address,
    env.oracle.address,
    env.router.address,
    settleTime,
    executionEndTime,
    1000n,
    15000n,
    12000n,
    30n,
    500n,
    "Supply Position Token",
    "SPT",
    "Junior Position Token",
    "JPT",
  ] as const;
  console.log("create pool sepolia");


  const txHash = await env.pledgeProxy.write.createPool([params], {
    account: env.admin,
  });
  await env.publicClient.waitForTransactionReceipt({ hash: txHash });

  const after = await env.pledgeProxy.read.poolCount();
  env.poolId = after-1n;

  const borrowerCollBefore = await env.collateralToken.read.balanceOf([borrower1.address]);
  console.log("borrower collateral before:", borrowerCollBefore.toString());
  console.log("createPool 完成，继续:", Date.now() / 1000);
  const poolCount = (await env.pledgeProxy.read.getPoolTotals([env.poolId]));
  console.log("new poolId:", env.poolId);

  const mintBorrowerCollTx = await env.collateralToken.write.mint(
    [borrower1.address, parseUnits("10", 8)],
    { account: borrower1 }
  );

  await env.publicClient.waitForTransactionReceipt({ hash: mintBorrowerCollTx });

  await env.collateralToken.write.approve([env.pledgeProxy.address, parseUnits("10", 8)], { account: borrower1 });
  const depositBorrowTx = await env.pledgeProxy.write.depositBorrow([env.poolId, parseUnits("10", 8)], { account: borrower1});
  await env.publicClient.waitForTransactionReceipt({ hash: depositBorrowTx });
  console.log("deposit 完成，安全继续");
  const borrowerCollAfterBorrow = await env.collateralToken.read.balanceOf([borrower1.address]);
  console.log("borrower collateral after deposit borrow:", borrowerCollAfterBorrow.toString());


  const tx = await env.pledgeProxy.write.settle([env.poolId], {
    account: env.admin,
  });

  await env.publicClient.waitForTransactionReceipt({ hash: tx });
  console.log("settle完成", tx);

  const getPoolStage = await env.pledgeProxy.read.getPoolStage([env.poolId]);
  console.log("pool stage after settle:", getPoolStage.toString());

  if (getPoolStage.toString() === "1") {
    console.log("pool stage is 1 UNDONE, to liquidate");
    const refundLendTx = await env.pledgeProxy.write.refundBorrow([env.poolId], {
      account: borrower1,
    });
  }
  const getPoolStageAfter = await env.pledgeProxy.read.getPoolStage([env.poolId]);
  console.log("pool stage after:", getPoolStageAfter.toString());

}

main().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});

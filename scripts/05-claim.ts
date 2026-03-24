import { getEnv } from "./common.js";

async function main() {
  const env = await getEnv();
  const lender1 = env.admin;
  const borrower1 = env.user2;
  env.poolId=2n;
  const totals = await env.pledgeProxy.read.getPoolTotals([env.poolId]);
  console.log("pool totals before flow:", totals.map((x: bigint) => x.toString()));

  const lenderBefore = await env.lendToken.read.balanceOf([lender1.address]);
  const borrowerBefore = await env.collateralToken.read.balanceOf([borrower1.address]);

  const refundLendTx = await env.pledgeProxy.write.refundLend([env.poolId], {
    account: lender1,
  });
  console.log("refundLend tx:", refundLendTx);

  const claimLendTx = await env.pledgeProxy.write.claimLend([env.poolId], {
    account: lender1,
  });
  console.log("claimLend tx:", claimLendTx);

  const claimBorrowTx = await env.pledgeProxy.write.claimBorrow([env.poolId], {
    account: borrower1,
  });
  console.log("claimBorrow tx:", claimBorrowTx);

  const refundBorrowTx = await env.pledgeProxy.write.refundBorrow([env.poolId], {
    account: borrower1,
  });
  console.log("refundBorrow tx:", refundBorrowTx);

  const lenderAfter = await env.lendToken.read.balanceOf([lender1.address]);
  const borrowerAfter = await env.collateralToken.read.balanceOf([borrower1.address]);
  const certs = await env.pledgeProxy.read.getUserCertificateBalances([env.poolId, borrower1.address]);
  const certsLender = await env.pledgeProxy.read.getUserCertificateBalances([env.poolId, lender1.address]);


  console.log("lender stable delta:", (lenderAfter - lenderBefore).toString());
  console.log("borrower stable delta:", (borrowerAfter - borrowerBefore).toString());
  console.log("cert balances [sp, jp]:", certs.map((x: bigint) => x.toString()));
  console.log("certsLender balances [sp, jp]:", certsLender.map((x: bigint) => x.toString()));

}

main().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});

import { getEnv, getAccount } from "./common.js";

async function main() {
  const env = await getEnv();
  const lender1 = env.admin;
  const borrower1 = env.user2;
  env.poolId=2n;
  const lenderBefore = await env.lendToken.read.balanceOf([lender1.address]);
  const borrowerStableBefore = await env.lendToken.read.balanceOf([borrower1.address]);
  const borrowerCollBefore = await env.collateralToken.read.balanceOf([borrower1.address]);

  // const tx1 = await env.pledgeProxy.write.withdrawLend([env.poolId], {
  //   account: lender1,
  // });
  // console.log("withdrawLend tx:", tx1);

  // const tx2 = await env.pledgeProxy.write.withdrawBorrow([env.poolId], {
  //   account: borrower1,
  // });
  // console.log("withdrawBorrow tx:", tx2);

  const lenderAfter = await env.lendToken.read.balanceOf([lender1.address]);
  const borrowerStableAfter = await env.lendToken.read.balanceOf([borrower1.address]);
  const borrowerCollAfter = await env.collateralToken.read.balanceOf([borrower1.address]);

  console.log("lender stable delta:", (lenderAfter).toString());
  console.log("borrower stable delta:", (borrowerStableAfter).toString());
  console.log("borrower collateral delta:", (borrowerCollAfter).toString());

  const lenderAfter2 = await env.lendToken.read.balanceOf([env.pledgeProxy.address]);
  console.log("lender after2:", lenderAfter2.toString());


  const borrowerCollAfter2 = await env.collateralToken.read.balanceOf([env.pledgeProxy.address]);
  console.log("borrower collateral after2:", borrowerCollAfter2.toString());
}

main().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});

import { getEnv, getAccount } from "./common";

async function main() {
  const env = await getEnv();
  const lender1 = getAccount("lender1");

  const before = await env.lendTokenContract.read.balanceOf([lender1.address]);

  const tx = await env.pledgeContract.write.withdrawLend([env.poolId], {
    account: lender1,
  });
  console.log("withdrawLend tx:", tx);

  const after = await env.lendTokenContract.read.balanceOf([lender1.address]);
  console.log("lender stable delta:", (after - before).toString());
}

main().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});

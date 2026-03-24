import { parseUnits } from "viem";
import { getEnv } from "./common";

async function main() {
  const env = await getEnv();

  console.log("lendToken:", env.lendToken.address);
  console.log("collateralToken:", env.collateralToken.address);

  await env.lendToken.write.mint(
    [env.admin.address, parseUnits("10000000", 18)],
    { account: env.admin }
  );
  await env.collateralToken.write.mint(
    [env.user2.address, parseUnits("10", 8)],
    { account: env.user2 }
  );

  await env.lendToken.write.approve([env.pledgeProxy.address, parseUnits("10000000", 18)], { account: env.deployer});
  await env.collateralToken.write.approve([env.pledgeProxy.address, parseUnits("10", 8)], { account: env.user2 });

  await env.pledgeProxy.write.depositLend([2n, parseUnits("10000000", 18)], { account: env.admin});
  await env.pledgeProxy.write.depositBorrow([2n, parseUnits("10", 8)], { account: env.user2});

  const poolCount = (await env.pledgeProxy.read.getPoolTotals([2n]));
  console.log("pool:", poolCount);
}

main();
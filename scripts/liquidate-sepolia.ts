import { parseUnits } from "viem";
import { getEnv, getAccount, nowTs } from "./common";

async function main() {
  const env = await getEnv();
  const admin = getAccount("admin");

  const lowPrice = parseUnits(process.env.LIQUIDATION_WBTC_PRICE || "70000", 18);
  const deadline = nowTs() + BigInt(process.env.LIQUIDATION_DEADLINE_OFFSET_SEC || "1000");

  await env.oracleContract.write.setPrice([env.collateralToken, lowPrice], {
    account: admin,
  });
  console.log("oracle price set:", lowPrice.toString());

  await env.routerContract.write.setPrice([env.collateralToken, env.lendToken, lowPrice], {
    account: admin,
  });
  console.log("router price set:", lowPrice.toString());

  const tx = await env.pledgeContract.write.liquidate(
    [env.poolId, deadline, [env.collateralToken, env.lendToken], 0n],
    { account: admin }
  );
  console.log("liquidate tx:", tx);

  const stage = await env.pledgeContract.read.getPoolStage([env.poolId]);
  console.log("stage after liquidation:", stage.toString());
}

main().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});

import { getEnv } from "./common.js";

async function main() {
  const env = await getEnv();
  const beforeSettleStage = await env.pledgeProxy.read.getPoolStage([2n]);
  console.log("beforeSettleStage:", beforeSettleStage.toString());
  const tx = await env.pledgeProxy.write.settle([2n], {
    account: env.admin,
  });

  console.log("settle tx:", tx);

  const stage = await env.pledgeProxy.read.getPoolStage([2n]);
  const totals = await env.pledgeProxy.read.getPoolTotals([2n]);

  console.log("stage:", stage.toString());
  console.log("totals:", totals.map((x: bigint) => x.toString()));
}

main().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});

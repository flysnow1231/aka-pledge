import { parseUnits } from "viem";
import { getEnv} from "./common.js";

async function main() {
  const env = await getEnv();
  const lender1 = env.admin;
  const borrower1 = env.user2;

  const finishOraclePrice = parseUnits("90000", 18);
  const finishDexPrice = parseUnits( "90000", 18);
  const deadline = BigInt(Math.floor(Date.now() / 1000)) + BigInt(process.env.FINISH_DEADLINE_OFFSET_SEC || "1000");

  await env.router.write.setPrice([env.collateralToken.address, env.lendToken.address, parseUnits("90000", 18)], {
    account: lender1,
  }); 
  console.log("router price set:", finishDexPrice.toString());

  await env.oracle.write.setPrice([env.collateralToken.address, finishOraclePrice], {
    account: lender1,
  });
  console.log("oracle price set:", finishOraclePrice.toString());

  const tx = await env.pledgeProxy.write.finish(
    [env.poolId, deadline, [env.collateralToken.address, env.lendToken.address], 0n],
    { account: lender1 }
  );  
  console.log("finish tx:", tx);

  const stage = await env.pledgeProxy.read.getPoolStage([env.poolId]);
  console.log("stage after finish:", stage.toString());
}

main().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});

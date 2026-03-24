import { parseUnits } from "viem";
import { getEnv, getAccount, parseAmountDecimal } from "./common";

async function main() {
  const env = await getEnv();
  const admin = getAccount("admin");
  const lender1 = getAccount("lender1");
  const lender2 = getAccount("lender2");
  const borrower1 = getAccount("borrower1");
  const borrower2 = getAccount("borrower2");

  const routerFund = parseUnits(process.env.ROUTER_FUND_USDS || "10000000", 18);
  const lender1Fund = parseUnits(process.env.LENDER1_FUND_USDS || "1000000", 18);
  const lender2Fund = parseUnits(process.env.LENDER2_FUND_USDS || "1000000", 18);
  const borrower1Fund = parseAmountDecimal(process.env.BORROWER1_FUND_WBTC || "10", 8);
  const borrower2Fund = parseAmountDecimal(process.env.BORROWER2_FUND_WBTC || "10", 8);

  const priceX18 = parseUnits(process.env.ORACLE_WBTC_PRICE || "100000", 18);

  await env.oracleContract.write.setPrice([env.collateralToken, priceX18], {
    account: admin,
  });
  console.log("oracle price set:", priceX18.toString());

  await env.lendTokenContract.write.mint([env.router, routerFund], { account: admin });
  await env.lendTokenContract.write.mint([lender1.address, lender1Fund], { account: admin });
  await env.lendTokenContract.write.mint([lender2.address, lender2Fund], { account: admin });
  await env.collateralTokenContract.write.mint([borrower1.address, borrower1Fund], { account: admin });
  await env.collateralTokenContract.write.mint([borrower2.address, borrower2Fund], { account: admin });

  console.log("router funded USDS:", routerFund.toString());
  console.log("lender1 funded USDS:", lender1Fund.toString());
  console.log("lender2 funded USDS:", lender2Fund.toString());
  console.log("borrower1 funded WBTC:", borrower1Fund.toString());
  console.log("borrower2 funded WBTC:", borrower2Fund.toString());
}

main().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});

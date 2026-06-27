export const contractAddress =
  (process.env.NEXT_PUBLIC_CONTRACT_ADDRESS as `0x${string}` | undefined) ??
  "0xC7d598a10DB4300CB2634f25A62b816bCBd1Ea4b";

export const executorAddress =
  (process.env.NEXT_PUBLIC_EXECUTOR_ADDRESS as `0x${string}` | undefined) ??
  undefined;

export const ritualChainId: number =
  parseInt(process.env.NEXT_PUBLIC_CHAIN_ID ?? "1979", 10);

export const ritualRpcUrl: string =
  process.env.NEXT_PUBLIC_RPC_URL ?? "https://rpc.ritualfoundation.org";

export const isContractConfigured = !!contractAddress;

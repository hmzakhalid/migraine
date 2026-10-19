/* Migraine frontend configuration.
 *
 * Fill in `contractAddress` after deploying the contract. `rpcUrl` and `chainId`
 * are optional: when a browser wallet (MetaMask) is connected it is used for all
 * reads/writes; the RPC URL is only used as a read-only fallback.
 */
window.MIGRAINE_CONFIG = {
  // Address of the deployed Migraine contract.
  contractAddress: "0x0000000000000000000000000000000000000000",

  // Expected chain id (for example 1 for Ethereum mainnet). Set it for
  // every deployment so a wallet on the wrong network is refused; null skips the check.
  chainId: null,

  // Optional: read-only RPC endpoint (not required when using a browser wallet).
  rpcUrl: null
};

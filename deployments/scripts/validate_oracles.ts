import { createPublicClient, http, parseAbi } from 'viem';
import * as fs from 'fs';
import { argv } from 'process';

// Argument parsing
const args = argv.slice(2);
const rpcIndex = args.indexOf('--rpc-url');

if (rpcIndex === -1) {
    console.error('Missing --rpc-url argument. Add `--rpc-url <rpc_url>` to the command.');
    process.exit(1);
}

const rpcUrl = args[rpcIndex + 1];

// Initialize Viem client
const client = createPublicClient({
    transport: http(rpcUrl),
});

// Chain ID mapping
const chainMapping = {
    1: "eth",
    56: "bsc",
    137: "polygon",
    42161: "arb",
    10: "op",
    43114: "avalanche",
    8453: "base",
    5000: "mantle",
    11155111: "sonic"
};


(async () => {
    let chainId;
    try {
        chainId = await client.getChainId();
    } catch (e) {
        console.error('Failed to fetch chain ID:', e);
        process.exit(1);
    }

    const chainName = chainMapping[chainId] || `chain-${chainId}`;
    const filePath = `oracles/intern/${chainName}-oracles.json`;
    let data = [];

    try {
        const rawData = fs.readFileSync(filePath, 'utf-8');
        data = JSON.parse(rawData);
    } catch (e) {
        console.error(`Failed to load data from ${filePath}:`, e);
        process.exit(1);
    }

    // ERC-20 ABI for symbol fetching
    const ERC20_ABI = parseAbi(['function symbol() view returns (string)']);

    for (const entry of data) {
        const baseSymbol = entry.base;
        const contractAddress = entry.baseAddress;

        if (!contractAddress || contractAddress === '') {
            continue;
        }

        try {
            const symbol = await client.readContract({
                address: contractAddress,
                abi: ERC20_ABI,
                functionName: 'symbol',
            });

            const CHAINLINK_ABI = parseAbi(['function description() view returns (string)']);
            const description = await client.readContract({
                address: entry.proxyAddress,
                abi: CHAINLINK_ABI,
                functionName: 'description',
            });
            
            // Validate oracle description roughly
            if (!description.toUpperCase().match(`${baseSymbol} / USD`.toUpperCase())) {
                console.error(`Error: Oracle description '${description}' does not match '${baseSymbol} / USD'`);
            }

            // Validate symbol roughly
            if (symbol.includes(baseSymbol)) {
                console.log(`Contract symbol '${symbol}' contains base '${baseSymbol}'`);
            } else {
                console.error(`Error: Contract symbol '${symbol}' does not contain base '${baseSymbol}'`);
            }
        } catch (e) {
            console.error(`Failed to fetch symbol for ${contractAddress}:`, e);
        }
    }
})();

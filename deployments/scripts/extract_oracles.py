import json
import requests

# Define available endpoints
ENDPOINTS = {
    "op": "https://reference-data-directory.vercel.app/feeds-ethereum-mainnet-optimism-1.json",
    "avalanche": "https://reference-data-directory.vercel.app/feeds-avalanche-mainnet.json",
    "polygon": "https://reference-data-directory.vercel.app/feeds-matic-mainnet.json",
    "base": "https://reference-data-directory.vercel.app/feeds-ethereum-mainnet-base-1.json",
    "arb": "https://reference-data-directory.vercel.app/feeds-ethereum-mainnet-arbitrum-1.json",
    "sonic": "https://reference-data-directory.vercel.app/feeds-sonic-mainnet.json",
    "mantle": "https://reference-data-directory.vercel.app/feeds-ethereum-mainnet-mantle-1.json",
    "bsc": "https://reference-data-directory.vercel.app/feeds-bsc-mainnet.json"
}

# Function to extract oracles with specified conditions
def extract_oracles(data):
    oracles = []
    for item in data:
        docs = item.get('docs', {})
        quote_asset = docs.get('quoteAsset')
        if quote_asset in ['USD', 'USDC', 'USDT']:
            base_asset = docs.get('baseAsset')
            proxy_address = item.get('proxyAddress')
            if proxy_address is None:
                continue
            if item.get('feedType') == "Forex":
                continue
            if item.get('feedType') == "Equities":
                continue
            oracles.append({"base": base_asset, "baseAddress":"", "quote": quote_asset, "proxyAddress": proxy_address})
    return oracles

# Process each endpoint
for chain, api_url in ENDPOINTS.items():
    # Fetch data from the API endpoint
    response = requests.get(api_url)
    if response.status_code == 200:
        data = response.json()
    else:
        print(f"Failed to fetch data for {chain}")
        continue

    # Extract and write oracles
    extracted_oracles = extract_oracles(data)
    
    # Write to file
    with open(f"oracles/{chain}-oracles.json", "w") as f:
        json.dump(extracted_oracles, f, indent=2)

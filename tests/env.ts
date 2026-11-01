// Pin the app to the Arc mainnet deployment before any app module reads its config.
// Loaded first through bunfig.toml. Local and mock only: no test sends a transaction.
process.env.VITE_PLUG_CHAIN = 'arc-mainnet'
process.env.VITE_PLUG_ADDRESS = '0xaa5364de35d65633ad031ff4da4f941e0de6f913'
process.env.VITE_PLUG_DEPLOY_BLOCK = '28454210'
process.env.VITE_DEMO_AGENT_ADDRESS = '0x535df2938c7596497600564b41d0e98a5ea6b13b'
delete process.env.VITE_PLUG_RPC_URL

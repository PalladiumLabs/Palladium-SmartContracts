import { ethers } from "ethers"
const toEther = (n: number) => ethers.parseEther(n.toString())

const OUTPUT_FILE = "./scripts/deployment/output/botanix-testnetv4.json"
const TX_CONFIRMATIONS = 1
const ETHERSCAN_BASE_URL = "https://testnet.botanixscan.io/ "

/// @dev Safe Multisig on Mantle: https://multisig.mantle.xyz/

const CONTRACT_UPGRADES_ADMIN = "0xfB0140ea62F41f643959B2A4153bf908f80EA4aD"
const SYSTEM_PARAMS_ADMIN = "0xfB0140ea62F41f643959B2A4153bf908f80EA4aD"
const TREASURY_WALLET = "0xfB0140ea62F41f643959B2A4153bf908f80EA4aD"

const GRAI_TOKEN_ADDRESS = ""

const COLLATERAL = [
	// {
	//     name: "WBTC",
	//     address: "0x6e9Cd926Bf8F57FCe14b5884d9Ee0323126A772E",//mock wcore deployed on testnet
	//     oracleAddress: "0xc014933c805825D335e23Ef12eB92d2471D41DA7",//mock aggragator deployed on testnet
	//     oracleTimeoutSeconds:1440 ,
	//     oracleIsEthIndexed: false,
	//     oracleProviderType:0,//chainlink
	//     borrowingFee: toEther(0.025),//2.5 %
	//     MCR: toEther(1.1),
	//     CCR: toEther(1.3),
	//     minNetDebt: toEther(100),
	//     gasCompensation: toEther(10),
	//     mintCap: toEther(500_0000),
	//     redemptionBlockTimestamp: 265763
	// }
	{
		name: "WBTC",
		address: "0x321f90864fb21cdcddD0D67FE5e4Cbc812eC9e64", //mock wcore deployed on testnet
		//oracleAddress: "0xc014933c805825D335e23Ef12eB92d2471D41DA7", //mock aggragator deployed on testnet
		oracleAddress: "0x717431E3E7951196BCE7B5b0d0593Dad1b6D5e2d",
		oracleTimeoutSeconds: 900000,
		oracleIsEthIndexed: false,
		oracleProviderType: 0, //chainlink
		borrowingFee: toEther(0.025), //2.5 %
		MCR: toEther(1.1),
		CCR: toEther(1.3),
		minNetDebt: toEther(100),
		gasCompensation: toEther(10),
		mintCap: toEther(500_0000),
		redemptionBlockTimestamp: 320218,
	},
]

module.exports = {
	COLLATERAL,
	CONTRACT_UPGRADES_ADMIN,
	ETHERSCAN_BASE_URL,
	GRAI_TOKEN_ADDRESS,
	OUTPUT_FILE,
	SYSTEM_PARAMS_ADMIN,
	TREASURY_WALLET,
	TX_CONFIRMATIONS,
}

//yarn hardhat deploy-core-botanix-testnet --network botanix-testnet

// npx hardhat deploy-core-botanix-testnet --network botanix-testnet


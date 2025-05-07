import { HardhatRuntimeEnvironment } from "hardhat/types"
import {
	getImplementationAddress,
	getImplementationAddressFromProxy,
	EthereumProvider,
} from "@openzeppelin/upgrades-core"
import { Overrides, Wallet, utils, constants } from "ethers"
// import { utils.formatUnits } from "utils"
import { ZERO_ADDRESS } from "@openzeppelin/test-helpers/src/constants"
import fs from "fs"
import { ethers } from "ethers"

/**
 * Available target networks; each should have a matching file in the config folder.
 */
export enum DeploymentTarget {
	Localhost = "localhost",
	Arbitrum = "arbitrum",
	HoleskyTestnet = "holesky",
	Linea = "linea",
	Mainnet = "mainnet",
	Mantle = "mantle",
	Optimism = "optimism",
	PolygonZkEvm = "polygon-zkevm",
	ArbitrumFork = "arbitrum-fork",
	CoreTestnet = "core-testnet",
	BitFinity = "bitfinity",
	BotanixTestnet = "botanix-testnet",
}

/**
 * Exported deployment class, invoked from hardhat tasks defined on hardhat.config.ts
 */
export class CoreDeployer {
	config: any
	coreContracts: any
	deployerBalance: bigint = BigInt(0)
	deployerWallet: Wallet
	hre: HardhatRuntimeEnvironment
	state: any
	targetNetwork: DeploymentTarget
	feeData: Overrides | undefined
	private wallet: Wallet

	constructor(hre: HardhatRuntimeEnvironment, targetNetwork: DeploymentTarget) {
		this.targetNetwork = targetNetwork
		const configParams = require(`./config/${this.targetNetwork}`)
		if (!process.env.DEPLOYER_PRIVATEKEY) {
			throw Error("Provide a value for DEPLOYER_PRIVATEKEY in your .env file")
		}
		this.config = configParams
		this.hre = hre
		const provider = hre.ethers.provider
		this.deployerWallet = new Wallet(process.env.DEPLOYER_PRIVATEKEY!, provider)
		console.log("this.targetNetwork", this.targetNetwork)
	}

	isLocalhostDeployment = () => DeploymentTarget.Localhost == this.targetNetwork
	isTestnetDeployment = () =>
		[
			DeploymentTarget.Localhost,
			DeploymentTarget.GoerliTestnet,
			DeploymentTarget.ArbitrumGoerliTestnet,
			DeploymentTarget.OptimismGoerliTestnet,
			DeploymentTarget.CoreTestnet,
			DeploymentTarget.BitFinity,
			DeploymentTarget.BotanixTestnet,
		].includes(this.targetNetwork)
	isLayer2Deployment = () =>
		[
			DeploymentTarget.Arbitrum,
			DeploymentTarget.ArbitrumFork,
			DeploymentTarget.ArbitrumGoerliTestnet,
			DeploymentTarget.OptimismGoerliTestnet,
			DeploymentTarget.Optimism,
		].includes(this.targetNetwork)

	/**
	 * Main function that is invoked by the deployment process.
	 */
	async run() {
		console.log(`Deploying Gravita Core on ${this.targetNetwork}...`)

		// this.feeData = <Overrides>{
		// 	gasPrice:0.000000007,
		// 	// maxFeePerGas: 7,
		// 	// maxPriorityFeePerGas: 7_000_000_000,
		// }
		// this.feeData = <Overrides>{
		// 	maxFeePerGas: 100_000_000_000,
		// 	maxPriorityFeePerGas: 100_000_000_000,
		// }

		await this.printDeployerBalance()

		await this.loadOrDeployCoreContracts()
		await this.connectCoreContracts()
		await this.addCollaterals()

		// do not hand off from admin to timelock for now
		// await this.toggleContractSetupInitialization(this.coreContracts.adminContract)

		// await this.verifyCoreContracts()

		// do not transfer ownership for now
		// await this.transferContractsOwnerships(this.coreContracts)

		// await this.printDeployerBalance()
	}

	/**
	 * Deploys all Gravita's Core contracts to the target network.
	 * If any of the contracts have already been deployed and contain a matching entry in the JSON
	 *     "state" file, the existing address is attached to the contract instead.
	 */
	async loadOrDeployCoreContracts() {
		console.log(`Deploying core contracts...`)
		this.loadPreviousDeployment()

		try {
			// Deploy all contracts first
			const activePool = await this.deployUpgradeable("ActivePool")
			const adminContract = await this.deployUpgradeable("AdminContract")
			const borrowerOperations = await this.deployUpgradeable("BorrowerOperations")
			const collSurplusPool = await this.deployUpgradeable("CollSurplusPool")
			const defaultPool = await this.deployUpgradeable("DefaultPool")
			const feeCollector = await this.deployUpgradeable("FeeCollector")
			const sortedTroves = await this.deployUpgradeable("SortedTroves")
			const stabilityPool = await this.deployUpgradeable("StabilityPool")
			const troveManager = await this.deployUpgradeable("TroveManager")
			const troveManagerOperations = await this.deployUpgradeable("TroveManagerOperations")
			const gasPool = await this.deployNonUpgradeable("GasPool")

			let priceFeed: any
			if (this.isLocalhostDeployment()) {
				priceFeed = await this.deployNonUpgradeable("PriceFeedTestnet")
			} else {
				priceFeed = await this.deployUpgradeable("PriceFeed")
			}

			let timelockDelay: number
			let timelockFactoryName: string
			if (this.isTestnetDeployment()) {
				timelockDelay = 5 * 60 // 5 minutes
				timelockFactoryName = "TimelockTester"
			} else {
				timelockDelay = 2 * 86_400 // 2 days
				timelockFactoryName = "Timelock"
			}
			const timelockParams = [timelockDelay, this.config.SYSTEM_PARAMS_ADMIN]
			const timelock = await this.deployNonUpgradeable(timelockFactoryName, timelockParams)

			let debtToken: any
			if (this.config.GRAI_TOKEN_ADDRESS) {
				console.log(`Using existing DebtToken from ${this.config.GRAI_TOKEN_ADDRESS}`)
				debtToken = await this.hre.ethers.getContractAt("DebtToken", this.config.GRAI_TOKEN_ADDRESS)
			} else {
				debtToken = await this.deployNonUpgradeable("DebtToken")
			}

			// Store all contracts
			this.coreContracts = {
				activePool,
				adminContract,
				borrowerOperations,
				collSurplusPool,
				debtToken,
				defaultPool,
				feeCollector,
				gasPool,
				priceFeed,
				sortedTroves,
				stabilityPool,
				timelock,
				troveManager,
				troveManagerOperations,
			}

			// Verify all contract addresses
			console.log("\nVerifying contract addresses:")
			for (const [name, contract] of Object.entries(this.coreContracts)) {
				try {
					const address = await contract.getAddress()
					console.log(`${name}: ${address}`)
					if (!address || address === ethers.ZeroAddress) {
						throw new Error(`Invalid address for ${name}`)
					}
				} catch (e) {
					console.error(`Error getting address for ${name}:`, e)
					throw e
				}
			}

			// Set addresses
			console.log("\nSetting contract addresses...")
			if (debtToken) {
				try {
					const [borrowerOpsAddr, stabilityPoolAddr, troveManagerAddr] = await Promise.all([
						borrowerOperations.getAddress(),
						stabilityPool.getAddress(),
						troveManager.getAddress(),
					])

					console.log("Setting DebtToken addresses:", {
						borrowerOps: borrowerOpsAddr,
						stabilityPool: stabilityPoolAddr,
						troveManager: troveManagerAddr,
					})

					await debtToken.setAddresses(borrowerOpsAddr, stabilityPoolAddr, troveManagerAddr)
				} catch (e) {
					console.error("Error setting DebtToken addresses:", e)
					throw e
				}
			}

			return this.coreContracts
		} catch (e) {
			console.error("Error in loadOrDeployCoreContracts:", e)
			throw e
		}
	}

	async deployUpgradeable(contractName: string, params: string[] = []) {
		const isUpgradeable = true
		return await this.loadOrDeploy(contractName, isUpgradeable, params)
	}

	async deployNonUpgradeable(contractName: string, params: string[] = []) {
		const isUpgradeable = false
		return await this.loadOrDeploy(contractName, isUpgradeable, params)
	}

	async getFactory(name: string) {
		return await this.hre.ethers.getContractFactory(name, this.deployerWallet)
	}

	async loadOrDeploy(contractName: string, isUpgradeable: boolean, params: string[]) {
		let retry = 0
		const maxRetries = 2
		const factory = await this.getFactory(contractName)
		const address = this.state[contractName]?.address
		const alreadyDeployed = this.state[contractName] && address

		const feeData = await this.hre.ethers.provider.getFeeData()
		const minGasPrice = feeData.gasPrice
		console.log("minGasPrice", ethers.formatUnits(minGasPrice || 0n, "gwei"))

		if (!isUpgradeable) {
			if (alreadyDeployed) {
				console.log(`Using previous deployment: ${address} -> ${contractName}`)
				return factory.attach(address)
			} else {
				console.log(`(Deploying ${contractName}...)`)
				while (++retry < maxRetries) {
					try {
						const deploymentTx = await factory.deploy(...params, {
							maxPriorityFeePerGas: 10n,
							maxFeePerGas: 10n,
						})

						// Wait for deployment to complete
						const contract = await deploymentTx.waitForDeployment()

						// Get the deployment transaction
						const tx = deploymentTx.deploymentTransaction()
						if (!tx) {
							throw new Error("No deployment transaction found")
						}

						const receipt = await tx.wait()
						console.log(`- Gas Price (wei): ${receipt.gasPrice?.toString() || 0} wei`)
						console.log(`- Gas Price (gwei): ${ethers.formatUnits(receipt.gasPrice || 0n, "gwei")} gwei`)
						console.log("deployed")

						await this.updateState(contractName, contract, isUpgradeable, tx)
						return contract
					} catch (e: any) {
						console.log(`[Error: ${e.message}] Retrying...`)
					}
				}
				throw Error(`ERROR: Unable to deploy contract ${contractName} after ${maxRetries} attempts.`)
			}
		} else {
			if (alreadyDeployed) {
				const existingContract = factory.attach(address)
				console.log(`Using previous deployment: ${address} -> ${contractName}`)
				return existingContract
			} else {
				console.log(`(Deploying ${contractName} [uups]...)`)
				let opts: any = {
					kind: "uups",
					txOverrides: {
						maxPriorityFeePerGas: 10n,
						maxFeePerGas: 10n,
					},
				}

				if (factory.interface.getFunction("initialize()")) {
					opts.initializer = "initialize()"
				}

				while (++retry < maxRetries) {
					try {
						console.log("deploying")
						const newContract = await upgrades.deployProxy(factory, [], opts)
						await newContract.waitForDeployment()

						const deployTx = await newContract.deploymentTransaction()
						if (!deployTx) {
							throw new Error("No deployment transaction found")
						}

						const receipt = await deployTx.wait()
						console.log(`- Gas Price (wei): ${receipt.gasPrice?.toString() || 0} wei`)
						console.log(`- Gas Price (gwei): ${ethers.formatUnits(receipt.gasPrice || 0n, "gwei")} gwei`)
						console.log("deployed")

						await this.updateState(contractName, newContract, isUpgradeable, deployTx)
						return newContract
					} catch (e: any) {
						console.log(`[Error: ${e.message}] Retrying...`)
					}
				}
				throw Error(`ERROR: Unable to deploy contract ${contractName} after ${maxRetries} attempts.`)
			}
		}
	}

	/**
	 * Calls setAddresses() on all Addresses-inherited contracts.
	 */
	async connectCoreContracts() {
		const setAddresses = async (contract: any) => {
			// Get addresses using getAddress() for ethers v6
			const addresses = await Promise.all([
				this.coreContracts.activePool.getAddress(),
				this.coreContracts.adminContract.getAddress(),
				this.coreContracts.borrowerOperations.getAddress(),
				this.coreContracts.collSurplusPool.getAddress(),
				this.coreContracts.debtToken.getAddress(),
				this.coreContracts.defaultPool.getAddress(),
				this.coreContracts.feeCollector.getAddress(),
				this.coreContracts.gasPool.getAddress(),
				this.coreContracts.priceFeed.getAddress(),
				this.coreContracts.sortedTroves.getAddress(),
				this.coreContracts.stabilityPool.getAddress(),
				this.coreContracts.timelock.getAddress(),
				this.config.TREASURY_WALLET, // This is already an address string
				this.coreContracts.troveManager.getAddress(),
				this.coreContracts.troveManagerOperations.getAddress(),
			])

			// Validate addresses
			for (const [i, addr] of addresses.entries()) {
				if (!addr || addr === ethers.ZeroAddress) {
					throw new Error(`setAddresses :: Invalid address for index ${i}`)
				}
			}

			await contract.setAddresses(addresses, {
				maxPriorityFeePerGas: 10n,
				maxFeePerGas: 10n,
			})
		}

		// Connect each contract
		for (const key in this.coreContracts) {
			const contract = this.coreContracts[key]
			if (contract.setAddresses && contract.isAddressSetupInitialized) {
				const isAddressSetupInitialized = await contract.isAddressSetupInitialized()
				if (!isAddressSetupInitialized) {
					console.log(`${key}.setAddresses()...`)
					try {
						await setAddresses(contract)
					} catch (e) {
						console.error(`${key}.setAddresses() failed:`, e)
					}
				} else {
					console.log(`${key}.setAddresses() already set!`)
				}
			} else {
				console.log(`(${key} has no setAddresses() or isAddressSetupInitialized() function)`)
			}
		}

		// Set DebtToken addresses
		try {
			const [borrowerOpsAddr, stabilityPoolAddr, troveManagerAddr] = await Promise.all([
				this.coreContracts.borrowerOperations.getAddress(),
				this.coreContracts.stabilityPool.getAddress(),
				this.coreContracts.troveManager.getAddress(),
			])

			await this.sendAndWaitForTransaction(
				this.coreContracts.debtToken.setAddresses(borrowerOpsAddr, stabilityPoolAddr, troveManagerAddr, {
					maxPriorityFeePerGas: 10n,
					maxFeePerGas: 10n,
				})
			)

			const feeCollectorAddr = await this.coreContracts.feeCollector.getAddress()
			await this.sendAndWaitForTransaction(
				this.coreContracts.debtToken.addWhitelist(feeCollectorAddr, {
					maxPriorityFeePerGas: 10n,
					maxFeePerGas: 10n,
				})
			)

			const timelockAddr = await this.coreContracts.timelock.getAddress()
			console.log("time lock address", timelockAddr)

			const troveManagerOpsAddr = await this.coreContracts.troveManagerOperations.getAddress()
			const data = this.coreContracts.troveManagerOperations.interface.encodeFunctionData(
				"setRedemptionSofteningParam",
				[9950]
			)
			console.log("data", data)

			if (this.isTestnetDeployment()) {
				try {
					await this.sendAndWaitForTransaction(
						this.coreContracts.timelock.setSoftening(troveManagerOpsAddr, "", data, {
							maxPriorityFeePerGas: 10n,
							maxFeePerGas: 10n,
							gasLimit: 500000n, // Add explicit gas limit
						})
					)
				} catch (error) {
					console.warn("Warning: setSoftening failed, but continuing deployment:", error.message)
					// Continue with deployment even if setSoftening fails
				}
			}
		} catch (e) {
			console.error(`Error in connectCoreContracts:`, e)
			throw e // Re-throw the error to halt deployment if critical
		}
	}

	async addCollaterals() {
		console.log("Adding Collateral...")
		for (const coll of this.config.COLLATERAL) {
			if (!coll.address || coll.address == "") {
				console.log(`[${coll.name}] WARNING: No address setup for collateral`)
				continue
			}
			if (!coll.oracleAddress || coll.oracleAddress == "") {
				console.log(`[${coll.name}] WARNING: No price feed oracle address setup for collateral`)
				continue
			}
			await this.addPriceFeedOracle(coll)
			await this.addCollateral(coll)
			if (coll.name == "wETH") {
				await this.addPriceFeedOracle({ ...coll, name: "ETH", address: constants.AddressZero })
			}
		}
	}

	/**
	 * Calls AdminContract.addNewCollateral() and AdminContract.setCollateralParams()
	 *     using default values + parameters from the config file.
	 */
	async addCollateral(coll: any) {
		const collExists = (await this.coreContracts.adminContract.getMcr(coll.address)) > 0
		if (collExists) {
			console.log(`[${coll.name}] NOTICE: collateral has already been added before`)
		} else {
			const decimals = 18
			console.log(`[${coll.name}] AdminContract.addNewCollateral() ...`)
			await this.sendAndWaitForTransaction(
				this.coreContracts.adminContract.addNewCollateral(coll.address, coll.gasCompensation, decimals, {
					maxPriorityFeePerGas: 10n,
					maxFeePerGas: 10n,
				})
			)
			console.log(`[${coll.name}] Collateral added @ ${coll.address}`)
		}
		const isActive = await this.coreContracts.adminContract.getIsActive(coll.address)
		if (isActive) {
			console.log(`[${coll.name}] NOTICE: collateral params have already been set`)
		} else {
			console.log(`[${coll.name}] Setting collateral params...`)
			const defaultPercentDivisor = await this.coreContracts.adminContract.PERCENT_DIVISOR_DEFAULT()
			const defaultRedemptionFeeFloor = await this.coreContracts.adminContract.REDEMPTION_FEE_FLOOR_DEFAULT()
			const defaultBorrowingFee = await this.coreContracts.adminContract.BORROWING_FEE_DEFAULT()

			console.log(" coll.borrowingFee", coll.borrowingFee)
			await this.sendAndWaitForTransaction(
				this.coreContracts.adminContract.setCollateralParameters(
					coll.address,
					coll.borrowingFee,
					coll.CCR,
					coll.MCR,
					coll.minNetDebt,
					coll.mintCap,
					defaultPercentDivisor,
					defaultRedemptionFeeFloor,
					{
						maxPriorityFeePerGas: 10n,
						maxFeePerGas: 10n,
					}
				)
			)
			const redeemTimestamp = (await this.hre.ethers.provider.getBlock("latest")).timestamp

			await this.sendAndWaitForTransaction(
				this.coreContracts.adminContract.setRedemptionBlockTimestamp(coll.address, redeemTimestamp, {
					maxPriorityFeePerGas: 10n,
					maxFeePerGas: 10n,
				})
			)
			console.log(`[${coll.name}] AdminContract.setCollateralParameters() -> ok`)
		}
	}

	/**
	 * Calls PriceFeed.setOracle()
	 */
	async addPriceFeedOracle(coll: any) {
		const oracleRecord = await this.coreContracts.priceFeed.oracles(coll.address)

		if (oracleRecord.decimals == 0) {
			const owner = await this.coreContracts.priceFeed.owner()
			if (owner != this.deployerWallet.address) {
				console.log(
					`[${coll.name}] WARNING: Cannot call PriceFeed.setOracle(): deployer = ${this.deployerWallet.address}, owner = ${owner}`
				)
				return
			}
			console.log(`[${coll.name}] PriceFeed.setOracle()`)
			const oracleProviderType = 0
			const isFallback = false
			console.log("ccoll.oracleIsEthIndexed", coll.oracleIsEthIndexed)
			console.log("coll.oracleTimeoutSeconds", coll.oracleTimeoutSeconds)
			console.log("coll.oracleProviderType", coll.oracleProviderType)

			await this.sendAndWaitForTransaction(
				this.coreContracts.priceFeed.setOracle(
					coll.address,
					coll.oracleAddress,
					coll.oracleProviderType,
					coll.oracleTimeoutSeconds,
					coll.oracleIsEthIndexed,
					isFallback,
					{
						maxPriorityFeePerGas: 10n,
						maxFeePerGas: 10n,
					}
				)
			)

			console.log(`[${coll.name}] Oracle Price Feed has been set @ ${coll.oracleAddress}`)
		} else {
			if (oracleRecord.oracleAddress == coll.oracleAddress) {
				console.log(`[${coll.name}] Oracle Price Feed had already been set @ ${coll.oracleAddress}`)
			} else {
				console.log(
					`[${coll.name}] WARNING: another oracle had already been set, please update via Timelock.setOracle()`
				)
			}
		}
	}

	/**
	 * Transfers the ownership of all Ownable contracts to the address defined on config's CONTRACT_UPGRADES_ADMIN.
	 */
	async transferContractsOwnerships() {
		const upgradesAdmin = this.config.CONTRACT_UPGRADES_ADMIN
		if (!upgradesAdmin || upgradesAdmin == ZERO_ADDRESS) {
			throw Error(
				"Provide an address for CONTRACT_UPGRADES_ADMIN in the config file before transferring the ownerships."
			)
		}
		console.log(`\r\nTransferring contract ownerships to ${upgradesAdmin}...`)
		for (const contract of Object.values(this.coreContracts)) {
			let name = await this.getContractName(contract)
			if (!(contract as any).transferOwnership) {
				console.log(` - ${name} is NOT Ownable`)
			} else {
				const currentOwner = await (contract as any).owner()
				if (currentOwner == upgradesAdmin) {
					console.log(` - ${name} -> Owner had already been set to @ ${upgradesAdmin}`)
				} else {
					try {
						await this.sendAndWaitForTransaction(
							(contract as any).transferOwnership(upgradesAdmin, {
								maxPriorityFeePerGas: 10n,
								maxFeePerGas: 10n,
							})
						)
						console.log(` - ${name} -> Owner set to CONTRACT_UPGRADES_ADMIN @ ${upgradesAdmin}`)
					} catch (e: any) {
						console.error(e)
						console.log(` - ${name} -> ERROR [owner = ${currentOwner}]`)
					}
				}
			}
		}
	}

	/**
	 * If contract has an isSetupInitialized flag, set it to true via setSetupIsInitialized()
	 */
	async toggleContractSetupInitialization(contract: any) {
		let name = await this.getContractName(contract)
		if (!contract.isSetupInitialized) {
			console.log(`[NOTICE] ${name} does not have an isSetupInitialized flag!`)
			return
		}
		const isSetupInitialized = await contract.isSetupInitialized()
		if (isSetupInitialized) {
			console.log(`${name} is already initialized!`)
		} else {
			await this.sendAndWaitForTransaction(
				contract.setSetupIsInitialized({
					maxPriorityFeePerGas: 10n,
					maxFeePerGas: 10n,
				})
			)
			console.log(`${name} has been initialized`)
		}
	}

	async getContractName(contract: any): Promise<string> {
		try {
			return await contract.NAME()
		} catch (e) {
			return "?"
		}
	}

	async printDeployerBalance() {
		const prevBalance = this.deployerBalance
		this.deployerBalance = await this.hre.ethers.provider.getBalance(this.deployerWallet.address)
		const cost = prevBalance ? ethers.formatUnits(prevBalance - this.deployerBalance) : 0
		console.log(
			`${this.deployerWallet.address} Balance: ${ethers.formatUnits(this.deployerBalance)} ${
				cost ? `(Deployment cost: ${cost})` : ""
			}`
		)
	}

	async sendAndWaitForTransaction(txPromise: any) {
		try {
			const tx = await txPromise
			await tx.wait(this.config.TX_CONFIRMATIONS)
			return tx
		} catch (error: any) {
			console.error("Transaction failed:", {
				error: error.message,
				code: error.code,
				reason: error.reason,
			})
			throw error
		}
	}

	loadPreviousDeployment() {
		let previousDeployment = {}
		if (fs.existsSync(this.config.OUTPUT_FILE)) {
			console.log(`Loading previous deployment from ${this.config.OUTPUT_FILE}...`)
			previousDeployment = JSON.parse(fs.readFileSync(this.config.OUTPUT_FILE, "utf-8"))
		}
		this.state = previousDeployment
	}

	saveDeployment() {
		const deploymentStateJSON = JSON.stringify(this.state, null, 2)
		fs.writeFileSync(this.config.OUTPUT_FILE, deploymentStateJSON)
	}

	async updateState(
		contractName: string,
		contract: any,
		isUpgradeable: boolean,
		deploymentTransaction?: ethers.ContractTransactionResponse
	) {
		console.log(`(Updating state...)`)

		// Get the contract address
		const contractAddress = await contract.getAddress()

		this.state[contractName] = {
			address: contractAddress,
			txHash: deploymentTransaction ? deploymentTransaction.hash : undefined,
		}

		if (isUpgradeable) {
			try {
				const provider: EthereumProvider = this.deployerWallet.provider as unknown as EthereumProvider
				const implAddress = await getImplementationAddressFromProxy(provider, contractAddress)
				console.log(`(ImplAddress: ${implAddress})`)
				this.state[contractName].implAddress = implAddress
			} catch (e: any) {
				console.error(e)
				console.log(`Unable to find implAddress for ${contractName}`)
			}
		}

		this.saveDeployment()
	}

	async logContractObjects(contracts: Array<any>) {
		const names: string[] = []
		Object.keys(contracts).forEach(name => names.push(name))
		names.sort()
		for (let name of names) {
			const contract = contracts[name]
			try {
				name = await contract.NAME()
			} catch (e) {}
			console.log(`Contract deployed: ${await contract.getAddress()} -> ${name}`)
		}
	}

	async verifyCoreContracts() {
		if (!this.config.ETHERSCAN_BASE_URL) {
			console.log("(No Etherscan URL defined, skipping contract verification)")
		} else {
			await this.verifyContract("ActivePool")
			await this.verifyContract("AdminContract")
			await this.verifyContract("BorrowerOperations")
			await this.verifyContract("CollSurplusPool")
			await this.verifyContract("DebtToken")
			await this.verifyContract("DefaultPool")
			await this.verifyContract("FeeCollector")
			await this.verifyContract("GasPool")
			await this.verifyContract("PriceFeed")
			await this.verifyContract("SortedTroves")
			await this.verifyContract("StabilityPool")
			await this.verifyContract("TroveManager")
			await this.verifyContract("VesselManagerOperations")
		}
	}

	async verifyContract(name: string, constructorArguments: string[] = []) {
		if (!this.state[name] || !this.state[name].address) {
			console.error(`  --> No deployment state for contract ${name}!!`)
			return
		}
		if (this.state[name].verification) {
			console.log(`Contract ${name} already verified`)
			return
		}
		try {
			await this.hre.run("verify:verify", {
				address: this.state[name].address,
				constructorArguments,
			})
		} catch (error: any) {
			if (e.name != "NomicLabsHardhatPluginError") {
				console.error(`Error verifying: ${e.name}`)
				console.error(e)
				return
			}
		}
		this.state[name].verification = `${this.config.ETHERSCAN_BASE_URL}/${this.state[name].address}#code`
		this.saveDeployment()
	}
}


// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";

import "../Dependencies/BaseMath.sol";
import "../Dependencies/PalladiumMath.sol";
import "../Dependencies/SafetyTransfer.sol";

import "../Interfaces/IDeposit.sol";
import "../Interfaces/IPDMStaking.sol";

contract PDMStaking is IPDMStaking, PausableUpgradeable, OwnableUpgradeable, BaseMath, ReentrancyGuardUpgradeable {
	using SafeERC20Upgradeable for IERC20Upgradeable;

	// --- Data ---
	string public constant NAME = "PDMStaking";
	address constant ETH_REF_ADDRESS = address(0);

	mapping(address => uint256) public stakes;
	uint256 public totalPDMStaked;

	mapping(address => uint256) public F_ASSETS; // Running sum of asset fees per-PDM-staked
	uint256 public F_DEBT_TOKENS; // Running sum of debt token fees per-PDM-staked

	// User snapshots of F_ASSETS and F_DEBT_TOKENS, taken at the point at which their latest deposit was made
	mapping(address => Snapshot) public snapshots;

	struct Snapshot {
		mapping(address => uint256) F_ASSETS_Snapshot;
		uint256 F_DEBT_TOKENS_Snapshot;
	}

	address[] ASSET_TYPE;
	mapping(address => bool) isAssetTracked;
	mapping(address => uint256) public sentToTreasuryTracker;

	IERC20Upgradeable public override pdmToken;

	address public debtTokenAddress;
	address public feeCollectorAddress;
	address public treasuryAddress;
	address public troveManagerAddress;

	bool public isSetupInitialized;

	// --- Initializer ---

	function initialize() public initializer {
		__Ownable_init();
		__ReentrancyGuard_init();
		__Pausable_init();
		_pause();
	}

	// --- Functions ---
	function setAddresses(
		address _debtTokenAddress,
		address _feeCollectorAddress,
		address _pdmTokenAddress,
		address _treasuryAddress,
		address _troveManagerAddress
	) external onlyOwner {
		require(!isSetupInitialized, "Setup is already initialized");

		debtTokenAddress = _debtTokenAddress;
		feeCollectorAddress = _feeCollectorAddress;
		pdmToken = IERC20Upgradeable(_pdmTokenAddress);
		treasuryAddress = _treasuryAddress;
		troveManagerAddress = _troveManagerAddress;

		isAssetTracked[ETH_REF_ADDRESS] = true;
		ASSET_TYPE.push(ETH_REF_ADDRESS);
		isSetupInitialized = true;
	}

	// If caller has a pre-existing stake, send any accumulated asset and debtToken gains to them.
	function stake(uint256 _PDMamount) external override nonReentrant whenNotPaused {
		require(_PDMamount > 0);

		uint256 currentStake = stakes[msg.sender];

		uint256 assetLength = ASSET_TYPE.length;
		uint256 assetGain;
		address asset;

		for (uint256 i = 0; i < assetLength; i++) {
			asset = ASSET_TYPE[i];

			if (currentStake != 0) {
				assetGain = _getPendingAssetGain(asset, msg.sender);

				if (i == 0) {
					uint256 debtTokenGain = _getPendingDebtTokenGain(msg.sender);
					IERC20Upgradeable(debtTokenAddress).safeTransfer(msg.sender, debtTokenGain);
					emit StakingGainsDebtTokensWithdrawn(msg.sender, debtTokenGain);
				}

				_sendAssetGainToUser(asset, assetGain);
				emit StakingGainsAssetWithdrawn(msg.sender, asset, assetGain);
			}

			_updateUserSnapshots(asset, msg.sender);
		}

		uint256 newStake = currentStake + _PDMamount;

		// Increase user’s stake and total PDM staked
		stakes[msg.sender] = newStake;
		totalPDMStaked = totalPDMStaked + _PDMamount;
		emit TotalPDMStakedUpdated(totalPDMStaked);

		// Transfer PDM from caller to this contract
		pdmToken.transferFrom(msg.sender, address(this), _PDMamount);

		emit StakeChanged(msg.sender, newStake);
	}

	// Unstake the PDM and send the it back to the caller, along with their accumulated gains.
	// If requested amount > stake, send their entire stake.
	function unstake(uint256 _PDMamount) external override nonReentrant {
		uint256 currentStake = stakes[msg.sender];
		_requireUserHasStake(currentStake);

		uint256 assetLength = ASSET_TYPE.length;
		uint256 assetGain;
		address asset;

		for (uint256 i = 0; i < assetLength; i++) {
			asset = ASSET_TYPE[i];

			// Grab any accumulated asset and debtToken gains from the current stake
			assetGain = _getPendingAssetGain(asset, msg.sender);

			if (i == 0) {
				uint256 debtTokenGain = _getPendingDebtTokenGain(msg.sender);
				IERC20Upgradeable(debtTokenAddress).safeTransfer(msg.sender, debtTokenGain);
				emit StakingGainsDebtTokensWithdrawn(msg.sender, debtTokenGain);
			}

			_updateUserSnapshots(asset, msg.sender);
			emit StakingGainsAssetWithdrawn(msg.sender, asset, assetGain);
			_sendAssetGainToUser(asset, assetGain);
		}

		if (_PDMamount > 0) {
			uint256 PDMToWithdraw = PalladiumMath._min(_PDMamount, currentStake);
			uint256 newStake = currentStake - PDMToWithdraw;

			// Decrease user's stake and total PDM staked
			stakes[msg.sender] = newStake;
			totalPDMStaked = totalPDMStaked - PDMToWithdraw;
			emit TotalPDMStakedUpdated(totalPDMStaked);

			// Transfer unstaked PDM to user
			IERC20Upgradeable(address(pdmToken)).safeTransfer(msg.sender, PDMToWithdraw);
			emit StakeChanged(msg.sender, newStake);
		}
	}

	function pause() public onlyOwner {
		_pause();
	}

	function unpause() public onlyOwner {
		_unpause();
	}

	// --- Reward-per-unit-staked increase functions. Called by Palladium core contracts ---

	function increaseFee_Asset(address _asset, uint256 _assetFee) external override callerIsTroveManager {
		if (paused()) {
			sendToTreasury(_asset, _assetFee);
			return;
		}

		if (!isAssetTracked[_asset]) {
			isAssetTracked[_asset] = true;
			ASSET_TYPE.push(_asset);
		}

		uint256 assetFeePerPDMStaked;

		if (totalPDMStaked > 0) {
			assetFeePerPDMStaked = (_assetFee * DECIMAL_PRECISION) / totalPDMStaked;
		}

		F_ASSETS[_asset] = F_ASSETS[_asset] + assetFeePerPDMStaked;
		emit Fee_AssetUpdated(_asset, F_ASSETS[_asset]);
	}

	function increaseFee_DebtToken(uint256 _debtTokenFee) external override callerIsFeeCollector {
		if (paused()) {
			sendToTreasury(debtTokenAddress, _debtTokenFee);
			return;
		}

		uint256 feePerPDMStaked;
		if (totalPDMStaked > 0) {
			feePerPDMStaked = (_debtTokenFee * DECIMAL_PRECISION) / totalPDMStaked;
		}

		F_DEBT_TOKENS = F_DEBT_TOKENS + feePerPDMStaked;
		emit Fee_DebtTokenUpdated(F_DEBT_TOKENS);
	}

	function sendToTreasury(address _asset, uint256 _amount) internal {
		_sendAsset(treasuryAddress, _asset, _amount);
		sentToTreasuryTracker[_asset] += _amount;
		emit SentToTreasury(_asset, _amount);
	}

	// --- Pending reward functions ---

	function getPendingAssetGain(address _asset, address _user) external view override returns (uint256) {
		return _getPendingAssetGain(_asset, _user);
	}

	function _getPendingAssetGain(address _asset, address _user) internal view returns (uint256) {
		uint256 F_ASSET_Snapshot = snapshots[_user].F_ASSETS_Snapshot[_asset];
		uint256 AssetGain = (stakes[_user] * (F_ASSETS[_asset] - F_ASSET_Snapshot)) / DECIMAL_PRECISION;
		return AssetGain;
	}

	function getPendingDebtTokenGain(address _user) external view override returns (uint256) {
		return _getPendingDebtTokenGain(_user);
	}

	function _getPendingDebtTokenGain(address _user) internal view returns (uint256) {
		uint256 debtTokenSnapshot = snapshots[_user].F_DEBT_TOKENS_Snapshot;
		return (stakes[_user] * (F_DEBT_TOKENS - debtTokenSnapshot)) / DECIMAL_PRECISION;
	}

	// --- Internal helper functions ---

	function _updateUserSnapshots(address _asset, address _user) internal {
		snapshots[_user].F_ASSETS_Snapshot[_asset] = F_ASSETS[_asset];
		snapshots[_user].F_DEBT_TOKENS_Snapshot = F_DEBT_TOKENS;
		emit StakerSnapshotsUpdated(_user, F_ASSETS[_asset], F_DEBT_TOKENS);
	}

	function _sendAssetGainToUser(address _asset, uint256 _assetGain) internal {
		_assetGain = SafetyTransfer.decimalsCorrection(_asset, _assetGain);
		_sendAsset(msg.sender, _asset, _assetGain);
		emit AssetSent(_asset, msg.sender, _assetGain);
	}

	function _sendAsset(address _sendTo, address _asset, uint256 _amount) internal {
		IERC20Upgradeable(_asset).safeTransfer(_sendTo, _amount);
	}

	// --- 'require' functions ---

	modifier callerIsTroveManager() {
		require(msg.sender == troveManagerAddress, "PDMStaking: caller is not TroveManager");
		_;
	}

	modifier callerIsFeeCollector() {
		require(msg.sender == feeCollectorAddress, "PDMStaking: caller is not FeeCollector");
		_;
	}

	function _requireUserHasStake(uint256 currentStake) internal pure {
		require(currentStake > 0, "PDMStaking: User must have a non-zero stake");
	}
}

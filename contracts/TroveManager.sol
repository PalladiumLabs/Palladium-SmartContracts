// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";

import "./Dependencies/PalladiumBase.sol";
import "./Interfaces/ITroveManager.sol";
import "./Interfaces/IFeeCollector.sol";

contract TroveManager is ITroveManager, UUPSUpgradeable, ReentrancyGuardUpgradeable, PalladiumBase {
	// Constants ------------------------------------------------------------------------------------------------------

	string public constant NAME = "TroveManager";

	uint256 public constant SECONDS_IN_ONE_MINUTE = 60;
	/*
	 * Half-life of 12h. 12h = 720 min
	 * (1/2) = d^720 => d = (1/2)^(1/720)
	 */
	uint256 public constant MINUTE_DECAY_FACTOR = 999037758833783000;

	/*
	 * BETA: 18 digit decimal. Parameter by which to divide the redeemed fraction, in order to calc the new base rate from a redemption.
	 * Corresponds to (1 / ALPHA) in the white paper.
	 */
	uint256 public constant BETA = 2;

	// Structs --------------------------------------------------------------------------------------------------------

	// Object containing the asset and debt token snapshots for a given active trove
	struct RewardSnapshot {
		uint256 asset;
		uint256 debt;
	}

	// State ----------------------------------------------------------------------------------------------------------

	mapping(address => uint256) public baseRate;

	// The timestamp of the latest fee operation (redemption or new debt token issuance)
	mapping(address => uint256) public lastFeeOperationTime;

	// Troves[borrower address][Collateral address]
	mapping(address => mapping(address => Trove)) public Troves;

	mapping(address => uint256) public totalStakes;

	// Snapshot of the value of totalStakes, taken immediately after the latest liquidation
	mapping(address => uint256) public totalStakesSnapshot;

	// Snapshot of the total collateral across the ActivePool and DefaultPool, immediately after the latest liquidation.
	mapping(address => uint256) public totalCollateralSnapshot;

	/*
	 * L_Colls and L_Debts track the sums of accumulated liquidation rewards per unit staked. During its lifetime, each stake earns:
	 *
	 * An asset gain of ( stake * [L_Colls - L_Colls(0)] )
	 * A debt increase of ( stake * [L_Debts - L_Debts(0)] )
	 *
	 * Where L_Colls(0) and L_Debts(0) are snapshots of L_Colls and L_Debts for the active Trove taken at the instant the stake was made
	 */
	mapping(address => uint256) public L_Colls;
	mapping(address => uint256) public L_Debts;

	// Map addresses with active troves to their RewardSnapshot
	mapping(address => mapping(address => RewardSnapshot)) public rewardSnapshots;

	// Array of all active trove addresses - used to to compute an approximate hint off-chain, for the sorted list insertion
	mapping(address => address[]) public TroveOwners;

	// Error trackers for the trove redistribution calculation
	mapping(address => uint256) public lastCollError_Redistribution;
	mapping(address => uint256) public lastDebtError_Redistribution;

	bool public isSetupInitialized;

	// Modifiers ------------------------------------------------------------------------------------------------------

	modifier onlyTroveManagerOperations() {
		if (msg.sender != troveManagerOperations) {
			revert TroveManager__OnlyTroveManagerOperations();
		}
		_;
	}

	modifier onlyBorrowerOperations() {
		if (msg.sender != borrowerOperations) {
			revert TroveManager__OnlyBorrowerOperations();
		}
		_;
	}

	modifier onlyTroveManagerOperationsOrBorrowerOperations() {
		if (msg.sender != borrowerOperations && msg.sender != troveManagerOperations) {
			revert TroveManager__OnlyTroveManagerOperationsOrBorrowerOperations();
		}
		_;
	}

	// Initializer ------------------------------------------------------------------------------------------------------

	function initialize() public initializer {
		__Ownable_init();
		__UUPSUpgradeable_init();
		__ReentrancyGuard_init();
	}

	// External/public functions --------------------------------------------------------------------------------------

	function isValidFirstRedemptionHint(
		address _asset,
		address _firstRedemptionHint,
		uint256 _price
	) external view returns (bool) {
		if (
			_firstRedemptionHint == address(0) ||
			!ISortedTroves(sortedTroves).contains(_asset, _firstRedemptionHint) ||
			getCurrentICR(_asset, _firstRedemptionHint, _price) < IAdminContract(adminContract).getMcr(_asset)
		) {
			return false;
		}
		address nextTrove = ISortedTroves(sortedTroves).getNext(_asset, _firstRedemptionHint);
		return
			nextTrove == address(0) ||
			getCurrentICR(_asset, nextTrove, _price) < IAdminContract(adminContract).getMcr(_asset);
	}

	// Return the nominal collateral ratio (ICR) of a given Trove, without the price. Takes a trove's pending coll and debt rewards from redistributions into account.
	function getNominalICR(address _asset, address _borrower) external view override returns (uint256) {
		(uint256 currentAsset, uint256 currentDebt) = _getCurrentTroveAmounts(_asset, _borrower);

		uint256 NICR = PalladiumMath._computeNominalCR(currentAsset, currentDebt);
		return NICR;
	}

	// Return the current collateral ratio (ICR) of a given Trove. Takes a trove's pending coll and debt rewards from redistributions into account.
	function getCurrentICR(address _asset, address _borrower, uint256 _price) public view override returns (uint256) {
		(uint256 currentAsset, uint256 currentDebt) = _getCurrentTroveAmounts(_asset, _borrower);
		uint256 ICR = PalladiumMath._computeCR(currentAsset, currentDebt, _price);
		return ICR;
	}

	// Get the borrower's pending accumulated asset reward, earned by their stake
	function getPendingAssetReward(address _asset, address _borrower) public view override returns (uint256) {
		uint256 snapshotAsset = rewardSnapshots[_borrower][_asset].asset;
		uint256 rewardPerUnitStaked = L_Colls[_asset] - snapshotAsset;
		if (rewardPerUnitStaked == 0 || !isTroveActive(_asset, _borrower)) {
			return 0;
		}
		uint256 stake = Troves[_borrower][_asset].stake;
		uint256 pendingAssetReward = (stake * rewardPerUnitStaked) / DECIMAL_PRECISION;
		return pendingAssetReward;
	}

	// Get the borrower's pending accumulated debt token reward, earned by their stake
	function getPendingDebtTokenReward(address _asset, address _borrower) public view override returns (uint256) {
		uint256 snapshotDebt = rewardSnapshots[_borrower][_asset].debt;
		uint256 rewardPerUnitStaked = L_Debts[_asset] - snapshotDebt;
		if (rewardPerUnitStaked == 0 || !isTroveActive(_asset, _borrower)) {
			return 0;
		}
		uint256 stake = Troves[_borrower][_asset].stake;
		return (stake * rewardPerUnitStaked) / DECIMAL_PRECISION;
	}

	function hasPendingRewards(address _asset, address _borrower) public view override returns (bool) {
		if (!isTroveActive(_asset, _borrower)) {
			return false;
		}
		return (rewardSnapshots[_borrower][_asset].asset < L_Colls[_asset]);
	}

	function getEntireDebtAndColl(
		address _asset,
		address _borrower
	) external view override returns (uint256 debt, uint256 coll, uint256 pendingDebtReward, uint256 pendingCollReward) {
		pendingDebtReward = getPendingDebtTokenReward(_asset, _borrower);
		pendingCollReward = getPendingAssetReward(_asset, _borrower);
		Trove storage trove = Troves[_borrower][_asset];
		debt = trove.debt + pendingDebtReward;
		coll = trove.coll + pendingCollReward;
	}

	function isTroveActive(address _asset, address _borrower) public view override returns (bool) {
		return getTroveStatus(_asset, _borrower) == uint256(Status.active);
	}

	function getTCR(address _asset, uint256 _price) external view override returns (uint256) {
		return _getTCR(_asset, _price);
	}

	function checkRecoveryMode(address _asset, uint256 _price) external view override returns (bool) {
		return _checkRecoveryMode(_asset, _price);
	}

	function getBorrowingRate(address _asset) external view override returns (uint256) {
		return IAdminContract(adminContract).getBorrowingFee(_asset);
	}

	function getBorrowingFee(address _asset, uint256 _debt) external view override returns (uint256) {
		return (IAdminContract(adminContract).getBorrowingFee(_asset) * _debt) / DECIMAL_PRECISION;
	}

	function getRedemptionFee(address _asset, uint256 _assetDraw) public view returns (uint256) {
		return _calcRedemptionFee(getRedemptionRate(_asset), _assetDraw);
	}

	function getRedemptionFeeWithDecay(address _asset, uint256 _assetDraw) external view override returns (uint256) {
		return _calcRedemptionFee(getRedemptionRateWithDecay(_asset), _assetDraw);
	}

	function getRedemptionRate(address _asset) public view override returns (uint256) {
		return _calcRedemptionRate(_asset, baseRate[_asset]);
	}

	function getRedemptionRateWithDecay(address _asset) public view override returns (uint256) {
		return _calcRedemptionRate(_asset, _calcDecayedBaseRate(_asset));
	}

	// Called by Palladium contracts ------------------------------------------------------------------------------------

	function addTroveOwnerToArray(
		address _asset,
		address _borrower
	) external override onlyBorrowerOperations returns (uint256 index) {
		address[] storage assetOwners = TroveOwners[_asset];
		assetOwners.push(_borrower);
		index = assetOwners.length - 1;
		Troves[_borrower][_asset].arrayIndex = uint128(index);
		return index;
	}

	function executeFullRedemption(
		address _asset,
		address _borrower,
		uint256 _newColl
	) external override nonReentrant onlyTroveManagerOperations {
		_removeStake(_asset, _borrower);
		_closeTrove(_asset, _borrower, Status.closedByRedemption);
		_redeemCloseTrove(_asset, _borrower, IAdminContract(adminContract).getDebtTokenGasCompensation(_asset), _newColl);
		IFeeCollector(feeCollector).closeDebt(_borrower, _asset);
		emit TroveUpdated(_asset, _borrower, 0, 0, 0, TroveManagerOperation.redeemCollateral);
	}

	function executePartialRedemption(
		address _asset,
		address _borrower,
		uint256 _newDebt,
		uint256 _newColl,
		uint256 _newNICR,
		address _upperPartialRedemptionHint,
		address _lowerPartialRedemptionHint
	) external override onlyTroveManagerOperations {
		ISortedTroves(sortedTroves).reInsert(
			_asset,
			_borrower,
			_newNICR,
			_upperPartialRedemptionHint,
			_lowerPartialRedemptionHint
		);

		Trove storage trove = Troves[_borrower][_asset];
		uint256 paybackFraction = ((trove.debt - _newDebt) * 1 ether) / trove.debt;
		if (paybackFraction != 0) {
			IFeeCollector(feeCollector).decreaseDebt(_borrower, _asset, paybackFraction);
		}

		trove.debt = _newDebt;
		trove.coll = _newColl;
		_updateStakeAndTotalStakes(_asset, _borrower);

		emit TroveUpdated(_asset, _borrower, _newDebt, _newColl, trove.stake, TroveManagerOperation.redeemCollateral);
	}

	function finalizeRedemption(
		address _asset,
		address _receiver,
		uint256 _debtToRedeem,
		uint256 _assetFeeAmount,
		uint256 _assetRedeemedAmount
	) external override onlyTroveManagerOperations {
		// Send the asset fee
		if (_assetFeeAmount != 0) {
			address destination = IFeeCollector(feeCollector).getProtocolRevenueDestination();
			IActivePool(activePool).sendAsset(_asset, destination, _assetFeeAmount);
			IFeeCollector(feeCollector).handleRedemptionFee(_asset, _assetFeeAmount);
		}
		// Burn the total debt tokens that is cancelled with debt, and send the redeemed asset to msg.sender
		IDebtToken(debtToken).burn(_receiver, _debtToRedeem);
		// Update Active Pool, and send asset to account
		uint256 collToSendToRedeemer = _assetRedeemedAmount - _assetFeeAmount;
		IActivePool(activePool).decreaseDebt(_asset, _debtToRedeem);
		IActivePool(activePool).sendAsset(_asset, _receiver, collToSendToRedeemer);
	}

	function updateBaseRateFromRedemption(
		address _asset,
		uint256 _assetDrawn,
		uint256 _price,
		uint256 _totalDebtTokenSupply
	) external override onlyTroveManagerOperations returns (uint256) {
		uint256 decayedBaseRate = _calcDecayedBaseRate(_asset);
		uint256 redeemedDebtFraction = (_assetDrawn * _price) / _totalDebtTokenSupply;
		uint256 newBaseRate = decayedBaseRate + (redeemedDebtFraction / BETA);
		newBaseRate = PalladiumMath._min(newBaseRate, DECIMAL_PRECISION);
		assert(newBaseRate != 0);
		baseRate[_asset] = newBaseRate;
		emit BaseRateUpdated(_asset, newBaseRate);
		_updateLastFeeOpTime(_asset);
		return newBaseRate;
	}

	function applyPendingRewards(
		address _asset,
		address _borrower
	) external override nonReentrant onlyTroveManagerOperationsOrBorrowerOperations {
		return _applyPendingRewards(_asset, _borrower);
	}

	// Move a Trove's pending debt and collateral rewards from distributions, from the Default Pool to the Active Pool
	function movePendingTroveRewardsToActivePool(
		address _asset,
		uint256 _debt,
		uint256 _assetAmount
	) external override onlyTroveManagerOperations {
		_movePendingTroveRewardsToActivePool(_asset, _debt, _assetAmount);
	}

	// Update borrower's snapshots of L_Colls and L_Debts to reflect the current values
	function updateTroveRewardSnapshots(address _asset, address _borrower) external override onlyBorrowerOperations {
		return _updateTroveRewardSnapshots(_asset, _borrower);
	}

	function updateStakeAndTotalStakes(
		address _asset,
		address _borrower
	) external override onlyBorrowerOperations returns (uint256) {
		return _updateStakeAndTotalStakes(_asset, _borrower);
	}

	function removeStake(
		address _asset,
		address _borrower
	) external override onlyTroveManagerOperationsOrBorrowerOperations {
		return _removeStake(_asset, _borrower);
	}

	function redistributeDebtAndColl(
		address _asset,
		uint256 _debt,
		uint256 _coll,
		uint256 _debtToOffset,
		uint256 _collToSendToStabilityPool
	) external override nonReentrant onlyTroveManagerOperations {
		IStabilityPool(stabilityPool).offset(_debtToOffset, _asset, _collToSendToStabilityPool);

		if (_debt == 0) {
			return;
		}
		/*
		 * Add distributed coll and debt rewards-per-unit-staked to the running totals. Division uses a "feedback"
		 * error correction, to keep the cumulative error low in the running totals L_Colls and L_Debts:
		 *
		 * 1) Form numerators which compensate for the floor division errors that occurred the last time this
		 * function was called.
		 * 2) Calculate "per-unit-staked" ratios.
		 * 3) Multiply each ratio back by its denominator, to reveal the current floor division error.
		 * 4) Store these errors for use in the next correction when this function is called.
		 * 5) Note: static analysis tools complain about this "division before multiplication", however, it is intended.
		 */
		uint256 collNumerator = (_coll * DECIMAL_PRECISION) + lastCollError_Redistribution[_asset];
		uint256 debtNumerator = (_debt * DECIMAL_PRECISION) + lastDebtError_Redistribution[_asset];

		// Get the per-unit-staked terms
		uint256 assetStakes = totalStakes[_asset];
		uint256 collRewardPerUnitStaked = collNumerator / assetStakes;
		uint256 debtRewardPerUnitStaked = debtNumerator / assetStakes;

		lastCollError_Redistribution[_asset] = collNumerator - (collRewardPerUnitStaked * assetStakes);
		lastDebtError_Redistribution[_asset] = debtNumerator - (debtRewardPerUnitStaked * assetStakes);

		// Add per-unit-staked terms to the running totals
		uint256 liquidatedColl = L_Colls[_asset] + collRewardPerUnitStaked;
		uint256 liquidatedDebt = L_Debts[_asset] + debtRewardPerUnitStaked;
		L_Colls[_asset] = liquidatedColl;
		L_Debts[_asset] = liquidatedDebt;
		emit LTermsUpdated(_asset, liquidatedColl, liquidatedDebt);

		IActivePool(activePool).decreaseDebt(_asset, _debt);
		IDefaultPool(defaultPool).increaseDebt(_asset, _debt);
		IActivePool(activePool).sendAsset(_asset, defaultPool, _coll);
	}

	function updateSystemSnapshots_excludeCollRemainder(
		address _asset,
		uint256 _collRemainder
	) external onlyTroveManagerOperations {
		uint256 totalStakesCached = totalStakes[_asset];
		totalStakesSnapshot[_asset] = totalStakesCached;
		uint256 activeColl = IActivePool(activePool).getAssetBalance(_asset);
		uint256 liquidatedColl = IDefaultPool(defaultPool).getAssetBalance(_asset);
		uint256 _totalCollateralSnapshot = activeColl - _collRemainder + liquidatedColl;
		totalCollateralSnapshot[_asset] = _totalCollateralSnapshot;
		emit SystemSnapshotsUpdated(_asset, totalStakesCached, _totalCollateralSnapshot);
	}

	function closeTrove(
		address _asset,
		address _borrower
	) external override onlyTroveManagerOperationsOrBorrowerOperations {
		return _closeTrove(_asset, _borrower, Status.closedByOwner);
	}

	function closeTroveLiquidation(address _asset, address _borrower) external override onlyTroveManagerOperations {
		_closeTrove(_asset, _borrower, Status.closedByLiquidation);
		IFeeCollector(feeCollector).liquidateDebt(_borrower, _asset);
		emit TroveUpdated(_asset, _borrower, 0, 0, 0, TroveManagerOperation.liquidateInNormalMode);
	}

	function sendGasCompensation(
		address _asset,
		address _liquidator,
		uint256 _debtTokenAmount,
		uint256 _assetAmount
	) external nonReentrant onlyTroveManagerOperations {
		if (_debtTokenAmount != 0) {
			IDebtToken(debtToken).returnFromPool(gasPoolAddress, _liquidator, _debtTokenAmount);
		}
		if (_assetAmount != 0) {
			IActivePool(activePool).sendAsset(_asset, _liquidator, _assetAmount);
		}
	}

	// Internal functions ---------------------------------------------------------------------------------------------

	function _redeemCloseTrove(
		address _asset,
		address _borrower,
		uint256 _debtTokenAmount,
		uint256 _assetAmount
	) internal {
		IDebtToken(debtToken).burn(gasPoolAddress, _debtTokenAmount);
		// Update Active Pool, and send asset to account
		IActivePool(activePool).decreaseDebt(_asset, _debtTokenAmount);
		// send asset from Active Pool to CollSurplus Pool
		ICollSurplusPool(collSurplusPool).accountSurplus(_asset, _borrower, _assetAmount);
		IActivePool(activePool).sendAsset(_asset, collSurplusPool, _assetAmount);
	}

	function _movePendingTroveRewardsToActivePool(
		address _asset,
		uint256 _debtTokenAmount,
		uint256 _assetAmount
	) internal {
		IDefaultPool(defaultPool).decreaseDebt(_asset, _debtTokenAmount);
		IActivePool(activePool).increaseDebt(_asset, _debtTokenAmount);
		IDefaultPool(defaultPool).sendAssetToActivePool(_asset, _assetAmount);
	}

	function _getCurrentTroveAmounts(
		address _asset,
		address _borrower
	) internal view returns (uint256 coll, uint256 debt) {
		uint256 pendingCollReward = getPendingAssetReward(_asset, _borrower);
		uint256 pendingDebtReward = getPendingDebtTokenReward(_asset, _borrower);
		Trove memory trove = Troves[_borrower][_asset];
		coll = trove.coll + pendingCollReward;
		debt = trove.debt + pendingDebtReward;
	}

	// Add the borrowers's coll and debt rewards earned from redistributions, to their Trove
	function _applyPendingRewards(address _asset, address _borrower) internal {
		if (!hasPendingRewards(_asset, _borrower)) {
			return;
		}

		// Compute pending rewards
		uint256 pendingCollReward = getPendingAssetReward(_asset, _borrower);
		uint256 pendingDebtReward = getPendingDebtTokenReward(_asset, _borrower);

		// Apply pending rewards to trove's state
		Trove storage trove = Troves[_borrower][_asset];
		trove.coll = trove.coll + pendingCollReward;
		trove.debt = trove.debt + pendingDebtReward;

		_updateTroveRewardSnapshots(_asset, _borrower);

		// Transfer from DefaultPool to ActivePool
		_movePendingTroveRewardsToActivePool(_asset, pendingDebtReward, pendingCollReward);

		emit TroveUpdated(
			_asset,
			_borrower,
			trove.debt,
			trove.coll,
			trove.stake,
			TroveManagerOperation.applyPendingRewards
		);
	}

	function _updateTroveRewardSnapshots(address _asset, address _borrower) internal {
		uint256 liquidatedColl = L_Colls[_asset];
		uint256 liquidatedDebt = L_Debts[_asset];
		RewardSnapshot storage snapshot = rewardSnapshots[_borrower][_asset];
		snapshot.asset = liquidatedColl;
		snapshot.debt = liquidatedDebt;
		emit TroveSnapshotsUpdated(_asset, liquidatedColl, liquidatedDebt);
	}

	function _removeStake(address _asset, address _borrower) internal {
		Trove storage trove = Troves[_borrower][_asset];
		totalStakes[_asset] -= trove.stake;
		trove.stake = 0;
	}

	// Update borrower's stake based on their latest collateral value
	function _updateStakeAndTotalStakes(address _asset, address _borrower) internal returns (uint256) {
		Trove storage trove = Troves[_borrower][_asset];
		uint256 newStake = _computeNewStake(_asset, trove.coll);
		uint256 oldStake = trove.stake;
		trove.stake = newStake;
		uint256 newTotal = totalStakes[_asset] - oldStake + newStake;
		totalStakes[_asset] = newTotal;
		emit TotalStakesUpdated(_asset, newTotal);
		return newStake;
	}

	// Calculate a new stake based on the snapshots of the totalStakes and totalCollateral taken at the last liquidation
	function _computeNewStake(address _asset, uint256 _coll) internal view returns (uint256 stake) {
		uint256 assetColl = totalCollateralSnapshot[_asset];
		if (assetColl == 0) {
			stake = _coll;
		} else {
			uint256 assetStakes = totalStakesSnapshot[_asset];
			/*
			 * The following assert() holds true because:
			 * - The system always contains >= 1 trove
			 * - When we close or liquidate a trove, we redistribute the pending rewards, so if all troves were closed/liquidated,
			 * rewards would’ve been emptied and totalCollateralSnapshot would be zero too.
			 */
			assert(assetStakes != 0);
			stake = (_coll * assetStakes) / assetColl;
		}
	}

	function _closeTrove(address _asset, address _borrower, Status closedStatus) internal {
		assert(closedStatus != Status.nonExistent && closedStatus != Status.active);

		uint256 TroveOwnersArrayLength = TroveOwners[_asset].length;
		// if (TroveOwnersArrayLength <= 1 || ISortedTroves(sortedTroves).getSize(_asset) <= 1) {
		// 	revert TroveManager__OnlyOneTrove();
		// }

		Trove storage trove = Troves[_borrower][_asset];
		trove.status = closedStatus;
		trove.coll = 0;
		trove.debt = 0;

		RewardSnapshot storage rewardSnapshot = rewardSnapshots[_borrower][_asset];
		rewardSnapshot.asset = 0;
		rewardSnapshot.debt = 0;

		_removeTroveOwner(_asset, _borrower, TroveOwnersArrayLength);
		ISortedTroves(sortedTroves).remove(_asset, _borrower);
	}

	function _removeTroveOwner(address _asset, address _borrower, uint256 TroveOwnersArrayLength) internal {
		Trove memory trove = Troves[_borrower][_asset];
		assert(trove.status != Status.nonExistent && trove.status != Status.active);

		uint128 index = trove.arrayIndex;
		uint256 length = TroveOwnersArrayLength;
		uint256 idxLast = length - 1;

		assert(index <= idxLast);

		address[] storage troveAssetOwners = TroveOwners[_asset];
		address addressToMove = troveAssetOwners[idxLast];

		troveAssetOwners[index] = addressToMove;
		Troves[addressToMove][_asset].arrayIndex = index;
		emit TroveIndexUpdated(_asset, addressToMove, index);

		troveAssetOwners.pop();
	}

	function _calcRedemptionRate(address _asset, uint256 _baseRate) internal view returns (uint256) {
		return
			PalladiumMath._min(IAdminContract(adminContract).getRedemptionFeeFloor(_asset) + _baseRate, DECIMAL_PRECISION);
	}

	function _calcRedemptionFee(uint256 _redemptionRate, uint256 _assetDraw) internal pure returns (uint256) {
		uint256 redemptionFee = (_redemptionRate * _assetDraw) / DECIMAL_PRECISION;
		if (redemptionFee >= _assetDraw) {
			revert TroveManager__FeeBiggerThanAssetDraw();
		}
		return redemptionFee;
	}

	function _updateLastFeeOpTime(address _asset) internal {
		uint256 timePassed = block.timestamp - lastFeeOperationTime[_asset];
		if (timePassed >= SECONDS_IN_ONE_MINUTE) {
			// Update the last fee operation time only if time passed >= decay interval. This prevents base rate griefing.
			lastFeeOperationTime[_asset] = block.timestamp;
			emit LastFeeOpTimeUpdated(_asset, block.timestamp);
		}
	}

	function _calcDecayedBaseRate(address _asset) internal view returns (uint256) {
		uint256 minutesPassed = _minutesPassedSinceLastFeeOp(_asset);
		uint256 decayFactor = PalladiumMath._decPow(MINUTE_DECAY_FACTOR, minutesPassed);
		return (baseRate[_asset] * decayFactor) / DECIMAL_PRECISION;
	}

	function _minutesPassedSinceLastFeeOp(address _asset) internal view returns (uint256) {
		return (block.timestamp - lastFeeOperationTime[_asset]) / SECONDS_IN_ONE_MINUTE;
	}

	// --- Trove property getters --------------------------------------------------------------------------------------

	function getTroveStatus(address _asset, address _borrower) public view override returns (uint256) {
		return uint256(Troves[_borrower][_asset].status);
	}

	function getTroveStake(address _asset, address _borrower) external view override returns (uint256) {
		return Troves[_borrower][_asset].stake;
	}

	function getTroveDebt(address _asset, address _borrower) external view override returns (uint256) {
		return Troves[_borrower][_asset].debt;
	}

	function getTroveColl(address _asset, address _borrower) external view override returns (uint256) {
		return Troves[_borrower][_asset].coll;
	}

	function getTroveOwnersCount(address _asset) external view override returns (uint256) {
		return TroveOwners[_asset].length;
	}

	function getTroveFromTroveOwnersArray(address _asset, uint256 _index) external view override returns (address) {
		return TroveOwners[_asset][_index];
	}

	// --- Trove property setters, called by Palladium's BorrowerOperations/VMRedemptions/VMLiquidations ---------------

	function setTroveStatus(address _asset, address _borrower, uint256 _num) external override onlyBorrowerOperations {
		Troves[_borrower][_asset].status = Status(_num);
	}

	function increaseTroveColl(
		address _asset,
		address _borrower,
		uint256 _collIncrease
	) external override onlyBorrowerOperations returns (uint256 newColl) {
		Trove storage trove = Troves[_borrower][_asset];
		newColl = trove.coll + _collIncrease;
		trove.coll = newColl;
	}

	function decreaseTroveColl(
		address _asset,
		address _borrower,
		uint256 _collDecrease
	) external override onlyBorrowerOperations returns (uint256 newColl) {
		Trove storage trove = Troves[_borrower][_asset];
		newColl = trove.coll - _collDecrease;
		trove.coll = newColl;
	}

	function increaseTroveDebt(
		address _asset,
		address _borrower,
		uint256 _debtIncrease
	) external override onlyBorrowerOperations returns (uint256 newDebt) {
		Trove storage trove = Troves[_borrower][_asset];
		newDebt = trove.debt + _debtIncrease;
		trove.debt = newDebt;
	}

	function decreaseTroveDebt(
		address _asset,
		address _borrower,
		uint256 _debtDecrease
	) external override onlyBorrowerOperations returns (uint256) {
		Trove storage trove = Troves[_borrower][_asset];
		uint256 oldDebt = trove.debt;
		if (_debtDecrease == 0) {
			return oldDebt; // no changes
		}
		uint256 paybackFraction = (_debtDecrease * 1 ether) / oldDebt;
		uint256 newDebt = oldDebt - _debtDecrease;
		trove.debt = newDebt;
		if (paybackFraction != 0) {
			IFeeCollector(feeCollector).decreaseDebt(_borrower, _asset, paybackFraction);
		}
		return newDebt;
	}

	function authorizeUpgrade(address newImplementation) public {
		require(newImplementation != address(0), "TroveManager: new implementation is the zero address");
		_authorizeUpgrade(newImplementation);
	}

	function _authorizeUpgrade(address) internal override onlyOwner {}
}

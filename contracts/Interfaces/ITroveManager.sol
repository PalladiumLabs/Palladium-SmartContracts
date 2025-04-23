// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import "./IActivePool.sol";
import "./ICollSurplusPool.sol";
import "./IDebtToken.sol";
import "./IDefaultPool.sol";
import "./IPalladiumBase.sol";
import "./ISortedTroves.sol";
import "./IStabilityPool.sol";

interface ITroveManager is IPalladiumBase {
	// Enums ------------------------------------------------------------------------------------------------------------

	enum Status {
		nonExistent,
		active,
		closedByOwner,
		closedByLiquidation,
		closedByRedemption
	}

	enum TroveManagerOperation {
		applyPendingRewards,
		liquidateInNormalMode,
		liquidateInRecoveryMode,
		redeemCollateral
	}

	// Events -----------------------------------------------------------------------------------------------------------

	event BaseRateUpdated(address indexed _asset, uint256 _baseRate);
	event LastFeeOpTimeUpdated(address indexed _asset, uint256 _lastFeeOpTime);
	event TotalStakesUpdated(address indexed _asset, uint256 _newTotalStakes);
	event SystemSnapshotsUpdated(address indexed _asset, uint256 _totalStakesSnapshot, uint256 _totalCollateralSnapshot);
	event LTermsUpdated(address indexed _asset, uint256 _L_Coll, uint256 _L_Debt);
	event TroveSnapshotsUpdated(address indexed _asset, uint256 _L_Coll, uint256 _L_Debt);
	event TroveIndexUpdated(address indexed _asset, address _borrower, uint256 _newIndex);

	event TroveUpdated(
		address indexed _asset,
		address indexed _borrower,
		uint256 _debt,
		uint256 _coll,
		uint256 _stake,
		TroveManagerOperation _operation
	);

	// Custom Errors ----------------------------------------------------------------------------------------------------

	error TroveManager__FeeBiggerThanAssetDraw();
	error TroveManager__OnlyOneTrove();

	error TroveManager__OnlyTroveManagerOperations();
	error TroveManager__OnlyBorrowerOperations();
	error TroveManager__OnlyTroveManagerOperationsOrBorrowerOperations();

	// Structs ----------------------------------------------------------------------------------------------------------

	struct Trove {
		uint256 debt;
		uint256 coll;
		uint256 stake;
		Status status;
		uint128 arrayIndex;
	}

	// Functions --------------------------------------------------------------------------------------------------------

	function executeFullRedemption(address _asset, address _borrower, uint256 _newColl) external;

	function executePartialRedemption(
		address _asset,
		address _borrower,
		uint256 _newDebt,
		uint256 _newColl,
		uint256 _newNICR,
		address _upperPartialRedemptionHint,
		address _lowerPartialRedemptionHint
	) external;

	function getTroveOwnersCount(address _asset) external view returns (uint256);

	function getTroveFromTroveOwnersArray(address _asset, uint256 _index) external view returns (address);

	function getNominalICR(address _asset, address _borrower) external view returns (uint256);

	function getCurrentICR(address _asset, address _borrower, uint256 _price) external view returns (uint256);

	function updateStakeAndTotalStakes(address _asset, address _borrower) external returns (uint256);

	function updateTroveRewardSnapshots(address _asset, address _borrower) external;

	function addTroveOwnerToArray(address _asset, address _borrower) external returns (uint256 index);

	function applyPendingRewards(address _asset, address _borrower) external;

	function getPendingAssetReward(address _asset, address _borrower) external view returns (uint256);

	function getPendingDebtTokenReward(address _asset, address _borrower) external view returns (uint256);

	function hasPendingRewards(address _asset, address _borrower) external view returns (bool);

	function getEntireDebtAndColl(
		address _asset,
		address _borrower
	) external view returns (uint256 debt, uint256 coll, uint256 pendingDebtTokenReward, uint256 pendingAssetReward);

	function closeTrove(address _asset, address _borrower) external;

	function closeTroveLiquidation(address _asset, address _borrower) external;

	function removeStake(address _asset, address _borrower) external;

	function getRedemptionRate(address _asset) external view returns (uint256);

	function getRedemptionRateWithDecay(address _asset) external view returns (uint256);

	function getRedemptionFeeWithDecay(address _asset, uint256 _assetDraw) external view returns (uint256);

	function getBorrowingRate(address _asset) external view returns (uint256);

	function getBorrowingFee(address _asset, uint256 _debtTokenAmount) external view returns (uint256);

	function getTroveStatus(address _asset, address _borrower) external view returns (uint256);

	function getTroveStake(address _asset, address _borrower) external view returns (uint256);

	function getTroveDebt(address _asset, address _borrower) external view returns (uint256);

	function getTroveColl(address _asset, address _borrower) external view returns (uint256);

	function setTroveStatus(address _asset, address _borrower, uint256 num) external;

	function increaseTroveColl(address _asset, address _borrower, uint256 _collIncrease) external returns (uint256);

	function decreaseTroveColl(address _asset, address _borrower, uint256 _collDecrease) external returns (uint256);

	function increaseTroveDebt(address _asset, address _borrower, uint256 _debtIncrease) external returns (uint256);

	function decreaseTroveDebt(address _asset, address _borrower, uint256 _collDecrease) external returns (uint256);

	function getTCR(address _asset, uint256 _price) external view returns (uint256);

	function checkRecoveryMode(address _asset, uint256 _price) external returns (bool);

	function isValidFirstRedemptionHint(
		address _asset,
		address _firstRedemptionHint,
		uint256 _price
	) external returns (bool);

	function updateBaseRateFromRedemption(
		address _asset,
		uint256 _assetDrawn,
		uint256 _price,
		uint256 _totalDebtTokenSupply
	) external returns (uint256);

	function getRedemptionFee(address _asset, uint256 _assetDraw) external view returns (uint256);

	function finalizeRedemption(
		address _asset,
		address _receiver,
		uint256 _debtToRedeem,
		uint256 _fee,
		uint256 _totalRedemptionRewards
	) external;

	function redistributeDebtAndColl(
		address _asset,
		uint256 _debt,
		uint256 _coll,
		uint256 _debtToOffset,
		uint256 _collToSendToStabilityPool
	) external;

	function updateSystemSnapshots_excludeCollRemainder(address _asset, uint256 _collRemainder) external;

	function movePendingTroveRewardsToActivePool(address _asset, uint256 _debtTokenAmount, uint256 _assetAmount) external;

	function isTroveActive(address _asset, address _borrower) external view returns (bool);

	function sendGasCompensation(
		address _asset,
		address _liquidator,
		uint256 _debtTokenAmount,
		uint256 _assetAmount
	) external;
}

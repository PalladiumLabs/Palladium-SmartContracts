// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import "./IPalladiumBase.sol";
import "./ITroveManager.sol";

interface ITroveManagerOperations is IPalladiumBase {
	// Events -----------------------------------------------------------------------------------------------------------

	event Redemption(
		address indexed _asset,
		uint256 _attemptedDebtAmount,
		uint256 _actualDebtAmount,
		uint256 _collSent,
		uint256 _collFee
	);

	event Liquidation(
		address indexed _asset,
		uint256 _liquidatedDebt,
		uint256 _liquidatedColl,
		uint256 _collGasCompensation,
		uint256 _debtTokenGasCompensation
	);

	event TroveLiquidated(
		address indexed _asset,
		address indexed _borrower,
		uint256 _debt,
		uint256 _coll,
		ITroveManager.TroveManagerOperation _operation
	);

	event RedemptionSoftenParamChanged(uint256 _redemptionSofteningParam);

	// Custom Errors ----------------------------------------------------------------------------------------------------

	error TroveManagerOperations__InvalidArraySize();
	error TroveManagerOperations__EmptyAmount();
	error TroveManagerOperations__FeePercentOutOfBounds(uint256 lowerBoundary, uint256 upperBoundary);
	error TroveManagerOperations__InsufficientDebtTokenBalance(uint256 availableBalance);
	error TroveManagerOperations__NothingToLiquidate();
	error TroveManagerOperations__OnlyTroveManager();
	error TroveManagerOperations__RedemptionIsBlocked();
	error TroveManagerOperations__TCRMustBeAboveMCR(uint256 tcr, uint256 mcr);
	error TroveManagerOperations__UnableToRedeemAnyAmount();
	error TroveManagerOperations__TroveNotActive();
	error TroveManagerOperations__InvalidParam();
	error TroveManagerOperations__NotTimelock();

	// Structs ----------------------------------------------------------------------------------------------------------

	struct RedemptionTotals {
		uint256 remainingDebt;
		uint256 totalDebtToRedeem;
		uint256 totalCollDrawn;
		uint256 collFee;
		uint256 collToSendToRedeemer;
		uint256 decayedBaseRate;
		uint256 price;
		uint256 totalDebtTokenSupplyAtStart;
	}

	struct SingleRedemptionValues {
		uint256 debtLot;
		uint256 collLot;
		bool cancelledPartial;
	}

	struct LiquidationTotals {
		uint256 totalCollInSequence;
		uint256 totalDebtInSequence;
		uint256 totalCollGasCompensation;
		uint256 totalDebtTokenGasCompensation;
		uint256 totalDebtToOffset;
		uint256 totalCollToSendToSP;
		uint256 totalDebtToRedistribute;
		uint256 totalCollToRedistribute;
		uint256 totalCollSurplus;
	}

	struct LiquidationValues {
		uint256 entireTroveDebt;
		uint256 entireTroveColl;
		uint256 collGasCompensation;
		uint256 debtTokenGasCompensation;
		uint256 debtToOffset;
		uint256 collToSendToSP;
		uint256 debtToRedistribute;
		uint256 collToRedistribute;
		uint256 collSurplus;
	}

	struct LocalVariables_InnerSingleLiquidateFunction {
		uint256 collToLiquidate;
		uint256 pendingDebtReward;
		uint256 pendingCollReward;
	}

	struct LocalVariables_OuterLiquidationFunction {
		uint256 price;
		uint256 debtTokenInStabPool;
		bool recoveryModeAtStart;
		uint256 liquidatedDebt;
		uint256 liquidatedColl;
	}

	struct LocalVariables_LiquidationSequence {
		uint256 remainingDebtTokenInStabPool;
		uint256 ICR;
		address user;
		bool backToNormalMode;
		uint256 entireSystemDebt;
		uint256 entireSystemColl;
	}

	// Functions --------------------------------------------------------------------------------------------------------

	function liquidate(address _asset, address _borrower) external;

	function liquidateTroves(address _asset, uint256 _n) external;

	function batchLiquidateTroves(address _asset, address[] memory _troveArray) external;

	function redeemCollateral(
		address _asset,
		uint256 _debtTokenAmount,
		address _upperPartialRedemptionHint,
		address _lowerPartialRedemptionHint,
		address _firstRedemptionHint,
		uint256 _partialRedemptionHintNICR,
		uint256 _maxIterations,
		uint256 _maxFeePercentage
	) external;

	function getRedemptionHints(
		address _asset,
		uint256 _debtTokenAmount,
		uint256 _price,
		uint256 _maxIterations
	) external returns (address firstRedemptionHint, uint256 partialRedemptionHintNICR, uint256 truncatedDebtTokenAmount);

	function getApproxHint(
		address _asset,
		uint256 _CR,
		uint256 _numTrials,
		uint256 _inputRandomSeed
	) external returns (address hintAddress, uint256 diff, uint256 latestRandomSeed);

	function computeNominalCR(uint256 _coll, uint256 _debt) external returns (uint256);
}

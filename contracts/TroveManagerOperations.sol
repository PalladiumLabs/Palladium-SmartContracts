// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";

import "./Dependencies/PalladiumBase.sol";
import "./Interfaces/ITroveManagerOperations.sol";

contract TroveManagerOperations is ITroveManagerOperations, UUPSUpgradeable, ReentrancyGuardUpgradeable, PalladiumBase {
	string public constant NAME = "TroveManagerOperations";
	uint256 public constant PERCENTAGE_PRECISION = 100_00;
	uint256 public constant BATCH_SIZE_LIMIT = 25;

	uint256 public redemptionSofteningParam;

	// Structs ----------------------------------------------------------------------------------------------------------

	struct HintHelperLocalVars {
		address asset;
		uint256 debtTokenAmount;
		uint256 price;
		uint256 maxIterations;
	}

	// Modifiers --------------------------------------------------------------------------------------------------------

	modifier onlyTroveManager() {
		if (msg.sender != troveManager) {
			revert TroveManagerOperations__OnlyTroveManager();
		}
		_;
	}

	// Initializer ------------------------------------------------------------------------------------------------------

	function initialize() public initializer {
		__Ownable_init();
		__UUPSUpgradeable_init();
		__ReentrancyGuard_init();
	}

	// Liquidation external functions -----------------------------------------------------------------------------------

	/*
	 * Single liquidation function. Closes the trove if its ICR is lower than the minimum collateral ratio.
	 */
	function liquidate(address _asset, address _borrower) external override {
		if (!ITroveManager(troveManager).isTroveActive(_asset, _borrower)) {
			revert TroveManagerOperations__TroveNotActive();
		}
		address[] memory borrowers = new address[](1);
		borrowers[0] = _borrower;
		batchLiquidateTroves(_asset, borrowers);
	}

	/*
	 * Liquidate a sequence of troves. Closes a maximum number of n under-collateralized Troves,
	 * starting from the one with the lowest collateral ratio in the system, and moving upwards.
	 */
	function liquidateTroves(address _asset, uint256 _n) external override nonReentrant {
		LocalVariables_OuterLiquidationFunction memory vars;
		LiquidationTotals memory totals;
		vars.price = IPriceFeed(priceFeed).fetchPrice(_asset);
		vars.debtTokenInStabPool = IStabilityPool(stabilityPool).getTotalDebtTokenDeposits();
		vars.recoveryModeAtStart = _checkRecoveryMode(_asset, vars.price);

		// Perform the appropriate liquidation sequence - tally the values, and obtain their totals
		if (vars.recoveryModeAtStart) {
			totals = _getTotalsFromLiquidateTrovesSequence_RecoveryMode(_asset, vars.price, vars.debtTokenInStabPool, _n);
		} else {
			totals = _getTotalsFromLiquidateTrovesSequence_NormalMode(_asset, vars.price, vars.debtTokenInStabPool, _n);
		}

		if (totals.totalDebtInSequence == 0) {
			revert TroveManagerOperations__NothingToLiquidate();
		}

		ITroveManager(troveManager).redistributeDebtAndColl(
			_asset,
			totals.totalDebtToRedistribute,
			totals.totalCollToRedistribute,
			totals.totalDebtToOffset,
			totals.totalCollToSendToSP
		);
		if (totals.totalCollSurplus != 0) {
			IActivePool(activePool).sendAsset(_asset, collSurplusPool, totals.totalCollSurplus);
		}

		ITroveManager(troveManager).updateSystemSnapshots_excludeCollRemainder(_asset, totals.totalCollGasCompensation);

		vars.liquidatedDebt = totals.totalDebtInSequence;
		vars.liquidatedColl = totals.totalCollInSequence - totals.totalCollGasCompensation - totals.totalCollSurplus;
		emit Liquidation(
			_asset,
			vars.liquidatedDebt,
			vars.liquidatedColl,
			totals.totalCollGasCompensation,
			totals.totalDebtTokenGasCompensation
		);
		ITroveManager(troveManager).sendGasCompensation(
			_asset,
			msg.sender,
			totals.totalDebtTokenGasCompensation,
			totals.totalCollGasCompensation
		);
	}

	/*
	 * Attempt to liquidate a custom list of troves provided by the caller.
	 */
	function batchLiquidateTroves(address _asset, address[] memory _troveArray) public override nonReentrant {
		if (_troveArray.length == 0 || _troveArray.length > BATCH_SIZE_LIMIT) {
			revert TroveManagerOperations__InvalidArraySize();
		}

		LocalVariables_OuterLiquidationFunction memory vars;
		LiquidationTotals memory totals;

		vars.debtTokenInStabPool = IStabilityPool(stabilityPool).getTotalDebtTokenDeposits();
		vars.price = IPriceFeed(priceFeed).fetchPrice(_asset);
		vars.recoveryModeAtStart = _checkRecoveryMode(_asset, vars.price);

		// Perform the appropriate liquidation sequence - tally values and obtain their totals.
		if (vars.recoveryModeAtStart) {
			totals = _getTotalFromBatchLiquidate_RecoveryMode(_asset, vars.price, vars.debtTokenInStabPool, _troveArray);
		} else {
			totals = _getTotalsFromBatchLiquidate_NormalMode(_asset, vars.price, vars.debtTokenInStabPool, _troveArray);
		}

		if (totals.totalDebtInSequence == 0) {
			revert TroveManagerOperations__NothingToLiquidate();
		}

		ITroveManager(troveManager).redistributeDebtAndColl(
			_asset,
			totals.totalDebtToRedistribute,
			totals.totalCollToRedistribute,
			totals.totalDebtToOffset,
			totals.totalCollToSendToSP
		);
		if (totals.totalCollSurplus != 0) {
			IActivePool(activePool).sendAsset(_asset, collSurplusPool, totals.totalCollSurplus);
		}

		// Update system snapshots
		ITroveManager(troveManager).updateSystemSnapshots_excludeCollRemainder(_asset, totals.totalCollGasCompensation);

		vars.liquidatedDebt = totals.totalDebtInSequence;
		vars.liquidatedColl = totals.totalCollInSequence - totals.totalCollGasCompensation - totals.totalCollSurplus;
		emit Liquidation(
			_asset,
			vars.liquidatedDebt,
			vars.liquidatedColl,
			totals.totalCollGasCompensation,
			totals.totalDebtTokenGasCompensation
		);
		ITroveManager(troveManager).sendGasCompensation(
			_asset,
			msg.sender,
			totals.totalDebtTokenGasCompensation,
			totals.totalCollGasCompensation
		);
	}

	// Redemption external functions ------------------------------------------------------------------------------------

	function redeemCollateral(
		address _asset,
		uint256 _debtTokenAmount,
		address _upperPartialRedemptionHint,
		address _lowerPartialRedemptionHint,
		address _firstRedemptionHint,
		uint256 _partialRedemptionHintNICR,
		uint256 _maxIterations,
		uint256 _maxFeePercentage
	) external override {
		RedemptionTotals memory totals;
		totals.price = IPriceFeed(priceFeed).fetchPrice(_asset);
		_validateRedemptionRequirements(_asset, _maxFeePercentage, _debtTokenAmount, totals.price);
		totals.totalDebtTokenSupplyAtStart = getEntireSystemDebt(_asset);
		totals.remainingDebt = _debtTokenAmount;
		address currentBorrower;
		if (ITroveManager(troveManager).isValidFirstRedemptionHint(_asset, _firstRedemptionHint, totals.price)) {
			currentBorrower = _firstRedemptionHint;
		} else {
			currentBorrower = ISortedTroves(sortedTroves).getLast(_asset);
			// Find the first trove with ICR >= MCR
			while (
				currentBorrower != address(0) &&
				ITroveManager(troveManager).getCurrentICR(_asset, currentBorrower, totals.price) <
				IAdminContract(adminContract).getMcr(_asset)
			) {
				currentBorrower = ISortedTroves(sortedTroves).getPrev(_asset, currentBorrower);
			}
		}

		// Loop through the troves starting from the one with lowest collateral ratio until _debtTokenAmount is exchanged for collateral
		if (_maxIterations == 0) {
			_maxIterations = type(uint256).max;
		}
		while (currentBorrower != address(0) && totals.remainingDebt != 0 && _maxIterations != 0) {
			_maxIterations--;
			// Save the address of the trove preceding the current one, before potentially modifying the list
			address nextUserToCheck = ISortedTroves(sortedTroves).getPrev(_asset, currentBorrower);

			ITroveManager(troveManager).applyPendingRewards(_asset, currentBorrower);

			SingleRedemptionValues memory singleRedemption = _redeemCollateralFromTrove(
				_asset,
				currentBorrower,
				totals.remainingDebt,
				totals.price,
				_upperPartialRedemptionHint,
				_lowerPartialRedemptionHint,
				_partialRedemptionHintNICR
			);

			if (singleRedemption.cancelledPartial) break; // Partial redemption was cancelled (out-of-date hint, or new net debt < minimum), therefore we could not redeem from the last trove

			totals.totalDebtToRedeem = totals.totalDebtToRedeem + singleRedemption.debtLot;
			totals.totalCollDrawn = totals.totalCollDrawn + singleRedemption.collLot;

			totals.remainingDebt = totals.remainingDebt - singleRedemption.debtLot;
			currentBorrower = nextUserToCheck;
		}
		if (totals.totalCollDrawn == 0) {
			revert TroveManagerOperations__UnableToRedeemAnyAmount();
		}

		// Decay the baseRate due to time passed, and then increase it according to the size of this redemption.
		// Use the saved total PUSD supply value, from before it was reduced by the redemption.
		ITroveManager(troveManager).updateBaseRateFromRedemption(
			_asset,
			totals.totalCollDrawn,
			totals.price,
			totals.totalDebtTokenSupplyAtStart
		);

		// Calculate the collateral fee
		totals.collFee = ITroveManager(troveManager).getRedemptionFee(_asset, totals.totalCollDrawn);

		_requireUserAcceptsFee(totals.collFee, totals.totalCollDrawn, _maxFeePercentage);

		ITroveManager(troveManager).finalizeRedemption(
			_asset,
			msg.sender,
			totals.totalDebtToRedeem,
			totals.collFee,
			totals.totalCollDrawn
		);

		emit Redemption(_asset, _debtTokenAmount, totals.totalDebtToRedeem, totals.totalCollDrawn, totals.collFee);
	}

	// Hint helper functions --------------------------------------------------------------------------------------------

	/* getRedemptionHints() - Helper function for finding the right hints to pass to redeemCollateral().
	 *
	 * It simulates a redemption of `_debtTokenAmount` to figure out where the redemption sequence will start and what state the final Trove
	 * of the sequence will end up in.
	 *
	 * Returns three hints:
	 *  - `firstRedemptionHint` is the address of the first Trove with ICR >= MCR (i.e. the first Trove that will be redeemed).
	 *  - `partialRedemptionHintNICR` is the final nominal ICR of the last Trove of the sequence after being hit by partial redemption,
	 *     or zero in case of no partial redemption.
	 *  - `truncatedDebtTokenAmount` is the maximum amount that can be redeemed out of the the provided `_debtTokenAmount`. This can be lower than
	 *    `_debtTokenAmount` when redeeming the full amount would leave the last Trove of the redemption sequence with less net debt than the
	 *    minimum allowed value (i.e. IAdminContract(adminContract).MIN_NET_DEBT()).
	 *
	 * The number of Troves to consider for redemption can be capped by passing a non-zero value as `_maxIterations`, while passing zero
	 * will leave it uncapped.
	 */

	function getRedemptionHints(
		address _asset,
		uint256 _debtTokenAmount,
		uint256 _price,
		uint256 _maxIterations
	)
		external
		view
		override
		returns (address firstRedemptionHint, uint256 partialRedemptionHintNewICR, uint256 truncatedDebtTokenAmount)
	{
		HintHelperLocalVars memory vars = HintHelperLocalVars({
			asset: _asset,
			debtTokenAmount: _debtTokenAmount,
			price: _price,
			maxIterations: _maxIterations
		});

		uint256 remainingDebt = _debtTokenAmount;
		address currentTroveBorrower = ISortedTroves(sortedTroves).getLast(vars.asset);

		while (
			currentTroveBorrower != address(0) &&
			ITroveManager(troveManager).getCurrentICR(vars.asset, currentTroveBorrower, vars.price) <
			IAdminContract(adminContract).getMcr(vars.asset)
		) {
			currentTroveBorrower = ISortedTroves(sortedTroves).getPrev(vars.asset, currentTroveBorrower);
		}

		firstRedemptionHint = currentTroveBorrower;

		if (vars.maxIterations == 0) {
			vars.maxIterations = type(uint256).max;
		}

		while (currentTroveBorrower != address(0) && remainingDebt != 0 && vars.maxIterations-- != 0) {
			uint256 currentTroveNetDebt = _getNetDebt(
				vars.asset,
				ITroveManager(troveManager).getTroveDebt(vars.asset, currentTroveBorrower) +
					ITroveManager(troveManager).getPendingDebtTokenReward(vars.asset, currentTroveBorrower)
			);

			if (currentTroveNetDebt <= remainingDebt) {
				remainingDebt = remainingDebt - currentTroveNetDebt;
			} else {
				if (currentTroveNetDebt > IAdminContract(adminContract).getMinNetDebt(vars.asset)) {
					uint256 maxRedeemableDebt = PalladiumMath._min(
						remainingDebt,
						currentTroveNetDebt - IAdminContract(adminContract).getMinNetDebt(vars.asset)
					);

					uint256 currentTroveColl = ITroveManager(troveManager).getTroveColl(vars.asset, currentTroveBorrower) +
						ITroveManager(troveManager).getPendingAssetReward(vars.asset, currentTroveBorrower);

					uint256 collLot = (maxRedeemableDebt * DECIMAL_PRECISION) / vars.price;
					// Apply redemption softening
					collLot = (collLot * redemptionSofteningParam) / PERCENTAGE_PRECISION;
					uint256 newColl = currentTroveColl - collLot;
					uint256 newDebt = currentTroveNetDebt - maxRedeemableDebt;
					uint256 compositeDebt = _getCompositeDebt(vars.asset, newDebt);

					partialRedemptionHintNewICR = PalladiumMath._computeNominalCR(newColl, compositeDebt);
					remainingDebt = remainingDebt - maxRedeemableDebt;
				}

				break;
			}

			currentTroveBorrower = ISortedTroves(sortedTroves).getPrev(vars.asset, currentTroveBorrower);
		}

		truncatedDebtTokenAmount = _debtTokenAmount - remainingDebt;
	}

	/* getApproxHint() - return address of a Trove that is, on average, (length / numTrials) positions away in the 
    sortedTroves list from the correct insert position of the Trove to be inserted. 
    
    Note: The output address is worst-case O(n) positions away from the correct insert position, however, the function 
    is probabilistic. Input can be tuned to guarantee results to a high degree of confidence, e.g:

    Submitting numTrials = k * sqrt(length), with k = 15 makes it very, very likely that the ouput address will 
    be <= sqrt(length) positions away from the correct insert position.
    */
	function getApproxHint(
		address _asset,
		uint256 _CR,
		uint256 _numTrials,
		uint256 _inputRandomSeed
	) external view override returns (address hintAddress, uint256 diff, uint256 latestRandomSeed) {
		uint256 arrayLength = ITroveManager(troveManager).getTroveOwnersCount(_asset);

		if (arrayLength == 0) {
			return (address(0), 0, _inputRandomSeed);
		}

		hintAddress = ISortedTroves(sortedTroves).getLast(_asset);
		diff = PalladiumMath._getAbsoluteDifference(_CR, ITroveManager(troveManager).getNominalICR(_asset, hintAddress));
		latestRandomSeed = _inputRandomSeed;

		uint256 i = 1;

		while (i < _numTrials) {
			latestRandomSeed = uint256(keccak256(abi.encodePacked(latestRandomSeed)));

			uint256 arrayIndex = latestRandomSeed % arrayLength;
			address currentAddress = ITroveManager(troveManager).getTroveFromTroveOwnersArray(_asset, arrayIndex);
			uint256 currentNICR = ITroveManager(troveManager).getNominalICR(_asset, currentAddress);

			// check if abs(current - CR) > abs(closest - CR), and update closest if current is closer
			uint256 currentDiff = PalladiumMath._getAbsoluteDifference(currentNICR, _CR);

			if (currentDiff < diff) {
				diff = currentDiff;
				hintAddress = currentAddress;
			}
			i++;
		}
	}

	function computeNominalCR(uint256 _coll, uint256 _debt) external pure override returns (uint256) {
		return PalladiumMath._computeNominalCR(_coll, _debt);
	}

	// Liquidation internal/helper functions ----------------------------------------------------------------------------

	/*
	 * This function is used when the batch liquidation sequence starts during Recovery Mode. However, it
	 * handles the case where the system *leaves* Recovery Mode, part way through the liquidation sequence
	 */
	function _getTotalFromBatchLiquidate_RecoveryMode(
		address _asset,
		uint256 _price,
		uint256 _debtTokenInStabPool,
		address[] memory _troveArray
	) internal returns (LiquidationTotals memory totals) {
		LocalVariables_LiquidationSequence memory vars;
		LiquidationValues memory singleLiquidation;
		vars.remainingDebtTokenInStabPool = _debtTokenInStabPool;
		vars.backToNormalMode = false;
		vars.entireSystemDebt = getEntireSystemDebt(_asset);
		vars.entireSystemColl = getEntireSystemColl(_asset);

		for (uint i = 0; i < _troveArray.length; ) {
			vars.user = _troveArray[i];
			// Skip non-active troves
			if (ITroveManager(troveManager).getTroveStatus(_asset, vars.user) != uint256(ITroveManager.Status.active)) {
				unchecked {
					++i;
				}
				continue;
			}
			vars.ICR = ITroveManager(troveManager).getCurrentICR(_asset, vars.user, _price);

			if (!vars.backToNormalMode) {
				// Skip this trove if ICR is greater than MCR and Stability Pool is empty
				if (vars.ICR >= IAdminContract(adminContract).getMcr(_asset) && vars.remainingDebtTokenInStabPool == 0) {
					unchecked {
						++i;
					}
					continue;
				}
				uint256 TCR = PalladiumMath._computeCR(vars.entireSystemColl, vars.entireSystemDebt, _price);

				singleLiquidation = _liquidateRecoveryMode(
					_asset,
					vars.user,
					vars.ICR,
					vars.remainingDebtTokenInStabPool,
					TCR,
					_price
				);

				// Update aggregate trackers
				vars.remainingDebtTokenInStabPool = vars.remainingDebtTokenInStabPool - singleLiquidation.debtToOffset;
				vars.entireSystemDebt = vars.entireSystemDebt - singleLiquidation.debtToOffset;
				vars.entireSystemColl =
					vars.entireSystemColl -
					singleLiquidation.collToSendToSP -
					singleLiquidation.collGasCompensation -
					singleLiquidation.collSurplus;

				// Add liquidation values to their respective running totals
				totals = _addLiquidationValuesToTotals(totals, singleLiquidation);

				vars.backToNormalMode = !_checkPotentialRecoveryMode(
					_asset,
					vars.entireSystemColl,
					vars.entireSystemDebt,
					_price
				);
			} else if (vars.backToNormalMode && vars.ICR < IAdminContract(adminContract).getMcr(_asset)) {
				singleLiquidation = _liquidateNormalMode(_asset, vars.user, vars.remainingDebtTokenInStabPool);
				vars.remainingDebtTokenInStabPool = vars.remainingDebtTokenInStabPool - singleLiquidation.debtToOffset;

				// Add liquidation values to their respective running totals
				totals = _addLiquidationValuesToTotals(totals, singleLiquidation);
			}
			unchecked {
				++i;
			}
		}
	}

	function _getTotalsFromBatchLiquidate_NormalMode(
		address _asset,
		uint256 _price,
		uint256 _debtTokenInStabPool,
		address[] memory _troveArray
	) internal returns (LiquidationTotals memory totals) {
		LocalVariables_LiquidationSequence memory vars;
		LiquidationValues memory singleLiquidation;

		vars.remainingDebtTokenInStabPool = _debtTokenInStabPool;

		for (uint i = 0; i < _troveArray.length; ) {
			vars.user = _troveArray[i];
			vars.ICR = ITroveManager(troveManager).getCurrentICR(_asset, vars.user, _price);

			if (vars.ICR < IAdminContract(adminContract).getMcr(_asset)) {
				singleLiquidation = _liquidateNormalMode(_asset, vars.user, vars.remainingDebtTokenInStabPool);
				vars.remainingDebtTokenInStabPool = vars.remainingDebtTokenInStabPool - singleLiquidation.debtToOffset;

				// Add liquidation values to their respective running totals
				totals = _addLiquidationValuesToTotals(totals, singleLiquidation);
			}
			unchecked {
				++i;
			}
		}
	}

	function _addLiquidationValuesToTotals(
		LiquidationTotals memory oldTotals,
		LiquidationValues memory singleLiquidation
	) internal pure returns (LiquidationTotals memory newTotals) {
		// Tally all the values with their respective running totals
		newTotals.totalCollGasCompensation = oldTotals.totalCollGasCompensation + singleLiquidation.collGasCompensation;
		newTotals.totalDebtTokenGasCompensation =
			oldTotals.totalDebtTokenGasCompensation +
			singleLiquidation.debtTokenGasCompensation;
		newTotals.totalDebtInSequence = oldTotals.totalDebtInSequence + singleLiquidation.entireTroveDebt;
		newTotals.totalCollInSequence = oldTotals.totalCollInSequence + singleLiquidation.entireTroveColl;
		newTotals.totalDebtToOffset = oldTotals.totalDebtToOffset + singleLiquidation.debtToOffset;
		newTotals.totalCollToSendToSP = oldTotals.totalCollToSendToSP + singleLiquidation.collToSendToSP;
		newTotals.totalDebtToRedistribute = oldTotals.totalDebtToRedistribute + singleLiquidation.debtToRedistribute;
		newTotals.totalCollToRedistribute = oldTotals.totalCollToRedistribute + singleLiquidation.collToRedistribute;
		newTotals.totalCollSurplus = oldTotals.totalCollSurplus + singleLiquidation.collSurplus;
		return newTotals;
	}

	function _getTotalsFromLiquidateTrovesSequence_NormalMode(
		address _asset,
		uint256 _price,
		uint256 _debtTokenInStabPool,
		uint256 _n
	) internal returns (LiquidationTotals memory totals) {
		LocalVariables_LiquidationSequence memory vars;
		LiquidationValues memory singleLiquidation;

		vars.remainingDebtTokenInStabPool = _debtTokenInStabPool;

		for (uint i = 0; i < _n; ) {
			vars.user = ISortedTroves(sortedTroves).getLast(_asset);
			vars.ICR = ITroveManager(troveManager).getCurrentICR(_asset, vars.user, _price);

			if (vars.ICR < IAdminContract(adminContract).getMcr(_asset)) {
				singleLiquidation = _liquidateNormalMode(_asset, vars.user, vars.remainingDebtTokenInStabPool);

				vars.remainingDebtTokenInStabPool = vars.remainingDebtTokenInStabPool - singleLiquidation.debtToOffset;

				// Add liquidation values to their respective running totals
				totals = _addLiquidationValuesToTotals(totals, singleLiquidation);
			} else break; // break if the loop reaches a Trove with ICR >= MCR
			unchecked {
				++i;
			}
		}
	}

	function _liquidateNormalMode(
		address _asset,
		address _borrower,
		uint256 _debtTokenInStabPool
	) internal returns (LiquidationValues memory singleLiquidation) {
		LocalVariables_InnerSingleLiquidateFunction memory vars;
		(
			singleLiquidation.entireTroveDebt,
			singleLiquidation.entireTroveColl,
			vars.pendingDebtReward,
			vars.pendingCollReward
		) = ITroveManager(troveManager).getEntireDebtAndColl(_asset, _borrower);

		ITroveManager(troveManager).movePendingTroveRewardsToActivePool(
			_asset,
			vars.pendingDebtReward,
			vars.pendingCollReward
		);
		ITroveManager(troveManager).removeStake(_asset, _borrower);

		singleLiquidation.collGasCompensation = _getCollGasCompensation(_asset, singleLiquidation.entireTroveColl);
		singleLiquidation.debtTokenGasCompensation = IAdminContract(adminContract).getDebtTokenGasCompensation(_asset);
		uint256 collToLiquidate = singleLiquidation.entireTroveColl - singleLiquidation.collGasCompensation;

		(
			singleLiquidation.debtToOffset,
			singleLiquidation.collToSendToSP,
			singleLiquidation.debtToRedistribute,
			singleLiquidation.collToRedistribute
		) = _getOffsetAndRedistributionVals(singleLiquidation.entireTroveDebt, collToLiquidate, _debtTokenInStabPool);

		ITroveManager(troveManager).closeTroveLiquidation(_asset, _borrower);
		emit TroveLiquidated(
			_asset,
			_borrower,
			singleLiquidation.entireTroveDebt,
			singleLiquidation.entireTroveColl,
			ITroveManager.TroveManagerOperation.liquidateInNormalMode
		);
		return singleLiquidation;
	}

	function _liquidateRecoveryMode(
		address _asset,
		address _borrower,
		uint256 _ICR,
		uint256 _debtTokenInStabPool,
		uint256 _TCR,
		uint256 _price
	) internal returns (LiquidationValues memory singleLiquidation) {
		LocalVariables_InnerSingleLiquidateFunction memory vars;
		if (ITroveManager(troveManager).getTroveOwnersCount(_asset) <= 1) {
			return singleLiquidation;
		} // don't liquidate if last trove
		(
			singleLiquidation.entireTroveDebt,
			singleLiquidation.entireTroveColl,
			vars.pendingDebtReward,
			vars.pendingCollReward
		) = ITroveManager(troveManager).getEntireDebtAndColl(_asset, _borrower);

		singleLiquidation.collGasCompensation = _getCollGasCompensation(_asset, singleLiquidation.entireTroveColl);
		singleLiquidation.debtTokenGasCompensation = IAdminContract(adminContract).getDebtTokenGasCompensation(_asset);
		vars.collToLiquidate = singleLiquidation.entireTroveColl - singleLiquidation.collGasCompensation;

		// If ICR <= 100%, purely redistribute the Trove across all active Troves
		if (_ICR <= IAdminContract(adminContract)._100pct()) {
			ITroveManager(troveManager).movePendingTroveRewardsToActivePool(
				_asset,
				vars.pendingDebtReward,
				vars.pendingCollReward
			);
			ITroveManager(troveManager).removeStake(_asset, _borrower);

			singleLiquidation.debtToOffset = 0;
			singleLiquidation.collToSendToSP = 0;
			singleLiquidation.debtToRedistribute = singleLiquidation.entireTroveDebt;
			singleLiquidation.collToRedistribute = vars.collToLiquidate;

			ITroveManager(troveManager).closeTroveLiquidation(_asset, _borrower);
			emit TroveLiquidated(
				_asset,
				_borrower,
				singleLiquidation.entireTroveDebt,
				singleLiquidation.entireTroveColl,
				ITroveManager.TroveManagerOperation.liquidateInRecoveryMode
			);

			// If 100% < ICR < MCR, offset as much as possible, and redistribute the remainder
		} else if (
			(_ICR > IAdminContract(adminContract)._100pct()) && (_ICR < IAdminContract(adminContract).getMcr(_asset))
		) {
			ITroveManager(troveManager).movePendingTroveRewardsToActivePool(
				_asset,
				vars.pendingDebtReward,
				vars.pendingCollReward
			);
			ITroveManager(troveManager).removeStake(_asset, _borrower);

			(
				singleLiquidation.debtToOffset,
				singleLiquidation.collToSendToSP,
				singleLiquidation.debtToRedistribute,
				singleLiquidation.collToRedistribute
			) = _getOffsetAndRedistributionVals(
				singleLiquidation.entireTroveDebt,
				vars.collToLiquidate,
				_debtTokenInStabPool
			);

			ITroveManager(troveManager).closeTroveLiquidation(_asset, _borrower);
			emit TroveLiquidated(
				_asset,
				_borrower,
				singleLiquidation.entireTroveDebt,
				singleLiquidation.entireTroveColl,
				ITroveManager.TroveManagerOperation.liquidateInRecoveryMode
			);

			/*
			 * If 110% <= ICR < current TCR (accounting for the preceding liquidations in the current sequence)
			 * and there are debt tokens in the Stability Pool, only offset, with no redistribution,
			 * but at a capped rate of 1.1 and only if the whole debt can be liquidated.
			 * The remainder due to the capped rate will be claimable as collateral surplus.
			 */
		} else if (
			(_ICR >= IAdminContract(adminContract).getMcr(_asset)) &&
			(_ICR < _TCR) &&
			(singleLiquidation.entireTroveDebt <= _debtTokenInStabPool)
		) {
			ITroveManager(troveManager).movePendingTroveRewardsToActivePool(
				_asset,
				vars.pendingDebtReward,
				vars.pendingCollReward
			);
			assert(_debtTokenInStabPool != 0);

			ITroveManager(troveManager).removeStake(_asset, _borrower);
			singleLiquidation = _getCappedOffsetVals(
				_asset,
				singleLiquidation.entireTroveDebt,
				singleLiquidation.entireTroveColl,
				_price
			);

			ITroveManager(troveManager).closeTroveLiquidation(_asset, _borrower);
			if (singleLiquidation.collSurplus != 0) {
				ICollSurplusPool(collSurplusPool).accountSurplus(_asset, _borrower, singleLiquidation.collSurplus);
			}
			emit TroveLiquidated(
				_asset,
				_borrower,
				singleLiquidation.entireTroveDebt,
				singleLiquidation.collToSendToSP,
				ITroveManager.TroveManagerOperation.liquidateInRecoveryMode
			);
		} else {
			// if (_ICR >= MCR && ( _ICR >= _TCR || singleLiquidation.entireTroveDebt > _debtTokenInStabPool))
			LiquidationValues memory zeroVals;
			return zeroVals;
		}

		return singleLiquidation;
	}

	/*
	 * This function is used when the liquidateTroves sequence starts during Recovery Mode. However, it
	 * handles the case where the system *leaves* Recovery Mode, part way through the liquidation sequence
	 */
	function _getTotalsFromLiquidateTrovesSequence_RecoveryMode(
		address _asset,
		uint256 _price,
		uint256 _debtTokenInStabPool,
		uint256 _n
	) internal returns (LiquidationTotals memory totals) {
		LocalVariables_LiquidationSequence memory vars;
		LiquidationValues memory singleLiquidation;

		vars.remainingDebtTokenInStabPool = _debtTokenInStabPool;
		vars.backToNormalMode = false;
		vars.entireSystemDebt = getEntireSystemDebt(_asset);
		vars.entireSystemColl = getEntireSystemColl(_asset);

		vars.user = ISortedTroves(sortedTroves).getLast(_asset);
		address firstUser = ISortedTroves(sortedTroves).getFirst(_asset);
		for (uint i = 0; i < _n && vars.user != firstUser; ) {
			// we need to cache it, because current user is likely going to be deleted
			address nextUser = ISortedTroves(sortedTroves).getPrev(_asset, vars.user);

			vars.ICR = ITroveManager(troveManager).getCurrentICR(_asset, vars.user, _price);

			if (!vars.backToNormalMode) {
				// Break the loop if ICR is greater than MCR and Stability Pool is empty
				if (vars.ICR >= IAdminContract(adminContract).getMcr(_asset) && vars.remainingDebtTokenInStabPool == 0) {
					break;
				}

				uint256 TCR = PalladiumMath._computeCR(vars.entireSystemColl, vars.entireSystemDebt, _price);

				singleLiquidation = _liquidateRecoveryMode(
					_asset,
					vars.user,
					vars.ICR,
					vars.remainingDebtTokenInStabPool,
					TCR,
					_price
				);

				// Update aggregate trackers
				vars.remainingDebtTokenInStabPool = vars.remainingDebtTokenInStabPool - singleLiquidation.debtToOffset;
				vars.entireSystemDebt = vars.entireSystemDebt - singleLiquidation.debtToOffset;
				vars.entireSystemColl =
					vars.entireSystemColl -
					singleLiquidation.collToSendToSP -
					singleLiquidation.collGasCompensation -
					singleLiquidation.collSurplus;

				// Add liquidation values to their respective running totals
				totals = _addLiquidationValuesToTotals(totals, singleLiquidation);

				vars.backToNormalMode = !_checkPotentialRecoveryMode(
					_asset,
					vars.entireSystemColl,
					vars.entireSystemDebt,
					_price
				);
			} else if (vars.backToNormalMode && vars.ICR < IAdminContract(adminContract).getMcr(_asset)) {
				singleLiquidation = _liquidateNormalMode(_asset, vars.user, vars.remainingDebtTokenInStabPool);

				vars.remainingDebtTokenInStabPool = vars.remainingDebtTokenInStabPool - singleLiquidation.debtToOffset;

				// Add liquidation values to their respective running totals
				totals = _addLiquidationValuesToTotals(totals, singleLiquidation);
			} else break; // break if the loop reaches a Trove with ICR >= MCR

			vars.user = nextUser;
			unchecked {
				++i;
			}
		}
	}

	/* In a full liquidation, returns the values for a trove's coll and debt to be offset, and coll and debt to be
	 * redistributed to active troves.
	 */
	function _getOffsetAndRedistributionVals(
		uint256 _debt,
		uint256 _coll,
		uint256 _debtTokenInStabPool
	)
		internal
		pure
		returns (uint256 debtToOffset, uint256 collToSendToSP, uint256 debtToRedistribute, uint256 collToRedistribute)
	{
		if (_debtTokenInStabPool != 0) {
			/*
			 * Offset as much debt & collateral as possible against the Stability Pool, and redistribute the remainder
			 * between all active troves.
			 *
			 *  If the trove's debt is larger than the deposited debt token in the Stability Pool:
			 *
			 *  - Offset an amount of the trove's debt equal to the debt token in the Stability Pool
			 *  - Send a fraction of the trove's collateral to the Stability Pool, equal to the fraction of its offset debt
			 *
			 */
			debtToOffset = PalladiumMath._min(_debt, _debtTokenInStabPool);
			collToSendToSP = (_coll * debtToOffset) / _debt;
			debtToRedistribute = _debt - debtToOffset;
			collToRedistribute = _coll - collToSendToSP;
		} else {
			debtToOffset = 0;
			collToSendToSP = 0;
			debtToRedistribute = _debt;
			collToRedistribute = _coll;
		}
	}

	/*
	 *  Get its offset coll/debt and coll gas comp, and close the trove.
	 */
	function _getCappedOffsetVals(
		address _asset,
		uint256 _entireTroveDebt,
		uint256 _entireTroveColl,
		uint256 _price
	) internal view returns (LiquidationValues memory singleLiquidation) {
		singleLiquidation.entireTroveDebt = _entireTroveDebt;
		singleLiquidation.entireTroveColl = _entireTroveColl;
		uint256 cappedCollPortion = (_entireTroveDebt * IAdminContract(adminContract).getMcr(_asset)) / _price;

		singleLiquidation.collGasCompensation = _getCollGasCompensation(_asset, cappedCollPortion);
		singleLiquidation.debtTokenGasCompensation = IAdminContract(adminContract).getDebtTokenGasCompensation(_asset);

		singleLiquidation.debtToOffset = _entireTroveDebt;
		singleLiquidation.collToSendToSP = cappedCollPortion - singleLiquidation.collGasCompensation;
		singleLiquidation.collSurplus = _entireTroveColl - cappedCollPortion;
		singleLiquidation.debtToRedistribute = 0;
		singleLiquidation.collToRedistribute = 0;
	}

	function _checkPotentialRecoveryMode(
		address _asset,
		uint256 _entireSystemColl,
		uint256 _entireSystemDebt,
		uint256 _price
	) internal view returns (bool) {
		uint256 TCR = PalladiumMath._computeCR(_entireSystemColl, _entireSystemDebt, _price);
		return TCR < IAdminContract(adminContract).getCcr(_asset);
	}

	// Redemption internal/helper functions -----------------------------------------------------------------------------

	function _validateRedemptionRequirements(
		address _asset,
		uint256 _maxFeePercentage,
		uint256 _debtTokenAmount,
		uint256 _price
	) internal view {
		uint256 redemptionBlockTimestamp = IAdminContract(adminContract).getRedemptionBlockTimestamp(_asset);
		if (redemptionBlockTimestamp > block.timestamp) {
			revert TroveManagerOperations__RedemptionIsBlocked();
		}
		uint256 redemptionFeeFloor = IAdminContract(adminContract).getRedemptionFeeFloor(_asset);
		if (_maxFeePercentage < redemptionFeeFloor || _maxFeePercentage > DECIMAL_PRECISION) {
			revert TroveManagerOperations__FeePercentOutOfBounds(redemptionFeeFloor, DECIMAL_PRECISION);
		}
		if (_debtTokenAmount == 0) {
			revert TroveManagerOperations__EmptyAmount();
		}
		uint256 redeemerBalance = IDebtToken(debtToken).balanceOf(msg.sender);
		if (redeemerBalance < _debtTokenAmount) {
			revert TroveManagerOperations__InsufficientDebtTokenBalance(redeemerBalance);
		}
		uint256 tcr = _getTCR(_asset, _price);
		uint256 mcr = IAdminContract(adminContract).getMcr(_asset);
		if (tcr < mcr) {
			revert TroveManagerOperations__TCRMustBeAboveMCR(tcr, mcr);
		}
	}

	// Redeem as much collateral as possible from _borrower's trove in exchange for PUSD up to _maxDebtTokenAmount
	function _redeemCollateralFromTrove(
		address _asset,
		address _borrower,
		uint256 _maxDebtTokenAmount,
		uint256 _price,
		address _upperPartialRedemptionHint,
		address _lowerPartialRedemptionHint,
		uint256 _partialRedemptionHintNICR
	) internal returns (SingleRedemptionValues memory singleRedemption) {
		uint256 troveDebt = ITroveManager(troveManager).getTroveDebt(_asset, _borrower);
		uint256 troveColl = ITroveManager(troveManager).getTroveColl(_asset, _borrower);

		// Determine the remaining amount (lot) to be redeemed, capped by the entire debt of the trove minus the liquidation reserve
		singleRedemption.debtLot = PalladiumMath._min(
			_maxDebtTokenAmount,
			troveDebt - IAdminContract(adminContract).getDebtTokenGasCompensation(_asset)
		);

		// Get the debtToken lot of equivalent value in USD
		singleRedemption.collLot = (singleRedemption.debtLot * DECIMAL_PRECISION) / _price;

		// Apply redemption softening
		singleRedemption.collLot = (singleRedemption.collLot * redemptionSofteningParam) / PERCENTAGE_PRECISION;

		// Decrease the debt and collateral of the current trove according to the debt token lot and corresponding coll to send

		uint256 newDebt = troveDebt - singleRedemption.debtLot;
		uint256 newColl = troveColl - singleRedemption.collLot;

		if (newDebt == IAdminContract(adminContract).getDebtTokenGasCompensation(_asset)) {
			ITroveManager(troveManager).executeFullRedemption(_asset, _borrower, newColl);
		} else {
			uint256 newNICR = PalladiumMath._computeNominalCR(newColl, newDebt);

			/*
			 * If the provided hint is out of date, we bail since trying to reinsert without a good hint will almost
			 * certainly result in running out of gas.
			 *
			 * If the resultant net debt of the partial is less than the minimum, net debt we bail.
			 */
			if (
				newNICR != _partialRedemptionHintNICR ||
				_getNetDebt(_asset, newDebt) < IAdminContract(adminContract).getMinNetDebt(_asset)
			) {
				singleRedemption.cancelledPartial = true;
				return singleRedemption;
			}

			ITroveManager(troveManager).executePartialRedemption(
				_asset,
				_borrower,
				newDebt,
				newColl,
				newNICR,
				_upperPartialRedemptionHint,
				_lowerPartialRedemptionHint
			);
		}

		return singleRedemption;
	}

	function setRedemptionSofteningParam(uint256 _redemptionSofteningParam) public {
		if (msg.sender != timelockAddress) {
			revert TroveManagerOperations__NotTimelock();
		}
		if (_redemptionSofteningParam < 9700 || _redemptionSofteningParam > PERCENTAGE_PRECISION) {
			revert TroveManagerOperations__InvalidParam();
		}
		redemptionSofteningParam = _redemptionSofteningParam;
		emit RedemptionSoftenParamChanged(_redemptionSofteningParam);
	}

	function authorizeUpgrade(address newImplementation) public {
		require(newImplementation != address(0), "TroveManagerOperations: new implementation is zero address");
		_authorizeUpgrade(newImplementation);
	}

	function _authorizeUpgrade(address) internal override onlyOwner {}
}

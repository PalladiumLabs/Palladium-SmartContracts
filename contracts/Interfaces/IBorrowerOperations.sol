// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

interface IBorrowerOperations {
	// --- Enums ---
	enum BorrowerOperation {
		openTrove,
		closeTrove,
		adjustTrove
	}

	// --- Events ---

	event BorrowingFeePaid(address indexed _asset, address indexed _borrower, uint256 _feeAmount);
	event TroveCreated(address indexed _asset, address indexed _borrower, uint256 arrayIndex);
	event TroveUpdated(
		address indexed _asset,
		address indexed _borrower,
		uint256 _debt,
		uint256 _coll,
		uint256 stake,
		BorrowerOperation operation
	);

	// --- Functions ---

	function openTrove(
		address _asset,
		uint256 _assetAmount,
		uint256 _debtTokenAmount,
		address _upperHint,
		address _lowerHint
	) external;

	function addColl(address _asset, uint256 _assetSent, address _upperHint, address _lowerHint) external;

	function withdrawColl(address _asset, uint256 _assetAmount, address _upperHint, address _lowerHint) external;

	function withdrawDebtTokens(
		address _asset,
		uint256 _debtTokenAmount,
		address _upperHint,
		address _lowerHint
	) external;

	function repayDebtTokens(address _asset, uint256 _debtTokenAmount, address _upperHint, address _lowerHint) external;

	function closeTrove(address _asset) external;

	function adjustTrove(
		address _asset,
		uint256 _assetSent,
		uint256 _collWithdrawal,
		uint256 _debtChange,
		bool isDebtIncrease,
		address _upperHint,
		address _lowerHint
	) external;

	function claimCollateral(address _asset) external;

	function getCompositeDebt(address _asset, uint256 _debt) external view returns (uint256);
}

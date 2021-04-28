
// SPDX-License-Identifier: AGPL V3.0
pragma solidity ^0.6.12;

import "@ozUpgradesV3/contracts/access/OwnableUpgradeable.sol";
import "@ozUpgradesV3/contracts/token/ERC20/SafeERC20Upgradeable.sol";
import "@ozUpgradesV3/contracts/math/SafeMathUpgradeable.sol";
import "@ozUpgradesV3/contracts/utils/ReentrancyGuardUpgradeable.sol";
import "@ozUpgradesV3/contracts/cryptography/MerkleProofUpgradeable.sol";
import "@ozUpgradesV3/contracts/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

import "../../interfaces/IERC20Burnable.sol";
import "../../interfaces/IERC20Mintable.sol";
import "../../interfaces/delphi/IStakingPool.sol";

contract Rewards is OwnableUpgradeable, ReentrancyGuardUpgradeable, PausableUpgradeable {
    using SafeERC20 for IERC20;
    using SafeMathUpgradeable for uint256;

    event Claimed(address indexed receiver, uint256 amount);

    uint256 public minAmountToClaim = 0;
    bytes32[] public merkleRoots;
    mapping (address => uint256) public claimed;
    IERC20 public token;

    modifier enough(uint256 _claimAmount) {
        require(_claimAmount > 0 && _claimAmount >= minAmountToClaim, "Insufficient token amount");
        _;
    }

    /**
     * @param _token Token in which rewards will be paid
     * if_succeeds {:msg "you must specify token"} _token != address(0);
     */
    function initialize(address _token) virtual public initializer {
        __Ownable_init();
        __Pausable_init();
        __ReentrancyGuard_init();

        token = IERC20(_token);
    }

    /**
     * @notice Sets the minimum amount of  which can be swapped. 0 by default
     * @param _minAmount Minimum amount in wei (the least decimals)
     * if_succeeds {:msg "onlyOwner"} old(msg.sender == owner());
     */
    function setMinClaimAmount(uint256 _minAmount) external onlyOwner {
        minAmountToClaim = _minAmount;
    }

    /**
     * @notice Sets the Merkle roots
     * @param _merkleRoots Array of hashes
     * if_succeeds {:msg "merkle root not updated"} merkleRoots.length == _merkleRoots.length;
     * if_succeeds {:msg "onlyOwner"} old(msg.sender == owner());
     */
    function setMerkleRoots(bytes32[] memory _merkleRoots) external onlyOwner {
        require(_merkleRoots.length > 0, "Incorrect data");
        if (merkleRoots.length > 0) {
            delete merkleRoots;
        }
        merkleRoots = new bytes32[](_merkleRoots.length);
        merkleRoots = _merkleRoots;
    }

    /**
     * @notice Withdraws all tokens collected on a Rewards contract
     * @param _recipient Recepient of token.
     * if_succeeds {:msg "you must specify recipient"} _recipient != address(0);
     */
    function withdrawToken(address _recipient) external onlyOwner {
        require(_recipient != address(0), "Zero address");
        uint256 amount = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransfer(_recipient, amount);
    }

    /**
     * @notice Allows to claim token from the wallet
     * @param _merkleRootIndex Index of a merkle root to be used for calculations
     * @param _amountAllowedToClaim Maximum token allowed for a user to swap
     * @param _merkleProofs Array of consiquent merkle hashes
     * if_succeeds {:msg "wrong _merkleRootIndex"} _merkleRootIndex >= 0 && _merkleRootIndex < merkleRoots.length;
     * if_succeeds {:msg "wrong _amountAllowedToClaim"} _amountAllowedToClaim > 0;
     * if_succeeds {:msg "wrong _merkleProofs"} _merkleProofs.length > 0;
     * if_succeeds {:msg "reward not paid"} old(token.balanceOf(address(this))) - (_amountAllowedToClaim - old(claimed[_msgSender()])) == token.balanceOf(address(this));
     * if_succeeds {:msg "reward not paid"} old(token.balanceOf(_msgSender())) + (_amountAllowedToClaim - old(claimed[_msgSender()])) == token.balanceOf(_msgSender());
     * if_succeeds {:msg "no data about receiving a reward is saved"} old(claimed[_msgSender()]) + (_amountAllowedToClaim - old(claimed[_msgSender()])) == claimed[_msgSender()];
     */
    function claim(
        uint256 _merkleRootIndex,
        uint256 _amountAllowedToClaim,
        bytes32[] memory _merkleProofs
    )
        external nonReentrant whenNotPaused enough(_amountAllowedToClaim)
    {
        require(verifyMerkleProofs(_msgSender(), _merkleRootIndex, _amountAllowedToClaim, _merkleProofs), "Merkle proofs not verified");
        uint256 availableAmount = _amountAllowedToClaim.sub(claimed[_msgSender()]);
        require(availableAmount != 0 && availableAmount >= minAmountToClaim, "Not enough tokens");
        claimed[_msgSender()] = claimed[_msgSender()].add(availableAmount);
        token.safeTransfer(_msgSender(), availableAmount);
        emit Claimed(_msgSender(), availableAmount);
    }

    /**
     * @notice Verifies merkle proofs of user to be elligible for swap
     * @param _account Address of a user
     * @param _merkleRootIndex Index of a merkle root to be used for calculations
     * @param _amountAllowedToClaim Maximum ADEL allowed for a user to swap
     * @param _merkleProofs Array of consiquent merkle hashes
     * if_succeeds {:msg "you must specify account"} _account != address(0);
     * if_succeeds {:msg "wrong merkleRootIndex"} _merkleRootIndex >= 0 && _merkleRootIndex < merkleRoots.length;
     * if-succeeds {:msg "wrong amountAllowedToClaim"} _amountAllowedToClaim > 0;
     */
    function verifyMerkleProofs(
        address _account,
        uint256 _merkleRootIndex,
        uint256 _amountAllowedToClaim,
        bytes32[] memory _merkleProofs) virtual public view returns(bool)
    {
        require(_merkleProofs.length > 0, "No Merkle proofs");
        require(_merkleRootIndex < merkleRoots.length, "Merkle roots are not set");

        bytes32 node = keccak256(abi.encodePacked(_account, _amountAllowedToClaim));
        return MerkleProofUpgradeable.verify(_merkleProofs, merkleRoots[_merkleRootIndex], node);
    }

    /**
     * @notice Called by the owner to pause, deny claim reward
     * if_succeeds {:msg "not paused"} paused() == true;
     * if_succeeds {:msg "onlyOwner"} old(msg.sender == owner());
     */
    function pause() onlyOwner whenNotPaused external {
        _pause();
    }

    /**
     * @notice Called by the owner to unpause, allow claim reward
     * if_succeeds {:msg "paused"} paused() == false;
     * if_succeeds {:msg "onlyOwner"} old(msg.sender == owner());
     */
    function unpause() onlyOwner whenPaused external {
        _unpause();
    }
}

// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity 0.5.17;
pragma experimental ABIEncoderV2;

import {StakeManager, IERC20, IValidatorShare, Registry, StakingNFT} from "./StakeManagerV2.sol";
import {IService} from "../../hub/IService.sol";
import {ISlasher} from "../../hub/ISlasher.sol";
import {ILocker} from "../../hub/ILocker.sol";
import {IStakingHub} from "../../hub/IStakingHub.sol";
import {SafeERC20} from "openzeppelin-solidity/contracts/token/ERC20/SafeERC20.sol";
import {IStakingNFT} from "./IStakingNFT.sol";

interface IPolygonMigration {
    function migrate(uint256 amount) external;
}

/// @title ServicePoS
/// @author Polygon Labs
/// @notice Represents the Polygon PoS network
/// @notice Stakers can subscribe to this Service using the Staking Hub.
contract ServicePoS is StakeManager, IService {
    using SafeERC20 for IERC20;

    IStakingHub public stakingHub;
    ISlasher public slasher;
    ILocker public polLocker;
    IERC20 public polToken;
    IStakingNFT public old_NFTContract;
    address public serviceMigration;

    event ValidatorMigration(uint256 indexed validatorId, address indexed staker);

    struct RegisterParams {
        uint256 initalStake;
        uint256 heimdallFee;
        bool acceptDelegation;
        bytes signerPubKey;
    }
    mapping(address /*staker*/ => RegisterParams) public registerParams;

    function reinitializeV2(
        IStakingHub _stakingHub,
        IStakingHub.LockerSettings[] calldata _lockerSettings,
        uint40 _unsubNotice,
        ISlasher _slasher,
        ILocker _polLocker,
        IERC20 _polToken,
        address _polMigration,
        address _newNFTContract,
        address _serviceMigration
    ) external onlyGovernance {
        stakingHub = _stakingHub;
        stakingHub.registerService(_lockerSettings, _unsubNotice, address(_slasher));
        slasher = _slasher;
        polLocker = _polLocker;
        polToken = _polToken;
        old_NFTContract = IStakingNFT(address(NFTContract));
        NFTContract = StakingNFT(_newNFTContract);
        serviceMigration = _serviceMigration;

        uint256 maticBalance = token.balanceOf(address(this));
        token.approve(_polMigration, maticBalance);
        IPolygonMigration(_polMigration).migrate(maticBalance);
    }

    modifier onlyStakingHub() {
        require(msg.sender == address(stakingHub), "only StakingHub");
        _;
    }

    // @notice registers staker params
    // @dev has to be called by staker, before subscribing to the service
    function registeOrModifyStakerParams(RegisterParams calldata params) external onlyWhenUnlocked {
        // validate params
        require(params.initalStake >= minDeposit, "Invalid stake");
        require(params.signerPubKey.length == 64, "not pub");
        address signer = address(uint160(uint256(keccak256(params.signerPubKey))));
        require(signer != address(0) && signerToValidator[signer] == 0, "Invalid signer");

        require(params.heimdallFee >= minHeimdallFee, "fee too small");

        registerParams[msg.sender] = params;
    }

    function pullSelfStake(uint256 validatorId) external returns (uint256 amount, address staker) {
        require(msg.sender == serviceMigration, "not allowed");
        staker = old_NFTContract.ownerOf(validatorId);
        require(staker != address(0) && validators[validatorId].deactivationEpoch == 0, "validator migrated");
        amount = validators[validatorId].amount;
        polToken.safeTransfer(msg.sender, amount);
    }

    function migrateValidator(uint256 validatorId) external {
        require(msg.sender == serviceMigration, "not allowed");
        address staker = old_NFTContract.ownerOf(validatorId); // reverts if address(0), ie migrated
        NFTContract.mint(staker, validatorId);
    }

    function onSubscribe(address staker, uint256 /*lockingInUntil*/) public onlyStakingHub onlyWhenUnlocked {
        // existing validator
        if (old_NFTContract.balanceOf(staker) == 1) {
            uint256 validatorId = old_NFTContract.tokenOfOwnerByIndex(staker, 0);
            address target = address(NFTContract);
            assembly {
                mstore(0x40, 0x6352211e) // 'ownerOf(uint256)' signature, stored left padded
                mstore(0x60, validatorId)
                let success := staticcall(gas(), target, 0x5c, 0x24, 0x80, 0x20)
                // if call doesn't revert, `validatorId` is already migrated
                if eq(success, 1) {
                    mstore(0, 0x616c7265616479206d69677261746564) // 'already migrated', len 0x10
                    revert(0x10, 0x20) // 0x10 is the offset of the error message
                }
            }
            NFTContract.mint(staker, validatorId);
            require(
                polLocker.balanceOf(staker, stakingHub.serviceId(address(this))) >= validators[validatorId].amount,
                "Insufficient funds (re)staked on locker"
            );
            return;
        }
        RegisterParams memory params = registerParams[staker];
        delete registerParams[staker];

        require(params.initalStake != 0, "Staker not registered");
        require(currentValidatorSetSize() < validatorThreshold, "no more slots");
        require(
            polLocker.balanceOf(staker, stakingHub.serviceId(address(this))) >= params.initalStake,
            "Insufficient funds (re)staked on locker"
        );

        polToken.safeTransferFrom(staker, address(this), params.heimdallFee);
        _topUpFee(staker, params.heimdallFee);
        _stakeFor(staker, params.initalStake, params.acceptDelegation, params.signerPubKey);
    }

    function onInitiateUnsubscribe(address staker, bool isLockedIn) public onlyStakingHub {
        if (isLockedIn) revert("locked in");
        uint256 validatorId = NFTContract.tokenOfOwnerByIndex(staker, 0);
        require(validatorAuction[validatorId].amount == 0);

        Status status = validators[validatorId].status;
        require(
            validators[validatorId].activationEpoch > 0 &&
                validators[validatorId].deactivationEpoch == 0 &&
                (status == Status.Active || status == Status.Locked)
        );

        uint256 exitEpoch = currentEpoch.add(1); // notice period
        _unstake(validatorId, exitEpoch);
    }

    function onFinalizeUnsubscribe(address staker) public onlyStakingHub {
        uint256 validatorId = NFTContract.tokenOfOwnerByIndex(staker, 0);

        uint256 deactivationEpoch = validators[validatorId].deactivationEpoch;
        // can only claim stake back after WITHDRAWAL_DELAY
        require(
            deactivationEpoch > 0 &&
                deactivationEpoch.add(WITHDRAWAL_DELAY) <= currentEpoch &&
                validators[validatorId].status != Status.Unstaked
        );

        uint256 amount = validators[validatorId].amount;
        uint256 newTotalStaked = totalStaked.sub(amount);
        totalStaked = newTotalStaked;

        _liquidateRewards(validatorId, msg.sender);

        NFTContract.burn(validatorId);

        // locker is notified onInitiateUnsubscribe by hub
        validators[validatorId].amount = 0;
        validators[validatorId].jailTime = 0;
        validators[validatorId].signer = address(0);

        signerToValidator[validators[validatorId].signer] = INCORRECT_VALIDATOR_ID;
        validators[validatorId].status = Status.Unstaked;

        logger.logUnstaked(msg.sender, validatorId, amount, newTotalStaked);
    }

    function topUpForFee(address user, uint256 heimdallFee) external onlyWhenUnlocked {
        polToken.safeTransferFrom(user, address(this), heimdallFee);
        _topUpFee(user, heimdallFee);
    }

    function claimFee(uint256 accumFeeAmount, uint256 index, bytes calldata proof) external {
        //Ignoring other params because rewards' distribution is on chain
        require(
            keccak256(abi.encode(msg.sender, accumFeeAmount)).checkMembership(index, accountStateRoot, proof),
            "Wrong acc proof"
        );
        uint256 withdrawAmount = accumFeeAmount.sub(userFeeExit[msg.sender]);
        _claimFee(msg.sender, withdrawAmount);
        userFeeExit[msg.sender] = accumFeeAmount;
        polToken.safeTransfer(msg.sender, withdrawAmount);
    }

    function restake(
        uint256 validatorId,
        uint256 amount,
        bool stakeRewards
    ) public onlyWhenUnlocked onlyStaker(validatorId) {
        require(validators[validatorId].deactivationEpoch == 0, "No restaking");

        if (amount > 0) {
            polToken.safeTransferFrom(msg.sender, address(this), amount);
        }

        _updateRewards(validatorId);

        if (stakeRewards) {
            amount = amount.add(validators[validatorId].reward).sub(INITIALIZED_AMOUNT);
            validators[validatorId].reward = INITIALIZED_AMOUNT;
        }

        uint256 newTotalStaked = totalStaked.add(amount);
        totalStaked = newTotalStaked;
        uint256 newAmount = validators[validatorId].amount.add(amount);
        validators[validatorId].amount = newAmount;
        updateTimeline(int256(amount), 0, 0);

        logger.logStakeUpdate(validatorId);
        logger.logRestaked(validatorId, newAmount, newTotalStaked);
        polLocker.depositAndApproveFor(
            NFTContract.ownerOf(validatorId),
            stakingHub.serviceId(address(this)),
            newAmount
        );
    }

    function transferFunds(uint256 validatorId, uint256 amount, address delegator) external returns (bool) {
        require(
            validators[validatorId].contractAddress == msg.sender ||
                Registry(registry).getSlashingManagerAddress() == msg.sender,
            "not allowed"
        );
        return polToken.transfer(delegator, amount);
    }

    function delegationDeposit(
        uint256 validatorId,
        uint256 amount,
        address delegator
    ) external onlyDelegation(validatorId) returns (bool) {
        return polToken.transferFrom(delegator, address(this), amount);
    }

    function _liquidateRewards(uint256 validatorId, address validatorUser) internal {
        uint256 reward = validators[validatorId].reward.sub(INITIALIZED_AMOUNT);
        totalRewardsLiquidated = totalRewardsLiquidated.add(reward);
        validators[validatorId].reward = INITIALIZED_AMOUNT;
        polToken.safeTransfer(validatorUser, reward);
        logger.logClaimRewards(validatorId, reward, totalRewardsLiquidated);
    }

    function _unstake(uint256 validatorId, uint256 exitEpoch) internal {
        // must think how to handle it correctly
        _updateRewards(validatorId);

        uint256 amount = validators[validatorId].amount;
        address validator = ownerOf(validatorId);

        validators[validatorId].deactivationEpoch = exitEpoch;

        // unbond all delegators in future
        int256 delegationAmount = int256(validators[validatorId].delegatedAmount);

        address delegationContract = validators[validatorId].contractAddress;
        if (delegationContract != address(0)) {
            IValidatorShare(delegationContract).lock();
        }

        _removeSigner(validators[validatorId].signer);
        _liquidateRewards(validatorId, validator);

        uint256 targetEpoch = exitEpoch <= currentEpoch ? 0 : exitEpoch;
        updateTimeline(-(int256(amount) + delegationAmount), -1, targetEpoch);

        logger.logUnstakeInit(validator, validatorId, exitEpoch, amount);
    }

    function withdrawRewards(uint256 validatorId) public onlyStaker(validatorId) {
        _updateRewards(validatorId);
        _liquidateRewards(validatorId, msg.sender);
    }

    function drain(address _token, address _destination, uint256 _amount) external onlyGovernance {
        IERC20(_token).safeTransfer(_destination, _amount);
    }
}

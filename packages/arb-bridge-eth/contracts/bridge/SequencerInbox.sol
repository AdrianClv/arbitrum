// SPDX-License-Identifier: Apache-2.0

/*
 * Copyright 2021, Offchain Labs, Inc.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *    http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

pragma solidity ^0.6.11;

import "./interfaces/ISequencerInbox.sol";
import "./interfaces/IBridge.sol";
import "../arch/Marshaling.sol";

import "./Messages.sol";

contract SequencerInbox is ISequencerInbox {
    uint8 internal constant L2_MSG = 3;

    bytes32[] public override inboxAccs;
    uint256 public override messageCount;

    uint256 totalDelayedMessagesRead;

    IBridge public delayedInbox;
    address public sequencer;
    uint256 public override maxDelayBlocks;
    uint256 public override maxDelaySeconds;

    // Validated in constructor
    bytes32 internal constant END_OF_BLOCK_MESSAGE_HASH =
        0xe7a397496222d62de84457e9850e00d34ba37e557130feada7d6ea6fa6a21467;

    constructor(
        IBridge _delayedInbox,
        address _sequencer,
        uint256 _maxDelayBlocks,
        uint256 _maxDelaySeconds
    ) public {
        delayedInbox = _delayedInbox;
        sequencer = _sequencer;
        maxDelayBlocks = _maxDelayBlocks;
        maxDelaySeconds = _maxDelaySeconds;
        require(
            END_OF_BLOCK_MESSAGE_HASH ==
                Messages.messageHash(6, address(0), 0, 0, 0, 0, bytes32(0)),
            "WRONG_HASH_CONST"
        );
    }

    function getLastDelayedAcc() internal view returns (bytes32) {
        bytes32 acc = 0;
        if (totalDelayedMessagesRead > 0) {
            acc = delayedInbox.inboxAccs(totalDelayedMessagesRead - 1);
        }
        return acc;
    }

    function forceInclusion(
        uint256 _totalDelayedMessagesRead,
        uint8 kind,
        uint256 l1BlockNumber,
        uint256 l1Timestamp,
        uint256 inboxSeqNum,
        uint256 gasPriceL1,
        address sender,
        bytes32 messageDataHash
    ) external {
        require(_totalDelayedMessagesRead > totalDelayedMessagesRead, "DELAYED_BACKWARDS");
        {
            bytes32 messageHash =
                Messages.messageHash(
                    kind,
                    sender,
                    l1BlockNumber,
                    l1Timestamp,
                    inboxSeqNum,
                    gasPriceL1,
                    messageDataHash
                );
            require(l1BlockNumber + maxDelayBlocks < block.number, "MAX_DELAY_BLOCKS");
            require(l1Timestamp + maxDelaySeconds < block.timestamp, "MAX_DELAY_TIME");

            bytes32 prevDelayedAcc = 0;
            if (_totalDelayedMessagesRead > 1) {
                prevDelayedAcc = delayedInbox.inboxAccs(_totalDelayedMessagesRead - 2);
            }
            require(
                delayedInbox.inboxAccs(_totalDelayedMessagesRead - 1) ==
                    Messages.addMessageToInbox(prevDelayedAcc, messageHash),
                "DELAYED_ACCUMULATOR"
            );
        }

        uint256 startNum = messageCount;
        (bytes32 beforeSeqAcc, bytes32 acc, uint256 count) =
            includeDelayedMessages(_totalDelayedMessagesRead);
        inboxAccs.push(acc);
        messageCount = count;
        emit DelayedInboxForced(
            startNum,
            beforeSeqAcc,
            count,
            _totalDelayedMessagesRead,
            [acc, getLastDelayedAcc()]
        );
    }

    function addSequencerL2BatchFromOrigin(
        bytes calldata transactions,
        uint256[] calldata lengths,
        uint256 l1BlockNumber,
        uint256 timestamp,
        uint256 _totalDelayedMessagesRead
    ) external {
        // solhint-disable-next-line avoid-tx-origin
        require(msg.sender == tx.origin, "origin only");
        uint256 startNum = messageCount;
        (bytes32 beforeAcc, bytes32 afterAcc) =
            addSequencerL2BatchImpl(
                transactions,
                lengths,
                l1BlockNumber,
                timestamp,
                _totalDelayedMessagesRead
            );
        emit SequencerBatchDeliveredFromOrigin(
            startNum,
            beforeAcc,
            messageCount,
            afterAcc,
            getLastDelayedAcc()
        );
    }

    function addSequencerL2Batch(
        bytes calldata transactions,
        uint256[] calldata lengths,
        uint256 l1BlockNumber,
        uint256 timestamp,
        uint256 _totalDelayedMessagesRead
    ) external {
        uint256 startNum = messageCount;
        (bytes32 beforeAcc, bytes32 afterAcc) =
            addSequencerL2BatchImpl(
                transactions,
                lengths,
                l1BlockNumber,
                timestamp,
                _totalDelayedMessagesRead
            );
        emit SequencerBatchDelivered(
            startNum,
            beforeAcc,
            messageCount,
            afterAcc,
            transactions,
            lengths,
            l1BlockNumber,
            timestamp,
            _totalDelayedMessagesRead,
            getLastDelayedAcc()
        );
    }

    function addSequencerL2BatchImpl(
        bytes calldata transactions,
        uint256[] calldata lengths,
        uint256 l1BlockNumber,
        uint256 timestamp,
        uint256 _totalDelayedMessagesRead
    ) private returns (bytes32, bytes32) {
        require(msg.sender == sequencer, "ONLY_SEQUENCER");
        require(l1BlockNumber + maxDelayBlocks >= block.number, "BLOCK_TOO_OLD");
        require(l1BlockNumber <= block.number, "BLOCK_TOO_NEW");
        require(timestamp + maxDelaySeconds >= block.timestamp, "TIME_TOO_OLD");
        require(timestamp <= block.timestamp, "TIME_TOO_NEW");
        require(_totalDelayedMessagesRead >= totalDelayedMessagesRead, "DELAYED_BACKWARDS");

        (bytes32 beforeAcc, bytes32 acc, uint256 count) =
            includeDelayedMessages(_totalDelayedMessagesRead);

        uint256 offset = 0;
        for (uint256 i = 0; i < lengths.length; i++) {
            if (lengths[i] == 0) {
                acc = keccak256(
                    abi.encodePacked("Sequencer message:", acc, count, END_OF_BLOCK_MESSAGE_HASH)
                );
                count++;
            } else {
                bytes32 messageDataHash =
                    keccak256(bytes(transactions[offset:offset + lengths[i]]));
                bytes32 messageHash =
                    Messages.messageHash(
                        L2_MSG,
                        msg.sender,
                        l1BlockNumber,
                        timestamp, // solhint-disable-line not-rely-on-time
                        count,
                        tx.gasprice,
                        messageDataHash
                    );
                acc = keccak256(abi.encodePacked("Sequencer message:", acc, count, messageHash));
                offset += lengths[i];
                count++;
            }
        }
        require(count > messageCount, "EMPTY_BATCH");
        inboxAccs.push(acc);
        messageCount = count;

        return (beforeAcc, acc);
    }

    function includeDelayedMessages(uint256 _totalDelayedMessagesRead)
        private
        returns (
            bytes32,
            bytes32,
            uint256
        )
    {
        bytes32 beforeAcc = 0;
        if (inboxAccs.length > 0) {
            beforeAcc = inboxAccs[inboxAccs.length - 1];
        }
        bytes32 acc = beforeAcc;
        uint256 count = messageCount;
        if (_totalDelayedMessagesRead > totalDelayedMessagesRead) {
            require(_totalDelayedMessagesRead <= delayedInbox.messageCount(), "DELAYED_TOO_FAR");
            acc = keccak256(
                abi.encodePacked(
                    "Delayed messages:",
                    acc,
                    count,
                    totalDelayedMessagesRead,
                    _totalDelayedMessagesRead,
                    delayedInbox.inboxAccs(_totalDelayedMessagesRead - 1)
                )
            );
            count += _totalDelayedMessagesRead - totalDelayedMessagesRead;
            acc = keccak256(
                abi.encodePacked("Sequencer message:", acc, count, END_OF_BLOCK_MESSAGE_HASH)
            );
            count += 1;
            totalDelayedMessagesRead = _totalDelayedMessagesRead;
        }
        return (beforeAcc, acc, count);
    }

    function proveSeqBatchMsgCount(
        bytes calldata proof,
        uint256 offset,
        bytes32 acc
    ) internal pure returns (uint256, uint256) {
        uint256 endCount;

        bytes32 buildingAcc;
        (offset, buildingAcc) = Marshaling.deserializeBytes32(proof, offset);
        uint8 isDelayed = uint8(proof[offset]);
        offset++;
        require(isDelayed == 0 || isDelayed == 1, "IS_DELAYED_NUM");
        if (isDelayed == 0) {
            uint256 seqNum;
            bytes32 messageHash;
            (offset, seqNum) = Marshaling.deserializeInt(proof, offset);
            (offset, messageHash) = Marshaling.deserializeBytes32(proof, offset);
            buildingAcc = keccak256(
                abi.encodePacked("Sequencer message:", buildingAcc, seqNum, messageHash)
            );
            endCount = seqNum + 1;
        } else {
            uint256 firstSequencerSeqNum;
            uint256 delayedStart;
            uint256 delayedEnd;
            bytes32 delayedEndAcc;
            (offset, firstSequencerSeqNum) = Marshaling.deserializeInt(proof, offset);
            (offset, delayedStart) = Marshaling.deserializeInt(proof, offset);
            (offset, delayedEnd) = Marshaling.deserializeInt(proof, offset);
            (offset, delayedEndAcc) = Marshaling.deserializeBytes32(proof, offset);
            buildingAcc = keccak256(
                abi.encodePacked(
                    "Delayed messages:",
                    buildingAcc,
                    firstSequencerSeqNum,
                    delayedStart,
                    delayedEnd,
                    delayedEndAcc
                )
            );
            endCount = delayedEnd - delayedStart + firstSequencerSeqNum;
        }
        require(buildingAcc == acc, "BATCH_ACC");

        return (offset, endCount);
    }

    function proveBatchContainsSequenceNumber(bytes calldata proof, uint256 inboxCount)
        external
        view
        override
        returns (bytes32)
    {
        if (inboxCount == 0) {
            return 0;
        }

        (uint256 offset, uint256 seqBatchNum) = Marshaling.deserializeInt(proof, 0);
        uint256 lastBatchCount = 0;
        if (seqBatchNum > 0) {
            (offset, lastBatchCount) = proveSeqBatchMsgCount(
                proof,
                offset,
                inboxAccs[seqBatchNum - 1]
            );
            lastBatchCount++;
        }

        bytes32 seqBatchAcc = inboxAccs[seqBatchNum];
        uint256 thisBatchCount;
        (offset, thisBatchCount) = proveSeqBatchMsgCount(proof, offset, seqBatchAcc);

        require(inboxCount > lastBatchCount, "BATCH_START");
        require(inboxCount <= thisBatchCount, "BATCH_END");

        return seqBatchAcc;
    }
}
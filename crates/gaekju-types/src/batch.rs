use alloy_sol_types::sol;

sol! {
    struct BatchPublicInputs {
        bytes32 prevStateRoot;
        bytes32 postStateRoot;
        bytes32 batchHash;
        uint64 batchNonce;
        uint64 chainId;
        uint64 forceIncludeCursor;
    }

    struct ProofBundle {
        BatchPublicInputs publicInputs;
        bytes sp1Proof;
        bytes batchBlob;
    }

    struct BatchHeader {
        uint64 batchNonce;
        bytes32 prevStateRoot;
        uint64 timestamp;
        uint32 intentCount;
        uint32 fillCount;
        uint32 forcedCount;
        uint64 forceIncludeCursor;
    }

    struct ReplayedIntent {
        bytes payload;
    }

    struct PositionFill {
        address account;
        uint256 marketId;
        int256 newSize;
        uint256 newEntryPrice;
        uint256 newCollateral;
        int256 newCumulativeFunding;
        int256 sizeDelta;
        uint256 fillPrice;
        int256 realizedPnl;
    }

    struct BalanceDelta {
        address account;
        int256 freeDelta;
        int256 lockedMarginDelta;
        int256 orderMarginDelta;
        int256 realizedPnlDelta;
        int256 insuranceFundDelta;
    }

    struct MidPriceUpdate {
        uint256 marketId;
        uint256 mid;
    }

    struct ForcedOutcome {
        uint256 forcedIntentId;
        uint8 outcome;
        uint8 rejectReason;
        bytes32 resultHash;
    }

    struct BatchBlob {
        BatchHeader header;
        ReplayedIntent[] acceptedIntents;
        PositionFill[] fills;
        BalanceDelta[] balanceDeltas;
        MidPriceUpdate[] midPriceUpdates;
        ForcedOutcome[] forcedOutcomes;
        bytes32[] attestedPriceIds;
        bytes32[] attestedPriceHashes;
    }

    event BatchSettled(
        uint64 indexed batchNonce,
        bytes32 prevStateRoot,
        bytes32 postStateRoot,
        bytes32 batchHash,
        uint64 forceIncludeCursor
    );

    event ForceIncludeQueued(
        uint256 indexed forcedIntentId,
        address indexed trader,
        bytes32 intentHash,
        uint64 deadlineBatchNonce
    );

    event ForcedIntentResolved(uint256 indexed forcedIntentId, uint8 outcome, uint8 rejectReason, bytes32 resultHash);
}

#[cfg(test)]
mod tests {
    use alloy_primitives::B256;
    use alloy_sol_types::SolValue;

    use super::BatchPublicInputs;

    #[test]
    fn batch_public_inputs_uint64_fields_are_abi_words() {
        let public = BatchPublicInputs {
            prevStateRoot: B256::repeat_byte(1),
            postStateRoot: B256::repeat_byte(2),
            batchHash: B256::repeat_byte(3),
            batchNonce: 4,
            chainId: 5,
            forceIncludeCursor: 6,
        };
        let encoded = public.abi_encode();
        assert_eq!(encoded.len(), 32 * 6);
        assert_eq!(&encoded[32 * 3 + 24..32 * 4], &4u64.to_be_bytes());
        assert_eq!(&encoded[32 * 4 + 24..32 * 5], &5u64.to_be_bytes());
        assert_eq!(&encoded[32 * 5 + 24..32 * 6], &6u64.to_be_bytes());
    }
}

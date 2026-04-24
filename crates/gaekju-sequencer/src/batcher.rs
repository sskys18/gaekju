use std::fs;
use std::path::Path;
use std::time::Duration;

use alloy_primitives::{keccak256, Bytes, B256, I256, U256};
use alloy_sol_types::SolValue;
use tokio::sync::mpsc;

use crate::actor::{Batch, SequencerHandle};
use crate::config::Config;

pub async fn run_batcher(
    config: Config,
    sequencer: SequencerHandle,
    prover_tx: mpsc::Sender<Batch>,
) -> eyre::Result<()> {
    let mut interval = tokio::time::interval(Duration::from_millis(config.batch_ms));
    loop {
        interval.tick().await;
        if let Some(batch) = sequencer.close_batch().await {
            write_prover_inbox(&config.prover_inbox, &batch)?;
            let _ = prover_tx.send(batch).await;
        }
    }
}

pub fn write_prover_inbox(inbox: &Path, batch: &Batch) -> eyre::Result<()> {
    fs::create_dir_all(inbox)?;
    let path = inbox.join(format!("{}.batch", batch.header.batch_nonce));
    let bytes = bincode::serialize(batch)?;
    fs::write(path, bytes)?;
    Ok(())
}

pub fn canonical_batch_hash(batch: &Batch) -> [u8; 32] {
    keccak256(canonical_batch_abi(batch)).0
}

pub fn canonical_batch_abi(batch: &Batch) -> Vec<u8> {
    let blob = gaekju_types::BatchBlob {
        header: gaekju_types::BatchHeader {
            batchNonce: batch.header.batch_nonce,
            prevStateRoot: B256::from(batch.header.prev_state_root),
            timestamp: batch.header.timestamp,
            intentCount: batch.header.intent_count,
            fillCount: batch.header.fill_count,
            forcedCount: batch.header.forced_count,
            forceIncludeCursor: batch.header.force_include_cursor,
        },
        acceptedIntents: batch
            .accepted_intents
            .iter()
            .map(|intent| gaekju_types::ReplayedIntent {
                payload: Bytes::from(serde_json::to_vec(intent).expect("intent serializes")),
            })
            .collect(),
        fills: batch
            .position_fills
            .iter()
            .map(|fill| gaekju_types::PositionFill {
                account: fill.account,
                marketId: U256::from(fill.market_id),
                newSize: I256::unchecked_from(fill.new_size),
                newEntryPrice: U256::from(fill.new_entry_price.unsigned_abs()),
                newCollateral: U256::from(fill.new_collateral.unsigned_abs()),
                newCumulativeFunding: I256::unchecked_from(fill.new_cumulative_funding),
                sizeDelta: I256::unchecked_from(fill.size_delta),
                fillPrice: U256::from(fill.fill_price.unsigned_abs()),
                realizedPnl: I256::unchecked_from(fill.realized_pnl),
            })
            .collect(),
        balanceDeltas: batch
            .balance_deltas
            .iter()
            .map(|delta| gaekju_types::BalanceDelta {
                account: delta.account,
                freeDelta: I256::unchecked_from(delta.free_delta),
                lockedMarginDelta: I256::unchecked_from(delta.locked_margin_delta),
                orderMarginDelta: I256::unchecked_from(delta.order_margin_delta),
                realizedPnlDelta: I256::unchecked_from(delta.realized_pnl_delta),
                insuranceFundDelta: I256::unchecked_from(delta.insurance_fund_delta),
            })
            .collect(),
        midPriceUpdates: batch
            .mid_price_updates
            .iter()
            .map(|update| gaekju_types::MidPriceUpdate {
                marketId: U256::from(update.market_id),
                mid: U256::from(update.mid.unsigned_abs()),
            })
            .collect(),
        forcedOutcomes: batch
            .forced_outcomes
            .iter()
            .map(|outcome| gaekju_types::ForcedOutcome {
                forcedIntentId: U256::from(outcome.forced_intent_id),
                outcome: outcome.outcome,
                rejectReason: outcome.reject_reason,
                resultHash: B256::from(outcome.result_hash),
            })
            .collect(),
        attestedPriceIds: batch
            .attested_price_ids
            .iter()
            .copied()
            .map(B256::from)
            .collect(),
        attestedPriceHashes: batch
            .attested_price_hashes
            .iter()
            .copied()
            .map(B256::from)
            .collect(),
    };
    blob.abi_encode()
}

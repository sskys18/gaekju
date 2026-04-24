use alloy_primitives::Address;
use alloy_signer::SignerSync;
use alloy_signer_local::PrivateKeySigner;
use gaekju_matching_core::{
    intent_digest, state_root, Eip712Domain, Intent, IntentKind, Side, SignatureBytes, State,
    TimeInForce,
};
use gaekju_sequencer::batcher::{canonical_batch_abi, write_prover_inbox};
use gaekju_sequencer::{Config, SequencerHandle};

fn make_intent(trader: Address, nonce: u64, side: Side, price: i128, qty: i128) -> Intent {
    Intent {
        market_id: 1,
        trader,
        nonce,
        side,
        price,
        qty,
        tif: TimeInForce::Gtc,
        expiry: 0,
        flags: 0,
        kind: IntentKind::Place,
        ref_seq_id: 0,
    }
}

fn sign(domain: Eip712Domain, signer: &PrivateKeySigner, intent: &Intent) -> SignatureBytes {
    let sig = signer
        .sign_hash_sync(&intent_digest(domain, intent))
        .expect("signs intent");
    SignatureBytes(sig.into())
}

#[tokio::test]
async fn signed_intents_batch_and_replay_to_same_state_root() {
    let tmp = tempfile::tempdir().unwrap();
    let config = Config {
        data_dir: tmp.path().join("data"),
        prover_inbox: tmp.path().join("inbox"),
        ..Config::default()
    };
    let domain = Eip712Domain {
        chain_id: config.chain_id,
        verifying_contract: config.settlement,
    };
    let maker = PrivateKeySigner::random();
    let taker = PrivateKeySigner::random();
    let sequencer = SequencerHandle::new(config.clone(), None);

    let mut replay = State::default();
    for nonce in 1..=50 {
        let intent = make_intent(maker.address(), nonce, Side::Sell, 100, 1);
        let sig = sign(domain, &maker, &intent);
        sequencer
            .submit_intent(intent.clone(), sig)
            .await
            .expect("maker accepted");
        replay.apply_intent(&intent).expect("replay maker");
    }
    for nonce in 1..=50 {
        let intent = make_intent(taker.address(), nonce, Side::Buy, 100, 1);
        let sig = sign(domain, &taker, &intent);
        sequencer
            .submit_intent(intent.clone(), sig)
            .await
            .expect("taker accepted");
        replay.apply_intent(&intent).expect("replay taker");
    }

    let batch = sequencer.close_batch().await.expect("batch closes");
    write_prover_inbox(&config.prover_inbox, &batch).expect("batch written");
    assert!(config.prover_inbox.join("1.batch").exists());
    assert_eq!(batch.post_state_root, state_root(&replay));
    assert_eq!(batch.fills.len(), 50);
    assert_eq!(batch.header.batch_nonce, 1);
    assert_eq!(batch.header.intent_count, 100);
    assert!(!canonical_batch_abi(&batch).is_empty());
}

#[tokio::test]
async fn duplicate_of_forced_is_rejected() {
    let config = Config::default();
    let domain = Eip712Domain {
        chain_id: config.chain_id,
        verifying_contract: config.settlement,
    };
    let signer = PrivateKeySigner::random();
    let intent = make_intent(signer.address(), 1, Side::Buy, 100, 1);
    let sig = sign(domain, &signer, &intent);
    let sequencer = SequencerHandle::new(config, None);
    sequencer
        .mirror_forced(1, signer.address(), intent_digest(domain, &intent).0, 3)
        .await;

    let err = sequencer.submit_intent(intent, sig).await.unwrap_err();
    assert_eq!(err, gaekju_matching_core::Reject::DuplicateOfForced);
}

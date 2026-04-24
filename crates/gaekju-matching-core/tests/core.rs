use alloy_primitives::Address;
use gaekju_matching_core::{
    intent_digest, state_root, verify_intent, Eip712Domain, Intent, IntentKind, Reject, Side,
    SignatureBytes, State, TimeInForce,
};
use proptest::prelude::*;

fn addr(n: u8) -> Address {
    Address::repeat_byte(n)
}

fn intent(trader: Address, nonce: u64, side: Side, price: i128, qty: i128) -> Intent {
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

#[test]
fn price_time_priority_matches_fifo() {
    let mut state = State::default();
    let maker_a = intent(addr(1), 1, Side::Sell, 100, 5);
    let maker_b = intent(addr(2), 1, Side::Sell, 100, 5);
    state.apply_intent(&maker_a).unwrap();
    state.apply_intent(&maker_b).unwrap();

    let fills = state
        .apply_intent(&intent(addr(3), 1, Side::Buy, 100, 8))
        .unwrap();

    assert_eq!(fills.len(), 2);
    assert_eq!(fills[0].maker, addr(1));
    assert_eq!(fills[0].qty, 5);
    assert_eq!(fills[1].maker, addr(2));
    assert_eq!(fills[1].qty, 3);
}

#[test]
fn post_only_rejects_crossing_order() {
    let mut state = State::default();
    state
        .apply_intent(&intent(addr(1), 1, Side::Sell, 100, 5))
        .unwrap();
    let mut taker = intent(addr(2), 1, Side::Buy, 100, 1);
    taker.tif = TimeInForce::PostOnly;

    assert_eq!(state.apply_intent(&taker), Err(Reject::PostOnlyWouldCross));
}

#[test]
fn fok_is_atomic() {
    let mut state = State::default();
    state
        .apply_intent(&intent(addr(1), 1, Side::Sell, 100, 5))
        .unwrap();
    let before = state_root(&state);
    let mut taker = intent(addr(2), 1, Side::Buy, 100, 6);
    taker.tif = TimeInForce::Fok;

    assert_eq!(state.apply_intent(&taker), Err(Reject::FokWouldNotFill));
    assert_eq!(before, state_root(&state));
}

#[test]
fn eip712_digest_is_domain_bound() {
    let intent = intent(addr(1), 1, Side::Buy, 100, 1);
    let a = intent_digest(
        Eip712Domain {
            chain_id: 1,
            verifying_contract: addr(9),
        },
        &intent,
    );
    let b = intent_digest(
        Eip712Domain {
            chain_id: 2,
            verifying_contract: addr(9),
        },
        &intent,
    );
    assert_ne!(a, b);
}

#[test]
fn verify_rejects_bad_signature() {
    let intent = intent(addr(1), 1, Side::Buy, 100, 1);
    let sig = SignatureBytes([0u8; 65]);
    let err = verify_intent(
        Eip712Domain {
            chain_id: 1,
            verifying_contract: addr(9),
        },
        &intent,
        &sig,
        0,
    )
    .unwrap_err();
    assert!(matches!(
        err,
        gaekju_matching_core::eip712::VerifyError::InvalidSignature
    ));
}

proptest! {
    #[test]
    fn no_negative_resting_qty(qty in 1i128..1_000_000i128, take in 1i128..1_000_000i128) {
        let mut state = State::default();
        state.apply_intent(&intent(addr(1), 1, Side::Sell, 100, qty)).unwrap();
        let mut taker = intent(addr(2), 1, Side::Buy, 100, take);
        taker.tif = TimeInForce::Ioc;
        let _ = state.apply_intent(&taker);

        for book in state.books.values() {
            for orders in book.bids.values().chain(book.asks.values()) {
                for order in orders {
                    prop_assert!(order.remaining_qty > 0);
                }
            }
        }
    }
}

use alloc::vec::Vec;

use alloy_primitives::{keccak256, Address, B256};

use crate::book::Book;
use crate::state::{Position, State};

pub fn state_root(state: &State) -> [u8; 32] {
    let mut out = Vec::new();
    out.extend_from_slice(b"gaekju-state-v1");
    push_u64(&mut out, state.next_seq_id);

    push_u64(&mut out, state.balances.len() as u64);
    for (trader, balance) in &state.balances {
        push_address(&mut out, *trader);
        push_i128(&mut out, *balance);
    }

    push_u64(&mut out, state.positions.len() as u64);
    for ((trader, market), position) in &state.positions {
        push_address(&mut out, *trader);
        push_u64(&mut out, *market);
        push_position(&mut out, position);
    }

    push_u64(&mut out, state.nonces.len() as u64);
    for (trader, nonce) in &state.nonces {
        push_address(&mut out, *trader);
        push_u64(&mut out, *nonce);
    }

    push_u64(&mut out, state.books.len() as u64);
    for (market, book) in &state.books {
        push_u64(&mut out, *market);
        push_book(&mut out, book);
    }

    let hash: B256 = keccak256(out);
    hash.0
}

fn push_book(out: &mut Vec<u8>, book: &Book) {
    push_u64(out, book.bids.len() as u64);
    for (price, orders) in &book.bids {
        push_i128(out, price.0);
        push_u64(out, orders.len() as u64);
        for order in orders {
            push_u64(out, order.seq_id);
            push_address(out, order.trader);
            out.push(order.side as u8);
            push_i128(out, order.price);
            push_i128(out, order.remaining_qty);
            push_u64(out, order.nonce);
        }
    }

    push_u64(out, book.asks.len() as u64);
    for (price, orders) in &book.asks {
        push_i128(out, *price);
        push_u64(out, orders.len() as u64);
        for order in orders {
            push_u64(out, order.seq_id);
            push_address(out, order.trader);
            out.push(order.side as u8);
            push_i128(out, order.price);
            push_i128(out, order.remaining_qty);
            push_u64(out, order.nonce);
        }
    }
}

fn push_position(out: &mut Vec<u8>, position: &Position) {
    push_i128(out, position.size);
    push_i128(out, position.entry_price);
    push_i128(out, position.collateral);
    push_i128(out, position.last_cumulative_funding);
}

fn push_address(out: &mut Vec<u8>, value: Address) {
    out.extend_from_slice(value.as_slice());
}

fn push_u64(out: &mut Vec<u8>, value: u64) {
    out.extend_from_slice(&value.to_be_bytes());
}

fn push_i128(out: &mut Vec<u8>, value: i128) {
    out.extend_from_slice(&value.to_be_bytes());
}

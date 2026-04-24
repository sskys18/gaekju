#![cfg_attr(not(feature = "std"), no_std)]

extern crate alloc;

pub mod book;
pub mod eip712;
pub mod intent;
pub mod state;
pub mod state_root;

pub use alloy_primitives::{keccak256, Address, B256, U256};
pub use book::{Book, Level, RestingOrder};
pub use eip712::{intent_digest, intent_struct_hash, verify_intent, Eip712Domain, SignatureBytes};
pub use intent::{Fill, Intent, IntentKind, MarketId, Price, Qty, Side, TimeInForce, TraderId};
pub use state::{Position, Reject, State};
pub use state_root::state_root;

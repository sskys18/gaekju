use std::collections::BTreeMap;

use alloy_primitives::Address;

#[derive(Debug, Default, Clone)]
pub struct NonceMap {
    inner: BTreeMap<Address, u64>,
}

impl NonceMap {
    pub fn check_next(&self, trader: Address, nonce: u64) -> bool {
        self.inner
            .get(&trader)
            .copied()
            .unwrap_or_default()
            .saturating_add(1)
            == nonce
    }

    pub fn accept(&mut self, trader: Address, nonce: u64) {
        self.inner.insert(trader, nonce);
    }
}

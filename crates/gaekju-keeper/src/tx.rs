use alloy::network::EthereumWallet;
use alloy::primitives::Address;
use alloy::providers::{DynProvider, Provider, ProviderBuilder};
use alloy::signers::local::PrivateKeySigner;
use eyre::Result;
use std::sync::atomic::{AtomicU64, Ordering};

pub struct TxManager {
    pub provider: DynProvider,
    _wallet: EthereumWallet,
    pub sender: Address,
    nonce: AtomicU64,
}

impl TxManager {
    pub async fn new(rpc_url: &str, private_key: &str) -> Result<Self> {
        let signer: PrivateKeySigner = private_key.parse()?;
        let sender = signer.address();
        let wallet = EthereumWallet::from(signer);

        let provider = ProviderBuilder::new()
            .wallet(wallet.clone())
            .connect_http(rpc_url.parse()?)
            .erased();

        let nonce = provider.get_transaction_count(sender).await?;

        Ok(Self {
            provider,
            _wallet: wallet,
            sender,
            nonce: AtomicU64::new(nonce),
        })
    }

    #[allow(dead_code)] // used in Phase 3 for rapid sequential nonce management
    pub fn next_nonce(&self) -> u64 {
        self.nonce.fetch_add(1, Ordering::SeqCst)
    }

    pub async fn sync_nonce(&self) -> Result<()> {
        let nonce = self.provider.get_transaction_count(self.sender).await?;
        self.nonce.store(nonce, Ordering::SeqCst);
        Ok(())
    }
}

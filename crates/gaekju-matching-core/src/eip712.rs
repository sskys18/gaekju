use alloc::vec::Vec;

use alloy_primitives::{keccak256, Address, Signature, B256, U256};

use crate::intent::{Intent, IntentKind, Side, TimeInForce};
use crate::state::Reject;

const DOMAIN_TYPE: &[u8] =
    b"EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)";
const INTENT_TYPE: &[u8] =
    b"Intent(uint256 marketId,address trader,uint64 nonce,uint8 side,uint128 price,uint128 qty,uint8 tif,uint64 expiry,uint64 flags,uint8 kind,uint128 refSeqId)";

#[derive(Debug, Copy, Clone, Eq, PartialEq)]
pub struct Eip712Domain {
    pub chain_id: u64,
    pub verifying_contract: Address,
}

#[derive(Debug, Clone, Eq, PartialEq)]
pub struct SignatureBytes(pub [u8; 65]);

#[derive(Debug, Copy, Clone, Eq, PartialEq, thiserror::Error)]
pub enum VerifyError {
    #[error("invalid signature")]
    InvalidSignature,
    #[error("wrong signer")]
    WrongSigner,
    #[error("nonce not monotonic")]
    NonceNotMonotonic,
}

pub fn verify_intent(
    domain: Eip712Domain,
    intent: &Intent,
    signature: &SignatureBytes,
    last_nonce: u64,
) -> Result<Address, VerifyError> {
    if intent.nonce <= last_nonce {
        return Err(VerifyError::NonceNotMonotonic);
    }
    let sig = parse_signature(signature).ok_or(VerifyError::InvalidSignature)?;
    let digest = intent_digest(domain, intent);
    let signer = sig
        .recover_address_from_prehash(&digest)
        .map_err(|_| VerifyError::InvalidSignature)?;
    if signer != intent.trader {
        return Err(VerifyError::WrongSigner);
    }
    Ok(signer)
}

pub fn intent_digest(domain: Eip712Domain, intent: &Intent) -> B256 {
    let mut bytes = Vec::with_capacity(66);
    bytes.extend_from_slice(b"\x19\x01");
    bytes.extend_from_slice(domain_separator(domain).as_slice());
    bytes.extend_from_slice(intent_struct_hash(intent).as_slice());
    keccak256(bytes)
}

pub fn domain_separator(domain: Eip712Domain) -> B256 {
    let mut words = Vec::with_capacity(32 * 5);
    push_b256(&mut words, keccak256(DOMAIN_TYPE));
    push_b256(&mut words, keccak256(b"Gaekju"));
    push_b256(&mut words, keccak256(b"1"));
    push_u256(&mut words, U256::from(domain.chain_id));
    push_address(&mut words, domain.verifying_contract);
    keccak256(words)
}

pub fn intent_struct_hash(intent: &Intent) -> B256 {
    let mut words = Vec::with_capacity(32 * 11);
    push_b256(&mut words, keccak256(INTENT_TYPE));
    push_u256(&mut words, U256::from(intent.market_id));
    push_address(&mut words, intent.trader);
    push_u256(&mut words, U256::from(intent.nonce));
    push_u256(&mut words, U256::from(intent.side as u8));
    push_u256(&mut words, U256::from(abs_i128(intent.price)));
    push_u256(&mut words, U256::from(abs_i128(intent.qty)));
    push_u256(&mut words, U256::from(intent.tif as u8));
    push_u256(&mut words, U256::from(intent.expiry));
    push_u256(&mut words, U256::from(intent.flags));
    push_u256(&mut words, U256::from(intent.kind as u8));
    push_u256(&mut words, U256::from(intent.ref_seq_id));
    keccak256(words)
}

impl From<VerifyError> for Reject {
    fn from(value: VerifyError) -> Self {
        match value {
            VerifyError::NonceNotMonotonic => Reject::NonceNotMonotonic,
            VerifyError::InvalidSignature | VerifyError::WrongSigner => Reject::InsufficientMargin,
        }
    }
}

fn parse_signature(signature: &SignatureBytes) -> Option<Signature> {
    let parity = match signature.0[64] {
        0 | 27 => false,
        1 | 28 => true,
        _ => return None,
    };
    Some(Signature::from_bytes_and_parity(&signature.0[..64], parity))
}

fn push_b256(out: &mut Vec<u8>, value: B256) {
    out.extend_from_slice(value.as_slice());
}

fn push_u256(out: &mut Vec<u8>, value: U256) {
    out.extend_from_slice(&value.to_be_bytes::<32>());
}

fn push_address(out: &mut Vec<u8>, value: Address) {
    let mut word = [0u8; 32];
    word[12..].copy_from_slice(value.as_slice());
    out.extend_from_slice(&word);
}

fn abs_i128(value: i128) -> u128 {
    value.unsigned_abs()
}

#[cfg(feature = "serde")]
impl serde::Serialize for SignatureBytes {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        serializer.serialize_bytes(&self.0)
    }
}

#[cfg(feature = "serde")]
impl<'de> serde::Deserialize<'de> for SignatureBytes {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        struct Visitor;

        impl<'de> serde::de::Visitor<'de> for Visitor {
            type Value = SignatureBytes;

            fn expecting(&self, formatter: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
                formatter.write_str("65 signature bytes")
            }

            fn visit_bytes<E>(self, v: &[u8]) -> Result<Self::Value, E>
            where
                E: serde::de::Error,
            {
                if v.len() != 65 {
                    return Err(E::invalid_length(v.len(), &self));
                }
                let mut out = [0u8; 65];
                out.copy_from_slice(v);
                Ok(SignatureBytes(out))
            }

            fn visit_seq<A>(self, mut seq: A) -> Result<Self::Value, A::Error>
            where
                A: serde::de::SeqAccess<'de>,
            {
                let mut out = [0u8; 65];
                for (index, slot) in out.iter_mut().enumerate() {
                    *slot = seq
                        .next_element()?
                        .ok_or_else(|| serde::de::Error::invalid_length(index, &self))?;
                }
                Ok(SignatureBytes(out))
            }
        }

        deserializer.deserialize_bytes(Visitor)
    }
}

#[allow(dead_code)]
const _: fn() = || {
    let _ = Side::Buy;
    let _ = TimeInForce::Gtc;
    let _ = IntentKind::Place;
};

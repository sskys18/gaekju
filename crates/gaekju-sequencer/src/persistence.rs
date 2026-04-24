use std::fs::{self, OpenOptions};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};

use crate::actor::SignedIntent;

#[derive(Clone)]
pub struct Wal {
    path: PathBuf,
}

impl Wal {
    pub fn open(data_dir: &Path) -> eyre::Result<Self> {
        fs::create_dir_all(data_dir)?;
        let path = data_dir.join("intents.wal");
        OpenOptions::new().create(true).append(true).open(&path)?;
        Ok(Self { path })
    }

    pub fn append(&self, signed: &SignedIntent) -> eyre::Result<()> {
        let encoded = bincode::serialize(signed)?;
        let mut file = OpenOptions::new()
            .create(true)
            .append(true)
            .open(&self.path)?;
        file.write_all(&(encoded.len() as u32).to_be_bytes())?;
        file.write_all(&encoded)?;
        file.sync_data()?;
        Ok(())
    }

    pub fn replay(&self) -> eyre::Result<Vec<SignedIntent>> {
        let mut file = OpenOptions::new().read(true).open(&self.path)?;
        let mut out = Vec::new();
        loop {
            let mut len = [0u8; 4];
            match file.read_exact(&mut len) {
                Ok(()) => {}
                Err(err) if err.kind() == std::io::ErrorKind::UnexpectedEof => break,
                Err(err) => return Err(err.into()),
            }
            let mut buf = vec![0u8; u32::from_be_bytes(len) as usize];
            file.read_exact(&mut buf)?;
            out.push(bincode::deserialize(&buf)?);
        }
        Ok(out)
    }
}

pub fn write_snapshot<T: serde::Serialize>(
    data_dir: &Path,
    name: &str,
    value: &T,
) -> eyre::Result<()> {
    fs::create_dir_all(data_dir)?;
    fs::write(data_dir.join(name), bincode::serialize(value)?)?;
    Ok(())
}

pub fn read_snapshot<T: serde::de::DeserializeOwned>(
    data_dir: &Path,
    name: &str,
) -> eyre::Result<Option<T>> {
    let path = data_dir.join(name);
    if !path.exists() {
        return Ok(None);
    }
    Ok(Some(bincode::deserialize(&fs::read(path)?)?))
}

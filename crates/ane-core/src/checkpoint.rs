use std::io::{Read, Write};
use std::path::Path;
use crate::lora::{LoRAModel, LoRAConfig};
use serde::{Deserialize, Serialize};

#[derive(Serialize, Deserialize)]
struct CheckpointMeta {
    config: LoRAConfig,
    step: usize,
    loss: f32,
    adapter_names: Vec<String>,
    adapter_shapes: Vec<(usize, usize, usize)>, // (in_dim, out_dim, rank)
}

/// Save LoRA checkpoint to disk
pub fn save_checkpoint(
    lora: &LoRAModel,
    path: &Path,
    step: usize,
    loss: f32,
) -> std::io::Result<()> {
    let mut file = std::fs::File::create(path)?;

    // Metadata
    let meta = CheckpointMeta {
        config: lora.config.clone(),
        step,
        loss,
        adapter_names: lora.adapters.iter().map(|(n, _)| n.clone()).collect(),
        adapter_shapes: lora.adapters.iter().map(|(_, a)| (a.in_dim, a.out_dim, a.config.rank)).collect(),
    };

    let meta_json = serde_json::to_string(&meta).unwrap();
    let meta_bytes = meta_json.as_bytes();

    // Write header: magic + meta_len + meta
    file.write_all(b"ANEF")?; // Magic
    file.write_all(&(meta_bytes.len() as u32).to_le_bytes())?;
    file.write_all(meta_bytes)?;

    // Write adapter weights
    for (_, adapter) in &lora.adapters {
        // Write A matrix
        let a_bytes: Vec<u8> = adapter.a.iter()
            .flat_map(|f| f.to_le_bytes())
            .collect();
        file.write_all(&a_bytes)?;

        // Write B matrix
        let b_bytes: Vec<u8> = adapter.b.iter()
            .flat_map(|f| f.to_le_bytes())
            .collect();
        file.write_all(&b_bytes)?;
    }

    Ok(())
}

/// Load LoRA checkpoint from disk
pub fn load_checkpoint(path: &Path) -> std::io::Result<(LoRAModel, usize, f32)> {
    let mut file = std::fs::File::open(path)?;

    // Read header
    let mut magic = [0u8; 4];
    file.read_exact(&mut magic)?;
    if &magic != b"ANEF" {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "Invalid checkpoint format",
        ));
    }

    let mut meta_len_bytes = [0u8; 4];
    file.read_exact(&mut meta_len_bytes)?;
    let meta_len = u32::from_le_bytes(meta_len_bytes) as usize;

    let mut meta_bytes = vec![0u8; meta_len];
    file.read_exact(&mut meta_bytes)?;
    let meta: CheckpointMeta = serde_json::from_slice(&meta_bytes)
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?;

    // Reconstruct LoRA model
    let mut adapters = Vec::new();
    for (i, name) in meta.adapter_names.iter().enumerate() {
        let (in_dim, out_dim, _rank) = meta.adapter_shapes[i];
        let mut adapter = crate::lora::LoRAAdapter::new(&meta.config, in_dim, out_dim);

        // Read A matrix
        let a_len = adapter.a.len();
        let mut a_bytes = vec![0u8; a_len * 4];
        file.read_exact(&mut a_bytes)?;
        for j in 0..a_len {
            adapter.a[j] = f32::from_le_bytes([
                a_bytes[j * 4],
                a_bytes[j * 4 + 1],
                a_bytes[j * 4 + 2],
                a_bytes[j * 4 + 3],
            ]);
        }

        // Read B matrix
        let b_len = adapter.b.len();
        let mut b_bytes = vec![0u8; b_len * 4];
        file.read_exact(&mut b_bytes)?;
        for j in 0..b_len {
            adapter.b[j] = f32::from_le_bytes([
                b_bytes[j * 4],
                b_bytes[j * 4 + 1],
                b_bytes[j * 4 + 2],
                b_bytes[j * 4 + 3],
            ]);
        }

        adapters.push((name.clone(), adapter));
    }

    let lora = LoRAModel {
        config: meta.config,
        adapters,
    };

    Ok((lora, meta.step, meta.loss))
}

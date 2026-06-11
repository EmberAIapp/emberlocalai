use std::ffi::CStr;

#[repr(C)]
struct ANEChipInfoRaw {
    chip_id: i32,
    ane_cores: i32,
    peak_tops: f32,
    memory_bytes: i64,
    chip_name: [u8; 64],
}

unsafe extern "C" {
    fn ane_detect_chip(info: *mut ANEChipInfoRaw) -> i32;
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ChipGeneration {
    Unknown,
    M1,
    M1Pro,
    M1Max,
    M2,
    M2Pro,
    M2Max,
    M3,
    M3Pro,
    M3Max,
    M4,
    M4Pro,
    M4Max,
    M5,
    M5Pro,
    M5Max,
}

impl ChipGeneration {
    /// Recommended LoRA rank for this chip
    pub fn recommended_lora_rank(&self) -> usize {
        match self {
            Self::M1 => 8,
            Self::M1Pro => 16,
            Self::M1Max => 16,
            Self::M2 | Self::M2Pro => 16,
            Self::M2Max => 32,
            Self::M3 | Self::M3Pro => 16,
            Self::M3Max => 32,
            Self::M4 => 32,
            Self::M4Pro => 32,
            Self::M4Max => 64,
            Self::M5 => 32,
            Self::M5Pro => 64,
            Self::M5Max => 64,
            Self::Unknown => 8,
        }
    }

    /// Recommended sequence length
    pub fn recommended_seq_len(&self) -> usize {
        match self {
            Self::M1 => 256,
            Self::M1Pro | Self::M1Max => 512,
            Self::M2 | Self::M2Pro => 512,
            Self::M2Max => 1024,
            Self::M3 | Self::M3Pro => 512,
            Self::M3Max => 1024,
            Self::M4 | Self::M4Pro => 1024,
            Self::M4Max => 2048,
            Self::M5 => 1024,
            Self::M5Pro | Self::M5Max => 2048,
            Self::Unknown => 256,
        }
    }

    /// Recommended batch size
    pub fn recommended_batch_size(&self) -> usize {
        match self {
            Self::M1 | Self::M2 => 1,
            Self::M1Pro | Self::M1Max | Self::M2Pro | Self::M3 => 2,
            Self::M2Max | Self::M3Pro | Self::M3Max => 4,
            Self::M4 | Self::M4Pro | Self::M5 | Self::M5Pro => 4,
            Self::M4Max | Self::M5Max => 8,
            Self::Unknown => 1,
        }
    }

    /// Recommended gradient accumulation steps
    pub fn recommended_grad_accum(&self) -> usize {
        match self {
            Self::M1 => 8,
            Self::M1Pro | Self::M1Max => 4,
            Self::M2 | Self::M2Pro | Self::M3 | Self::M3Pro => 4,
            Self::M2Max | Self::M3Max => 2,
            Self::M4 | Self::M4Pro | Self::M5 => 2,
            Self::M4Max | Self::M5Pro | Self::M5Max => 1,
            Self::Unknown => 8,
        }
    }

    /// Number of GPU Neural Accelerators (new in M5 Pro/Max)
    pub fn gpu_neural_accelerators(&self) -> usize {
        match self {
            Self::M5 => 10,
            Self::M5Pro => 20,
            Self::M5Max => 40,
            _ => 0, // Pre-M5 chips don't have Neural Accelerators in GPU
        }
    }

    /// Memory bandwidth in GB/s
    pub fn memory_bandwidth_gbs(&self) -> usize {
        match self {
            Self::M1 => 68,
            Self::M1Pro => 200,
            Self::M1Max => 400,
            Self::M2 => 100,
            Self::M2Pro => 200,
            Self::M2Max => 400,
            Self::M3 => 100,
            Self::M3Pro => 200,
            Self::M3Max => 400,
            Self::M4 => 120,
            Self::M4Pro => 273,
            Self::M4Max => 546,
            Self::M5 => 120,
            Self::M5Pro => 307,
            Self::M5Max => 614,
            Self::Unknown => 0,
        }
    }
}

impl std::fmt::Display for ChipGeneration {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::M1 => write!(f, "Apple M1"),
            Self::M1Pro => write!(f, "Apple M1 Pro"),
            Self::M1Max => write!(f, "Apple M1 Max"),
            Self::M2 => write!(f, "Apple M2"),
            Self::M2Pro => write!(f, "Apple M2 Pro"),
            Self::M2Max => write!(f, "Apple M2 Max"),
            Self::M3 => write!(f, "Apple M3"),
            Self::M3Pro => write!(f, "Apple M3 Pro"),
            Self::M3Max => write!(f, "Apple M3 Max"),
            Self::M4 => write!(f, "Apple M4"),
            Self::M4Pro => write!(f, "Apple M4 Pro"),
            Self::M4Max => write!(f, "Apple M4 Max"),
            Self::M5 => write!(f, "Apple M5"),
            Self::M5Pro => write!(f, "Apple M5 Pro"),
            Self::M5Max => write!(f, "Apple M5 Max"),
            Self::Unknown => write!(f, "Unknown Apple Silicon"),
        }
    }
}

#[derive(Debug, Clone)]
pub struct ChipInfo {
    pub generation: ChipGeneration,
    pub ane_cores: i32,
    pub peak_tops: f32,
    pub memory_bytes: i64,
    pub chip_name: String,
}

impl ChipInfo {
    /// Detect the current hardware
    pub fn detect() -> Result<Self, String> {
        let mut raw = ANEChipInfoRaw {
            chip_id: 0,
            ane_cores: 0,
            peak_tops: 0.0,
            memory_bytes: 0,
            chip_name: [0u8; 64],
        };

        let _ret = unsafe { ane_detect_chip(&mut raw) };

        let chip_name = unsafe {
            CStr::from_ptr(raw.chip_name.as_ptr() as *const _)
                .to_string_lossy()
                .into_owned()
        };

        // Detect variant from chip name
        let name_lower = chip_name.to_lowercase();
        let _has_ultra = name_lower.contains("ultra");
        let has_max = name_lower.contains("max");
        let has_pro = name_lower.contains("pro");

        let generation = match raw.chip_id {
            1 => {
                if has_max { ChipGeneration::M1Max }
                else if has_pro { ChipGeneration::M1Pro }
                else { ChipGeneration::M1 }
            }
            2 => {
                if has_max { ChipGeneration::M2Max }
                else if has_pro { ChipGeneration::M2Pro }
                else { ChipGeneration::M2 }
            }
            3 => {
                if has_max { ChipGeneration::M3Max }
                else if has_pro { ChipGeneration::M3Pro }
                else { ChipGeneration::M3 }
            }
            4 => {
                if has_max { ChipGeneration::M4Max }
                else if has_pro { ChipGeneration::M4Pro }
                else { ChipGeneration::M4 }
            }
            5 => {
                if has_max { ChipGeneration::M5Max }
                else if has_pro { ChipGeneration::M5Pro }
                else { ChipGeneration::M5 }
            }
            _ => {
                // Try parsing from name if chip_id is 0
                if name_lower.contains("m5") {
                    if has_max { ChipGeneration::M5Max }
                    else if has_pro { ChipGeneration::M5Pro }
                    else { ChipGeneration::M5 }
                } else if name_lower.contains("m4") {
                    if has_max { ChipGeneration::M4Max }
                    else if has_pro { ChipGeneration::M4Pro }
                    else { ChipGeneration::M4 }
                } else {
                    ChipGeneration::Unknown
                }
            }
        };

        // Override peak_tops based on known specs
        let peak_tops = if raw.peak_tops > 0.0 {
            raw.peak_tops
        } else {
            match generation {
                ChipGeneration::M1 | ChipGeneration::M1Pro | ChipGeneration::M1Max => 11.0,
                ChipGeneration::M2 | ChipGeneration::M2Pro | ChipGeneration::M2Max => 15.8,
                ChipGeneration::M3 | ChipGeneration::M3Pro | ChipGeneration::M3Max => 18.0,
                ChipGeneration::M4 | ChipGeneration::M4Pro | ChipGeneration::M4Max => 38.0,
                ChipGeneration::M5 | ChipGeneration::M5Pro | ChipGeneration::M5Max => 38.0,
                ChipGeneration::Unknown => 0.0,
            }
        };

        Ok(Self {
            generation,
            ane_cores: if raw.ane_cores > 0 { raw.ane_cores } else { 16 },
            peak_tops,
            memory_bytes: raw.memory_bytes,
            chip_name,
        })
    }

    /// Memory in GB
    pub fn memory_gb(&self) -> f64 {
        self.memory_bytes as f64 / (1024.0 * 1024.0 * 1024.0)
    }

    /// Check if ANE is available
    pub fn has_ane(&self) -> bool {
        self.generation != ChipGeneration::Unknown && self.ane_cores > 0
    }
}

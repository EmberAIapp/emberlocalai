"""Auto-configuration based on hardware detection."""

import platform
import subprocess
from dataclasses import dataclass, field
from typing import Optional


@dataclass
class ANEConfig:
    """Configuration for ANEForge training."""

    # Backend
    backend: str = "auto"  # "ane", "mlx", "cpu", "auto"

    # LoRA
    lora_rank: int = 16
    lora_alpha: float = 32.0
    lora_dropout: float = 0.0
    target_modules: list[str] = field(
        default_factory=lambda: ["q_proj", "v_proj"]
    )

    # Training
    learning_rate: float = 1e-4
    batch_size: int = 1
    seq_len: int = 256
    grad_accum_steps: int = 4
    max_steps: int = 1000
    warmup_steps: int = 50
    weight_decay: float = 0.01
    max_grad_norm: float = 1.0

    # ANE-specific
    compile_budget: int = 100
    ane_qos: int = 21

    # Output
    output_dir: str = "./output"
    save_every: int = 100
    log_every: int = 10


def detect_chip() -> dict:
    """Detect Apple Silicon chip information including Pro/Max variants."""
    info = {
        "chip": "unknown",
        "chip_id": 0,
        "variant": "base",  # base, pro, max, ultra
        "memory_gb": 8,
        "has_ane": False,
        "ane_cores": 16,
        "gpu_cores": 0,
        "gpu_neural_accelerators": 0,  # New in M5 Pro/Max
        "mem_bandwidth_gbs": 0,
    }

    if platform.machine() != "arm64" or platform.system() != "Darwin":
        return info

    try:
        result = subprocess.run(
            ["sysctl", "-n", "machdep.cpu.brand_string"],
            capture_output=True, text=True, timeout=5,
        )
        brand = result.stdout.strip()
        info["chip"] = brand

        # Detect variant (Pro, Max, Ultra)
        brand_lower = brand.lower()
        if "ultra" in brand_lower:
            info["variant"] = "ultra"
        elif "max" in brand_lower:
            info["variant"] = "max"
        elif "pro" in brand_lower:
            info["variant"] = "pro"
        else:
            info["variant"] = "base"

        # Detect generation
        if "M5" in brand:
            info["chip_id"] = 5
        elif "M4" in brand:
            info["chip_id"] = 4
        elif "M3" in brand:
            info["chip_id"] = 3
        elif "M2" in brand:
            info["chip_id"] = 2
        elif "M1" in brand:
            info["chip_id"] = 1

        info["has_ane"] = info["chip_id"] > 0

        # Set ANE/GPU specs based on chip + variant
        specs = _get_chip_specs(info["chip_id"], info["variant"])
        info.update(specs)

        # Get memory
        result = subprocess.run(
            ["sysctl", "-n", "hw.memsize"],
            capture_output=True, text=True, timeout=5,
        )
        info["memory_gb"] = int(result.stdout.strip()) / (1024**3)

    except Exception:
        pass

    return info


def _get_chip_specs(chip_id: int, variant: str) -> dict:
    """Get detailed chip specifications based on generation and variant."""
    # M5 family (Fusion Architecture, Neural Accelerators in GPU)
    if chip_id == 5:
        if variant == "max":
            return {
                "ane_cores": 16, "gpu_cores": 40,
                "gpu_neural_accelerators": 40,
                "mem_bandwidth_gbs": 614,
            }
        elif variant == "pro":
            return {
                "ane_cores": 16, "gpu_cores": 20,
                "gpu_neural_accelerators": 20,
                "mem_bandwidth_gbs": 307,
            }
        else:  # base M5
            return {
                "ane_cores": 16, "gpu_cores": 10,
                "gpu_neural_accelerators": 10,
                "mem_bandwidth_gbs": 120,
            }
    # M4 family
    elif chip_id == 4:
        if variant == "max":
            return {"ane_cores": 16, "gpu_cores": 40, "gpu_neural_accelerators": 0, "mem_bandwidth_gbs": 546}
        elif variant == "pro":
            return {"ane_cores": 16, "gpu_cores": 20, "gpu_neural_accelerators": 0, "mem_bandwidth_gbs": 273}
        else:
            return {"ane_cores": 16, "gpu_cores": 10, "gpu_neural_accelerators": 0, "mem_bandwidth_gbs": 120}
    # M3 family
    elif chip_id == 3:
        if variant == "max":
            return {"ane_cores": 16, "gpu_cores": 40, "gpu_neural_accelerators": 0, "mem_bandwidth_gbs": 400}
        elif variant == "pro":
            return {"ane_cores": 16, "gpu_cores": 18, "gpu_neural_accelerators": 0, "mem_bandwidth_gbs": 200}
        else:
            return {"ane_cores": 16, "gpu_cores": 10, "gpu_neural_accelerators": 0, "mem_bandwidth_gbs": 100}
    # M2 family
    elif chip_id == 2:
        return {"ane_cores": 16, "gpu_cores": 10, "gpu_neural_accelerators": 0, "mem_bandwidth_gbs": 100}
    # M1 family
    elif chip_id == 1:
        return {"ane_cores": 16, "gpu_cores": 8, "gpu_neural_accelerators": 0, "mem_bandwidth_gbs": 68}
    else:
        return {"ane_cores": 0, "gpu_cores": 0, "gpu_neural_accelerators": 0, "mem_bandwidth_gbs": 0}


# Hardware-specific presets
# Now accounts for Pro/Max variants with their higher bandwidth and GPU neural accelerators
CHIP_PRESETS = {
    # M1 family
    (1, "base"):  {"lora_rank": 8,  "batch_size": 1, "seq_len": 256,  "grad_accum_steps": 8},
    (1, "pro"):   {"lora_rank": 16, "batch_size": 1, "seq_len": 512,  "grad_accum_steps": 4},
    (1, "max"):   {"lora_rank": 16, "batch_size": 2, "seq_len": 512,  "grad_accum_steps": 4},
    # M2 family
    (2, "base"):  {"lora_rank": 16, "batch_size": 1, "seq_len": 512,  "grad_accum_steps": 4},
    (2, "pro"):   {"lora_rank": 16, "batch_size": 2, "seq_len": 512,  "grad_accum_steps": 4},
    (2, "max"):   {"lora_rank": 32, "batch_size": 2, "seq_len": 1024, "grad_accum_steps": 2},
    # M3 family
    (3, "base"):  {"lora_rank": 16, "batch_size": 2, "seq_len": 512,  "grad_accum_steps": 4},
    (3, "pro"):   {"lora_rank": 32, "batch_size": 2, "seq_len": 1024, "grad_accum_steps": 2},
    (3, "max"):   {"lora_rank": 32, "batch_size": 4, "seq_len": 1024, "grad_accum_steps": 2},
    # M4 family
    (4, "base"):  {"lora_rank": 32, "batch_size": 2, "seq_len": 1024, "grad_accum_steps": 2},
    (4, "pro"):   {"lora_rank": 32, "batch_size": 4, "seq_len": 1024, "grad_accum_steps": 2},
    (4, "max"):   {"lora_rank": 64, "batch_size": 4, "seq_len": 2048, "grad_accum_steps": 1},
    # M5 family (Fusion Architecture + GPU Neural Accelerators)
    (5, "base"):  {"lora_rank": 32, "batch_size": 4, "seq_len": 1024, "grad_accum_steps": 2},
    (5, "pro"):   {"lora_rank": 64, "batch_size": 4, "seq_len": 2048, "grad_accum_steps": 1},
    (5, "max"):   {"lora_rank": 64, "batch_size": 8, "seq_len": 2048, "grad_accum_steps": 1},
}

# Backward compatibility: old numeric-only keys
_CHIP_PRESETS_LEGACY = {
    1: (1, "base"),
    2: (2, "base"),
    3: (3, "base"),
    4: (4, "base"),
    5: (5, "base"),
}


def auto_config(model_name: Optional[str] = None) -> ANEConfig:
    """Automatically configure based on detected hardware."""
    chip = detect_chip()
    chip_id = chip.get("chip_id", 0)
    variant = chip.get("variant", "base")

    config = ANEConfig()

    # Try exact (chip_id, variant) match first
    key = (chip_id, variant)
    if key in CHIP_PRESETS:
        preset = CHIP_PRESETS[key]
        config.lora_rank = preset["lora_rank"]
        config.batch_size = preset["batch_size"]
        config.seq_len = preset["seq_len"]
        config.grad_accum_steps = preset["grad_accum_steps"]
        config.backend = "ane"
    elif (chip_id, "base") in CHIP_PRESETS:
        # Fall back to base variant
        preset = CHIP_PRESETS[(chip_id, "base")]
        config.lora_rank = preset["lora_rank"]
        config.batch_size = preset["batch_size"]
        config.seq_len = preset["seq_len"]
        config.grad_accum_steps = preset["grad_accum_steps"]
        config.backend = "ane"
    else:
        config.backend = "cpu"

    # Scale up for high-memory configs
    mem_gb = chip.get("memory_gb", 8)
    if mem_gb >= 96:
        config.target_modules = ["q_proj", "k_proj", "v_proj", "o_proj"]
    elif mem_gb >= 48:
        config.target_modules = ["q_proj", "k_proj", "v_proj"]

    config.lora_alpha = config.lora_rank * 2.0

    return config

"""
ANEForge - Democratizing AI fine-tuning on Apple Neural Engine

Simple for beginners, powerful for experts.

Quick start:
    from aneforge import Trainer
    trainer = Trainer("SmolLM2-135M")
    trainer.train("my_data.txt")

CLI:
    aneforge train SmolLM2-135M --data my_data.txt
    aneforge create mon-ia --base smollm2
    aneforge learn mon-ia --data notes.txt
    aneforge chat mon-ia
    aneforge info
"""

__version__ = "0.1.0"

# Try to import native bindings, fall back to pure Python
NATIVE_AVAILABLE = False
try:
    from aneforge._core import (
        detect_hardware,
        available_models,
        PyChipInfo as ChipInfo,
        PyModelConfig as ModelConfig,
        PyLoRAConfig as LoRAConfig,
        PyTrainer as NativeTrainer,
    )
    NATIVE_AVAILABLE = True
except ImportError:
    pass

from aneforge.trainer import Trainer
from aneforge.config import ANEConfig, auto_config
from aneforge.personal import PersonalModel
from aneforge.chat import ChatSession

__all__ = [
    "Trainer",
    "ANEConfig",
    "PersonalModel",
    "ChatSession",
    "auto_config",
    "NATIVE_AVAILABLE",
]

if NATIVE_AVAILABLE:
    __all__.extend([
        "LoRAConfig",
        "ChipInfo",
        "ModelConfig",
        "NativeTrainer",
        "detect_hardware",
        "available_models",
    ])

"""ANEForge CLI - Simple command-line interface for AI fine-tuning."""

import sys
from typing import Optional

try:
    import typer
    from rich.console import Console
    from rich.table import Table
    from rich.panel import Panel
    HAS_RICH = True
except ImportError:
    HAS_RICH = False

if HAS_RICH:
    app = typer.Typer(
        name="aneforge",
        help="ANEForge - Fine-tune AI models on Apple Neural Engine",
        add_completion=False,
    )
    console = Console()
else:
    app = None


def _ensure_deps():
    if not HAS_RICH:
        print("Missing dependencies. Install with: pip install typer rich")
        sys.exit(1)


# ============================================================================
# Commands
# ============================================================================

if HAS_RICH:

    @app.command()
    def info():
        """Show hardware info and available models."""
        from aneforge.config import detect_chip
        from aneforge.model import MODEL_REGISTRY, get_model_info
        from aneforge.mlx_backend import is_mlx_available

        chip = detect_chip()

        # Try native detection too
        native_info = None
        try:
            from aneforge._core import detect_hardware
            native_info = detect_hardware()
        except ImportError:
            pass

        # Hardware info
        if native_info:
            hw_text = (
                f"[bold]ANEForge v0.1.0[/bold]\n\n"
                f"Chip: [cyan]{native_info.chip_name}[/cyan] ({native_info.generation})\n"
                f"Memory: [cyan]{native_info.memory_gb:.0f} GB[/cyan]\n"
                f"ANE: [{'green' if native_info.has_ane else 'red'}]"
                f"{'Available' if native_info.has_ane else 'Not detected'}[/] "
                f"({native_info.ane_cores} cores, {native_info.peak_tops:.0f} TOPS)\n"
                f"Native Backend: [green]Loaded[/green]\n"
                f"MLX Backend: [{'green' if is_mlx_available() else 'yellow'}]"
                f"{'Available' if is_mlx_available() else 'Not installed'}[/]\n"
                f"Recommended: rank={native_info.recommended_lora_rank}, "
                f"seq_len={native_info.recommended_seq_len}, "
                f"batch={native_info.recommended_batch_size}"
            )
        else:
            hw_text = (
                f"[bold]ANEForge v0.1.0[/bold]\n\n"
                f"Chip: [cyan]{chip.get('chip', 'Unknown')}[/cyan]\n"
                f"Memory: [cyan]{chip.get('memory_gb', 0):.0f} GB[/cyan]\n"
                f"ANE: [{'green' if chip.get('has_ane') else 'red'}]"
                f"{'Available' if chip.get('has_ane') else 'Not detected'}[/]\n"
                f"Native Backend: [yellow]Not built[/yellow] (run: maturin develop)\n"
                f"MLX Backend: [{'green' if is_mlx_available() else 'yellow'}]"
                f"{'Available' if is_mlx_available() else 'Not installed'}[/]"
            )

        console.print(Panel.fit(hw_text, title="Hardware", border_style="cyan"))

        # Models table
        table = Table(title="Available Models")
        table.add_column("Name", style="cyan")
        table.add_column("Params", style="green")
        table.add_column("Layers")
        table.add_column("Dim")
        table.add_column("HuggingFace ID", style="dim")

        for key, hf_id in sorted(MODEL_REGISTRY.items()):
            m_info = get_model_info(key)
            table.add_row(
                key,
                m_info.get("params", "?"),
                str(m_info.get("layers", "?")),
                str(m_info.get("dim", "?")),
                hf_id,
            )

        console.print(table)

        # Personal models
        from aneforge.personal import PersonalModel
        personal = PersonalModel.list_models()
        if personal:
            ptable = Table(title="Your Personal Models")
            ptable.add_column("Name", style="cyan")
            ptable.add_column("Base", style="green")
            ptable.add_column("Version")
            ptable.add_column("Steps")
            for m in personal:
                ptable.add_row(m["name"], m["base_model"], f"v{m['version']}", str(m["total_training_steps"]))
            console.print(ptable)

    @app.command()
    def train(
        model: str = typer.Argument(..., help="Model name or HuggingFace ID"),
        data: str = typer.Option(..., "--data", "-d", help="Path to training data"),
        epochs: int = typer.Option(1, "--epochs", "-e", help="Number of epochs"),
        lr: float = typer.Option(1e-4, "--lr", help="Learning rate"),
        lora_rank: int = typer.Option(0, "--lora-rank", "-r", help="LoRA rank (0=auto)"),
        seq_len: int = typer.Option(0, "--seq-len", "-s", help="Sequence length (0=auto)"),
        output: str = typer.Option("./output", "--output", "-o", help="Output directory"),
        format: str = typer.Option("auto", "--format", "-f", help="Data format (auto/txt/jsonl/chat)"),
        backend: str = typer.Option("auto", "--backend", "-b", help="Backend (auto/ane/mlx/cpu)"),
    ):
        """Fine-tune a model with LoRA on your data."""
        from aneforge.trainer import Trainer
        from aneforge.config import auto_config

        config = auto_config(model)
        if lora_rank > 0:
            config.lora_rank = lora_rank
            config.lora_alpha = lora_rank * 2.0
        if seq_len > 0:
            config.seq_len = seq_len
        config.learning_rate = lr
        config.output_dir = output
        config.backend = backend

        trainer = Trainer(model, config=config)
        trainer.load_data(data, format=format)
        losses = trainer.train(epochs=epochs)
        trainer.save(output)

        console.print(f"\n[green]Training complete![/green] Output saved to {output}")

    @app.command()
    def create(
        name: str = typer.Argument(..., help="Name for your personal model"),
        base: str = typer.Option("smollm2-135m", "--base", "-b", help="Base model"),
    ):
        """Create a new personal AI model."""
        from aneforge.personal import PersonalModel

        model = PersonalModel.create(name, base=base)
        console.print(f"\n[green]Model '{name}' created![/green]")
        console.print(f"Train it: [cyan]aneforge learn {name} --data your_data.txt[/cyan]")
        console.print(f"Chat:     [cyan]aneforge chat {name}[/cyan]")

    @app.command()
    def learn(
        name: str = typer.Argument(..., help="Personal model name"),
        data: str = typer.Option(..., "--data", "-d", help="Path to training data"),
        epochs: int = typer.Option(1, "--epochs", "-e", help="Number of epochs"),
    ):
        """Train your personal model on new data (incremental)."""
        from aneforge.personal import PersonalModel

        model = PersonalModel(name)
        model.learn(data, epochs=epochs)

    @app.command()
    def chat(
        name: str = typer.Argument(..., help="Model or personal model name"),
        temperature: float = typer.Option(0.7, "--temp", "-t", help="Sampling temperature"),
        max_tokens: int = typer.Option(256, "--max-tokens", "-m", help="Max tokens to generate"),
        system: str = typer.Option("", "--system", "-s", help="System prompt"),
    ):
        """Chat with a model interactively."""
        from aneforge.chat import start_chat
        from aneforge.personal import PersonalModel, MODELS_DIR
        from aneforge.model import resolve_model_name

        # Check if it's a personal model
        adapter_path = None
        if (MODELS_DIR / name).exists():
            pm = PersonalModel(name)
            model_name = pm._config["base_model"]
            # Find latest version adapter
            versions = sorted(pm.versions_dir.iterdir()) if pm.versions_dir.exists() else []
            if versions:
                adapter_path = str(versions[-1])
            console.print(f"Loading personal model [cyan]{name}[/cyan] (base: {model_name}, v{pm._config['version']})")
        else:
            model_name = resolve_model_name(name)
            console.print(f"Loading model [cyan]{model_name}[/cyan]")

        start_chat(
            model_name=model_name,
            adapter_path=adapter_path,
            temperature=temperature,
            max_tokens=max_tokens,
            system_prompt=system,
        )

    @app.command()
    def ask(
        name: str = typer.Argument(..., help="Personal model or base model name"),
        prompt: str = typer.Argument(..., help="The prompt / question"),
        max_tokens: int = typer.Option(24, "--max-tokens", "-m", help="Max tokens to generate"),
    ):
        """One-shot generation (no interactive loop) — for scripts and the GUI."""
        from aneforge.chat import ChatSession
        from aneforge.personal import PersonalModel, MODELS_DIR
        from aneforge.model import resolve_model_name

        adapter_path = None
        if (MODELS_DIR / name).exists():
            pm = PersonalModel(name)
            model_name = pm._config["base_model"]
            versions = sorted(pm.versions_dir.iterdir()) if pm.versions_dir.exists() else []
            if versions:
                adapter_path = str(versions[-1])
        else:
            model_name = resolve_model_name(name)

        cs = ChatSession(model_name, adapter_path=adapter_path, max_tokens=max_tokens)
        tokens = cs._generate_native(cs._encode(prompt))
        # Collapse to a single clean line and emit behind a marker so the GUI can
        # capture the answer reliably regardless of any other stdout noise.
        answer = " ".join(cs._decode(tokens).split())
        print(f"===ANSWER===\t{answer}")

    @app.command()
    def models(
        json_out: bool = typer.Option(False, "--json", help="Machine-readable JSON output"),
    ):
        """List your personal models."""
        if json_out:
            import json as _json
            from aneforge.personal import PersonalModel
            data = [
                {
                    "name": m["name"],
                    "base": m["base_model"],
                    "version": m["version"],
                    "steps": m["total_training_steps"],
                    "sessions": len(m["training_sessions"]),
                }
                for m in PersonalModel.list_models()
            ]
            print(_json.dumps(data))
            return
        _models_table()

    def _models_table():
        """List your personal models (rich table)."""
        from aneforge.personal import PersonalModel

        personal_models = PersonalModel.list_models()

        if not personal_models:
            console.print("No personal models found.")
            console.print("Create one: [cyan]aneforge create my-model --base smollm2[/cyan]")
            return

        table = Table(title="Your Personal Models")
        table.add_column("Name", style="cyan")
        table.add_column("Base", style="green")
        table.add_column("Version")
        table.add_column("Steps")
        table.add_column("Sessions")
        table.add_column("Created", style="dim")

        for m in personal_models:
            table.add_row(
                m["name"],
                m["base_model"],
                f"v{m['version']}",
                str(m["total_training_steps"]),
                str(len(m["training_sessions"])),
                m["created_at"],
            )

        console.print(table)

    @app.command(name="export")
    def export_cmd(
        adapter: str = typer.Argument(..., help="Path to trained adapter"),
        format: str = typer.Option("safetensors", "--format", "-f", help="Export format (safetensors/gguf/coreml)"),
        output: str = typer.Option(..., "--output", "-o", help="Output path"),
        base: Optional[str] = typer.Option(None, "--base", "-b", help="Base model for merge"),
    ):
        """Export trained model to various formats."""
        from aneforge.export import export_model

        result = export_model(adapter, format, output, base)
        console.print(f"[green]Exported to {result}[/green]")

    @app.command()
    def version():
        """Show version information."""
        console.print("[bold]ANEForge[/bold] v0.1.0")
        try:
            from aneforge._core import version as native_version
            console.print(f"Native core: v{native_version()}")
        except ImportError:
            console.print("Native core: [yellow]not built[/yellow]")


def main():
    """Entry point for the CLI."""
    if app is None:
        _ensure_deps()
    else:
        app()


if __name__ == "__main__":
    main()

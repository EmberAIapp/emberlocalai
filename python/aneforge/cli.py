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
        """Create a new personal AI model (idempotent: opens it if it already exists)."""
        from aneforge.personal import PersonalModel, MODELS_DIR

        if (MODELS_DIR / name).exists():
            console.print(f"[yellow]Le modèle '{name}' existe déjà — ouverture.[/yellow]")
            return
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
        memory_path = None
        if (MODELS_DIR / name).exists():
            pm = PersonalModel(name)
            model_name = pm._config["base_model"]
            # Find latest version adapter
            versions = sorted(pm.versions_dir.iterdir()) if pm.versions_dir.exists() else []
            if versions:
                adapter_path = str(versions[-1])
            memory_path = str(MODELS_DIR / name / "memory.db")
            console.print(f"Loading personal model [cyan]{name}[/cyan] (base: {model_name}, v{pm._config['version']})")
        else:
            model_name = resolve_model_name(name)
            console.print(f"Loading model [cyan]{model_name}[/cyan]")

        # Apply per-AI settings (persona / response length) if present
        s = _load_settings(name)
        if s.get("persona") and not system:
            system = s["persona"]
        if s.get("max_tokens"):
            max_tokens = s["max_tokens"]

        start_chat(
            model_name=model_name,
            adapter_path=adapter_path,
            temperature=temperature,
            max_tokens=max_tokens,
            system_prompt=system,
            memory_path=memory_path,
        )

    def _load_settings(name: str) -> dict:
        import json as _json
        from aneforge.personal import MODELS_DIR
        f = MODELS_DIR / name / "settings.json"
        try:
            return _json.loads(f.read_text()) if f.exists() else {}
        except Exception:
            return {}

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
        memory_path = None
        if (MODELS_DIR / name).exists():
            pm = PersonalModel(name)
            model_name = pm._config["base_model"]
            versions = sorted(pm.versions_dir.iterdir()) if pm.versions_dir.exists() else []
            if versions:
                adapter_path = str(versions[-1])
            memory_path = str(MODELS_DIR / name / "memory.db")
        else:
            model_name = resolve_model_name(name)

        s = _load_settings(name)
        cs = ChatSession(model_name, adapter_path=adapter_path,
                         max_tokens=s.get("max_tokens", max_tokens),
                         system_prompt=s.get("persona", ""),
                         memory_path=memory_path)
        # Route through generate() — same path as interactive chat (memory-first
        # recall + LLM). Emit behind a marker so the GUI captures it reliably.
        answer = " ".join(cs.generate(prompt).split())
        print(f"===ANSWER===\t{answer}")

    @app.command()
    def delete(
        name: str = typer.Argument(..., help="Personal model to delete"),
    ):
        """Permanently delete a personal AI (and its memory)."""
        from aneforge.personal import PersonalModel, MODELS_DIR
        if not (MODELS_DIR / name).exists():
            console.print(f"[yellow]Aucune IA '{name}'.[/yellow]")
            return
        PersonalModel(name).delete(confirm=True)
        console.print(f"[green]IA '{name}' supprimée.[/green]")

    @app.command()
    def settings(
        name: str = typer.Argument(..., help="Personal model name"),
        persona: Optional[str] = typer.Option(None, "--persona", help="How the AI should behave (system prompt)"),
        max_tokens: Optional[int] = typer.Option(None, "--max-tokens", help="Max response length"),
        show: bool = typer.Option(False, "--show", help="Print current settings as JSON"),
    ):
        """Get or set an AI's settings (persona, response length)."""
        import json as _json
        from aneforge.personal import MODELS_DIR
        sdir = MODELS_DIR / name
        if not sdir.exists():
            console.print(f"[red]Aucune IA '{name}'.[/red]"); return
        sfile = sdir / "settings.json"
        cfg = _json.loads(sfile.read_text()) if sfile.exists() else {}
        if persona is not None: cfg["persona"] = persona
        if max_tokens is not None: cfg["max_tokens"] = max_tokens
        if persona is not None or max_tokens is not None:
            sfile.write_text(_json.dumps(cfg, indent=2))
        if show or (persona is None and max_tokens is None):
            print(_json.dumps(cfg))
        else:
            console.print("[green]Réglages enregistrés.[/green]")

    @app.command()
    def memory(
        name: str = typer.Argument(..., help="Personal model name"),
        json_out: bool = typer.Option(False, "--json", help="Machine-readable JSON output"),
    ):
        """Show everything Ember knows about you (editable, local)."""
        from aneforge.memory import store_for_model
        from aneforge.personal import MODELS_DIR
        if not (MODELS_DIR / name).exists():
            console.print(f"[red]No personal model '{name}'.[/red]")
            return
        facts = store_for_model(name).all()
        if json_out:
            import json as _json
            print(_json.dumps([{"id": f.id, "kind": f.kind, "text": f.text,
                                "source": f.source} for f in facts]))
            return
        if not facts:
            console.print(f"Ember doesn't know anything about you yet. Chat with it, "
                          f"or: [cyan]aneforge remember {name} \"...\"[/cyan]")
            return
        table = Table(title=f"What Ember knows about you ({name})")
        table.add_column("ID", style="dim"); table.add_column("Kind", style="cyan")
        table.add_column("Fact"); table.add_column("Source", style="dim")
        for f in facts:
            table.add_row(str(f.id), f.kind, f.text, f.source)
        console.print(table)
        console.print(f"[dim]Forget one: aneforge forget {name} <id>  ·  "
                      f"Forget all: aneforge forget {name} --all[/dim]")

    @app.command()
    def remember(
        name: str = typer.Argument(..., help="Personal model name"),
        fact: str = typer.Argument(..., help="A fact to remember, e.g. \"My dog is named Pixel\""),
    ):
        """Teach Ember a fact directly (stored in editable memory)."""
        from aneforge.memory import store_for_model
        from aneforge.personal import MODELS_DIR
        if not (MODELS_DIR / name).exists():
            console.print(f"[red]No personal model '{name}'.[/red]")
            return
        f = store_for_model(name).add(fact, kind="misc", source="explicit")
        console.print(f"[green]Remembered:[/green] {f.text}" if f else "[yellow]Already known.[/yellow]")

    @app.command()
    def forget(
        name: str = typer.Argument(..., help="Personal model name"),
        fact_id: Optional[int] = typer.Argument(None, help="Fact ID to forget"),
        all_facts: bool = typer.Option(False, "--all", help="Forget everything"),
    ):
        """Make Ember forget a fact (or everything)."""
        from aneforge.memory import store_for_model
        from aneforge.personal import MODELS_DIR
        if not (MODELS_DIR / name).exists():
            console.print(f"[red]No personal model '{name}'.[/red]")
            return
        store = store_for_model(name)
        if all_facts:
            n = store.clear()
            console.print(f"[green]Forgot all {n} facts.[/green]")
        elif fact_id is not None:
            ok = store.delete(fact_id)
            console.print(f"[green]Forgot fact {fact_id}.[/green]" if ok else f"[yellow]No fact {fact_id}.[/yellow]")
        else:
            console.print("Specify a fact ID or --all. See: [cyan]aneforge memory " + name + "[/cyan]")

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

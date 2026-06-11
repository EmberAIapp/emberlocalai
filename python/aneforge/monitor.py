"""Training monitoring with real-time Rich terminal display."""

import time
import json
from pathlib import Path
from typing import Optional

try:
    from rich.console import Console
    from rich.live import Live
    from rich.table import Table
    from rich.panel import Panel
    from rich.progress import Progress, BarColumn, TextColumn, TimeRemainingColumn
    from rich.layout import Layout
    from rich.text import Text
    HAS_RICH = True
except ImportError:
    HAS_RICH = False


class TrainingMonitor:
    """Real-time training progress display with Rich dashboard."""

    def __init__(self, total_steps: int = 0, live: bool = True):
        self.start_time = time.time()
        self.losses: list[float] = []
        self.steps: list[int] = []
        self.lrs: list[float] = []
        self.speeds: list[float] = []
        self.total_steps = total_steps
        self._live_mode = live and HAS_RICH
        self._console = Console() if HAS_RICH else None
        self._live: Optional[Live] = None
        self._best_loss = float("inf")
        self._tokens_processed = 0
        self._ane_utilization = 0.0

    def start(self):
        """Start the live dashboard."""
        if self._live_mode:
            self._live = Live(
                self._render_dashboard(),
                console=self._console,
                refresh_per_second=4,
            )
            self._live.start()

    def stop(self):
        """Stop the live dashboard."""
        if self._live:
            self._live.stop()
            self._live = None

    def log_step(
        self,
        step: int,
        loss: float,
        steps_per_sec: float,
        lr: float,
        tokens_per_sec: float = 0,
        ane_util: float = 0.0,
    ):
        """Log a training step."""
        self.losses.append(loss)
        self.steps.append(step)
        self.lrs.append(lr)
        self.speeds.append(steps_per_sec)
        self._best_loss = min(self._best_loss, loss)
        self._tokens_processed += int(tokens_per_sec / max(steps_per_sec, 0.001))
        self._ane_utilization = ane_util

        if self._live:
            self._live.update(self._render_dashboard())
        else:
            # Fallback: simple print
            elapsed = time.time() - self.start_time
            bar = self._loss_bar(loss)
            print(
                f"  step {step:>6d}/{self.total_steps} | loss {loss:>8.4f} {bar} | "
                f"{steps_per_sec:>6.1f} steps/s | lr {lr:.2e} | "
                f"{self._format_time(elapsed)}",
                flush=True,
            )

    def _render_dashboard(self) -> Panel:
        """Render the full training dashboard."""
        if not self.losses:
            return Panel("Waiting for first step...", title="ANEForge Training")

        elapsed = time.time() - self.start_time
        current_step = self.steps[-1] if self.steps else 0
        current_loss = self.losses[-1] if self.losses else 0
        current_lr = self.lrs[-1] if self.lrs else 0
        current_speed = self.speeds[-1] if self.speeds else 0

        # ETA
        if current_speed > 0 and self.total_steps > 0:
            remaining = (self.total_steps - current_step) / current_speed
            eta_str = self._format_time(remaining)
        else:
            eta_str = "?"

        # Progress percentage
        pct = (current_step / self.total_steps * 100) if self.total_steps > 0 else 0

        # Loss chart (last 50 values, ASCII sparkline)
        chart = self._sparkline(self.losses[-50:])

        # Build display
        lines = []
        lines.append(f"[bold cyan]Step:[/] {current_step}/{self.total_steps} ({pct:.1f}%)")
        lines.append(f"[bold cyan]Loss:[/] {current_loss:.4f}  [dim](best: {self._best_loss:.4f})[/]")
        lines.append(f"[bold cyan]LR:[/]   {current_lr:.2e}")
        lines.append(f"[bold cyan]Speed:[/] {current_speed:.1f} steps/s")
        lines.append(f"[bold cyan]Time:[/]  {self._format_time(elapsed)}  [dim](ETA: {eta_str})[/]")

        if self._ane_utilization > 0:
            ane_bar = self._util_bar(self._ane_utilization)
            lines.append(f"[bold cyan]ANE:[/]   {self._ane_utilization:.1f}% {ane_bar}")

        lines.append("")
        lines.append(f"[bold]Loss curve:[/]")
        lines.append(f"  {chart}")

        # Progress bar
        if self.total_steps > 0:
            prog_width = 40
            filled = int(pct / 100 * prog_width)
            prog_bar = "[green]" + "█" * filled + "[/][dim]" + "░" * (prog_width - filled) + "[/]"
            lines.append("")
            lines.append(f"  {prog_bar}")

        content = "\n".join(lines)
        return Panel(content, title="[bold]ANEForge Training[/]", border_style="cyan")

    def _sparkline(self, values: list[float], width: int = 50) -> str:
        """Create ASCII sparkline chart."""
        if not values:
            return ""

        blocks = " ▁▂▃▄▅▆▇█"
        min_v = min(values)
        max_v = max(values)
        range_v = max_v - min_v if max_v != min_v else 1.0

        chars = []
        for v in values:
            idx = int((v - min_v) / range_v * (len(blocks) - 1))
            idx = max(0, min(len(blocks) - 1, idx))
            chars.append(blocks[idx])

        return "".join(chars)

    def _loss_bar(self, loss: float, width: int = 20) -> str:
        """Create ASCII loss visualization."""
        normalized = max(0.0, min(1.0, (loss - 0.5) / 8.0))
        filled = int(normalized * width)
        return "[" + "#" * filled + "." * (width - filled) + "]"

    def _util_bar(self, pct: float, width: int = 20) -> str:
        """Create utilization bar."""
        filled = int(pct / 100 * width)
        return "[" + "█" * filled + "░" * (width - filled) + "]"

    def _format_time(self, seconds: float) -> str:
        """Format seconds into human readable time."""
        if seconds < 60:
            return f"{seconds:.0f}s"
        elif seconds < 3600:
            return f"{seconds / 60:.0f}m {seconds % 60:.0f}s"
        else:
            h = int(seconds // 3600)
            m = int((seconds % 3600) // 60)
            return f"{h}h {m}m"

    def summary(self) -> str:
        """Print training summary."""
        elapsed = time.time() - self.start_time
        total_steps = len(self.losses)
        avg_speed = total_steps / elapsed if elapsed > 0 else 0

        lines = [
            "",
            "╔══════════════════════════════════╗",
            "║       Training Summary           ║",
            "╠══════════════════════════════════╣",
            f"║  Steps:      {total_steps:>18} ║",
            f"║  Duration:   {self._format_time(elapsed):>18} ║",
            f"║  Avg speed:  {avg_speed:>14.1f} st/s ║",
        ]

        if self.losses:
            lines.append(f"║  Init loss:  {self.losses[0]:>18.4f} ║")
            lines.append(f"║  Final loss: {self.losses[-1]:>18.4f} ║")
            lines.append(f"║  Best loss:  {self._best_loss:>18.4f} ║")

            # Improvement percentage
            if self.losses[0] > 0:
                improvement = (1 - self.losses[-1] / self.losses[0]) * 100
                lines.append(f"║  Improvement:{improvement:>17.1f}% ║")

        lines.append("╚══════════════════════════════════╝")
        return "\n".join(lines)

    def save_metrics(self, path: str):
        """Save training metrics to JSON."""
        metrics = {
            "losses": self.losses,
            "steps": self.steps,
            "learning_rates": self.lrs,
            "speeds": self.speeds,
            "total_time": time.time() - self.start_time,
            "best_loss": self._best_loss,
        }
        Path(path).parent.mkdir(parents=True, exist_ok=True)
        with open(path, "w") as f:
            json.dump(metrics, f, indent=2)

//! `kanban` — Windows port of the Kanban Code CLI helpers.
//!
//! Only the Claude Code statusline hook lives here; card orchestration lives
//! in the TS CLI under `cli/`.

use clap::{Parser, Subcommand};
use std::process::ExitCode;

#[derive(Parser)]
#[command(
    name = "kanban",
    version,
    about = "Kanban Code CLI (Windows port)"
)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Claude Code statusline contract — reads the per-turn JSON from stdin,
    /// snapshots context usage to <data_dir>/context/<sessionId>.json, and
    /// prints a short status line to stdout. Wire it into Claude Code via
    /// `~/.claude/settings.json` `statusLine` (or via the Settings UI).
    Statusline,
}

fn main() -> ExitCode {
    let cli = Cli::parse();
    let rt = match tokio::runtime::Runtime::new() {
        Ok(r) => r,
        Err(e) => {
            eprintln!("kanban: failed to start runtime: {e}");
            return ExitCode::from(1);
        }
    };

    let result: anyhow::Result<()> = rt.block_on(async move {
        match cli.command {
            Command::Statusline => run_statusline().await,
        }
    });

    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("kanban: {e}");
            ExitCode::from(1)
        }
    }
}

// ── statusline ──────────────────────────────────────────────────────────────

/// Claude Code's statusline contract: stdin gets a JSON blob per turn, stdout
/// gets a one-line status string. We treat the per-turn invocation as a
/// `context_usage` snapshot point — parse the JSON, extract token counts +
/// model, and write `<data_dir>/context/<session_id>.json` for the polling
/// loop and drop-guard to read.
///
/// The exact stdin shape from Claude Code is documented at
/// docs.claude.com/en/docs/claude-code/statusline. We tolerate field
/// renames by parsing into a `serde_json::Value` and probing both
/// snake_case (`total_input_tokens`) and camelCase variants.
async fn run_statusline() -> anyhow::Result<()> {
    use std::io::Read;

    let mut raw = String::new();
    std::io::stdin().read_to_string(&mut raw)?;
    if raw.trim().is_empty() {
        // Nothing piped in — silent no-op so manual `kanban statusline`
        // invocations don't error.
        return Ok(());
    }
    let v: serde_json::Value = match serde_json::from_str(&raw) {
        Ok(v) => v,
        Err(_) => {
            // Don't drag Claude Code's chrome down with a parse error;
            // just print nothing and exit clean.
            return Ok(());
        }
    };

    let session_id = pick_string(&v, &["session_id", "sessionId"]);
    let Some(session_id) = session_id else {
        return Ok(());
    };

    let used_pct = pick_f64(&v, &["used_percentage", "usedPercentage"]).unwrap_or(0.0);
    let window = pick_i64(&v, &["context_window_size", "contextWindowSize"]).unwrap_or(0);
    let input = pick_i64(&v, &["total_input_tokens", "totalInputTokens"]).unwrap_or(0);
    let output = pick_i64(&v, &["total_output_tokens", "totalOutputTokens"]).unwrap_or(0);
    let cost = pick_f64(&v, &["total_cost_usd", "totalCostUsd"]);
    let model = pick_string(&v, &["model"]);

    // Match the ContextUsage serde shape exactly so context_usage::read()
    // can deserialize what we write here.
    let mut out = serde_json::Map::new();
    out.insert("usedPercentage".into(), serde_json::json!(used_pct));
    out.insert("contextWindowSize".into(), serde_json::json!(window));
    out.insert("totalInputTokens".into(), serde_json::json!(input));
    out.insert("totalOutputTokens".into(), serde_json::json!(output));
    if let Some(c) = cost { out.insert("totalCostUsd".into(), serde_json::json!(c)); }
    if let Some(ref m) = model { out.insert("model".into(), serde_json::json!(m)); }

    let dir = kanban_code_lib::coordination_store::kanban_data_dir().join("context");
    std::fs::create_dir_all(&dir)?;
    let path = dir.join(format!("{session_id}.json"));
    let tmp = path.with_extension("json.tmp");
    let bytes = serde_json::to_vec_pretty(&serde_json::Value::Object(out))?;
    std::fs::write(&tmp, &bytes)?;
    std::fs::rename(&tmp, &path)?;

    // Print a short status. Claude Code surfaces this verbatim at the
    // bottom of the terminal — keep it terse.
    let used_tokens = if window > 0 && used_pct > 0.0 {
        ((window as f64) * used_pct / 100.0).round() as i64
    } else {
        input + output
    };
    let used_k = used_tokens as f64 / 1000.0;
    let model_tag = model.unwrap_or_else(|| "claude".into());
    println!("{model_tag} · {used_k:.0}k ctx");
    Ok(())
}

fn pick_string(v: &serde_json::Value, keys: &[&str]) -> Option<String> {
    for k in keys {
        if let Some(s) = v.get(*k).and_then(|x| x.as_str()) {
            return Some(s.to_string());
        }
    }
    None
}

fn pick_i64(v: &serde_json::Value, keys: &[&str]) -> Option<i64> {
    for k in keys {
        if let Some(n) = v.get(*k).and_then(|x| x.as_i64()) {
            return Some(n);
        }
        if let Some(n) = v.get(*k).and_then(|x| x.as_f64()) {
            return Some(n.round() as i64);
        }
    }
    None
}

fn pick_f64(v: &serde_json::Value, keys: &[&str]) -> Option<f64> {
    for k in keys {
        if let Some(n) = v.get(*k).and_then(|x| x.as_f64()) {
            return Some(n);
        }
        if let Some(n) = v.get(*k).and_then(|x| x.as_i64()) {
            return Some(n as f64);
        }
    }
    None
}

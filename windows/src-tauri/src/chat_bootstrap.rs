use std::path::{Path, PathBuf};

/// One-shot, idempotent bootstrap: ensures `%USERPROFILE%\.claude\skills\kanban-code`
/// points to the repo's kanban-code skill via a directory junction, so
/// freshly-launched Claude sessions pick it up.
///
/// Called on app launch. Failures are logged via the structured logger, not
/// fatal — agents just don't auto-load the skill.
pub fn run() {
    ensure_skill_link();
}

fn ensure_skill_link() {
    let Some(home) = dirs::home_dir() else {
        crate::logging::warn("bootstrap", "no home dir; skipping skill link");
        return;
    };
    let skills_dir = home.join(".claude").join("skills");
    let link = skills_dir.join("kanban-code");

    // Idempotent: if the link already resolves to a readable SKILL.md, we're done.
    if link.join("SKILL.md").exists() {
        return;
    }

    let Some(src) = locate_skill_source() else {
        crate::logging::warn(
            "bootstrap",
            "kanban-code skill source not found; skipping link",
        );
        return;
    };

    if let Err(e) = std::fs::create_dir_all(&skills_dir) {
        crate::logging::warn(
            "bootstrap",
            &format!("failed to create {}: {e}", skills_dir.display()),
        );
        return;
    }

    // Best-effort remove of a stale entry. fs::remove_dir works for empty dirs
    // and for junctions (the link, not the target). If it fails because the
    // link is a non-empty real dir, we leave it alone rather than risk data.
    if link.exists() {
        if let Err(e) = std::fs::remove_dir(&link) {
            crate::logging::warn(
                "bootstrap",
                &format!("existing entry at {} is in the way: {e}", link.display()),
            );
            return;
        }
    }

    if let Err(e) = create_junction(&link, &src) {
        crate::logging::warn("bootstrap", &format!("mklink /J failed: {e}"));
        return;
    }
    crate::logging::info(
        "bootstrap",
        &format!("linked kanban-code skill → {}", src.display()),
    );
}

/// Create a directory junction (Windows reparse point). Junctions don't require
/// Developer Mode or admin, unlike `symlink_dir`. Implemented via `cmd /C mklink /J`
/// — Win32 has a CreateSymbolicLink API but no public junction one.
fn create_junction(link: &Path, target: &Path) -> std::io::Result<()> {
    // CREATE_NO_WINDOW = 0x08000000. Suppresses the first-launch console flash
    // that would otherwise pop a cmd window for the mklink invocation.
    #[cfg(windows)]
    use std::os::windows::process::CommandExt;
    let mut cmd = std::process::Command::new("cmd");
    cmd.args(["/C", "mklink", "/J"]).arg(link).arg(target);
    #[cfg(windows)]
    cmd.creation_flags(0x08000000);
    let status = cmd.status()?;
    if !status.success() {
        return Err(std::io::Error::new(
            std::io::ErrorKind::Other,
            format!("mklink /J exited with status {status}"),
        ));
    }
    Ok(())
}

/// Walk up from the current exe looking for `.claude/skills/kanban-code/SKILL.md`.
/// Caps at 12 levels — enough for `target/debug/...exe` inside a worktree, and
/// the dev-mode `cargo tauri dev` layout.
fn locate_skill_source() -> Option<PathBuf> {
    if let Ok(env_path) = std::env::var("KANBAN_CODE_REPO") {
        let p = PathBuf::from(env_path);
        if p.join(".claude/skills/kanban-code/SKILL.md").exists() {
            return Some(p.join(".claude/skills/kanban-code"));
        }
    }

    let Ok(exe) = std::env::current_exe() else { return None };
    let mut cur: &Path = exe.as_path();
    for _ in 0..12 {
        let Some(parent) = cur.parent() else { return None };
        let candidate = parent.join(".claude").join("skills").join("kanban-code");
        if candidate.join("SKILL.md").exists() {
            return Some(candidate);
        }
        cur = parent;
    }
    None
}

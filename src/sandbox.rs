use std::path::{Path, PathBuf};

pub fn profiles(workspace: &Path) -> Option<(PathBuf, PathBuf)> {
    if !Path::new("/usr/bin/sandbox-exec").exists() {
        return None;
    }
    Some((
        write_profile(workspace, true).ok()?,
        write_profile(workspace, false).ok()?,
    ))
}

fn write_profile(workspace: &Path, writable: bool) -> std::io::Result<PathBuf> {
    let path = std::env::temp_dir().join(format!(
        "nanocode-sandbox-{}-{}.sb",
        std::process::id(),
        fxhash(&format!("{}{writable}", workspace.display()))
    ));
    std::fs::write(&path, profile(workspace, writable))?;
    Ok(path)
}

fn profile(workspace: &Path, writable: bool) -> String {
    let mut writable_paths = vec![
        canonical(&std::env::temp_dir()),
        PathBuf::from("/private/tmp"),
        PathBuf::from("/private/var/folders"),
    ];
    if writable {
        let workspace = canonical(workspace);
        if let Some(git) = git_directory(&workspace) {
            writable_paths.push(git);
        }
        writable_paths.push(workspace);
    }
    let subpaths = writable_paths
        .iter()
        .map(|path| format!("  (subpath {})", quote(path)))
        .collect::<Vec<_>>()
        .join("\n");
    format!(
        r#"(version 1)
(allow default)
(deny file-write*)
(allow file-write*
{subpaths}
  (literal "/dev/null") (literal "/dev/zero") (literal "/dev/tty") (literal "/dev/dtracehelper")
  (regex #"^/dev/fd/") (regex #"^/dev/ttys"))
(deny network*)
(allow network* (remote unix-socket))
"#
    )
}

pub fn wrap(command: &str, profile: &Path) -> String {
    format!(
        "/usr/bin/sandbox-exec -f {} /bin/bash -c {}",
        shell_quote(&profile.display().to_string()),
        shell_quote(command)
    )
}

pub fn denied(output: &str) -> bool {
    [
        "Operation not permitted",
        "deny(1)",
        "sandbox-exec:",
        "Could not resolve host",
        "nodename nor servname",
        "getaddrinfo ENOTFOUND",
        "Network is unreachable",
        "Couldn't connect to server",
    ]
    .iter()
    .any(|marker| output.contains(marker))
}

fn git_directory(workspace: &Path) -> Option<PathBuf> {
    let dot_git = workspace
        .ancestors()
        .map(|dir| dir.join(".git"))
        .find(|path| path.exists())?;
    if dot_git.is_dir() {
        return Some(canonical(&dot_git));
    }
    let text = std::fs::read_to_string(&dot_git).ok()?;
    let own = PathBuf::from(text.trim().strip_prefix("gitdir:")?.trim());
    let common = std::fs::read_to_string(own.join("commondir"))
        .ok()
        .map(|common| own.join(common.trim()));
    Some(canonical(&common.unwrap_or(own)))
}

fn canonical(path: &Path) -> PathBuf {
    std::fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf())
}

fn quote(path: &Path) -> String {
    format!(
        "\"{}\"",
        path.display()
            .to_string()
            .replace('\\', "\\\\")
            .replace('"', "\\\"")
    )
}

fn shell_quote(text: &str) -> String {
    format!("'{}'", text.replace('\'', r"'\''"))
}

fn fxhash(text: &str) -> u64 {
    text.bytes().fold(0xcbf2_9ce4_8422_2325, |hash, byte| {
        (hash ^ u64::from(byte)).wrapping_mul(0x0100_0000_01b3)
    })
}

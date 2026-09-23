//! Native runtime identity for conditional input. Initial support is Claude on
//! macOS; unsupported/missing metadata fails closed instead of guessing by cwd.
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{io::Read, path::PathBuf};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
pub struct RuntimeBinding {
    pub token: String,
    pub terminal_id: String,
    pub agent: String,
    pub native_session_id: String,
    pub process_id: u32,
    pub cwd: String,
}

#[derive(Deserialize)]
struct NativeMetadata {
    pid: u32,
    #[serde(rename = "sessionId")]
    session_id: String,
    cwd: String,
    #[serde(rename = "procStart")]
    process_start: String,
    kind: String,
}

fn decode_metadata(bytes: &[u8], pid: u32, started: (u64, u64)) -> Option<NativeMetadata> {
    let m: NativeMetadata = serde_json::from_slice(bytes).ok()?;
    let format = time::format_description::parse("[weekday repr:short] [month repr:short] [day padding:space] [hour]:[minute]:[second] [year]").ok()?;
    let start = time::OffsetDateTime::from_unix_timestamp(i64::try_from(started.0).ok()?)
        .ok()?
        .format(&format)
        .ok()?;
    if m.pid != pid
        || m.process_start != start
        || m.kind != "interactive"
        || m.session_id.is_empty()
        || m.cwd.is_empty()
    {
        return None;
    }
    Some(m)
}

fn binding_token(terminal: &str, pid: u32, started: (u64, u64), session: &str) -> String {
    format!(
        "{:x}",
        Sha256::digest(format!(
            "{terminal}\0{pid}\0{}\0{}\0{session}",
            started.0, started.1
        ))
    )
}

pub fn inspect(shell_pid: u32, terminal_id: &str) -> Option<RuntimeBinding> {
    let job = crate::platform::foreground_job(shell_pid)?;
    let leader = job
        .processes
        .iter()
        .find(|p| p.pid == job.process_group_id)?;
    let single = crate::platform::ForegroundJob {
        process_group_id: job.process_group_id,
        processes: vec![leader.clone()],
    };
    if crate::detect::identify_agent_in_job(&single)?.0 != crate::detect::Agent::Claude {
        return None;
    }
    let started = crate::platform::process_start_time(leader.pid)?;
    let root = std::env::var_os("CLAUDE_CONFIG_DIR")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".claude")))?;
    let mut bytes = Vec::new();
    let file =
        std::fs::File::open(root.join("sessions").join(format!("{}.json", leader.pid))).ok()?;
    let modified = file
        .metadata()
        .ok()?
        .modified()
        .ok()?
        .duration_since(std::time::UNIX_EPOCH)
        .ok()?;
    if modified.as_micros() < u128::from(started.0) * 1_000_000 + u128::from(started.1) {
        return None; // metadata belongs to an earlier incarnation of this PID
    }
    file.take(65537).read_to_end(&mut bytes).ok()?;
    if bytes.len() > 65536 {
        return None;
    }
    let native = decode_metadata(&bytes, leader.pid, started)?;
    // Recheck after filesystem I/O, including PID reuse and foreground changes.
    if crate::platform::process_start_time(leader.pid)? != started
        || crate::platform::foreground_job(shell_pid)?.process_group_id != job.process_group_id
    {
        return None;
    }
    Some(RuntimeBinding {
        token: binding_token(terminal_id, leader.pid, started, &native.session_id),
        terminal_id: terminal_id.into(),
        agent: "claude".into(),
        native_session_id: native.session_id,
        process_id: leader.pid,
        cwd: native.cwd,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn native_metadata_requires_matching_process_incarnation() {
        let data = br#"{"pid":42,"sessionId":"native-a","cwd":"project","procStart":"Thu Jan  1 00:00:00 1970","kind":"interactive"}"#;
        let found = decode_metadata(data, 42, (0, 123)).unwrap();
        assert_eq!(found.session_id, "native-a");
        assert!(decode_metadata(data, 43, (0, 123)).is_none());
        assert!(decode_metadata(data, 42, (1, 123)).is_none());
    }
    #[test]
    fn binding_changes_for_session_process_or_terminal() {
        let a = binding_token("term-a", 42, (1, 2), "native-a");
        assert_ne!(a, binding_token("term-a", 42, (1, 3), "native-a"));
        assert_ne!(a, binding_token("term-a", 42, (1, 2), "native-b"));
        assert_ne!(a, binding_token("term-b", 42, (1, 2), "native-a"));
    }
}

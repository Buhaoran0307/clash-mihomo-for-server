use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

fn arg_value(args: &[String], key: &str) -> Option<String> {
    let mut i = 0usize;
    while i < args.len() {
        if args[i] == key {
            return args.get(i + 1).cloned();
        }
        i += 1;
    }
    None
}

fn has_flag(args: &[String], key: &str) -> bool {
    args.iter().any(|a| a == key)
}

fn err<T>(msg: &str) -> Result<T, String> {
    Err(msg.to_string())
}

fn print_help() {
    println!("verge-sync 0.1.0");
    println!("Usage:");
    println!("  verge-sync --url <subscription_url> [--target <path>] [--user-agent <ua>] [--no-restart]");
    println!("Defaults:");
    println!("  --target /opt/clash/config.yaml");
    println!("  --user-agent clash-verge/v2.4.7");
}

fn fetch_text(url: &str, user_agent: &str) -> Result<String, String> {
    let output = Command::new("curl")
        .args(["-fsSL", "-A", user_agent, url])
        .output()
        .map_err(|e| format!("failed to run curl: {e}"))?;
    if !output.status.success() {
        return err("curl failed to fetch subscription");
    }
    String::from_utf8(output.stdout).map_err(|e| format!("subscription is not utf-8: {e}"))
}

fn validate_subscription_text(text: &str) -> Result<(), String> {
    let stripped = text.trim();
    let lower_head = stripped
        .chars()
        .take(500)
        .collect::<String>()
        .to_lowercase();
    if stripped.to_lowercase().starts_with("<!doctype html") || lower_head.contains("<html") {
        return err("downloaded content looks like html");
    }

    let yaml_signals = ["proxies:", "proxy-groups:", "rules:", "mixed-port:", "port:"];
    let has_yaml_signal = yaml_signals.iter().any(|sig| text.contains(sig));
    if !has_yaml_signal {
        return err("subscription content is not valid clash yaml");
    }
    Ok(())
}

fn extract_top_level_keys(lines: &[String], keys: &[&str]) -> Vec<(String, String)> {
    let mut out = Vec::new();
    for line in lines {
        let stripped = line.trim();
        if stripped.is_empty() || stripped.starts_with('#') || !line.contains(':') {
            continue;
        }
        let key = line.split(':').next().unwrap_or("").trim().to_string();
        if keys.iter().any(|k| *k == key) {
            out.push((key, line.clone()));
        }
    }
    out
}

fn is_marker_line(line: &str) -> bool {
    let t = line.trim_start();
    let count = t.chars().take_while(|c| *c == '#').count();
    count >= 5
}

fn marker_indices(lines: &[String]) -> Vec<usize> {
    let mut out = Vec::new();
    for (idx, line) in lines.iter().enumerate() {
        if is_marker_line(line) {
            out.push(idx);
        }
    }
    out
}

fn extract_blocks(lines: &[String], markers: &[usize]) -> Result<Vec<Vec<String>>, String> {
    if markers.len() % 2 != 0 {
        return err("protected marker count mismatch");
    }
    let mut blocks = Vec::new();
    let mut i = 0usize;
    while i < markers.len() {
        let start = markers[i];
        let end = markers[i + 1];
        if end <= start {
            return err("invalid marker order");
        }
        blocks.push(lines[start + 1..end].to_vec());
        i += 2;
    }
    Ok(blocks)
}

fn apply_key_overrides(new_lines: &[String], key_values: &[(String, String)]) -> Vec<String> {
    let mut merged = new_lines.to_vec();
    let mut not_found = Vec::new();
    for (key, protected_line) in key_values {
        let mut replaced = false;
        for line in &mut merged {
            let left = line.split(':').next().unwrap_or("").trim();
            if left == key {
                *line = protected_line.clone();
                replaced = true;
                break;
            }
        }
        if !replaced {
            not_found.push(protected_line.clone());
        }
    }
    if !not_found.is_empty() {
        not_found.push("\n".to_string());
        not_found.extend(merged);
        not_found
    } else {
        merged
    }
}

fn merge_subscription_with_local(local_text: &str, downloaded_text: &str) -> Result<String, String> {
    let old_lines: Vec<String> = local_text
        .lines()
        .map(|l| format!("{l}\n"))
        .collect();
    let new_lines: Vec<String> = downloaded_text
        .lines()
        .map(|l| format!("{l}\n"))
        .collect();

    let old_markers = marker_indices(&old_lines);
    let new_markers = marker_indices(&new_lines);

    if old_markers.is_empty() {
        let critical_keys = [
            "external-controller",
            "secret",
            "external-ui",
            "mixed-port",
            "socks-port",
            "redir-port",
            "allow-lan",
            "bind-address",
            "mode",
            "log-level",
        ];
        let preserved = extract_top_level_keys(&old_lines, &critical_keys);
        if preserved.is_empty() {
            return Ok(new_lines.join(""));
        }
        return Ok(apply_key_overrides(&new_lines, &preserved).join(""));
    }

    let old_blocks = extract_blocks(&old_lines, &old_markers)?;
    if new_markers.is_empty() {
        let mut protected = Vec::new();
        for block in old_blocks {
            for line in block {
                let stripped = line.trim();
                if stripped.is_empty() || stripped.starts_with('#') || !line.contains(':') {
                    continue;
                }
                let key = line.split(':').next().unwrap_or("").trim().to_string();
                if !key.is_empty() {
                    protected.push((key, line));
                }
            }
        }
        return Ok(apply_key_overrides(&new_lines, &protected).join(""));
    }

    if old_markers.len() != new_markers.len() {
        return err(&format!(
            "protected marker mismatch local={} downloaded={}",
            old_markers.len(),
            new_markers.len()
        ));
    }
    extract_blocks(&new_lines, &new_markers)?;

    let mut merged = Vec::new();
    let mut cursor = 0usize;
    for (idx, chunk) in new_markers.chunks(2).enumerate() {
        let start = chunk[0];
        let end = chunk[1];
        merged.extend_from_slice(&new_lines[cursor..=start]);
        merged.extend(old_blocks[idx].clone());
        merged.extend_from_slice(&new_lines[end..=end]);
        cursor = end + 1;
    }
    merged.extend_from_slice(&new_lines[cursor..]);
    Ok(merged.join(""))
}

fn backup_file(target: &Path) -> Result<(), String> {
    if !target.exists() {
        return Ok(());
    }
    let ts = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    let mut backup = PathBuf::from(target);
    backup.set_extension(format!("yaml.bak.{ts}"));
    fs::copy(target, backup).map_err(|e| format!("failed to backup target config: {e}"))?;
    Ok(())
}

fn run_systemctl_restart() -> Result<(), String> {
    let status = std::process::Command::new("systemctl")
        .args(["restart", "clash-core"])
        .status()
        .map_err(|e| format!("failed to run systemctl restart clash-core: {e}"))?;
    if !status.success() {
        return err("systemctl restart clash-core failed");
    }
    Ok(())
}

fn ensure_yaml_like(content: &str) -> Result<(), String> {
    let has_proxies = content.contains("\nproxies:") || content.starts_with("proxies:");
    let has_providers = content.contains("\nproxy-providers:") || content.starts_with("proxy-providers:");
    if !has_proxies && !has_providers {
        return err("yaml does not contain proxies or proxy-providers");
    }
    Ok(())
}

fn main() -> Result<(), String> {
    let args: Vec<String> = env::args().collect();
    if has_flag(&args, "--help") || has_flag(&args, "-h") {
        print_help();
        return Ok(());
    }

    let url = arg_value(&args, "--url")
        .or_else(|| env::var("SUB_URL").ok())
        .unwrap_or_default();
    if url.trim().is_empty() {
        return err("missing --url and SUB_URL");
    }
    let target = arg_value(&args, "--target")
        .or_else(|| env::var("TARGET").ok())
        .unwrap_or_else(|| "/opt/clash/config.yaml".to_string());
    let user_agent = arg_value(&args, "--user-agent")
        .or_else(|| env::var("SUB_UA").ok())
        .unwrap_or_else(|| "clash-verge/v2.4.7".to_string());
    let no_restart = has_flag(&args, "--no-restart");

    let downloaded = fetch_text(&url, &user_agent)?;
    validate_subscription_text(&downloaded)?;

    let old_content = fs::read_to_string(&target).unwrap_or_default();
    let merged = if old_content.trim().is_empty() {
        downloaded
    } else {
        merge_subscription_with_local(&old_content, &downloaded)?
    };
    ensure_yaml_like(&merged)?;

    let target_path = Path::new(&target);
    backup_file(target_path)?;
    fs::write(target_path, merged).map_err(|e| format!("failed to write target {}: {e}", target))?;

    if !no_restart {
        run_systemctl_restart()?;
    }

    println!("ok: subscription updated -> {}", target);
    Ok(())
}

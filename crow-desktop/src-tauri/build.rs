fn main() {
    // Embed the short git SHA so the About dialog can show the build revision.
    let sha = std::process::Command::new("git")
        .args(["rev-parse", "--short", "HEAD"])
        .output()
        .ok()
        .filter(|o| o.status.success())
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "dev".to_string());
    println!("cargo:rustc-env=CROW_GIT_SHA={sha}");
    println!("cargo:rerun-if-changed=../../.git/HEAD");
    tauri_build::build()
}

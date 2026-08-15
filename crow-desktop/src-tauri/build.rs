fn main() {
    // Embed the short git SHA so the About dialog can show the build revision,
    // and the full one so the "Build on GitHub" menu item (CROW-1030) can point
    // at an unambiguous commit. Both fall back to "dev" when the build runs
    // outside a git checkout, which the menu item treats as unlinkable.
    let sha = git_rev(&["rev-parse", "--short", "HEAD"]);
    let sha_full = git_rev(&["rev-parse", "HEAD"]);
    println!("cargo:rustc-env=CROW_GIT_SHA={sha}");
    println!("cargo:rustc-env=CROW_GIT_SHA_FULL={sha_full}");
    println!("cargo:rerun-if-changed=../../.git/HEAD");
    tauri_build::build()
}

fn git_rev(args: &[&str]) -> String {
    std::process::Command::new("git")
        .args(args)
        .output()
        .ok()
        .filter(|o| o.status.success())
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "dev".to_string())
}

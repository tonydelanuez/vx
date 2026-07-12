#![cfg(target_os = "macos")]

use std::process::Command;

#[test]
fn metal_frameworks_are_weak_linked() {
    let binary = env!("CARGO_BIN_EXE_vx-rs");
    let output = Command::new("otool")
        .args(["-l", binary])
        .output()
        .expect("failed to run otool; required to inspect the macOS binary");

    assert!(
        output.status.success(),
        "otool failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );

    let load_commands = String::from_utf8_lossy(&output.stdout);
    for framework in ["Metal.framework", "MetalKit.framework"] {
        let framework_position = load_commands
            .find(framework)
            .unwrap_or_else(|| panic!("{framework} is not linked"));
        let command_start = load_commands[..framework_position]
            .rfind("Load command ")
            .expect("framework load command has no header");
        let load_command = &load_commands[command_start..];
        assert!(
            load_command.contains("cmd LC_LOAD_WEAK_DYLIB"),
            "{framework} must use LC_LOAD_WEAK_DYLIB; nearby load commands:\n{}",
            &load_command[..load_command.len().min(240)]
        );
    }
}

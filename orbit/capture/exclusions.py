EXCLUDED_BUNDLES = {
    # Privacy-sensitive
    "com.apple.keychainaccess",
    "com.apple.Passwords",
    "com.1password.1password",
    "com.agilebits.onepassword7",
    "com.bitwarden.desktop",
    # Native macOS finance apps. Most banking on macOS happens in a browser,
    # which this list cannot selectively exclude (excluding a browser's
    # bundle ID would block capture for everything in it, not just banking
    # tabs) — that needs domain-level exclusion in the Tier 2 browser
    # companion, not a bundle ID. Add your own via `~/.orbit/policy.json`.
    "com.iggsoftware.banktivity",
    # System shells with no AX-queryable main window — capture would always
    # return empty and the focus event is usually a transient handoff.
    "com.apple.dock",
    "com.apple.WindowManager",
    "com.apple.controlcenter",
    "com.apple.notificationcenterui",
    "com.apple.systemuiserver",
    "com.apple.loginwindow",
    "com.apple.spotlight",
    # Daemon's own interpreter — focus events fire on it during handoffs.
    "org.python.python",
    # Low-signal
    "com.apple.finder",
}

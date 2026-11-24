# Security policy

NixPit is experimental and not approved for production or Internet-exposed management. The rootful workload repository trust boundary is equivalent to administrator access. Use a trusted LAN or VPN, verified repository identities and dedicated test hosts. Never store runtime secrets in Git, Nix derivations, logs or issue reports.

Report vulnerabilities privately using GitHub private vulnerability reporting if enabled, or contact the maintainer through a private channel. Do not publish credentials or exploit details in public issues. See docs/architecture.md for security and recovery requirements.

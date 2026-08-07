//! kirikae: a multi-host NixOS deployment tool.
//!
//! A declarative tool in the spirit of [colmena](https://github.com/zhaofengli/colmena),
//! driven from a flake `kirikae.hosts` output.
//!
//! ## Flake schema
//!
//! ```nix
//! kirikae.hosts.myhost = {
//!   targetHost = "10.0.0.1";   # required
//!   targetUser = "root";       # optional, default "root"
//!   targetPort = 22;           # optional, default 22
//!   nice = 100;                # optional, higher means it get's deployed first, default 0
//! };
//! ```
//!
//! Every key in `kirikae.hosts` must have a matching `nixosConfigurations.<key>`
//! in the same flake.
//!
//! ## Usage
//!
//! ```sh
//! # Build all hosts in the current flake
//! kirikae build
//!
//! # Build and deploy a specific host
//! kirikae apply --on myhost
//!
//! # Deploy all hosts except one, using a remote flake
//! kirikae -f github:user/infra apply --not-on unstable-host
//!
//! # Show evaluated host config
//! kirikae eval
//! ```

pub const cli = @import("cli.zig");
pub const config = @import("config.zig");
pub const nix = @import("nix.zig");
pub const ssh = @import("ssh.zig");
pub const output = @import("output.zig");
pub const progress = @import("progress.zig");
pub const ansi = @import("ansi.zig");

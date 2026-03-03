FROM lukemathwalker/cargo-chef:latest-rust-bookworm AS chef

WORKDIR /build

# Install the toolchain components early so this layer is cached independently
# of source changes. Only re-runs when rust-toolchain.toml changes.
COPY rust-toolchain.toml .
RUN rustup show

# --- Planner: generate a dependency recipe from Cargo.toml/Cargo.lock ---
FROM chef AS planner
COPY . .
RUN cargo chef prepare --recipe-path recipe.json

# --- Builder: cook deps (cached), then build the binary ---
FROM chef AS builder

# cmake and clang are required by aws-lc-rs (statically linked TLS)
RUN apt-get update && apt-get install -y cmake clang pkg-config && rm -rf /var/lib/apt/lists/*

COPY --from=planner /build/recipe.json recipe.json
# Only cook moq-relay's transitive deps — not the whole workspace
RUN cargo chef cook --release -p moq-relay --recipe-path recipe.json

COPY . .
RUN cargo build --release -p moq-relay && cp target/release/moq-relay /output

# --- Runtime ---
FROM debian:bookworm-slim

RUN apt-get update && \
    apt-get install -y --no-install-recommends curl jq ca-certificates fuse3 certbot openssl rclone && \
    rm -rf /var/lib/apt/lists/*

# Install tigrisfs — lightweight S3-compatible FUSE adapter
RUN ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/') && \
    TIGRISFS_VER=$(curl -sf "https://api.github.com/repos/tigrisdata/tigrisfs/releases/latest" | \
        grep '"tag_name"' | head -1 | sed 's/.*"tag_name": "v\([^"]*\)".*/\1/') && \
    curl -fsSL "https://github.com/tigrisdata/tigrisfs/releases/download/v${TIGRISFS_VER}/tigrisfs_${TIGRISFS_VER}_linux_${ARCH}.tar.gz" | \
    tar -xz -C /usr/local/bin tigrisfs && \
    chmod +x /usr/local/bin/tigrisfs

COPY --from=builder /output /usr/local/bin/moq-relay
COPY rs/moq-relay/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

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
    apt-get install -y --no-install-recommends curl certbot jq && \
    rm -rf /var/lib/apt/lists/*

COPY --from=builder /output /usr/local/bin/moq-relay
COPY rs/moq-relay/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

FROM debian:stable-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends curl ca-certificates \
 && curl --proto '=https' --proto-redir '=https' --tlsv1.2 -fsSL https://get.agent-vault.dev | sh \
 && rm -rf /var/lib/apt/lists/*
ENTRYPOINT ["agent-vault"]

FROM node:20-slim
ARG GH_VER=2.62.0
RUN apt-get update \
 && apt-get install -y --no-install-recommends curl ca-certificates git tmux \
 && curl --proto '=https' --proto-redir '=https' --tlsv1.2 -fsSL https://get.agent-vault.dev | sh \
 && curl -fsSL https://github.com/cli/cli/releases/download/v${GH_VER}/gh_${GH_VER}_linux_amd64.tar.gz | tar xz -C /tmp \
 && mv /tmp/gh_${GH_VER}_linux_amd64/bin/gh /usr/local/bin/gh \
 && npm i -g opencode-ai \
 && rm -rf /var/lib/apt/lists/* /tmp/gh_*

# git push to github.com over HTTPS uses this placeholder as the password; the
# vault swaps it for the real PAT at the proxy. --system so a /root volume can't hide it.
RUN git config --system credential.helper '!f() { echo username=x-access-token; echo password=__github_token__; }; f'

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# agent-vault run validates the token, sets HTTP(S)_PROXY + CA env, then execs the child.
ENTRYPOINT ["agent-vault", "run", "--", "/usr/local/bin/entrypoint.sh"]

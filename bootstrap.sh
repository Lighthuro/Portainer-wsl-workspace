#!/usr/bin/env bash
set -Eeuo pipefail

phase=${1:-missing}
trap 'status=$?; printf "bootstrap.sh: phase %s failed at line %s (exit %s).\n" "$phase" "$LINENO" "$status" >&2; exit "$status"' ERR

if [ "$EUID" -ne 0 ]; then
    echo 'Run this bootstrap through Install-PortainerWorkspace.ps1 as root in WSL.' >&2
    exit 1
fi

. /etc/os-release
if [ "$ID" != ubuntu ] || [ "$VERSION_ID" != 24.04 ]; then
    echo "This installer requires Ubuntu 24.04; found $PRETTY_NAME." >&2
    exit 1
fi

configure_systemd() (
    local config=/etc/wsl.conf
    local temporary
    temporary=$(mktemp)
    trap 'rm -f "$temporary"' EXIT
    if [ -f "$config" ]; then
        awk '
            BEGIN { in_boot = 0; seen_boot = 0; written = 0 }
            /^[[:space:]]*\[/ {
                if (in_boot && !written) { print "systemd=true"; written = 1 }
                in_boot = ($0 ~ /^[[:space:]]*\[boot\][[:space:]]*([#;].*)?$/)
                if (in_boot) seen_boot = 1
            }
            in_boot && /^[[:space:]]*systemd[[:space:]]*=/ {
                if (!written) { print "systemd=true"; written = 1 }
                next
            }
            { print }
            END {
                if (!seen_boot) print "\n[boot]"
                if (!written) print "systemd=true"
            }
        ' "$config" > "$temporary"
        if ! cmp -s "$config" "$temporary"; then
            cp -p "$config" "$config.backup-$(date +%Y%m%d%H%M%S)-$$"
            install -m 0644 "$temporary" "$config"
        fi
    else
        printf '[boot]\nsystemd=true\n' > "$temporary"
        install -m 0644 "$temporary" "$config"
    fi
)

verify_systemd() {
    if [ "$(ps -p 1 -o comm= | xargs)" != systemd ]; then
        echo 'PID 1 is not systemd. Update WSL (wsl --update), restart WSL, and rerun.' >&2
        exit 1
    fi
    printf 'PID 1: systemd\n'
}

configure_proxy() (
    : "${WORKSPACE_PROXY_URL:?Proxy URL must be supplied by the PowerShell installer}"
    : "${WORKSPACE_NO_PROXY:?NO_PROXY must be supplied by the PowerShell installer}"
    install -d -m 0755 /etc/profile.d /etc/sudoers.d
    {
        printf 'export HTTP_PROXY=%q\n' "$WORKSPACE_PROXY_URL"
        printf 'export HTTPS_PROXY=%q\n' "$WORKSPACE_PROXY_URL"
        printf '%s\n' 'export http_proxy="$HTTP_PROXY"' 'export https_proxy="$HTTPS_PROXY"'
        printf 'export NO_PROXY=%q\n' "$WORKSPACE_NO_PROXY"
        printf '%s\n' 'export no_proxy="$NO_PROXY"'
    } > /etc/profile.d/proxy.sh
    chmod 0644 /etc/profile.d/proxy.sh
    if ! command -v visudo >/dev/null || ! command -v sudo >/dev/null; then
        echo 'Ubuntu must provide sudo and visudo before the proxy checkpoint.' >&2
        exit 1
    fi
    local temporary
    temporary=$(mktemp)
    trap 'rm -f "$temporary"' EXIT
    printf '%s\n' 'Defaults env_keep += "HTTP_PROXY HTTPS_PROXY http_proxy https_proxy NO_PROXY no_proxy"' > "$temporary"
    visudo -cf "$temporary"
    install -m 0440 "$temporary" /etc/sudoers.d/portainer-workspace-proxy
    visudo -c
    if [ -n "${WORKSPACE_CORPORATE_CA:-}" ]; then
        command -v openssl >/dev/null
        command -v update-ca-certificates >/dev/null
        printf '%s\n' "$WORKSPACE_CORPORATE_CA" > "$temporary"
        openssl x509 -in "$temporary" -noout
        install -m 0644 "$temporary" /usr/local/share/ca-certificates/portainer-workspace-corporate.crt
        update-ca-certificates
    fi
    source /etc/profile.d/proxy.sh
    env | grep -i proxy
    echo 'Required checkpoint: sudo apt-get update'
    sudo -n apt-get update --error-on=any
)

install_docker() (
    source /etc/profile.d/proxy.sh
    local package
    local conflicts=()
    for package in docker.io docker-compose docker-compose-v2 docker-doc podman-docker containerd runc; do
        if [ "$(dpkg-query -W -f='${db:Status-Status}' "$package" 2>/dev/null || true)" = installed ]; then
            conflicts+=("$package")
        fi
    done
    if [ "${#conflicts[@]}" -gt 0 ]; then
        printf 'Conflicting packages found: %s\n' "${conflicts[*]}" >&2
        echo 'Review/remove these packages explicitly, then rerun. Nothing was uninstalled.' >&2
        exit 1
    fi
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y ca-certificates curl gnupg
    install -d -m 0755 /etc/apt/keyrings
    local temporary
    temporary=$(mktemp)
    trap 'rm -f "$temporary"' EXIT
    curl --fail --show-error --silent --location --connect-timeout 30 --max-time 180 \
        https://download.docker.com/linux/ubuntu/gpg -o "$temporary"
    gpg --batch --show-keys "$temporary" >/dev/null
    install -m 0644 "$temporary" /etc/apt/keyrings/docker.asc
    cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $VERSION_CODENAME
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF
    apt-get update --error-on=any
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
)

escape_systemd_value() {
    # Environment= uses systemd quoting and specifiers, not shell quoting.
    local value=$1
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    value=${value//%/%%}
    printf '%s' "$value"
}

configure_docker() {
    source /etc/profile.d/proxy.sh
    local proxy no_proxy_value
    proxy=$(escape_systemd_value "$HTTP_PROXY")
    no_proxy_value=$(escape_systemd_value "$NO_PROXY")
    install -d -m 0755 /etc/systemd/system/docker.service.d
    {
        printf '[Service]\n'
        printf 'Environment="HTTP_PROXY=%s"\n' "$proxy"
        printf 'Environment="HTTPS_PROXY=%s"\n' "$proxy"
        printf 'Environment="NO_PROXY=%s"\n' "$no_proxy_value"
    } > /etc/systemd/system/docker.service.d/proxy.conf
    chmod 0644 /etc/systemd/system/docker.service.d/proxy.conf
    systemctl daemon-reload
    systemctl enable docker
    systemctl restart docker
    systemctl is-active --quiet docker
    echo 'Required checkpoint: sudo docker pull hello-world'
    sudo -n docker pull hello-world
    sudo -n docker compose version
}

deploy_portainer() {
    source /etc/profile.d/proxy.sh
    docker volume create portainer_data
    local image restart data socket port
    if [ -n "$(docker container ls -a --filter 'name=^/portainer$' --format '{{.Names}}')" ]; then
        image=$(docker inspect --format '{{.Config.Image}}' portainer)
        restart=$(docker inspect --format '{{.HostConfig.RestartPolicy.Name}}' portainer)
        data=$(docker inspect --format '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Name}}{{end}}{{end}}' portainer)
        socket=$(docker inspect --format '{{range .Mounts}}{{if eq .Destination "/var/run/docker.sock"}}{{.Source}}{{end}}{{end}}' portainer)
        port=$(docker inspect --format '{{range (index .HostConfig.PortBindings "9000/tcp")}}{{.HostIp}}:{{.HostPort}}{{end}}' portainer)
        if [ "$image" != portainer/portainer-ce:lts ] ||
           [ "$restart" != unless-stopped ] ||
           [ "$data" != portainer_data ] ||
           [ "$socket" != /var/run/docker.sock ] ||
           [ "$port" != 127.0.0.1:9002 ]; then
            echo 'An existing portainer container has different settings. Review it manually; no container or data was deleted.' >&2
            exit 1
        fi
        docker start portainer
    else
        docker run -d \
            --name portainer \
            --restart unless-stopped \
            -p 127.0.0.1:9002:9000 \
            -v /var/run/docker.sock:/var/run/docker.sock \
            -v portainer_data:/data \
            portainer/portainer-ce:lts
    fi
    local ready=false attempt
    for attempt in $(seq 1 60); do
        if curl --noproxy '*' --fail --silent --show-error --max-time 2 \
            http://127.0.0.1:9002/api/status >/dev/null 2>&1; then
            ready=true
            break
        fi
        sleep 2
    done
    if [ "$ready" != true ]; then
        docker logs --tail 50 portainer >&2
        echo 'Portainer did not become ready at http://localhost:9002. Check its logs, port conflicts, and initial-setup timeout.' >&2
        exit 1
    fi
}

case "${1:-}" in
    configure-systemd) configure_systemd ;;
    verify-systemd) verify_systemd ;;
    configure-proxy) configure_proxy ;;
    install-docker) install_docker ;;
    configure-docker) configure_docker ;;
    deploy-portainer) deploy_portainer ;;
    *)
        echo 'Usage: bootstrap.sh {configure-systemd|verify-systemd|configure-proxy|install-docker|configure-docker|deploy-portainer}' >&2
        echo 'Use Install-PortainerWorkspace.ps1 to supply configuration and orchestrate the WSL restart.' >&2
        exit 2
        ;;
esac

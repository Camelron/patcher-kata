#!/usr/bin/env bats

setup() {
    export PATCHER="$BATS_TEST_DIRNAME/patch-kata.sh"
    export MOCK_DIR="$BATS_TEST_TMPDIR/mock"
    mkdir -p "$MOCK_DIR/bin"
    export PATH="$MOCK_DIR/bin:$PATH"
    printf 'test RPM payload\n' > "$MOCK_DIR/package.rpm"
    printf 'test tools RPM payload\n' > "$MOCK_DIR/tools.rpm"
    cat > "$MOCK_DIR/bin/kubectl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$MOCK_DIR/calls"
while (($#)); do
    case "$1" in
        --context|-n) shift 2 ;;
        --request-timeout=*) shift ;;
        *) break ;;
    esac
done
case "$1" in
    config) echo test-context ;;
    get)
        jq -n --arg arch "${MOCK_ARCH:-amd64}" '{items: ["node-a", "node-b"] | map({
            metadata: {name: .}, status: {nodeInfo: {operatingSystem: "linux", architecture: $arch}}
        })}'
        ;;
    create)
        cat >> "$MOCK_DIR/manifests"
        echo >> "$MOCK_DIR/manifests"
        ;;
    wait) [[ "${MOCK_FAIL:-}" != wait ]] ;;
    describe) echo 'Mock pod diagnostics' ;;
    delete) : ;;
    exec)
        shift
        while [[ "$1" != -- ]]; do shift; done
        shift
        case "$*" in
            'chroot /host mktemp '*) echo /var/tmp/kata-rpm-patcher.Mock ;;
            'tee '*) cat > "$MOCK_DIR/upload-$(basename "$2")" ;;
            'chroot /host /bin/sh -s -- '*)
                cat > "$MOCK_DIR/install.sh"
                [[ "${MOCK_FAIL:-}" != install ]]
                ;;
            'chroot /host /bin/sh -s')
                cat > "$MOCK_DIR/host.sh"
                if grep -q 'make uvm' "$MOCK_DIR/host.sh"; then
                    cp "$MOCK_DIR/host.sh" "$MOCK_DIR/build.sh"
                    [[ "${MOCK_FAIL:-}" != build ]]
                else
                    cp "$MOCK_DIR/host.sh" "$MOCK_DIR/preflight.sh"
                    [[ "${MOCK_FAIL:-}" != preflight ]]
                fi
                ;;
            *) exit 1 ;;
        esac
        ;;
    *) exit 1 ;;
esac
MOCK
    chmod +x "$MOCK_DIR/bin/kubectl"
}

patcher() {
    bash "$PATCHER" --tools-rpm "$MOCK_DIR/tools.rpm" "$@"
}

host_preflight() {
    bash -c '
        command() {
            if [[ "$1" == -v ]]; then
                if [[ "$2" == tdnf && "${MOCK_MANAGER:-tdnf}" == dnf && ! -f "$MOCK_DIR/dependencies-installed" ]]; then
                    return 1
                fi
                if [[ "$2" == make ]]; then
                    [[ -f "$MOCK_DIR/dependencies-installed" ]]
                    return
                fi
                return 0
            fi
            builtin command "$@"
        }
        rpm() { printf "%s\n" "$*" >> "$MOCK_DIR/preflight-rpm-calls"; }
        uname() { printf "x86_64\n"; }
        sudo() { [[ "$*" == "-n true" ]]; }
        install_dependencies() {
            printf "%s\n" "$*" >> "$MOCK_DIR/dependency-calls"
            [[ "${MOCK_DEPENDENCY_FAIL:-}" != true ]] || return "${MOCK_DEPENDENCY_STATUS:-1}"
            touch "$MOCK_DIR/dependencies-installed"
        }
        dnf() { install_dependencies dnf "$@"; }
        tdnf() { install_dependencies tdnf "$@"; }
        source "$MOCK_DIR/preflight.sh"
    '
}

@test "default plan is read-only and pins the current context" {
    run patcher --rpm "$MOCK_DIR/package.rpm"
    [ "$status" -eq 0 ]
    [[ "$output" == *'Context: test-context'* ]]
    [[ "$output" == *'node-a'* && "$output" == *'node-b'* ]]
    ! grep -Eq 'create|exec|delete' "$MOCK_DIR/calls"
    grep -q -- '--context test-context --request-timeout=60s get nodes' "$MOCK_DIR/calls"
}

@test "apply streams bytes and cleans each helper before creating the next" {
    run patcher --apply --rpm "$MOCK_DIR/package.rpm"
    [ "$status" -eq 0 ]
    cmp "$MOCK_DIR/package.rpm" "$MOCK_DIR/upload-kata.rpm"
    cmp "$MOCK_DIR/tools.rpm" "$MOCK_DIR/upload-tools.rpm"
    [ "$(grep -c 'create -f -' "$MOCK_DIR/calls")" -eq 2 ]
    [ "$(grep -c 'delete pod' "$MOCK_DIR/calls")" -eq 2 ]
    [ "$(grep -E 'create -f -|delete pod' "$MOCK_DIR/calls" | sed -n '2p' | grep -c 'delete pod')" -eq 1 ]
    jq -se 'length == 2 and all(.[]; .spec.containers[0].securityContext.privileged and
        (.spec.volumes[0].hostPath.path == "/") and (.spec.automountServiceAccountToken == false) and
        (.spec.runtimeClassName == "runc") and
        (.spec.containers[0].resources.requests.memory == "4Gi") and
        (.spec.containers[0].resources.limits.memory == "4Gi") and
        (.spec.containers[0].command == ["tail", "-f", "/dev/null"]) and
        (.spec.activeDeadlineSeconds == 7200))' "$MOCK_DIR/manifests"
    bash -n "$MOCK_DIR/preflight.sh" "$MOCK_DIR/install.sh" "$MOCK_DIR/build.sh"
    grep -q -- '--request-timeout=0 .*exec -i' "$MOCK_DIR/calls"
    [[ "$output" == *'deployed the UVM on all 2 selected node(s)'* ]]
}

@test "installation failure stops the rollout and retains the pod" {
    export MOCK_FAIL=install
    run patcher --apply --rpm "$MOCK_DIR/package.rpm"
    [ "$status" -ne 0 ]
    [ "$(grep -c 'create -f -' "$MOCK_DIR/calls")" -eq 1 ]
    ! grep -q 'delete pod' "$MOCK_DIR/calls"
    [[ "$output" == *'Retaining helper pod'* ]]
    [ ! -e "$MOCK_DIR/build.sh" ]
}

@test "readiness failure prints diagnostics and retains the pod" {
    export MOCK_FAIL=wait
    run patcher --apply --rpm "$MOCK_DIR/package.rpm"
    [ "$status" -ne 0 ]
    [[ "$output" == *'Mock pod diagnostics'* ]]
    ! grep -q 'exec -i' "$MOCK_DIR/calls"
    ! grep -q 'delete pod' "$MOCK_DIR/calls"
    [[ "$output" == *'Retaining helper pod'* ]]
}

@test "unsupported architecture fails before creating pods" {
    export MOCK_ARCH=arm64
    run patcher --apply --rpm "$MOCK_DIR/package.rpm"
    [ "$status" -ne 0 ]
    [[ "$output" == *'Linux amd64'* ]]
    ! grep -q 'create' "$MOCK_DIR/calls"
}

@test "explicit context and selector are forwarded" {
    run patcher --context another-cluster --selector agentpool=kata --rpm "$MOCK_DIR/package.rpm"
    [ "$status" -eq 0 ]
    ! grep -q 'config current-context' "$MOCK_DIR/calls"
    grep -q -- '--context another-cluster --request-timeout=60s get nodes --selector agentpool=kata' "$MOCK_DIR/calls"
}

@test "missing option values produce a useful error" {
    run patcher --context
    [ "$status" -ne 0 ]
    [[ "$output" == *'Missing value for --context'* ]]
}

@test "host transaction checks checksum and identity before test and upgrade" {
    run patcher --apply --rpm "$MOCK_DIR/package.rpm"
    [ "$status" -eq 0 ]
    mkdir -p "$MOCK_DIR/staging"
    cp "$MOCK_DIR/package.rpm" "$MOCK_DIR/staging/kata.rpm"
    cp "$MOCK_DIR/tools.rpm" "$MOCK_DIR/staging/tools.rpm"
    cat > "$MOCK_DIR/bin/rpm" <<'RPM'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$MOCK_DIR/rpm-calls"
case "$1" in
    -qp|-q)
        case "${*: -1}" in
            */tools.rpm|kata-containers-tools) printf '%s' 'kata-containers-tools-4.1.0.kata100-1.azl3.x86_64' ;;
            *) printf '%s' 'kata-containers-4.1.0.kata100-1.azl3.x86_64' ;;
        esac
        ;;
esac
RPM
    chmod +x "$MOCK_DIR/bin/rpm"
    checksum=$(sha256sum "$MOCK_DIR/package.rpm")
    tools_checksum=$(sha256sum "$MOCK_DIR/tools.rpm")
    run sh "$MOCK_DIR/install.sh" "$MOCK_DIR/staging" incorrect-checksum kata-containers-4.1.0.kata100-1.azl3.x86_64 \
        "${tools_checksum%% *}" kata-containers-tools-4.1.0.kata100-1.azl3.x86_64
    [ "$status" -ne 0 ]
    [ ! -e "$MOCK_DIR/rpm-calls" ]
    [ ! -d "$MOCK_DIR/staging" ]
    mkdir -p "$MOCK_DIR/staging"
    cp "$MOCK_DIR/package.rpm" "$MOCK_DIR/staging/kata.rpm"
    cp "$MOCK_DIR/tools.rpm" "$MOCK_DIR/staging/tools.rpm"
    run sh "$MOCK_DIR/install.sh" "$MOCK_DIR/staging" "${checksum%% *}" kata-containers-4.1.0.kata100-1.azl3.x86_64 \
        incorrect-checksum kata-containers-tools-4.1.0.kata100-1.azl3.x86_64
    [ "$status" -ne 0 ]
    [ ! -e "$MOCK_DIR/rpm-calls" ]
    [ ! -d "$MOCK_DIR/staging" ]
    mkdir -p "$MOCK_DIR/staging"
    cp "$MOCK_DIR/package.rpm" "$MOCK_DIR/staging/kata.rpm"
    cp "$MOCK_DIR/tools.rpm" "$MOCK_DIR/staging/tools.rpm"
    run sh "$MOCK_DIR/install.sh" "$MOCK_DIR/staging" "${checksum%% *}" kata-containers-4.1.0.kata100-1.azl3.x86_64 \
        "${tools_checksum%% *}" kata-containers-tools-4.1.0.kata100-1.azl3.x86_64
    [ "$status" -eq 0 ]
    [ "$(sed -n '3p' "$MOCK_DIR/rpm-calls")" = "-Uvh --test --replacepkgs $MOCK_DIR/staging/kata.rpm $MOCK_DIR/staging/tools.rpm" ]
    [ "$(sed -n '4p' "$MOCK_DIR/rpm-calls")" = "-Uvh --replacepkgs $MOCK_DIR/staging/kata.rpm $MOCK_DIR/staging/tools.rpm" ]
    [ ! -d "$MOCK_DIR/staging" ]
}

@test "UVM failure stops the rollout and retains the pod" {
    export MOCK_FAIL=build
    run patcher --apply --rpm "$MOCK_DIR/package.rpm"
    [ "$status" -ne 0 ]
    [ "$(grep -c 'create -f -' "$MOCK_DIR/calls")" -eq 1 ]
    ! grep -q 'delete pod' "$MOCK_DIR/calls"
    [[ "$output" == *'Retaining helper pod'* ]]
    [ -f "$MOCK_DIR/install.sh" ]
    [ -f "$MOCK_DIR/build.sh" ]
}

@test "UVM deploy preserves shim configuration and only follows a successful build" {
    run patcher --apply --rpm "$MOCK_DIR/package.rpm"
    [ "$status" -eq 0 ]
    cat > "$MOCK_DIR/bin/make" <<'MAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$MOCK_DIR/make-calls"
[[ "${MOCK_MAKE_FAIL:-}" != "$1" ]]
MAKE
    chmod +x "$MOCK_DIR/bin/make"
    run bash -c '
        cd() { [[ "$1" == /opt/kata-containers/uvm/tools/osbuilder/node-builder/azure-linux ]] && command cd "$MOCK_DIR"; }
        test() { [[ "$1" == -s && "$2" == /usr/share/kata-containers/kata-containers.img ]]; }
        source "$MOCK_DIR/build.sh"
    '
    [ "$status" -eq 0 ]
    [ "$(sed -n '1p' "$MOCK_DIR/make-calls")" = uvm ]
    [ "$(sed -n '2p' "$MOCK_DIR/make-calls")" = 'SHIM_REDEPLOY_CONFIG=no deploy-uvm' ]
    rm "$MOCK_DIR/make-calls"
    export MOCK_MAKE_FAIL=uvm
    run bash -c '
        cd() { command cd "$MOCK_DIR"; }
        source "$MOCK_DIR/build.sh"
    '
    [ "$status" -ne 0 ]
    [ "$(cat "$MOCK_DIR/make-calls")" = uvm ]
}

@test "tdnf is preferred and installs the full dependency list before checking make" {
    run patcher --apply --rpm "$MOCK_DIR/package.rpm"
    [ "$status" -eq 0 ]
    run host_preflight
    [ "$status" -eq 0 ]
    [ "$(cat "$MOCK_DIR/dependency-calls")" = 'tdnf -y --exclude kernel-uvm install git golang rust cargo build-essential protobuf-compiler protobuf-devel expect openssl-devel clang-devel libseccomp-devel btrfs-progs-devel device-mapper-devel cmake fuse-devel kata-packages-uvm-build make sudo gawk e2fsprogs' ]
}

@test "dependency provisioning falls back to dnf" {
    run patcher --apply --rpm "$MOCK_DIR/package.rpm"
    [ "$status" -eq 0 ]
    export MOCK_MANAGER=dnf
    run host_preflight
    [ "$status" -eq 0 ]
    grep -q '^dnf -y --exclude kernel-uvm install ' "$MOCK_DIR/dependency-calls"
}

@test "dependency installation failure fails preflight and rollout stops before upload" {
    export MOCK_FAIL=preflight
    run patcher --apply --rpm "$MOCK_DIR/package.rpm"
    [ "$status" -ne 0 ]
    [ "$(grep -c 'create -f -' "$MOCK_DIR/calls")" -eq 1 ]
    ! grep -q 'delete pod' "$MOCK_DIR/calls"
    [[ "$output" == *'Retaining helper pod'* ]]
    [ ! -e "$MOCK_DIR/upload-kata.rpm" ]
    [ ! -e "$MOCK_DIR/install.sh" ]
    export MOCK_DEPENDENCY_FAIL=true
    run host_preflight
    [ "$status" -ne 0 ]
    [ ! -e "$MOCK_DIR/dependencies-installed" ]
}

@test "SIGKILL during dependency installation preserves exit 137 and reports diagnostics" {
    run patcher --apply --rpm "$MOCK_DIR/package.rpm"
    [ "$status" -eq 0 ]
    export MOCK_DEPENDENCY_FAIL=true
    export MOCK_DEPENDENCY_STATUS=137
    run host_preflight
    [ "$status" -eq 137 ]
    [[ "$output" == *'tdnf failed (exit 137)'* ]]
    [[ "$output" == *'SIGKILL received'* ]]
    [ ! -e "$MOCK_DIR/dependencies-installed" ]
}
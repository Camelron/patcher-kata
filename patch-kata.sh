#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
package_relative=RPMS/x86_64/kata-containers-4.1.0.kata100-1.azl3.x86_64.rpm
tools_relative=RPMS/x86_64/kata-containers-tools-4.1.0.kata100-1.azl3.x86_64.rpm
expected_package=kata-containers-4.1.0.kata100-1.azl3.x86_64
expected_tools=kata-containers-tools-4.1.0.kata100-1.azl3.x86_64
rpm_path="$script_dir/$package_relative"
tools_rpm_path="$script_dir/$tools_relative"
archive="$script_dir/rpms.tar.gz"
namespace='kube-system'
image=docker.io/library/busybox:1.36.1
selector=
context=
apply=false
work_dir=
pod=

usage() {
    cat <<'USAGE'
Usage: bash notes/patcher/patch-kata.sh [OPTIONS]

Default: show the target context, nodes, and RPMs without changing the cluster.

    --apply                Install both RPMs and build/deploy the UVM on each node
  --context NAME         Use this context instead of the current context
  --selector LABELS      Restrict nodes by Kubernetes label selector
  --namespace NAME       Helper pod namespace (default: kube-system)
    --image IMAGE          Helper image with sh, chroot, tee, sleep (default: busybox:1.36.1)
    --rpm PATH             Use an already extracted Kata runtime RPM
    --tools-rpm PATH       Use an already extracted Kata tools RPM
  -h, --help             Show help

Requires bash, kubectl, jq, tar, sha256sum, and permission to run privileged
pods with a host-root mount. No custom image or registry is needed.
Does not drain/reboot nodes, restart services, or update existing Kata VMs.
Builds using the tools RPM's UVM targets; preserves shim configuration.
Installs host build dependencies with tdnf (or dnf) before installing the RPMs.
USAGE
}

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

while (($#)); do
    case "$1" in
        --apply) apply=true; shift ;;
        --context|--selector|--namespace|--image|--rpm|--tools-rpm)
            if (($# < 2)) || [[ -z "$2" ]]; then
                die "Missing value for $1"
            fi
            case "$1" in
                --context) context=$2 ;;
                --selector) selector=$2 ;;
                --namespace) namespace=$2 ;;
                --image) image=$2 ;;
                --rpm) rpm_path=$2 ;;
                --tools-rpm) tools_rpm_path=$2 ;;
            esac
            shift 2
            ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown argument: $1" ;;
    esac
done

for dependency in kubectl jq tar sha256sum; do
    command -v "$dependency" >/dev/null || die "Missing command: $dependency"
done
if [[ -z "$context" ]]; then
    context=$(kubectl config current-context)
fi
[[ -n "$context" ]] || die 'No Kubernetes context selected'
kube=(kubectl --context "$context" --request-timeout=60s)

cleanup_pod() {
    if [[ -n "$pod" ]]; then
        if ! "${kube[@]}" -n "$namespace" delete pod "$pod" --ignore-not-found --timeout=60s; then
            printf 'Cleanup failed; delete pod %s in namespace %s manually.\n' "$pod" "$namespace" >&2
            return 1
        fi
        pod=
    fi
}

cleanup() {
    local result=$?
    trap - EXIT
    if [[ "$result" -ne 0 && -n "$pod" ]]; then
        printf 'Retaining helper pod %s in namespace %s for diagnostics (exit %s).\n' "$pod" "$namespace" "$result" >&2
        printf 'Inspect: kubectl --context %q -n %q describe pod %q\n' "$context" "$namespace" "$pod" >&2
        printf 'Exec: kubectl --context %q -n %q exec -it %q -- sh\n' "$context" "$namespace" "$pod" >&2
        printf 'Delete when finished: kubectl --context %q -n %q delete pod %q\n' "$context" "$namespace" "$pod" >&2
    else
        cleanup_pod || result=1
    fi
    if [[ -n "$work_dir" ]]; then
        rm -rf -- "$work_dir"
    fi
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ ! -f "$rpm_path" ]]; then
    [[ "$rpm_path" == "$script_dir/$package_relative" && -f "$archive" ]] || die "RPM not found: $rpm_path"
    work_dir=$(mktemp -d)
    tar -xf "$archive" -C "$work_dir" "$package_relative"
    rpm_path="$work_dir/$package_relative"
fi
if [[ ! -f "$tools_rpm_path" ]]; then
    [[ "$tools_rpm_path" == "$script_dir/$tools_relative" && -f "$archive" ]] || die "Tools RPM not found: $tools_rpm_path"
    if [[ -z "$work_dir" ]]; then
        work_dir=$(mktemp -d)
    fi
    tar -xf "$archive" -C "$work_dir" "$tools_relative"
    tools_rpm_path="$work_dir/$tools_relative"
fi
checksum=$(sha256sum "$rpm_path")
checksum=${checksum%% *}
tools_checksum=$(sha256sum "$tools_rpm_path")
tools_checksum=${tools_checksum%% *}
node_args=()
if [[ -n "$selector" ]]; then
    node_args+=(--selector "$selector")
fi
node_json=$("${kube[@]}" get nodes "${node_args[@]}" -o json)
jq -e '.items | length > 0' <<<"$node_json" >/dev/null || die 'No nodes matched'
jq -e 'all(.items[]; .status.nodeInfo.operatingSystem == "linux" and .status.nodeInfo.architecture == "amd64")' \
    <<<"$node_json" >/dev/null || die 'All selected nodes must be Linux amd64; narrow --selector'
mapfile -t nodes < <(jq -r '.items[].metadata.name' <<<"$node_json")

printf 'Context: %s\nNamespace: %s\nRPM: %s\nSHA256: %s\nHelper image: %s\nNodes:\n' \
    "$context" "$namespace" "$rpm_path" "$checksum" "$image"
printf '  %s\n' "${nodes[@]}"
printf 'Tools RPM: %s\nTools SHA256: %s\nUVM: build and deploy on each node (SHIM_REDEPLOY_CONFIG=no)\n' \
    "$tools_rpm_path" "$tools_checksum"
printf 'Host dependencies: install build packages with tdnf (or dnf) before RPM installation\n'
if [[ "$apply" != true ]]; then
    printf '\nPlan only. Re-run with --apply to install. No cluster changes made.\n'
    exit 0
fi

for node in "${nodes[@]}"; do
    printf '\n=== %s ===\n' "$node"
    pod="kata-rpm-patcher-$(date +%s)-$$-$RANDOM"
    jq -n --arg name "$pod" --arg namespace "$namespace" --arg node "$node" --arg image "$image" '{
        apiVersion: "v1", kind: "Pod",
        metadata: {name: $name, namespace: $namespace, labels: {app: "kata-rpm-patcher"}},
        spec: {
            nodeName: $node, restartPolicy: "Never", activeDeadlineSeconds: 7200,
            runtimeClassName: "runc",
            terminationGracePeriodSeconds: 1, automountServiceAccountToken: false,
            tolerations: [{operator: "Exists"}],
            containers: [{name: "patcher", image: $image, imagePullPolicy: "IfNotPresent",
                command: ["tail", "-f", "/dev/null"],
                securityContext: {privileged: true, runAsUser: 0},
                resources: {requests: {memory: "4Gi"}, limits: {memory: "4Gi"}},
                volumeMounts: [{name: "host", mountPath: "/host"}]}],
            volumes: [{name: "host", hostPath: {path: "/", type: "Directory"}}]
        }
    }' | "${kube[@]}" create -f - >/dev/null
    if ! "${kube[@]}" -n "$namespace" wait --for=condition=Ready "pod/$pod" --timeout=60s; then
        "${kube[@]}" -n "$namespace" describe pod "$pod" >&2 || true
        die "Helper pod did not become ready on $node"
    fi
    exec_pod=(kubectl --context "$context" --request-timeout=0 -n "$namespace" exec -i "$pod" -c patcher --)
    "${exec_pod[@]}" chroot /host /bin/sh -s <<'PREFLIGHT'
set -eu
command -v rpm >/dev/null
command -v sha256sum >/dev/null
test "$(uname -m)" = x86_64
rpm -q kata-containers
if command -v tdnf >/dev/null; then
    package_manager=tdnf
elif command -v dnf >/dev/null; then
    package_manager=dnf
else
    echo 'Missing host package manager: dnf or tdnf required' >&2
    exit 1
fi
printf 'Installing host build dependencies with %s...\n' "$package_manager"
if "$package_manager" -y --exclude kernel-uvm install \
    git golang rust cargo build-essential protobuf-compiler protobuf-devel \
    expect openssl-devel clang-devel libseccomp-devel btrfs-progs-devel \
    device-mapper-devel cmake fuse-devel kata-packages-uvm-build \
    make sudo gawk e2fsprogs; then
    printf 'Host build dependencies installed.\n'
else
    result=$?
    printf 'Host dependency installation with %s failed (exit %s).\n' "$package_manager" "$result" >&2
    if test "$result" -eq 137; then
        printf 'SIGKILL received; check node kernel/security logs and helper cgroup limits.\n' >&2
    fi
    exit "$result"
fi
for dependency in bash make sudo tdnf gawk; do
    command -v "$dependency" >/dev/null || { echo "Missing host build command: $dependency" >&2; exit 1; }
done
sudo -n true
PREFLIGHT
    host_dir=$("${exec_pod[@]}" chroot /host mktemp -d /var/tmp/kata-rpm-patcher.XXXXXX)
    [[ "$host_dir" =~ ^/var/tmp/kata-rpm-patcher\.[[:alnum:]]+$ ]] || die 'Unexpected host staging directory'
    if ! "${exec_pod[@]}" tee "/host$host_dir/kata.rpm" < "$rpm_path" >/dev/null; then
        "${exec_pod[@]}" chroot /host rm -rf -- "$host_dir" || true
        die "RPM upload failed on $node"
    fi
    if ! "${exec_pod[@]}" tee "/host$host_dir/tools.rpm" < "$tools_rpm_path" >/dev/null; then
        "${exec_pod[@]}" chroot /host rm -rf -- "$host_dir" || true
        die "Tools RPM upload failed on $node"
    fi
    "${exec_pod[@]}" chroot /host /bin/sh -s -- "$host_dir" "$checksum" "$expected_package" "$tools_checksum" "$expected_tools" <<'INSTALL'
set -eu
staging=$1
checksum=$2
expected=$3
tools_checksum=$4
expected_tools=$5
trap 'rm -rf -- "$staging"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
package="$staging/kata.rpm"
tools_package="$staging/tools.rpm"
printf '%s  %s\n' "$checksum" "$package" | sha256sum -c -
printf '%s  %s\n' "$tools_checksum" "$tools_package" | sha256sum -c -
identity=$(rpm -qp --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}' "$package")
test "$identity" = "$expected" || { echo "Unexpected RPM: $identity" >&2; exit 1; }
tools_identity=$(rpm -qp --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}' "$tools_package")
test "$tools_identity" = "$expected_tools" || { echo "Unexpected tools RPM: $tools_identity" >&2; exit 1; }
rpm -Uvh --test --replacepkgs "$package" "$tools_package"
rpm -Uvh --replacepkgs "$package" "$tools_package"
installed=$(rpm -q --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}' kata-containers)
test "$installed" = "$expected"
installed_tools=$(rpm -q --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}' kata-containers-tools)
test "$installed_tools" = "$expected_tools"
printf 'Installed: %s and %s\n' "$installed" "$installed_tools"
INSTALL
    "${exec_pod[@]}" chroot /host /bin/sh -s <<'BUILD'
set -eu
cd /opt/kata-containers/uvm/tools/osbuilder/node-builder/azure-linux
printf 'Building the UVM with the installed tools and agent...\n'
make uvm
printf 'Deploying the UVM without changing shim configuration...\n'
make SHIM_REDEPLOY_CONFIG=no deploy-uvm
test -s /usr/share/kata-containers/kata-containers.img
printf 'UVM deployed: /usr/share/kata-containers/kata-containers.img\n'
BUILD
    cleanup_pod
done
printf '\nUpdated both RPMs and deployed the UVM on all %s selected node(s). Existing Kata VMs are unchanged.\n' "${#nodes[@]}"
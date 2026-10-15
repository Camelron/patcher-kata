# Kata RPM Node Patcher

Uses one temporary privileged `busybox:1.36.1` pod per node. The local runtime and
tools RPMs are streamed through `kubectl exec` into the host filesystem, so no custom container
image, registry, SSH access, or package download server is required.

From this directory, inspect the plan first:

```bash
bash ./patch-kata.sh
```

Install both RPMs, then build and deploy the matching UVM on every node in the current context:

```bash
bash ./patch-kata.sh --apply
```

For an explicit context or a subset of nodes:

```bash
bash ./patch-kata.sh --context kata-prerel-oct-3 \
  --selector kubernetes.azure.com/agentpool=nodepool1 --apply
```

Run `--help` for namespace, image, `--rpm`, and `--tools-rpm` path overrides. The tool pins the
context at startup. Without `--apply`, it only reads node information.

## UVM Build And Deploy

After installing the RPMs, the tool runs these commands as root on each node:

```bash
cd /opt/kata-containers/uvm/tools/osbuilder/node-builder/azure-linux
make uvm
make SHIM_REDEPLOY_CONFIG=no deploy-uvm
```

These are the UVM portions of `make all` and `make deploy`. The tools RPM does
not ship `package_build.sh` or `package_install.sh`, so the aggregate targets
cannot run from the packaged tree. Package installation is instead handled by
the preceding RPM transaction. No source checkout or host compilation of the
Kata agent is needed: the tools RPM includes the matching prebuilt agent.

The deployed image is `/usr/share/kata-containers/kata-containers.img`. The
packaged deploy script keeps numbered backups of previous images and does not
rewrite shim configuration. Existing Kata VMs are not updated.

## Behavior And Requirements

- Targets `kata-containers` and `kata-containers-tools`, both at
  `4.1.0.kata100-1.azl3.x86_64`. Uses the extracted RPMs under `RPMS/x86_64/` by
  default, or extracts missing RPMs into a temporary local directory from `rpms.tar.gz`.
  Automatic tar format detection also handles this bundle's uncompressed tar.
- Local requirements: Bash, `kubectl`, `jq`, `tar`, and `sha256sum`.
- Requires permission to list nodes and create, inspect, exec into, and delete
  privileged pods mounting `/` in `kube-system` (or `--namespace`). Admission
  policy must allow that access. Nodes must be able to pull the public helper
  image, or already have it cached; `--image` can select an approved mirror.
- All selected nodes must be Linux amd64 with an existing Kata RPM installation
  and host `rpm`, `sha256sum`, and `mktemp`. These RPMs are built for Azure Linux 3.0.
  The build also requires host Bash, `make`, `sudo` (noninteractive root access),
  `tdnf`, `gawk`, and the node builder's image tools, including `e2fsprogs`.
  The packaged build scripts invoke `sudo` internally even when running as root.
  The patcher checks the main build commands before installing either RPM; it
  does not provision build dependencies. Nodes need sufficient disk space and
  repository access for `tdnf` to install guest packages into the rootfs.
- Verifies both uploaded SHA-256 checksums and RPM identities, runs
  `rpm -Uvh --test --replacepkgs`, installs with `rpm -Uvh --replacepkgs`, and
  verifies both installed versions. Both RPMs are passed to the same transaction.
  Reinstallation is intentional for rebuilt RPMs
  with an unchanged version. Downgrades and dependency bypasses are not enabled.
- Does not install the sibling cloud-hypervisor RPM.
  Dependencies must already be satisfied, including `containerd2`, `kernel-uvm`,
  and `virtiofsd = 1.8.0`; otherwise the RPM test transaction fails.
- Processes nodes sequentially and stops at the first failure. Earlier successful
  installations are not rolled back. If a UVM build or deployment fails, the
  RPMs on that node have already been installed; no automatic rollback occurs.
  Host staging files and helper pods are
  removed on normal completion and handled failures. A lost connection or forced
  process termination can leave staging files under `/var/tmp/kata-rpm-patcher.*`;
  a helper left behind exits after two hours but may need manual deletion.
  Exec calls allow long builds; the helper has a two-hour overall deadline.
- **No draining, cordoning, rebooting, or service restarts.** Existing Kata VMs
  and shims retain their running binaries; recreate workloads to use the new
  runtime. Schedule maintenance/drain nodes yourself if needed. This is an ad hoc
  patch, not a persistent node-image change: replacement/reimaged nodes will need
  patching again. There is no automatic rollback.

## Tests

```bash
bats ./patch-kata.bats
shellcheck --exclude=SC2250 ./patch-kata.sh
```

Tests mock Kubernetes access and exercise the host transaction and UVM commands
with fake RPM and make commands; they do not modify a real cluster or its
installed packages, or build a real UVM.
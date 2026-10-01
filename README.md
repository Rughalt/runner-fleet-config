# Seele and Lux — Incus Actions runners

`provision-seele-runners.sh` turns an Ubuntu VPS into a small Incus-based runner
factory for GitHub Actions or an existing Forgejo instance. It creates one prepared Ubuntu
VM, snapshots it as a golden source, then makes fast CoW clones named
`selee-trotter-01` for GitHub or `lux-poro-01` for Forgejo. Runner software is
downloaded and configured only inside each clone. The base VM never contains
provider credentials or a configured runner.

Existing Docker on the host is not installed, removed, reconfigured, or restarted.
Docker is installed inside the VMs.

## Direct runner on a small Ubuntu host (Mikr.us potato)

`provision-potato-runner.sh` installs exactly one persistent runner directly on
an Ubuntu machine that already has a working Docker daemon. It does not use
Incus and never installs, restarts, reconfigures, or prunes host Docker. Because
the runner user belongs to the Docker group, treat it as root-equivalent and run
only trusted workflows on this machine.

At first installation, an omitted `RUNNER_NAME` is randomly selected from a
cake menu such as `cakecat-tiramisu`, `cakecat-brownie`, or `cakecat-pavlova`.
Before persisting the choice, the script checks the selected GitHub organization
or Forgejo scope and skips cake names that are already registered. The choice is
then persisted under `/etc/runner-fleet-config`, so reruns retain the same
identity. You can instead set an explicit `cakecat-<cake>` name in `.env`; an
occupied explicit name is reported rather than replaced automatically.

For GitHub, copy the potato example and fill in the token and organization:

```bash
cp .env.potato.example .env
nano .env
chmod 600 .env
sudo ./provision-potato-runner.sh
```

GitHub automatically supplies `self-hosted`, `Linux`, and the architecture label
(`X64` on an amd64 Mikr.us). The provisioner adds `cakecat`, `potato`, and
`mikrus`, allowing either a broad or narrow workflow selector:

```yaml
runs-on: [self-hosted, Linux, X64, cakecat, potato, mikrus]
```

To use the same potato with Forgejo instead, select `RUNNER_PROVIDER=forgejo`
and provide `FORGEJO_URL`, `FORGEJO_API_TOKEN`, and a narrow
`FORGEJO_SCOPE`. Forgejo jobs use the existing Docker daemon and the configured
`FORGEJO_LABELS`; current Forgejo Runner v13 requires Docker 25 or newer. The
downloaded Forgejo binary and detached signature are verified against Forgejo's
published release-signing fingerprint before installation.

Optional `HOST_SWAP_SIZE=1G` creates persistent swap only if the potato has no
active swap; existing swap and a non-swap `/swapfile` are never overwritten.
Passwordless sudo is disabled unless `RUNNER_PASSWORDLESS_SUDO=1` is explicitly
set. Routine operations are idempotent:

```bash
sudo ./provision-potato-runner.sh --status
sudo ./provision-potato-runner.sh --restart
sudo ./provision-potato-runner.sh --cleanup
```

Cleanup requires the matching provider token and settings. It removes the
managed service, files, and remote runner registration, but retains the Linux
user and leaves Docker untouched.

## On-demand disk cleanup

`cleanup-runner-disks.sh` reclaims disposable runner data without changing
runner registrations. With no target option it discovers both provisioner-owned
Incus runner VMs and the locally managed potato runner:

```bash
sudo ./cleanup-runner-disks.sh --dry-run
sudo ./cleanup-runner-disks.sh
```

Use `--incus`, `--vm selee-trotter-01`, or `--local` to narrow the target.
Normal cleanup removes stopped containers, old unused images and builder cache,
stale GitHub workspaces, Go caches, apt cache, and old journals. In Incus VMs it
also runs `fstrim`, allowing released guest blocks to be reclaimed by the CoW
storage pool.

`--aggressive` additionally removes all unused images/build cache and reusable
GitHub Actions/tool caches. Docker volumes are never pruned. An active GitHub
worker or Forgejo job container causes that VM to be skipped rather than
interrupted. For an idle target, its runner service is briefly stopped to prevent
a new job from arriving during deletion, then restored to its previous state.
Stopped or errored VMs are also left stopped.

The direct potato may share Docker with other host services, so local cleanup
does not touch host Docker unless explicitly authorized:

```bash
sudo ./cleanup-runner-disks.sh --local --include-host-docker
sudo ./cleanup-runner-disks.sh --local --aggressive --include-host-docker
```

That flag can remove unused Docker objects belonging to non-runner workloads;
volumes are still excluded. Run `--dry-run` and `docker system df` first on a
shared host.

## What it builds

- Incus with a managed NAT bridge (`incusbr0` by default) and a dedicated
  `seele-runners` profile; the existing `default` profile is not modified.
- A non-`dir` storage pool: an existing ready Btrfs/LVM/ZFS pool is reused when
  available. Otherwise a non-destructive loop-backed Btrfs pool is created, with
  loop-backed LVM-thin as the fallback.
- `seele-base`, an Ubuntu 24.04 VM with Docker, build tools, `sudo`, and a `runner`
  user that has passwordless sudo and Docker access. The golden VM also carries
  persistent guest swap and a daily cleanup timer, so every clone inherits both.
- The stopped snapshot `seele-base/golden-v1`.
- The requested runner VMs, registered with GitHub's `Default` group or the
  selected Forgejo scope and managed by systemd.

The loop-backed fallback is safe for a VPS with no spare block device, but a
dedicated disk/partition or explicitly reserved VG/dataset performs better. The
script never guesses that a device, VG, or zpool is disposable.

## Requirements

- Ubuntu 24.04 or newer on the host.
- Working nested virtualization: `/dev/kvm` must exist and be accessible.
- Defaults expect at least 4 vCPUs, 7168 MiB RAM, and 30 GiB free under `/var`.
- Outbound DNS and HTTPS to Ubuntu, the selected Actions provider, and the Incus
  image server.
- A GitHub fine-grained token belonging to an organization owner, with the
  organization permission **Self-hosted runners: Read and write**. A classic PAT
  needs `admin:org` (and `repo` when required for private repositories).

GitHub recommends self-hosted runners only for trusted workflows. In particular,
do not expose this runner group to arbitrary workflows from public-repository
forks: jobs can access the VM, Docker daemon, network, and persisted workspace.

### OVH VPS preflight

OVH VPS product pages do not constitute a reliable promise that nested KVM is
enabled for every range or generation. Check the actual machine before running the
provisioner:

```bash
sudo test -r /dev/kvm -a -w /dev/kvm && echo 'KVM OK' || echo 'NO KVM'
sudo apt-get update && sudo apt-get install -y cpu-checker
sudo kvm-ok
```

Continue only when `/dev/kvm` is present and `kvm-ok` reports usable acceleration.
If it is absent, ask OVH whether nested virtualization is available for that exact
offer, or use an OVH dedicated server/Public Cloud flavor that exposes KVM. Incus
system containers could run without it, but this design deliberately uses VMs.

## Usage

Copy the script to Seele, make it executable, and run:

```bash
chmod +x provision-seele-runners.sh
read -rsp 'GitHub token: ' GH_TOKEN; export GH_TOKEN; echo
sudo --preserve-env=GH_TOKEN ./provision-seele-runners.sh
unset GH_TOKEN
```

Alternatively, put supported settings in `.env` beside the shell prompt from
which you invoke the script:

```dotenv
GH_TOKEN=github_pat_redacted
RUNNER_COUNT=2
VM_MEMORY=1536MiB
```

Then run `sudo ./provision-seele-runners.sh`. The script reads `$PWD/.env`
without executing it as shell code, ignores unsupported keys with a warning,
and gives already-exported variables precedence. Keep this file mode `0600` and
out of version control. Set `ENV_FILE=/absolute/path/to/file` to use another
location.

To remove a failed or obsolete generation before a fresh attempt:

```bash
sudo ./provision-seele-runners.sh --stop-running
sudo --preserve-env=GH_TOKEN ./provision-seele-runners.sh --cleanup
```

`--stop-running` stops a previous provisioning process and its child operations,
using escalating signals only when necessary, then exits. It does not delete any
Incus or GitHub resources. Normal and cleanup runs hold a lock and record their PID,
so a second accidental invocation fails instead of racing the first one.

Cleanup deletes only instances and profiles carrying this provisioner's
`user.seele.*` ownership markers. It removes a storage pool or network only when
recorded as created by this provisioner; reused infrastructure is retained. If a
runner VM exists, `GH_TOKEN` is mandatory so the matching organization runner
registration is removed before its VM. Cleanup exits after removal and never starts
a new provisioning run in the same invocation.

The default creates two runners sized for the 7.6 GiB Seele host. To create
three or change VM sizing deliberately:

```bash
sudo --preserve-env=GH_TOKEN,RUNNER_COUNT,VM_CPUS,VM_MEMORY,VM_DISK \
  RUNNER_COUNT=3 VM_CPUS=2 VM_MEMORY=2048MiB VM_DISK=20GiB \
  ./provision-seele-runners.sh
```

Environment assignments normally belong before `sudo`; a shell that rejects the
example can use:

```bash
export RUNNER_COUNT=3 VM_CPUS=2 VM_MEMORY=2048MiB VM_DISK=20GiB
sudo --preserve-env=GH_TOKEN,RUNNER_COUNT,VM_CPUS,VM_MEMORY,VM_DISK \
  ./provision-seele-runners.sh
```

Useful settings:

| Variable | Default | Purpose |
|---|---:|---|
| `RUNNER_COUNT` | `2` | Creates deterministic names through `selee-trotter-NN`. |
| `VM_CPUS` / `VM_MEMORY` / `VM_DISK` | `2` / `1536MiB` / `15GiB` | Per-VM limits. |
| `HOST_SWAP_SIZE` | `2G` | Creates `/swapfile` only when the host has no active swap. |
| `GUEST_SWAP_SIZE` | `1G` | Persistent swap baked into the golden VM and its clones. |
| `DAILY_CLEANUP` | `1` | Enables conservative daily cleanup inside runner VMs. |
| `POOL_SIZE_GIB` | 60% of free, max 40 | New loop pool size in GiB (minimum 20). |
| `INCUS_STORAGE_POOL` | auto | Reuse this existing Btrfs/LVM/ZFS pool. |
| `APT_FORCE_IPV4` | `auto` | Retry apt over IPv4; use `1` to force it immediately. |
| `RUNNER_VERSION` | `latest` | Pin a runner version without the leading `v`. |
| `REPLACE_OFFLINE_RUNNER` | `0` | Replace a verified stale same-named remote runner. |

## Forgejo Actions: Lux and the Poro fleet

The same VM factory can create persistent Forgejo Actions runners. Forgejo must
already exist and be reachable over HTTPS; the script does not install or alter
the Forgejo server, its domain, proxy, or TLS configuration.

Create a narrowly scoped Forgejo access token that is allowed to list, create,
and delete runners at the chosen scope, then create a root-readable `.env` in
the directory where the script is invoked:

```dotenv
RUNNER_PROVIDER=forgejo
FORGEJO_URL=https://git.example.com
FORGEJO_API_TOKEN=replace-me
FORGEJO_SCOPE=org:my-organization
FORGEJO_RUNNER_COUNT=2
FORGEJO_RUNNER_PREFIX=lux-poro
FORGEJO_LABELS=docker:docker://node:20-bookworm
```

Supported scopes are `global`, `user`, `org:NAME`, and
`repo:OWNER/REPOSITORY`. Prefer the narrowest scope that covers the intended
workflows. `global` requires a Forgejo site administrator token. This automated
API registration requires Forgejo 15 or newer; it creates a distinct UUID and
secret for every VM rather than reusing the deprecated shared registration-token
flow.

Run:

```bash
chmod 600 .env
sudo ./provision-seele-runners.sh
```

This produces `lux-poro-01`, `lux-poro-02`, and so on. Each clone downloads the
pinned Forgejo Runner, receives only its own connection credential, and starts
`forgejo-runner.service` as the unprivileged `runner` user with Docker access.
The API token never enters a VM or the golden snapshot. Forgejo Runner v13 needs
Docker 25 or newer and the script checks this before installing the service.

## Swap and automatic cleanup

If the host has no active swap, the normal provisioning run creates a persistent
`/swapfile` of `HOST_SWAP_SIZE` (2 GiB by default). An existing host swap is left
unchanged, and an existing non-swap `/swapfile` is never overwritten. The script
also refuses to allocate the file if fewer than 8 GiB would remain on `/`.

Each fresh golden VM receives `GUEST_SWAP_SIZE` (1 GiB by default). Set either
size to `0` to disable its automatic creation. Because these settings are baked
into the golden snapshot, changing them requires a cleanup and fresh rebuild;
existing clones are intentionally not mutated behind your back.

With `DAILY_CLEANUP=1`, every runner VM gets a persistent systemd timer. Once per
day, with a randomized delay, it removes stopped containers and unused networks
older than 24 hours, unused images older than 7 days, old builder cache, stale
GitHub job workspaces, apt cache, and journals older than 7 days. Downloaded
actions and tool caches are preserved, and Docker volumes are never pruned. The
whole run is skipped while a GitHub worker or any Docker container is active.
The timer cleans guests only; host Docker remains untouched.

The default label runs jobs in a `node:20-bookworm` Docker container:

```yaml
jobs:
  build:
    runs-on: docker
    steps:
      - uses: actions/checkout@v6
```

To inspect a Poro:

```bash
sudo incus exec lux-poro-01 -- systemctl status forgejo-runner --no-pager
sudo incus exec lux-poro-01 -- journalctl -u forgejo-runner -n 100 --no-pager
```

## Restarting and rescuing runners

`restart-runners.sh` is a separate maintenance helper. It discovers owned GitHub
Trotters and Forgejo Poros from their `user.seele.role` markers, starts stopped
VMs, waits for the Incus agent, and restarts the correct systemd service without
touching runner registrations or provisioning resources:

```bash
chmod +x restart-runners.sh
sudo ./restart-runners.sh
sudo ./restart-runners.sh --vm selee-trotter-02
```

An owned runner left in Incus `ERROR` state (for example after host OOM kills its
QEMU process) is force-stopped to clear the stale runtime state and then started
normally. If recovery fails, instance diagnostics are printed and the helper
continues attempting the remaining runner VMs.

For small Go-build runners, it can safely add a persistent swap file only when
the VM has no active swap. Existing swap and a non-swap `/swapfile` are never
overwritten:

```bash
sudo SWAP_SIZE=2G ./restart-runners.sh --ensure-swap
```

Before creating VM swap, the helper conservatively assumes that every selected
VM needs the full requested allocation. It refuses the operation if `/var` would
retain less than 8 GiB (`MIN_HOST_FREE_AFTER_SWAP_GIB`) so thin/CoW storage is
not silently driven to exhaustion. Select a single VM with `--vm`, lower
`SWAP_SIZE`, or free host storage instead of bypassing the check casually.

Rerunning is idempotent: a VM with its local connection file and matching remote
runner is reused. If Forgejo contains the name but a failed VM never received its
credential, the script stops; set `REPLACE_OFFLINE_RUNNER=1` only after verifying
that the remote entry is stale. Cleanup requires the same `FORGEJO_URL`,
`FORGEJO_SCOPE`, and API token so the remote identity is removed before its VM.

To use storage explicitly reserved for Incus, all three values are required. This
double opt-in exists because Incus assumes control over the supplied storage:

```bash
export INCUS_STORAGE_DRIVER=lvm
export INCUS_STORAGE_SOURCE=incus-vg
export CONFIRM_STORAGE_SOURCE=incus-vg
sudo --preserve-env=GH_TOKEN,INCUS_STORAGE_DRIVER,INCUS_STORAGE_SOURCE,CONFIRM_STORAGE_SOURCE \
  ./provision-seele-runners.sh
```

Equivalent drivers are `zfs` (a dedicated zpool/dataset) and `btrfs` (a dedicated
path/device). Do not point this at a VG, dataset, partition, or device used by
anything else.

Re-running the same command is intentional and safe: the golden snapshot is not
rebuilt, existing VMs are not overwritten, and a locally configured runner is not
registered again. If GitHub already has a same-named online runner but the VM is
unconfigured, the script stops instead of stealing its identity.

If a run stops after creating `seele-base` but before creating `golden-v1`, leave
the VM and pool in place and rerun the same command. The ownership marker lets the
provisioner resume the incomplete base safely.

Golden snapshot detection uses Incus' snapshot API directly. If a previous call
created the database record but returned an error to the client, a rerun recognizes
the existing `golden-v1` instead of attempting to create a duplicate record.

The first VM boot can take a few minutes. The provisioner waits up to four minutes
for the Incus guest agent before declaring failure; on failure it prints instance
information and the VM console log for diagnosis.

Cloud-init exit code `2` means it completed with recoverable warnings. The
provisioner prints the detailed status and continues; exit code `1` or an unexpected
failure remains fatal and includes the `cloud-final` journal in diagnostics.

The dedicated profile also attaches Incus' official `agent:config` CD-ROM fallback.
This covers VPS environments where the normal 9p-based agent delivery is not
available. An incomplete base VM is restarted on resume so a newly attached agent
device is detected. The host dependency `genisoimage` is installed so Incus can
build that agent CD-ROM.

Some VM images stop once during the initial Incus-agent/NoCloud handoff instead of
remaining up across the requested guest reboot. The provisioner automatically
starts such a VM again, up to two times, before treating repeated stops as a real
boot failure. If Incus still has the `agent:config` ISO mounted while reporting the
VM stopped, the script waits and retries the start instead of modifying daemon-owned
mounts or failing immediately with `device or resource busy`. If the VM resumes
by itself between the state check and the explicit start, `already running` is
recognized as success instead of being retried as a mount failure.

The otherwise quiet first-boot stages are reported separately: Incus agent,
cloud-init, DHCPv4, DNS, and GitHub connectivity. A VM that remains running but
receives no IPv4 address now stops after 90 seconds with guest and bridge
diagnostics instead of appearing to hang.

Provider connectivity is verified with a real HTTPS request, explicitly over
IPv4 and with five retries. This avoids treating a transient timeout or an
unusable IPv6 address selected by a raw `/dev/tcp` hostname lookup as a permanent
GitHub/Forgejo outage.

Every cloned VM receives a small Netplan override with
`dhcp-identifier: mac`. Ubuntu cloud images can otherwise preserve the golden
VM's DHCP client identity across copies, causing several clones with different
MAC addresses to receive the same IPv4 lease. Existing owned clones are repaired
in place on their next provisioning run before network validation.

When UFW is active, the script adds idempotent bridge-scoped rules for DHCPv4,
DNS, and routed egress from the detected Incus IPv4/IPv6 subnets. It does not
disable UFW, open the public interface, restart Docker, or rewrite Docker's
firewall configuration.

Resources created by the provisioner carry `user.seele.*` ownership markers. An
unmarked legacy VM or profile with a conflicting name is never adopted or changed;
the run stops and asks you to rename it. An incompatible legacy pool called
`seele-cow` is left alone and the new pool receives the next free suffix.

## Workflow

The standard labels are retained, so the requested minimal selector works:

```yaml
jobs:
  build:
    runs-on: self-hosted
    steps:
      - uses: actions/checkout@v4
      - run: docker version
```

With more self-hosted fleets, prefer a narrower selector to avoid sending a job to
the wrong machine:

```yaml
runs-on: [self-hosted, Linux, X64, seele]
```

## Safe migration from the partial old setup

### Full destructive rebuild of this managed fleet

Use this when the current Trotters and their golden image are disposable. It
removes only VMs and infrastructure carrying this provisioner's ownership
markers, plus matching remote runner registrations. It does not touch host
Docker or unmarked Incus resources.

Put the GitHub token in the local `.env`, stop any stuck earlier provisioner,
then run cleanup as a separate operation before provisioning again:

```bash
chmod 600 .env
sudo ./provision-seele-runners.sh --stop-running
sudo ./provision-seele-runners.sh --cleanup
sudo ./provision-seele-runners.sh
```

The cleanup command is intentionally destructive and exits when finished. The
final command creates the smaller two-runner generation, host swap, the new
golden snapshot, guest swap, and cleanup timers. If pool deletion reports a
remaining dependency, stop instead of deleting its backing file manually and
inventory the exact owner:

```bash
sudo incus list --all-projects
sudo incus image list --all-projects
sudo incus storage volume list seele-cow --all-projects
```

Only remove a legacy project or image after confirming it belongs exclusively to
the abandoned runner generation.

1. Disable workflows or set the old runners temporarily offline so jobs cannot
   land during migration. Do not delete anything yet.
2. Inventory the old state:

   ```bash
   sudo incus list
   sudo incus storage list
   sudo incus network list
   sudo systemctl list-units 'actions.runner*'
   docker ps --format 'table {{.Names}}\t{{.Status}}'
   ```

3. Preserve anything useful. Export old Incus instances before touching them:

   ```bash
   sudo incus stop OLD_VM
   sudo incus export OLD_VM ./OLD_VM-backup.tar.gz --optimized-storage
   ```

4. Rename conflicting old instances instead of deleting them. If an old VM is
   already called `selee-trotter-01`, stop it and use an unmistakable quarantine name:

   ```bash
   sudo incus stop selee-trotter-01
   sudo incus move selee-trotter-01 legacy-selee-trotter-01
   ```

5. In **Organization settings → Actions → Runners**, remove stale old runner
   registrations that use the target names. If uncertain, leave them in place:
   the new script will stop safely. `REPLACE_OFFLINE_RUNNER=1` is available only
   after you have verified that the same-named registration is genuinely stale.
6. Run the new script. Verify every `selee-trotter-NN` is `Idle` in GitHub and run a small
   trusted test workflow using `runs-on: [self-hosted, seele]`.
7. Keep the quarantined setup for a short observation period. Only then remove old
   instances, obsolete pools, or host services manually. The provisioning script
   deliberately performs no cleanup and never touches host Docker.

### Manual cleanup of the old setup

Do this only after the new Trotters have completed a real test job. Commands below
use explicit placeholder names on purpose; do not replace them with wildcards.

First inventory every dependency and write down the exact legacy names:

```bash
sudo incus list -c ns4t
sudo incus profile list
sudo incus storage list
sudo incus network list
sudo systemctl list-units --all 'actions.runner*'
```

For each suspected legacy VM, inspect it before acting:

```bash
OLD_VM=legacy-seele-01
sudo incus config show "$OLD_VM" --expanded
sudo incus info "$OLD_VM"
```

Remove its old registration in **GitHub organization settings → Actions →
Runners**. Make sure the displayed name is the old runner, not a new
`selee-trotter-NN`. Then stop, optionally export, and interactively delete that one
VM:

```bash
OLD_VM=legacy-seele-01
sudo incus stop "$OLD_VM" --timeout 120
sudo incus export "$OLD_VM" "./${OLD_VM}-backup.tar.gz" --optimized-storage
sudo incus delete --interactive "$OLD_VM"
```

If an old runner was installed directly on the host rather than in Incus, locate
its directory from the unit before removing anything:

```bash
sudo systemctl list-units --all 'actions.runner*'
sudo systemctl cat 'actions.runner.EXACT-OLD-NAME.service'
```

After removing the matching registration in GitHub, run `./svc.sh stop` and
`sudo ./svc.sh uninstall` from that runner's exact installation directory. Rename
the directory into quarantine first; do not recursively delete a guessed path.

Finally inspect legacy infrastructure objects. The `used_by` list must be empty
before deletion:

```bash
OLD_PROFILE=exact-old-profile
OLD_POOL=exact-old-pool
OLD_NETWORK=exact-old-network

sudo incus profile show "$OLD_PROFILE"
sudo incus storage show "$OLD_POOL"
sudo incus network show "$OLD_NETWORK"
```

Only for exact, verified, unused legacy objects:

```bash
sudo incus profile delete "$OLD_PROFILE"
sudo incus storage delete "$OLD_POOL"
sudo incus network delete "$OLD_NETWORK"
```

Never delete `seele-runners`, the pool referenced by that profile, or its network
while the new VMs exist. Do not delete the Incus `default` profile. Pool deletion
also removes its remaining volumes and, for an Incus-managed loop pool, its backing
loop file, so an unexpected `used_by` entry is a hard stop.

## Operations and recovery

```bash
# VM and IP status
sudo incus list '^selee-trotter-'

# Runner service inside a VM
sudo incus exec selee-trotter-01 -- systemctl --no-pager --full status 'actions.runner*'

# Runner diagnostic logs
sudo incus exec selee-trotter-01 -- bash -lc 'ls -lt /opt/actions-runner/_diag | head'

# Reboot a runner VM
sudo incus restart selee-trotter-01
```

To add capacity later, keep the same base and increase `RUNNER_COUNT`; only missing
sequential VMs are cloned and registered. To deliberately rebuild the golden image
after package changes, use a new `GOLDEN_SNAPSHOT` name and preferably a new
`BASE_VM` name. This leaves the working generation available for rollback.

## Design notes

- Package installation happens once in the base VM. Apt uses finite timeouts and
  retries, then falls back to IPv4 when the normal path stalls.
- Runner archives are downloaded in each clone and verified against the SHA-256
  digest published in GitHub's release API before extraction.
- Registration tokens are short-lived, written only to a root-readable file in
  the VM's `/run`, and removed after configuration. The long-lived GitHub token is
  never copied into a VM.
- The default group is named explicitly during unattended registration. Confirm
  its repository access policy in organization settings.

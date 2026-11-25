# Configuration

> [!TIP]
> If you are using a cluster setup - this step needs to be executed only on one node of the cluster - corosync will do the rest for you.

After installing the plugin, configure Proxmox VE to use it. On Proxmox VE 9.3 or later you can add and edit the storage in the web UI under Datacenter → Storage (the form comes from the plugin property schema). On older versions, use the shell and `pvesm`:

```bash
pvesm add purestorage <storage_id> \
   --nodes <proxmox_node_list> \
   --address https://<purestorage_fqdn_or_ip> \
   --token <purestorage_api_token> \
   --vgname <purestorage_volume_group_name> \
   --hgsuffix <purestorage_host_suffix> \
   --content images
```

Alternatively, edit the storage configuration file `/etc/pve/storage.cfg`:

```text
purestorage: <storage_id>
  nodes <proxmox_node_list>
  address https://<purestorage_fqdn_or_ip>
  token <purestorage_api_token>
  vgname <purestorage_volume_group_name>
  hgsuffix <purestorage_host_suffix>
  content images
```

## Parameters

| Parameter | Description |
| --------- | ----------- |
| storage_id | The storage identifier (name under which it will appear in the Storage list) |
| nodes | (`optional`) A comma-separated list of Proxmox node names. Use this parameter to limit the plugin to specific nodes in your cluster. If omitted, the storage is available to all nodes. |
| address | The URL or IP address of the Pure Storage API endpoint. Ensure that the Proxmox VE nodes can reach this address over the network. For high availability or Active Cluster configuration (experimental), you can specify multiple arrays separated by commas (e.g., `https://array1.example.com,https://array2.example.com`). When multiple arrays are specified, the plugin automatically connects volumes to hosts on all arrays. |
| token | The API token used for authentication with the Pure Storage array. This token must have sufficient permissions to create and manage volumes. For multiple arrays, specify tokens separated by commas in the same order as addresses. Each token must have permissions for its corresponding array. |
| vgname | (`optional`, conflicts with `podname`) The volume group name where virtual disks will be stored. This should match the configuration on your Pure Storage array. |
| podname | (`optional`, conflicts with `vgname`) The pod name where virtual disks will be stored. This should match the configuration on your Pure Storage array. |
| vnprefix | (`optional`) The prefix to prepend to name of virtual disks. |
| hgsuffix | (`optional`) A suffix that is appended to the hostname when the plugin interacts with the Pure Storage array. This can help differentiate hosts if necessary. |
| content | Specifies the types of content that can be stored. Use `images` for QEMU VM disks. Add `rootdir` (e.g. `images,rootdir`) to allow LXC root volumes on the same pool; see [Linux containers (LXC)](#linux-containers-lxc). |
| protocol | (`optional`, default is `iscsi`) Specifies the storage protocol (`iscsi`, `fc`). |
| check_ssl | (`optional`, default is `no`) Verify the server's TLS certificate. Set to `yes` to enable SSL certificate verification. |
| token_ttl | (`optional`, default is `3600`) Session token time-to-live in seconds. The plugin caches the API session tokens in `/etc/pve/priv/purestorage/` and refreshes them at 80% of the TTL; see [architecture](architecture.md#authentication-and-token-cache). |
| debug | (`optional`, default is `0`) Debug level 0 to 3 (off, basic, verbose, trace); `PURESTORAGE_DEBUG` is the fallback when it is not set. See [troubleshooting](troubleshooting.md#debug-logging). |
| pgroup_sync | (`optional`, default is `no`) Import Pure protection-group snapshots into QEMU VM snapshot trees. Off by default. See [Protection-group snapshot sync](#protection-group-snapshot-sync). |
| pgroup_sync_interval | (`optional`, default is `60`) Minimum seconds between protection-group snapshot sync runs (minimum 30). Only used when `pgroup_sync` is enabled. |
| san-multipath | (`optional`, default is `no`) On Proxmox VE 9.3+, register each volume WWID in the cluster multipath configuration so Datacenter → SAN can show the LUN as managed. Off by default. See [SAN multipath registration](#san-multipath-registration). |

> **_NOTE:_** Ensure that the token and other sensitive information are kept secure and not exposed publicly.

Active Cluster (multiple arrays, experimental): list the addresses and the tokens in the same order, and the plugin connects every volume to the host on all arrays:

```text
purestorage: pure-cluster
  address https://array1.example.com,https://array2.example.com
  token token1,token2
  vgname pure_vg
  content images
```

## SAN multipath registration

Proxmox VE 9.3 adds cluster-wide multipath management and a Datacenter → SAN view. Built-in iSCSI storages can supply LUN WWIDs with their `managed-multipath` option; third-party plugins need an explicit entry per WWID in `/etc/pve/multipath.cfg`.

With `san-multipath` enabled, the plugin registers a volume's WWID when the volume is created, cloned, or activated, and removes the entry when the volume is deleted. Host-side connect, SCSI scan, `multipathd add` / `remove`, and array disconnect stay as they are. On Proxmox VE without the multipath configuration API the setting is accepted but registration is a no-op.

Enable it on a storage:

```bash
pvesm set <storage_id> --san-multipath 1
```

Existing volumes are adopted the next time they are activated (lazy registration). Auto-registered entries do not set `paths-expected`, because a Pure volume is only connected on nodes that activated it; other nodes may show the LUN as Missing in the SAN view without multipath notifications. Datacenter → SAN reports about 700 LUNs per node before falling back to Node → SAN only, so large estates should treat this as opt-in observability rather than registering every idle volume by hand.

## Linux containers (LXC)

The plugin exposes the Proxmox `rootdir` content type, so a storage can host LXC root filesystems as raw volumes next to `images` (QEMU disks): set `content images,rootdir`. LXC uses the same allocation and device path logic as VM disks. Support is best-effort and community-tested: validate create, resize and delete for your workloads on a real array before relying on it in production. If you only need QEMU VMs, keep `content images`.

## Protection-group snapshot sync

Pure protection-group snapshots (for example `pgroup-auto.277`) are **not** imported into the Proxmox VM snapshot tree unless you turn this on. The feature is QEMU-only; LXC/`rootdir` volumes are skipped.

Enable it on a storage, with an optional interval (seconds, minimum 30, default 60):

```text
pvesm set <storage_id> --pgroup_sync 1 --pgroup_sync_interval 60
```

Imported names replace `.` and `:` with `-` (for example `pgroup-auto-277`; a group in a pod, `POD::GROUP.SUFFIX`, becomes `POD--GROUP-SUFFIX`). Delete those snapshots on the Pure protection group, not from the Proxmox UI: when the snapshot is gone from the array, the sync removes its entry from the VM config and moves the parent references that pointed at it.

A snapshot of the user that already has the name is never taken over: the group is imported under `<name>-<snapshot time>` (cut so that the name is at most 40 characters, the limit of Proxmox). A clone (`qm clone --snapname`) and a rollback restore from the exact snapshot of the array. How the sync keeps the entries is in [architecture](architecture.md#protection-group-snapshot-sync).

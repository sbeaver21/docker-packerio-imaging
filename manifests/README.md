# manifests

Build manifests. **Generated output, not source.**

```text
manifests/
├── .gitkeep
├── linux/
└── windows/
    └── 2026-10-21-18-57-20.json
```

Manifests are written into a subdirectory per guest OS family, named with the
build timestamp. `.gitignore` excludes `manifests/**/*.json` and keeps the
directory structure through the `.gitkeep` files.

---

## What is in a manifest

Written by the `manifest` post-processor. A real one, with the inventory values
redacted:

```json
{
  "builds": [
    {
      "name": "windows-server-2025-standard-core",
      "builder_type": "vsphere-iso",
      "files": null,
      "artifact_id": "windows-server-2025-standard-core-docker",
      "packer_run_uuid": "540439ac-d321-31de-0aa2-9b515799436f",
      "custom_data": {
        "build_date": "2026-10-21",
        "build_username": "<build account>",
        "build_version": "docker",
        "common_data_source": "disk",
        "common_vm_version": "21",
        "vm_cpu_cores": "2",
        "vm_cpu_count": "2",
        "vm_disk_size": "102400",
        "vm_disk_thin_provisioned": "true",
        "vm_firmware": "efi-secure",
        "vm_guest_os_type": "windows2022srvNext_64Guest",
        "vm_mem_size": "4096",
        "vm_network_card": "vmxnet3",
        "vsphere_cluster": "<cluster>",
        "vsphere_datacenter": "<datacenter>",
        "vsphere_datastore": "<datastore>",
        "vsphere_endpoint": "<vcenter>"
      }
    }
  ],
  "last_run_uuid": "540439ac-d321-31de-0aa2-9b515799436f"
}
```

| Field | Meaning |
| :---- | :------ |
| `name` | The source that produced the image |
| `builder_type` | Always `vsphere-iso` here |
| `artifact_id` | The VM or library item name produced |
| `packer_run_uuid` | Identifies this run; equals `last_run_uuid` for the most recent |
| `files` | `null` — the artifact is in vSphere, not on disk |
| `custom_data` | Everything the template chose to record |

There is no `build_time` field. The timestamp is in the file name, and in
`custom_data.build_date` at day granularity.

`custom_data` values are all strings, including the numbers. Compare them as
text, or convert: `(custom_data.vm_mem_size | tonumber)`.

---

## The manifest contains infrastructure identifiers

`custom_data` records `vsphere_endpoint`, `vsphere_username`,
`vsphere_datacenter`, `vsphere_cluster` and `vsphere_datastore`.

The password is not there, but the service account's **name** and the inventory
layout are. Treat a manifest as internal:

- Do not attach one to a issue without redacting `vsphere_endpoint`,
  `vsphere_username` and the inventory names.
- Do not copy one into a place that is not access-controlled.
- This is why `manifests/**/*.json` is gitignored.

---

## Reading one

```shell
jq '.builds[] | {name, artifact_id, run: .packer_run_uuid}' manifests/windows/<file>.json
jq '.builds[0].custom_data' manifests/windows/<file>.json
```

On Windows, `jq` is available via `winget install jqlang.jq`.

---

## Why they are not committed

- They are output. Committing them makes every build a merge conflict.
- They contain inventory names and the service-account name.
- They are per-run; the useful history belongs in the release notes, not in git.

If an image's provenance must be retained for a release or an audit, copy the
manifest somewhere durable and access-controlled before the working copy is
cleaned up. The file name carries the timestamp, so manifests do not overwrite
each other — the directory simply grows.

---

## Operational use

| Question | Field |
| :------- | :---- |
| Which source produced this image? | `builds[].name` |
| How was it configured? | `builds[].custom_data` |
| Did the build publish anything? | `builds[].artifact_id` |
| Which run, to correlate with a build log? | `builds[].packer_run_uuid` |

A manifest exists only if the build reached the post-processor. Its absence is a
reliable signal that the build failed earlier — which is the usual case, and why
a missing manifest says more than an empty directory.

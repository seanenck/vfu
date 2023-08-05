swiftvf
===

`swiftvf` is a swift re-implementation of `vftool` (in swift!) with a set of changes that
make it a bit different to run. The baseline functionality of [vftool](https://github.com/evansm7/vftool)
remains the basis for the current state at this time.

[![build](https://github.com/enckse/swiftvf/actions/workflows/build.yml/badge.svg)](https://github.com/enckse/vftool/actions/workflows/build.yml)

## Build

to get `swiftvf` working:
- clone the repository
- `make`

## Canges

While there is quite a bit of divergence, the major changes are really:

- instead of CLI arguments for all parameters, a JSON configuration file is
  passed via the `-c` flag
- bridged networking functionality is (currently) removed
- shared directory support (including readonly) via virtio is added
- a static mac can be attached
- no tty options

## Configuration

The JSON configuration, to run a minimal alpine iso, is below with the following
expectations
1. Download the arm64 (aarch64) standard iso for alpine
2. Extract the vmlinuz-lts and initramfs-lts from the iso (and gzip decompress them)
3. Run the following (assuming swiftvf has already been built and is PATH and all the specified files are in the current directory)...
4. Create the JSON configuration file

```
vim alpine.json
---
{
  "kernel": "vmlinuz-lts",
  "initrd": "initramfs-lts",
  "cpus": 2,
  "memory": 8192, 
  "disks": [
    { 
      "path": "alpine-standard-3.18.2-aarch64.iso",
      "readonly": "yes"
    },
    { 
      "path": "apkovl.img"
    },
    { 
      "path": "data.img"
    }
  ],
  "tty": "connect",
  "shares": {
    "downloads": {
       "path": "/Users/me/Downloads"
    },
    "documents": {
       "path": "/Users/me/Documents",
       "readonly": "yes"
    }
  },
  "mac": "12:34:56:78:90:ab"
}
```

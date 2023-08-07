vfu
===

`vfu` is a swift re-implementation of `vftool` (in swift!) with a set of changes that
make it a bit different to run. The baseline functionality of [vftool](https://github.com/evansm7/vftool)
remains the basis for the current state at this time. The main goal is to take
what `vftool` is and provide the ability to run/configure simple Linux-based
VMs.

[![build](https://github.com/enckse/vfu/actions/workflows/build.yml/badge.svg)](https://github.com/enckse/vftool/actions/workflows/build.yml)

## Build

to get `vfu` working:
- clone the repository
- `make`

## Changes

While there is quite a bit of divergence, the major changes are really:

- instead of CLI arguments for all parameters, a JSON configuration file is
  passed via the `--config` flag (pass `--verify` to check the configuration without
  running the VM)
- bridged networking functionality is (currently) removed
- shared directory support (including readonly) via virtio is added
- one (or more) static MACs can be attached
- no tty options
- use '~/' to refer to a location starting with the user's home

## Configuration

The JSON configuration, to run a minimal alpine iso, is below with the following
expectations
1. Download the arm64 (aarch64) standard iso for alpine
2. Extract the vmlinuz-lts and initramfs-lts from the iso (and gzip decompress them)
3. Run the following (assuming `vfu` has already been built and is PATH and all the specified files are in the current directory)...
4. Create the JSON configuration file (see example.json as a starting place)
5. Run `vfu --config <file>.json`

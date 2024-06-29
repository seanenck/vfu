vfu
===

`vfu` is a swift re-implementation of `vftool` (in swift!) with a set of changes that
make it a bit different to run. The baseline functionality of [vftool](https://github.com/evansm7/vftool)
remains the basis for the current state at this time. The main goal is to take
what `vftool` is and provide the ability to run/configure simple Linux-based VMs
via JSON definitions.

[![build](https://github.com/seanenck/vfu/actions/workflows/build.yml/badge.svg)](https://github.com/seanenck/vfu/actions/workflows/build.yml)

## Build

to get `vfu` working:
- clone the repository
- `make`

## Usage

There is a small set of example JSON configurations in the `examples/` directory

### CLI

To validate a configuration without starting the VM
```
vfu --config <config file> --verify
```

To start the VM
```
vfu --config <config file>
```

### GUI

There is a simple GUI variant of the same `vfu` code that can be built and used
via `make` targets (and then `make install` or manually copying the output
release files to `/Applications`). This functionality allows for attaching
an actual virtio graphics setup to a VM configuration. When started it will
open a dialog box to select a configuration JSON file and the GUI will close when
VM stops.

## Changes

While there is quite a bit of divergence from vftool, the major changes are really:

- instead of CLI arguments for all parameters, a JSON configuration file is
  passed via the `--config` flag (pass `--verify` to check the configuration without
  running the VM)
- bridged networking functionality is removed
- shared directory support (including readonly) via virtio is added
- one (or more) static MACs can be attached
- no tty/pty options, there are serial options (raw, full, none)
- use '~/' to refer to a location starting with the user's home


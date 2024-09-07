vfu
===

`vfu` is a swift re-implementation of [vftool](https://github.com/evansm7/vftool) (but in swift!)
with a set of changes that make it a bit different to run and including additional functionality, like:
- VM JSON configuration (instead of CLI flags)
- Additional features (e.g. nvme, entropy, time sync, shared directories, static
  MACs...)
- Graphical option/output

[![build](https://github.com/seanenck/vfu/actions/workflows/build.yml/badge.svg)](https://github.com/seanenck/vfu/actions/workflows/build.yml)

## Build

to get `vfu` working, clone the repository
```
make
```

## Install

build and then deploy the full application contents to `/Applications` as
`vfu.app`
```
make install
```

## Usage

There is a small set of example JSON configurations in the `examples/` directory

### CLI

To validate a configuration without starting the VM
```
/Applications/vfu.app/Contents/MacOS/vfu-cli --config <config file> --verify
```

To start the VM
```
/Applications/vfu.app/Contents/MacOS/vfu-cli --config <config file>
```

### GUI

The simple GUI variant allows for attaching an actual virtio graphics setup to a 
VM configuration. When started it will open a dialog box to select a configuration
JSON file and the GUI will close when VM stops. This is starting by running the `vfu.app`.

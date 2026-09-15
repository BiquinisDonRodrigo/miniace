#!/bin/sh
# Expose the Kubo HTTP gateway on all interfaces so the acestream
# container can resolve IPFS/IPNS playlists over the Docker network.
# The stock ipfs/kubo image binds the gateway to 127.0.0.1 only; this
# script runs through the official /container-init.d extension point.
ipfs config Addresses.Gateway /ip4/0.0.0.0/tcp/48080

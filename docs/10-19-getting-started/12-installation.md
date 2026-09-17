# 12 Installation

## 1. Clone the repository

```sh
git clone https://github.com/BiquinisDonRodrigo/miniace.git
cd miniace
```

## 2. Create the environment file

```sh
cp .env.example .env
```

Edit `.env` and set at least `WG_PRIVATE_KEY`. Generate the WireGuard
configuration at <https://account.proton.me/vpn/WireGuard> with
**"NAT-PMP (Port Forwarding)" enabled** and paste the `PrivateKey` value.
Every variable is documented in [13 Configuration](13-configuration.md).

## 3. Declare your playlist sources

`data/` is gitignored and therefore absent from a fresh clone. Create the
directory and your sources file:

```sh
mkdir -p data
cat > data/sources.json <<'EOF'
[
  {"name": "example", "origin": "ipns://<key>/playlist.m3u"}
]
EOF
```

Format details in [21 Playlists](../20-29-operation/21-playlists.md).

## 4. Start the stack

With the prebuilt image from GHCR:

```sh
docker compose pull
docker compose up -d
```

If the GHCR package is private and you have not logged in, the pull fails;
build the image locally instead (no registry access needed):

```sh
docker compose up -d --build
```

## 5. Watch the first boot

```sh
docker compose ps
docker compose logs -f gluetun acestream
```

Then follow [14 First run](14-first-run.md).

## Update

```sh
docker compose pull
docker compose up -d
```

The engine cache, generated playlists and the IPFS repository live in
`data/` (bind mounts) and survive recreates.

## Uninstall

```sh
docker compose down
rm -rf data/    # optional: deletes playlists, sources, engine cache and IPFS repo
```

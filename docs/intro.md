# miniace documentation

miniace runs the [AceStream](https://www.acestream.org/) P2P engine behind a
ProtonVPN WireGuard tunnel with **dynamic P2P port forwarding**, and publishes
**IPFS/IPNS M3U playlists** to IPTV clients. The whole stack is three
containers driven by Docker Compose:

| Service | Image | Role |
|---|---|---|
| gluetun | `qmcgaw/gluetun` (official) | VPN tunnel, NAT-PMP port forwarding, published ports |
| acestream | `ghcr.io/biquinisdonrodrigo/miniace` (built by CI) | AceStream engine + port supervisor + IPNS→M3U sync + playlist server |
| kubo | `ipfs/kubo` (official) | Local IPFS node resolving `ipns://` playlists |

## Quick start

```sh
git clone https://github.com/BiquinisDonRodrigo/miniace.git
cd miniace
cp .env.example .env                        # set WG_PRIVATE_KEY
mkdir -p data                               # data/ is gitignored
$EDITOR data/sources.json                   # declare your playlist sources
docker compose pull && docker compose up -d
```

Full walkthrough: [12 Installation](10-19-getting-started/12-installation.md).
Verify the result with [14 First run](10-19-getting-started/14-first-run.md).

## Documentation map

Areas group documents by purpose; categories are the numbered files inside
each area.

### 10-19 Getting started

| ID | Document |
|----|----------|
| 11 | [Requirements](10-19-getting-started/11-requirements.md) |
| 12 | [Installation](10-19-getting-started/12-installation.md) |
| 13 | [Configuration](10-19-getting-started/13-configuration.md) |
| 14 | [First run](10-19-getting-started/14-first-run.md) |

### 20-29 Operation

| ID | Document |
|----|----------|
| 21 | [Playlists](20-29-operation/21-playlists.md) |
| 22 | [Clients](20-29-operation/22-clients.md) |
| 23 | [Maintenance](20-29-operation/23-maintenance.md) |

### 30-39 Architecture

| ID | Document |
|----|----------|
| 31 | [Architecture](30-39-architecture/31-architecture.md) |
| 32 | [P2P port forwarding](30-39-architecture/32-p2p-port-forwarding.md) |
| 33 | [Data layout](30-39-architecture/33-data-layout.md) |

### 40-49 Troubleshooting

| ID | Document |
|----|----------|
| 41 | [Common issues](40-49-troubleshooting/41-common-issues.md) |
| 42 | [Diagnostics](40-49-troubleshooting/42-diagnostics.md) |

### 50-59 Development

| ID | Document |
|----|----------|
| 51 | [Repository layout](50-59-development/51-repository-layout.md) |
| 52 | [The acestream image](50-59-development/52-acestream-image.md) |
| 53 | [CI/CD](50-59-development/53-ci-cd.md) |

## How this documentation is organized

The `docs/` tree uses a lightweight [Johnny Decimal](https://johnnydecimal.com/)
scheme:

- **Areas** are folders numbered in blocks of ten:
  `10-19-getting-started/`, `20-29-operation/`, `30-39-architecture/`,
  `40-49-troubleshooting/`, `50-59-development/`. A new area is added only
  when no existing one fits.
- **Categories** are the files inside an area, named `NN-topic.md` with `NN`
  unique inside its area (`11`, `12`, …). The category number is the stable
  address of the document: links always point to `docs/.../NN-topic.md`.
- If a category outgrows a single page, split it into IDs `NN.01-topic.md`,
  `NN.02-topic.md`, … inside an `NN-topic/` folder and keep `NN` in the map
  above.

Conventions for contributors:

- One topic per file; relative Markdown links between documents.
- Keep the tables in this file in sync when adding or renaming a document.
- Commands are written for the repository root (`docker compose ...`).

## Related

- Project README: [`../README.md`](../README.md)
- Issue tracker: <https://github.com/BiquinisDonRodrigo/miniace/issues>

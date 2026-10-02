# miniace

[![Build acestream image](https://github.com/BiquinisDonRodrigo/miniace/actions/workflows/docker.yml/badge.svg)](https://github.com/BiquinisDonRodrigo/miniace/actions/workflows/docker.yml)

Dockerized [AceStream](https://www.acestream.org/) engine behind a ProtonVPN
WireGuard tunnel with **dynamic P2P port forwarding**, plus **IPFS/IPNS M3U
playlist** support for IPTV clients (TiviMate, VLC, Jellyfin, Kodi...).

Three containers, one custom image:

| Service   | Image | Role |
|-----------|-------|------|
| gluetun   | `qmcgaw/gluetun` (official, digest-pinned) | VPN tunnel, NAT-PMP port forwarding, published ports |
| acestream | `ghcr.io/biquinisdonrodrigo/miniace:latest` (built by CI) | AceStream 3.2.11 engine + port supervisor + IPNS→M3U sync + playlist HTTP server |
| kubo      | `ipfs/kubo:v0.43.0` (official) | Local IPFS node resolving the `ipns://` playlists |

```
IPTV client (TiviMate / VLC / Jellyfin)
   │  stream:    http://<HOST>:6878/ace/getstream?id=<infohash>
   │  playlists: http://<HOST>:8080/{<source>,all}.m3u
   ▼
[gluetun] ──netns──► [acestream]
                        │  engine P2P bound to the port announced by ProtonVPN
                        ▼
                     [kubo] :48080 (IPNS resolution, Docker network only)
```

## Table of contents

- [Features](#features)
- [Requirements](#requirements)
- [Quick start](#quick-start)
- [Configuration](#configuration)
- [Playlists](#playlists)
- [How it works](#how-it-works)
- [Connecting clients](#connecting-clients)
- [Data layout](#data-layout)
- [Updates](#updates)
- [Build & CI](#build--ci)
- [Troubleshooting](#troubleshooting)
- [Security notes](#security-notes)
- [Documentation](#documentation)
- [Legal](#legal)
- [License](#license)
- [Acknowledgements](#acknowledgements)

## Features

- The engine only binds the P2P port ProtonVPN announces and rebinds on rotation.
- Every AceStream engine option is configurable from `.env`; empty value = factory default.
- IPFS/IPNS playlists with per-request host rewriting (LAN and Tailscale at once).
- One custom image; gluetun and kubo run official images untouched.

## Requirements

- Docker Engine + Docker Compose v2 on an x86_64 host. The official engine is
  amd64 only; ARM hosts are not supported.
- A ProtonVPN paid plan (Plus/Unlimited) and a WireGuard configuration
  generated at [account.proton.me/vpn/WireGuard](https://account.proton.me/vpn/WireGuard)
  with **NAT-PMP (Port Forwarding)** enabled.
- Two free TCP host ports (default 6878 and 8080).
- A `data/sources.json` file with at least one playlist source
  (see [Playlists](#playlists)).

Without a forwarded port the engine does not start.

## Quick start

```sh
git clone https://github.com/BiquinisDonRodrigo/miniace.git
cd miniace
cp .env.example .env
# edit .env: WG_PRIVATE_KEY (the PrivateKey from the ProtonVPN config)
mkdir -p data
cat > data/sources.json <<'EOF'
[
  {"name": "example", "origin": "ipns://<key>/playlist.m3u"}
]
EOF
docker compose up -d    # pulls the prebuilt image from GHCR
```

Watch the first boot:

```sh
docker compose ps
docker compose logs -f gluetun acestream
```

The engine waits for the forwarded port, then binds to it. First IPNS
resolution on a fresh Kubo repo can take minutes.

## Configuration

Copy `.env.example` to `.env`. The only required value is `WG_PRIVATE_KEY`.
Everything else ships with working defaults: ports 6878/8080, hourly
playlist sync and engine budgets tuned for sharing while you watch.

Each variable in [.env.example](.env.example) is documented by its own
comment: effect, unit, and what an empty value does. The full reference is
[13 Configuration](docs/10-19-getting-started/13-configuration.md). To
measure upload, see
[42 Diagnostics](docs/40-49-troubleshooting/42-diagnostics.md#upload-throughput).

## Playlists

Sources live in `data/sources.json`, re-read on every sync cycle:

```json
[
  {"name": "example", "origin": "ipns://<key>/playlist.m3u"},
  {"name": "iptv", "origin": "ipns://<key>/channels.m3u"}
]
```

- Origins: `ipns://`, `ipfs://` or `http(s)://` URLs (`nombre`/`origen` are
  accepted as aliases of `name`/`origin`).
- AceStream entries are rewritten per request to
  `http://<request-host>:6878/ace/getstream?id=<hash>`, where the host is
  the one you used to fetch the playlist. Other URLs are preserved.
- Output: `data/playlists/<name>.m3u` plus a merged `all.m3u`, served at
  `http://<HOST>:8080/`. IPNS resolves through the local Kubo gateway, with
  public gateways as fallback.

Details: [21 Playlists](docs/20-29-operation/21-playlists.md).

## How it works

- **gluetun** tunnels ProtonVPN over WireGuard, negotiates the NAT-PMP
  forwarded port and exposes it on a loopback control server (`:8001`) and
  a status file.
- **acestream** shares gluetun's network namespace. The entrypoint resolves
  the announced port, starts the engine bound to it, applies client
  settings through the local API and restarts on port rotation. Without a
  forwarded port the engine does not start.
- **sync.py** fetches the sources, rewrites the entries and serves the
  playlists on `:8080`.
- **kubo** resolves IPNS through its gateway on `:48080` (Docker network
  only).

Deep dive: [31 Architecture](docs/30-39-architecture/31-architecture.md) ·
[32 P2P port forwarding](docs/30-39-architecture/32-p2p-port-forwarding.md).

## Connecting clients

| What | URL |
|------|-----|
| Playlist (all sources merged) | `http://<HOST>:8080/all.m3u` |
| Playlist (single source) | `http://<HOST>:8080/<name>.m3u` |
| Single stream | `http://<HOST>:6878/ace/getstream?id=<infohash>` |

The client must reach the engine port (`ACESTREAM_HTTP_PORT`) on the same
host it used to fetch the playlist. Verify the stack at any time:

```sh
docker compose logs gluetun | grep -i "forwarded port"      # announced port N
docker compose logs acestream | grep "P2P on forwarded"     # engine bound to N
docker compose exec gluetun ss -lntup | grep -E "6878|<N>"  # both listening
```

Client setup guides: [22 Clients](docs/20-29-operation/22-clients.md).

## Data layout

```
data/
├── sources.json    # playlist sources (yours)
├── playlists/      # generated .m3u files (yours, gitignored)
├── gluetun/        # forwarded-port status file (runtime)
├── ipfs/           # Kubo repository (runtime)
└── acestream/      # engine state + disk cache (runtime)
```

Everything lives in bind mounts under `data/` and survives container
recreates. Details: [33 Data layout](docs/30-39-architecture/33-data-layout.md).

## Updates

```sh
docker compose pull
docker compose up -d
```

The engine cache, generated playlists and the IPFS repository persist in
`data/`. ProtonVPN rotates the forwarded port on every reconnect; the
watcher detects it within `PORT_WATCH_INTERVAL_S` and restarts the engine
so it rebinds (streams in flight are interrupted for a few seconds).
Maintenance guide: [23 Maintenance](docs/20-29-operation/23-maintenance.md).

## Build & CI

`.github/workflows/docker.yml` builds `images/acestream` and publishes it
to [GHCR](https://github.com/BiquinisDonRodrigo/miniace/pkgs/container/miniace):

- push to `main` → `latest` + `sha-<short>`
- tag `vX.Y.Z` → `X.Y.Z` and `X.Y`
- pull requests → build only (no push)

Only `linux/amd64` is built (the official engine is x86_64 only). To build
locally instead of pulling:

```sh
docker compose up -d --build
```

Details: [53 CI/CD](docs/50-59-development/53-ci-cd.md).

## Troubleshooting

- **No forwarded port** (`engine: no Gluetun forwarded port available yet`):
  plan without port forwarding, WireGuard config without NAT-PMP, or a
  server without support. Check `docker compose logs gluetun`.
- **NAT-PMP renewal errors** (`connection refused` / `i/o timeout` on
  `10.2.0.1:5351`): ProtonVPN gateways occasionally drop a renewal datagram;
  the pinned Gluetun build retries them instead of dropping the forwarded
  port.
- **Playlist 404 / empty**: first IPNS resolution can take minutes on a
  fresh Kubo repo. Check `docker compose logs kubo`; force a refresh with
  `docker compose restart acestream`.
- **DNS errors at first boot**: the sync starts before the VPN is ready;
  it retries every 60 s until one source is refreshed.
- **kubo unreachable from acestream**: `FIREWALL_OUTBOUND_SUBNETS` must
  match the compose subnet (`DOCKER_SUBNET`).
- **Streams fail from clients but work locally**: the client must reach
  `ACESTREAM_HTTP_PORT` on the host it fetched the playlist from.

More: [41 Common issues](docs/40-49-troubleshooting/41-common-issues.md) ·
[42 Diagnostics](docs/40-49-troubleshooting/42-diagnostics.md).

## Security notes

- `.env` holds `WG_PRIVATE_KEY`: gitignored, never commit or share it.
- The gluetun control server (`:8001`) is loopback-only inside the shared
  network namespace and is not published to the host.
- Ports 6878/8080 are published on the host without authentication; restrict
  them with a host firewall if you do not want them LAN-wide.
- The engine keeps a disk cache under `data/acestream/`; set
  `ACESTREAM_CACHE_LIMIT_GB=0` for RAM caching instead.

## Documentation

Full documentation lives in [`docs/`](docs/intro.md), organized with the
[Johnny Decimal](https://johnnydecimal.com/) scheme. Start at
[docs/intro.md](docs/intro.md):

| Topic | Document |
|-------|----------|
| Requirements | [11](docs/10-19-getting-started/11-requirements.md) |
| Installation | [12](docs/10-19-getting-started/12-installation.md) |
| Configuration | [13](docs/10-19-getting-started/13-configuration.md) |
| First run | [14](docs/10-19-getting-started/14-first-run.md) |
| Playlists | [21](docs/20-29-operation/21-playlists.md) |
| Clients | [22](docs/20-29-operation/22-clients.md) |
| Maintenance | [23](docs/20-29-operation/23-maintenance.md) |
| Architecture | [31](docs/30-39-architecture/31-architecture.md) |
| P2P port forwarding | [32](docs/30-39-architecture/32-p2p-port-forwarding.md) |
| Data layout | [33](docs/30-39-architecture/33-data-layout.md) |
| Common issues | [41](docs/40-49-troubleshooting/41-common-issues.md) |
| Diagnostics | [42](docs/40-49-troubleshooting/42-diagnostics.md) |
| Repository layout | [51](docs/50-59-development/51-repository-layout.md) |
| The acestream image | [52](docs/50-59-development/52-acestream-image.md) |
| CI/CD | [53](docs/50-59-development/53-ci-cd.md) |

## Legal

This notice governs the use of miniace and is drafted by reference to
Spanish law and applicable European Union law. By cloning, building,
deploying or otherwise using this software you accept it in full.

### 1. Project and scope

miniace is a self-hosted software project maintained under the GitHub
handle **BiquinisDonRodrigo**. It provides Docker configuration and
supporting code to run the AceStream engine, manage VPN connectivity and
process playlist sources configured by the operator.

An **operator** is the person or organisation that deploys, configures or
controls an instance of the software. The operator selects its sources,
manages its infrastructure and decides who can access its services.

The project publishes software and container images. It does not provide
subscriptions or grant access rights to audiovisual programming.

### 2. Lawful use and operator responsibility

**This repository does not host pirated audiovisual content or supply
unauthorised stream links or playlists. Contributions that facilitate
unlawful access to protected content are not permitted.**

The operator is responsible for the configuration and use of their
deployment, including the sources selected and any content accessed,
downloaded, stored, shared or made available through it.

Operators must ensure that these activities are authorised by the relevant
rights holders or otherwise permitted by applicable law. In Spain, this
includes the rules on copyright and related rights established by
[Royal Legislative Decree 1/1996, approving the Intellectual Property Law](https://www.boe.es/buscar/act.php?id=BOE-A-1996-8930).

The public availability of a URL, playlist, content identifier or hash
does not establish permission to use the associated content. Likewise,
permission to view content does not necessarily include permission to
retransmit it or make it available to others.

### 3. Peer-to-peer operation and third-party services

AceStream and IPFS use peer-to-peer technologies. Depending on their
operation and configuration, a deployment may receive, cache and upload
data to other participants. Operators must account for this sharing when
assessing their rights and obligations.

Using a VPN does not grant content rights or remove legal obligations.

Third-party software and services, including AceStream, Gluetun, Kubo and
the VPN provider, remain subject to their respective licences, terms and
privacy policies. Those conditions also apply where relevant components
are included in a container image.

### 4. Intellectual property and software licensing

Rights in the original miniace code and documentation belong to their
respective authors, including BiquinisDonRodrigo. Third-party code,
trademarks and other materials remain subject to the rights of their
respective owners.

Publication in a public repository does not place the software in the
public domain. Rights to use, reproduce, modify or redistribute software
depend on the permissions expressly granted, applicable platform terms and
statutory rights.

This notice does not replace a software licence, alter third-party licence
conditions or grant rights over audiovisual content, playlists or other
material processed by a deployment.

### 5. Responsibility for container use

By deploying, running or otherwise using a miniace container, **you assume
full and exclusive responsibility for your deployment and for everything
carried out with or through that container.**

This responsibility includes, without limitation:

- The configuration, security and access management of your deployment.
- The sources, playlists, content identifiers and services you configure.
- Content accessed, downloaded, cached, uploaded, retransmitted or made
  available through the container, including automatic peer-to-peer
  sharing.
- Compliance with applicable law, intellectual property rights and the
  terms governing the software and services you use.

You are responsible for the legal consequences of actions and omissions
attributable to you in connection with your deployment. The publication or
distribution of miniace does not mean that BiquinisDonRodrigo or the
contributors authorise, endorse or assume responsibility for those
activities.

To the maximum extent permitted by applicable law, the maintainer and
contributors disclaim liability arising from your use or misuse of the
container. This clause does not exclude liability that cannot lawfully be
excluded — such as liability for intentional wrongdoing, addressed by
[Article 1102 of the Spanish Civil Code](https://www.boe.es/buscar/act.php?id=BOE-A-1889-4763#art1102)
— or transfer responsibility for the maintainer's or contributors' own
acts or omissions to you. Mandatory consumer rights remain unaffected
wherever applicable, including those protected by
[Royal Legislative Decree 1/2007](https://www.boe.es/buscar/act.php?id=BOE-A-2007-20555).

### 6. Acceptance of third-party terms and licences

By running or using a miniace container that includes AceStream, you
acknowledge and accept the
[AceStream User Agreement](https://acestream.org/about/user-agreement)
insofar as it applies to your use, subject to applicable law. Running
AceStream inside a container does not waive or replace its applicable
terms.

You also agree to comply with the licences and terms applicable to the
other software and services included in, required by or used through your
deployment. These include:

- [Gluetun](https://github.com/passteque/gluetun/blob/master/LICENSE) (MIT).
- [Kubo](https://github.com/ipfs/kubo/blob/v0.43.0/LICENSE) (MIT /
  Apache-2.0).
- The operating-system packages, runtime, libraries and other dependencies
  included in the container images.
- Your VPN provider and any other external services you configure or use.

Before using a component or service, you must review the terms applicable
to the version and features you use and complete any acceptance procedure
required by its provider. If you do not accept terms required for your
intended use, you must not use the affected component or service.

Each component remains governed by its own licence. This notice does not
relicense third-party software, restrict rights granted by an applicable
open-source licence, or grant permissions that its rights holder has not
provided. Acceptance of software or service terms does not, by itself,
supply any separate consent required under data-protection law.

### 7. Warranties and limits of liability

To the maximum extent permitted by applicable law, the software is
provided **"as is" and "as available"**, without warranties of
uninterrupted operation, accuracy, security or fitness for a particular
purpose.

Subject to those legal limits, the maintainer and contributors disclaim
liability for loss or damage arising from an operator's unlawful use,
configuration choices or use of third-party content and services.

Nothing in this notice excludes liability that cannot lawfully be
excluded. Civil, criminal and administrative responsibility is determined
by applicable law and the conduct of each party; this notice does not
transfer responsibility for the maintainer's or contributors' own acts or
omissions to an operator.

### 8. Information-society services and intermediary liability

Where an activity falls within their scope,
[Law 34/2002 on information-society services and electronic commerce (LSSI-CE)](https://www.boe.es/buscar/act.php?id=BOE-A-2002-13758)
and [Regulation (EU) 2022/2065, the Digital Services Act](https://www.boe.es/buscar/doc.php?id=DOUE-L-2022-81573),
apply. Since 17 February 2024, the liability regime of the DSA (Articles
4–8) has replaced Articles 12–15 of Directive 2000/31/EC, to which
Articles 14–17 LSSI-CE correspond.

Any exemption or limitation of intermediary liability depends on the
actual activity performed and compliance with the relevant statutory
conditions — for example, Article 17 LSSI-CE requires diligent removal or
disabling of links upon effective knowledge of unlawfulness. Describing
software as a technical tool or referring to external sources does not, by
itself, establish entitlement to an exemption. Applicable duties to act
upon knowledge of unlawful content, comply with lawful orders or provide
identifying and contact information remain unaffected.

### 9. Privacy and personal data

Self-hosting does not mean that no personal data is processed. Network
connections, IP addresses, peer identifiers, requests and operational logs
may involve personal data. A deployment also communicates with third-party
services and peer networks, and can retain logs and cached data on the
operator's infrastructure.

Where [Regulation (EU) 2016/679 (GDPR)](https://www.boe.es/buscar/doc.php?id=DOUE-L-2016-80807)
and [Spanish Organic Law 3/2018 (LOPDGDD)](https://www.boe.es/buscar/act.php?id=BOE-A-2018-16673)
apply, the operator must fulfil the obligations corresponding to their
actual role. An operator determining the purposes and means of processing
personal data must meet the applicable controller obligations, including
lawful processing, transparency, security, retention limits and respect
for data-subject rights.

Each third-party provider remains responsible for its own applicable
obligations. Downloading or running the software does not constitute
consent to personal-data processing.

### 10. Reports, applicable law and updates

Concerns about material published in this repository may be reported
through the [project issue tracker](https://github.com/BiquinisDonRodrigo/miniace/issues).
Reports should identify the affected repository location and explain the
alleged infringement; they will be reviewed and appropriate action taken
where warranted. Issues are public — do not include confidential
information or unnecessary personal data.

This notice is drafted by reference to Spanish law and applicable European
Union law. Mandatory rules applicable in other jurisdictions, and the rules
determining applicable law and competent courts, remain unaffected.

Updates to this notice will be published in the repository. Publication of
an update does not, by itself, retroactively change previously granted
licence rights or waive mandatory statutory rights.

*This notice is provided for information and does not constitute legal
advice.*

## License

The original miniace code — the compose stack, the `acestream` image
scripts, and the repository documentation — is released under the
[MIT License](LICENSE) (© 2026 BiquinisDonRodrigo).

| Component | Licence / terms |
|-----------|-----------------|
| miniace original code | [MIT](LICENSE) |
| [AceStream](https://www.acestream.org/) engine | Proprietary — [User Agreement](https://acestream.org/about/user-agreement); official tarball, SHA256-pinned, not redistributed by this repository |
| [Gluetun](https://github.com/passteque/gluetun) | [MIT](https://github.com/passteque/gluetun/blob/master/LICENSE) |
| [Kubo (IPFS)](https://github.com/ipfs/kubo) | [MIT / Apache-2.0](https://github.com/ipfs/kubo/blob/v0.43.0/LICENSE) |
| `python:3.10-slim` base image and OS packages | Their respective licences |

miniace is an independent project and is not affiliated with, endorsed by,
or connected to the AceStream developers. All product names, trademarks
and registered trademarks are the property of their respective owners.

## Acknowledgements

- [gluetun](https://github.com/passteque/gluetun) — VPN tunneling and
  port forwarding.
- [Kubo](https://github.com/ipfs/kubo) — IPFS implementation powering the
  IPNS playlist resolution.
- [AceStream](https://www.acestream.org/) — the P2P streaming engine this
  stack orchestrates.

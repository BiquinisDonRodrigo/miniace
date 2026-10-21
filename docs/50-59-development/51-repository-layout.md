# 51 Repository layout

```text
.
├── docker-compose.yml            # the three-service stack
├── .env.example                  # template for .env (gitignored)
├── README.md                     # project overview
├── NOTICE                        # third-party notices (outpace / AGPL)
├── docs/                         # this documentation (Johnny Decimal)
├── data/                         # runtime data (gitignored)
├── images/
│   └── outpace/                  # the only custom image
│       ├── Dockerfile            # multi-arch outpace runtime + playlist sync
│       ├── entrypoint.sh         # container entrypoint
│       ├── outpace.sh            # port resolution + outpace supervisor
│       └── sync.py               # playlist sync + HTTP server
├── kubo/
│   └── 001-gateway-port.sh       # binds the Kubo gateway to 0.0.0.0:48080
└── .github/
    └── workflows/docker.yml      # CI: build and publish the multi-arch image
```

Tracked vs ignored:

| Path | Tracked in git |
|---|---|
| `docker-compose.yml`, `.env.example`, `README.md`, `NOTICE`, `docs/` | yes |
| `images/`, `kubo/`, `.github/` | yes |
| `.env` | no |
| `data/` | no (entirely) |

Where to look next:

- Change the stack → [13 Configuration](../10-19-getting-started/13-configuration.md)
- Work on the image → [52 The engine image](52-engine-image.md)
- CI and releases → [53 CI/CD](53-ci-cd.md)

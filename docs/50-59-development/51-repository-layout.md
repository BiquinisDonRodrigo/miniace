# 51 Repository layout

```text
.
├── docker-compose.yml            # the three-service stack
├── .env.example                  # template for .env (gitignored)
├── README.md                     # project overview
├── docs/                         # this documentation (Johnny Decimal)
├── data/                         # runtime data (gitignored)
├── images/
│   └── acestream/                # the only custom image
│       ├── Dockerfile            # engine tarball + pinned Python deps
│       ├── entrypoint.sh         # container entrypoint
│       ├── engine.sh             # port resolution + engine supervisor
│       ├── sync.py               # playlist sync + HTTP server
│       └── requirements.txt      # pinned engine Python dependencies
├── kubo/
│   └── 001-gateway-port.sh       # binds the Kubo gateway to 0.0.0.0:48080
└── .github/
    └── workflows/docker.yml      # CI: build and publish the image
```

Tracked vs ignored:

| Path | Tracked in git |
|---|---|
| `docker-compose.yml`, `.env.example`, `README.md`, `docs/` | yes |
| `images/`, `kubo/`, `.github/` | yes |
| `.env` | no |
| `data/` | no (entirely) |

Where to look next:

- Change the stack → [13 Configuration](../10-19-getting-started/13-configuration.md)
- Work on the image → [52 The acestream image](52-acestream-image.md)
- CI and releases → [53 CI/CD](53-ci-cd.md)

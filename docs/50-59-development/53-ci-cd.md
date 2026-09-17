# 53 CI/CD

`.github/workflows/docker.yml` builds `images/acestream` and publishes it
to GHCR as `ghcr.io/biquinisdonrodrigo/miniace`.

## Triggers

| Event | Result |
|---|---|
| Push to `main` | Build and push `latest` + `sha-<short>` |
| Tag `vX.Y.Z` | Build and push `X.Y.Z` and `X.Y` (semver tags) |
| Pull request touching `images/acestream/**` or the workflow | Build only, no push |
| `workflow_dispatch` | Manual build |

Concurrency cancels in-progress runs for the same ref.

## Details

- Runs on `ubuntu-latest` with Buildx; only `linux/amd64` is built (the
  engine is x86_64-only).
- Pushes with the workflow `GITHUB_TOKEN` (`packages: write`); pull
  requests never push.
- Layer cache: GitHub Actions cache (`type=gha`, `mode=max`).
- OCI labels point back to the repository.

## Consuming the image

`docker-compose.yml` references
`ghcr.io/biquinisdonrodrigo/miniace:latest` **and** declares
`build: ./images/acestream`, so a local `docker compose build` overrides
the registry image.

The package is **private by default**. Either make it public (GitHub →
Packages → miniace → Package settings) or authenticate:

```sh
echo "$GHCR_PAT" | docker login ghcr.io -u <user> --password-stdin
docker compose pull
```

## Release checklist

1. Merge to `main`; CI publishes `latest`.
2. Tag and push: `git tag vX.Y.Z && git push origin vX.Y.Z`; CI publishes
   `X.Y.Z` and `X.Y`.
3. Optionally pin the new version in `docker-compose.yml` and
   `.env.example` comments.

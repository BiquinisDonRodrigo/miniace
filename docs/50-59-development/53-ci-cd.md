# 53 CI/CD

`.github/workflows/docker.yml` builds `images/outpace` and publishes it
to GHCR as `ghcr.io/biquinisdonrodrigo/miniace`.

## Triggers

| Event | Result |
|---|---|
| Push to `main` | Build and push `latest` + `sha-<short>` |
| Tag `vX.X.X` | Build and push `X.X.X` and `X.Y` (semver tags) |
| Pull request touching `images/outpace/**` or the workflow | Build only, no push |
| `workflow_dispatch` | Manual build |

Concurrency cancels in-progress runs for the same ref.

## Details

- Runs on `ubuntu-latest` with Buildx and QEMU.
- Builds and publishes a single multi-arch manifest for
  `linux/amd64`, `linux/arm64` and `linux/arm/v7`.
- Pushes with the workflow `GITHUB_TOKEN` (`packages: write`); pull
  requests never push.
- Layer cache: GitHub Actions cache (`type=gha`, `mode=max`).
- OCI labels point back to the repository.

The outpace binary is copied from its official image, so ARM builds do not
compile Rust or install the engine's Python dependencies; only the small
`apt-get` layer runs under QEMU.

## Consuming the image

`docker-compose.yml` references
`ghcr.io/biquinisdonrodrigo/miniace:latest` **and** declares
`build: ./images/outpace`, so a local `docker compose build` overrides
the registry image. The package is public: pulling it requires no
authentication.

Docker automatically selects the manifest that matches the host
architecture; an ARM host pulls the arm64/armv7 variant of the same tag.

## Release checklist

1. Merge to `main`; CI publishes `latest`.
2. Tag and push: `git tag vX.Y.Z && git push origin vX.Y.Z`; CI publishes
   `X.Y.Z` and `X.Y`.
3. Optionally pin the new version in `docker-compose.yml` and
   `.env.example` comments.
4. When bumping the outpace digest in the Dockerfile, run the multi-arch
   build and the validation checklist in
   [52 The engine image](52-engine-image.md#validation-checklist) before
   publishing.

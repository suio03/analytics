# Production deployment

The release branch is `custom/v2.1.5`. GitHub Actions builds AMD64 and ARM64 images in `ghcr.io/suio03/plausible-custom`.

Production runs in Dokploy Cloud, Banjo → production → plausible, using Raw Compose on Hetzner. The service is `banjo-plausible-qew37p` (Compose ID `WZNVztZpF1tgPuMZuf8ym`).

## Automatic deployment setup

The workflow's deployment job needs the repository secret `DOKPLOY_DEPLOY_WEBHOOK`, containing this service's existing deployment webhook URL. Keep the URL out of repository files and logs. Autodeploy must remain enabled in Dokploy.

The `plausible` service is configured with:

```yaml
image: ghcr.io/suio03/plausible-custom:v2.1.5-production
pull_policy: always
```

The deploy job waits for successful Elixir CI on the same commit and checks the release branch head. It promotes the commit-specific image to the production tag, then triggers Dokploy. The production tag is separate from the build tag so a failed CI run cannot promote an image. Dokploy must pull on each deployment to avoid reusing a cached tag. A successful webhook response means deployment was accepted; verify Dokploy's deployment result and application availability separately.

For rollback, change only the application image to a previous `v2.1.5-custom-<sha>` tag and deploy. Preserve database services, environment, and volumes.

## Last verified manual deployment

On 2026-09-09, `v2.1.5-custom-a98410b` replaced `v2.1.5-custom-40eab1c`. Dokploy reported Done and the application container started. The deployment webhook secret and production-tag Compose configuration were enabled with user approval on the same day. The first automated run must be checked in GitHub Actions and Dokploy.

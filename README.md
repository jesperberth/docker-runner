# docker-runner

Update __docker-compose.yml__ with your GitHub URL and credentials.

Credentials:

- `GITHUB_TOKEN`: short-lived runner registration token from GitHub settings.
- `GITHUB_PAT` (optional): PAT that the container exchanges into registration/remove tokens.
	- Repo runner URL (`https://github.com/<owner>/<repo>`): PAT must have repo admin access.
	- Org runner URL (`https://github.com/<org>`): PAT must include `admin:org`.

If you see `404 Not Found` during registration, it is usually one of these:

- `GITHUB_URL` points to the wrong scope (repo vs org).
- PAT permissions are missing.
- A PAT was put in `GITHUB_TOKEN` and was not exchanged first (now supported by `entrypoint.sh`).

```bash
# Build the runner image
docker compose build

# Scale to N parallel runners
docker compose up -d --scale runner=4
```

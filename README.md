# docker-runner

Update __docker-compose.yml__ with GitHub URL and GitHub Token

```bash
# Build the runner image
docker compose build

# Scale to N parallel runners
docker compose up -d --scale runner=4
```

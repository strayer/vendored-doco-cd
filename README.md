# vendored-doco-cd

This repository is used to build a trusted Docker image for the `doco-cd` GitOps software using vendored source code.

## Docker Images

Tagged images are built and published to GitHub Container Registry:

- `ghcr.io/strayer/doco-cd:latest` - Latest version
- `ghcr.io/strayer/doco-cd:v{version}` - Specific version tags (e.g., `v0.34.0`)

## Workflows

### Sync Vendor Code

The **Sync Vendor Code** workflow (`.github/workflows/sync-code.yml`) automatically syncs source code from the upstream repository when the `.doco-cd-version` file is updated in a pull request:

- Triggers on changes to `.doco-cd-version` in pull requests
- Downloads and extracts source code from the upstream repository tag
- Validates the version format and extracted files
- Commits the synced source code automatically

### Build and Publish Image

The **Build and Publish Image** workflow (`.github/workflows/build-publish.yml`) builds and publishes Docker images when changes are pushed to the main branch:

- Builds multi-platform images (linux/amd64, linux/arm64)
- Tags images with both version-specific and `latest` tags
- Publishes to GitHub Container Registry (`ghcr.io/strayer/doco-cd`)

## Code Vendoring and Licensing

The source code for `doco-cd` is vendored into the `doco-cd-src/` directory directly from the official upstream repository for security review and building.

The original project is available here:

- **Upstream Repository:** https://github.com/kimdre/doco-cd

The `doco-cd` project is licensed under the Apache 2.0 License. In accordance with its terms, the original `LICENSE` and `NOTICE` files are preserved within the `doco-cd-src/` directory. The build scripts in this repository are also licensed under the Apache 2.0 License.

## AI Usage Notice

To ensure the responsible use of AI, this project adheres to a strict policy of human oversight. While a Large Language Model (LLM) is used as an assistive tool, its role is limited to implementation based on human-led design. Every line of AI-generated code is then manually reviewed and validated for correctness, security, and quality before being accepted into the codebase. The final authority and accountability for the code rests with the human developer.


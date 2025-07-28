Of course. Here is the complete, final, copy-pasteable task description with all the details filled in.

---

### **Task: Implement a Vendoring Workflow for the `doco-cd` GitOps Tool**

**Goal:**
To establish a secure and reviewable process for building our own Docker images of the `doco-cd` GitOps software. The process must reuse the official upstream `Dockerfile` and build logic as closely as possible to ensure our builds are consistent with the official releases we are mirroring. This is a security measure to allow code review before deployment.

**Upstream Project:** [https://github.com/kimdre/doco-cd](https://github.com/kimdre/doco-cd)
**License:** Apache 2.0

---

### **Acceptance Criteria (AC):**

1.  A new GitHub repository is created to house the vendoring process and build workflows.
2.  Renovate is configured to monitor the upstream `doco-cd` repository for new releases and open PRs to update a version file.
3.  A GitHub Action automatically syncs the new source code (including the upstream `Dockerfile`) into the Renovate PR branch, providing a clean, reviewable diff of the code changes.
4.  **[Compliance]** The builder repository's `README.md` file clearly states that it vendors code from the upstream project and provides a link. The repository root contains a copy of the Apache 2.0 `LICENSE` file.
5.  Upon merging a PR to the `main` branch, a separate GitHub Action is triggered that:
    - Builds a new Docker image **using the `Dockerfile` vendored inside the `doco-cd-src/` directory**.
    - Injects the correct version string (`v0.31.1`, etc.) into the build via `build-args`.
    - Tags the image with multiple relevant tags (e.g., `v0.31.1`, `v0.31`, `v0`, `latest`).
    - Pushes the image to our organization's GitHub Container Registry (GHCR).

---

### **Technical Implementation Plan:**

#### **Step 1: Repository Setup & Compliance**

1.  Create a new GitHub repository (e.g., `our-org/doco-cd-builder`).
2.  In the repository root, create a `LICENSE` file containing the standard [Apache 2.0 License text](https://www.apache.org/licenses/LICENSE-2.0.txt).
3.  In the repository root, create a `README.md` file with the following content:

    ```markdown
    # Builder for Our `doco-cd` Instance

    This repository is used to build a trusted Docker image for the `doco-cd` GitOps software.

    ## Code Vendoring and Licensing

    The source code for `doco-cd` is vendored into the `doco-cd-src/` directory directly from the official upstream repository for security review and building.

    The original project is available here:

    - **Upstream Repository:** https://github.com/kimdre/doco-cd

    The `doco-cd` project is licensed under the Apache 2.0 License. In accordance with its terms, the original `LICENSE` and `NOTICE` files are preserved within the `doco-cd-src/` directory. Our build scripts in this repository are also licensed under the Apache 2.0 License.
    ```

4.  Create the following initial file structure and commit it to the `main` branch:

    ```
    .
    ├── .doco-cd-version
    ├── .github/
    │   └── workflows/
    ├── doco-cd-src/
    │   └── .gitkeep
    ├── LICENSE
    ├── README.md
    └── renovate.json
    ```

5.  Set the content of `.doco-cd-version` to: `v0.31.1`
6.  Set the content of `renovate.json` to:

    ```json
    {
      "$schema": "https://docs.renovatebot.com/renovate-schema.json",
      "extends": ["config:base"],
      "regexManagers": [
        {
          "fileMatch": ["^\\.doco-cd-version$"],
          "matchStrings": ["^v(?<currentValue>[0-9]+\\.[0-9]+\\.[0-9]+)$"],
          "depNameTemplate": "kimdre/doco-cd",
          "datasourceTemplate": "github-releases"
        }
      ]
    }
    ```

#### **Step 2: Create the Source Code Sync Workflow**

1.  Create a file at `.github/workflows/sync-code.yml` with the following content:

    ```yaml
    name: Sync Vendor Code
    on:
      pull_request:
    jobs:
      sync:
        if: "startsWith(github.head_ref, 'renovate/')"
        runs-on: ubuntu-latest
        steps:
          - name: Checkout PR branch
            uses: actions/checkout@v4
            with:
              ref: ${{ github.head_ref }}
          - name: Get Target Version
            id: get_version
            run: |
              VERSION=$(cat .doco-cd-version)
              echo "Target version from file: ${VERSION}"
              echo "tag=${VERSION}" >> $GITHUB_OUTPUT
          - name: Sync Source Code
            run: |
              TARGET_DIR="doco-cd-src"
              UPSTREAM_REPO="kimdre/doco-cd"
              VERSION_TAG="${{ steps.get_version.outputs.tag }}"
              echo "Cleaning old code from ${TARGET_DIR}"
              rm -rf "${TARGET_DIR:?}"/* .[!.]* || true
              mkdir -p "${TARGET_DIR}"
              echo "Downloading source for tag ${VERSION_TAG} from ${UPSTREAM_REPO}"
              curl -sL "https://github.com/${UPSTREAM_REPO}/archive/refs/tags/${VERSION_TAG}.tar.gz" | \
              tar -xz --strip-components=1 -C "${TARGET_DIR}"
          - name: Commit and Push Changes
            run: |
              git config user.name "github-actions[bot]"
              git config user.email "github-actions[bot]@users.noreply.github.com"
              if git diff --quiet --exit-code; then
                echo "No source code changes detected. Nothing to commit."
                exit 0
              fi
              echo "Committing updated source code..."
              git add doco-cd-src/
              git commit -m "[Auto] Sync source code for ${{ steps.get_version.outputs.tag }}"
              git push
    ```

#### **Step 3: Create the Build & Publish Workflow**

1.  Create a file at `.github/workflows/build-publish.yml` with the following content. **Note:** The `images:` line must be updated with the correct organization/user name.

    ```yaml
    name: Build and Publish Image
    on:
      push:
        branches:
          - main
    jobs:
      build-and-push:
        runs-on: ubuntu-latest
        permissions:
          contents: read
          packages: write
        steps:
          - name: Checkout repository
            uses: actions/checkout@v4
          - name: Log in to the GitHub Container Registry
            uses: docker/login-action@v3
            with:
              registry: ghcr.io
              username: ${{ github.actor }}
              password: ${{ secrets.GITHUB_TOKEN }}
          - name: Set up QEMU for multi-platform builds
            uses: docker/setup-qemu-action@v3
          - name: Set up Docker Buildx
            uses: docker/setup-buildx-action@v3
          - name: Get image version from file
            id: get_version
            run: echo "tag=$(cat .doco-cd-version)" >> $GITHUB_OUTPUT
          - name: Extract metadata for the Docker image
            id: meta
            uses: docker/metadata-action@v5
            with:
              # <!-- DEVELOPER: Update with your org/user name -->
              images: ghcr.io/your-org-name/doco-cd
              tags: |
                type=semver,pattern={{version}},value=${{ steps.get_version.outputs.tag }}
                type=semver,pattern={{major}}.{{minor}},value=${{ steps.get_version.outputs.tag }}
                type=semver,pattern={{major}},value=${{ steps.get_version.outputs.tag }}
                type=raw,value=latest
          - name: Build and push image using upstream Dockerfile
            uses: docker/build-push-action@v6
            with:
              context: ./doco-cd-src
              push: true
              build-args: |
                APP_VERSION=${{ steps.get_version.outputs.tag }}
              tags: ${{ steps.meta.outputs.tags }}
              labels: ${{ steps.meta.outputs.labels }}
              platforms: linux/amd64,linux/arm64
              cache-from: type=registry,ref=${{ steps.meta.outputs.images[0] }}:buildcache
              cache-to: type=registry,ref=${{ steps.meta.outputs.images[0] }}:buildcache,mode=max
    ```

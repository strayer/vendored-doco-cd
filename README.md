# Builder for Our `doco-cd` Instance

This repository is used to build a trusted Docker image for the `doco-cd` GitOps software.

## Code Vendoring and Licensing

The source code for `doco-cd` is vendored into the `doco-cd-src/` directory directly from the official upstream repository for security review and building.

The original project is available here:

- **Upstream Repository:** https://github.com/kimdre/doco-cd

The `doco-cd` project is licensed under the Apache 2.0 License. In accordance with its terms, the original `LICENSE` and `NOTICE` files are preserved within the `doco-cd-src/` directory. Our build scripts in this repository are also licensed under the Apache 2.0 License.
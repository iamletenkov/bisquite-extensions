# Changelog

## [3.1.0](https://github.com/iamletenkov/bisquite-extensions/compare/v3.0.0...v3.1.0) (2026-10-15)


### Добавлено

* **can:** arm64 and L4T kernels are checked without linux-modules-extra ([390643d](https://github.com/iamletenkov/bisquite-extensions/commit/390643d0df657fc58c414f74cc97dfb4ed93b695))
* **rustdesk:** arm64 installs the aarch64 release package with its own pinned sha256 ([58ddcfa](https://github.com/iamletenkov/bisquite-extensions/commit/58ddcfa2eae9a3f4e43d24bc3f6cd820510978e6))


### Исправлено

* **firewall:** refuse an image kernel without nft_ct instead of booting unfiltered ([1b79f87](https://github.com/iamletenkov/bisquite-extensions/commit/1b79f87fe1e2764c6599dc082e3a3e970f9ca281))

## [3.0.0](https://github.com/iamletenkov/bisquite-extensions/compare/v2.0.0...v3.0.0) (2026-10-14)


### ⚠ BREAKING CHANGES

* **nvidia:** Ubuntu 20.04 dropped; a missing branch is a build error.

### Добавлено

* **can:** CAN modules for the image kernel, can-utils and autoload list ([8885cca](https://github.com/iamletenkov/bisquite-extensions/commit/8885cca81fb1242895dcf792ecf64214bc5d977d))
* **firewall:** nftables table inet bisquite rebuilt on every boot, Docker chains untouched ([c8d91d5](https://github.com/iamletenkov/bisquite-extensions/commit/c8d91d54f887023f99aa5f6333e8108c6f5a7a4d))
* **locale:** system locale and keyboard layouts for console, Xorg/GDM and GNOME ([3dc3397](https://github.com/iamletenkov/bisquite-extensions/commit/3dc33970fcb23d456fb6e22fc52cc304704ba903))
* **nvidia:** 2.0.0 — pinned driver branch built for the image kernel; add nvidia-container-toolkit 1.0.0 ([4bf2c86](https://github.com/iamletenkov/bisquite-extensions/commit/4bf2c864e0d3ecb10f6c99a66f2c44f162004d9f))
* robot workstation extensions — nvidia 2.0, container toolkit, can, firewall, locale, rustdesk ([5a03da3](https://github.com/iamletenkov/bisquite-extensions/commit/5a03da3f3d467073b51b9a400d8e02c472ff5eae))
* **rustdesk:** pinned .deb, server settings rendered per device, no identity in the image ([464bc09](https://github.com/iamletenkov/bisquite-extensions/commit/464bc09c22d63cd7b610423163b6a07897745aa3))
* **teleport-agent:** 3.1.0 pins bisquite-teleport-agent 3.1.0 ([6ffd94f](https://github.com/iamletenkov/bisquite-extensions/commit/6ffd94f26fa1cb7b8f8b856b209a93bd4f52fc58))
* **teleport-agent:** 3.1.0 pins bisquite-teleport-agent 3.1.0 — join waits for the network and retries ([a4190ad](https://github.com/iamletenkov/bisquite-extensions/commit/a4190ad568f65c52fb4c19fb183cb2a2af2171fb))


### Исправлено

* **firefox:** trust only the pinned Mozilla key, not every key in the downloaded file ([06a3680](https://github.com/iamletenkov/bisquite-extensions/commit/06a36806e847df24c4401a594bb7264eb7d36394))
* **locale:** typed empty xkb-options so dconf update accepts the GNOME defaults ([7d20348](https://github.com/iamletenkov/bisquite-extensions/commit/7d20348e0b0f7a17db315d3a022acb7a9db94d8a))
* **nvidia-container-toolkit:** a missing daemon.json is not a default-runtime change ([80b9009](https://github.com/iamletenkov/bisquite-extensions/commit/80b9009ea988682ccaad08aad56a5704f1f3897c))
* **nvidia:** name an OOM-killed DKMS build and the --memsize that fixes it ([25246fa](https://github.com/iamletenkov/bisquite-extensions/commit/25246fac5d1db6d824cdae4d603cfa57be47d220))
* **nvidia:** trust only the pinned repository key, not every key in the downloaded file ([212cd44](https://github.com/iamletenkov/bisquite-extensions/commit/212cd441a5470c66c5f9e23d921c291d4f7fe57f))
* **rustdesk:** re-check the rendered server settings after RustDesk's first run ([b889084](https://github.com/iamletenkov/bisquite-extensions/commit/b88908409480ad2b4a56da90589eb6aab09c9e4e))

# HarmoNiLink Makefile — GNU/Linux + DevEco CLI only
#
# Targets API 24 (build-profile.json5); CLT bundles are single-SDK, so the
# toolchain is auto-discovered below by SDK metadata — NOT taken from
# $OHOS_CLI_HOME (the shell may export the API-26 preview line, which cannot
# build or sign this project). Requires an apiVersion-24 bundle under
# ~/.local/share/harmonyos/cli-tools-* and `@ohos:registry=...` in ~/.npmrc;
# both are enforced with clear errors.

OS := $(shell uname -s)
ifeq ($(OS),Linux)
else
  $(error This Makefile requires GNU/Linux (detected: $(OS)))
endif

ENV_OK := $(shell command -v hvigorw >/dev/null 2>&1 && echo yes || echo no)
ifeq ($(ENV_OK),no)
  $(error hvigorw not found on PATH — check DevEco CLI installation)
endif

# Toolchain root: the API-24 Release SDK lives in its own CLT bundle (NOT the
# API-26 preview line pointed to by ~/.local/share/harmonyos/.current).
# Scan cli-tools-* for the bundle whose SDK reports apiVersion 24 and pin it
# (deliberate := override: a shell-exported OHOS_CLI_HOME may point at the
# API-26 preview line, which CANNOT build this project).
OHOS_ROOT := $(HOME)/.local/share/harmonyos
OHOS_CLI_HOME := $(shell for d in $(OHOS_ROOT)/cli-tools-*; do \
  grep -q '"apiVersion": "24"' "$$d/command-line-tools/sdk/default/sdk-pkg.json" 2>/dev/null && { echo $$d; break; }; done)
ifeq ($(strip $(OHOS_CLI_HOME)),)
  $(error No CLI bundle with API 24 SDK found under $(OHOS_ROOT)/cli-tools-* — install one or edit OHOS_CLI_HOME in this Makefile)
endif
export OHOS_CLI_HOME

# Scoped registry check: @ohos/* packages live only on Huawei's registry.
NPMRC_OK := $(shell grep -q '^@ohos:registry=' $(HOME)/.npmrc 2>/dev/null && echo yes || echo no)
ifeq ($(NPMRC_OK),no)
  $(error Missing '@ohos:registry=https://repo.harmonyos.com/npm/' in ~/.npmrc — hvigor cannot fetch @ohos/* deps without it)
endif
CLI_SDK := $(OHOS_CLI_HOME)/command-line-tools/sdk
export NODE_HOME ?= $(OHOS_CLI_HOME)/command-line-tools/tool/node
export PATH    := $(OHOS_CLI_HOME)/command-line-tools/bin:$(PATH)

HVIGORW := hvigorw
TOOL    := $(CLI_SDK)/default/openharmony/toolchains/lib/hap-sign-tool.jar
OUT     := build/outputs/default
HAP     := $(OUT)/HarmoNiLink-default-signed.hap
APP     := $(OUT)/HarmoNiLink-default-signed.app
U_HAP   := entry/build/default/outputs/default/entry-default-unsigned.hap
U_APP   := $(OUT)/HarmoNiLink-default-unsigned.app

.PHONY: all build hap app sign clean clean-old-artifacts

all: build

build: hap app

hap: clean-old-artifacts
	$(HVIGORW) assembleHap --mode module -p module=entry@default -p product=default

app: clean-old-artifacts
	$(HVIGORW) assembleApp -p product=default

sign: clean-old-artifacts
	@bash sign.sh

clean:
	rm -rf build/ entry/build/ .hvigor/ entry/.cxx
	@echo "Cleaned."

# 每次构建前清理旧产物，避免误装/误用上次生成的包（尤其是已签名的）
clean-old-artifacts:
	rm -rf build/outputs
	rm -f entry/build/default/outputs/default/*.hap

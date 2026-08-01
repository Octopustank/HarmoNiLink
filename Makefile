# HarmoNiLink Makefile — GNU/Linux + DevEco CLI only

OS := $(shell uname -s)
ifeq ($(OS),Linux)
else
  $(error This Makefile requires GNU/Linux (detected: $(OS)))
endif

ENV_OK := $(shell command -v hvigorw >/dev/null 2>&1 && echo yes || echo no)
ifeq ($(ENV_OK),no)
  $(error hvigorw not found on PATH — check DevEco CLI installation)
endif

export OHOS_CLI_HOME ?= $(HOME)/Repo/InstallPackage/harmony-cli-tools
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

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

.PHONY: all build hap app sign clean

all: build

build: hap app

hap:
	$(HVIGORW) assembleHap --mode module -p module=entry@default -p product=default

app:
	$(HVIGORW) assembleApp -p product=default

sign:
	@if [ ! -f .env ]; then echo "ERROR: .env not found (cp .env.example .env)"; exit 1; fi
	@if [ ! -f "$(TOOL)" ]; then echo "ERROR: $(TOOL) not found"; exit 1; fi
	@set -a; . ./.env; set +a; \
	if [ -z "$$SIGN_KEYSTORE_PASS" ]; then echo "ERROR: SIGN_KEYSTORE_PASS empty"; exit 1; fi; \
	echo ">>> 1/4 Build HAP (release)"; \
	$(HVIGORW) assembleHap --mode module -p module=entry@default -p product=default -p buildMode=release || exit 1; \
	echo ">>> 2/4 Sign HAP"; \
	java -jar $(TOOL) sign-app -mode localSign \
		-keyAlias "$${SIGN_KEY_ALIAS:-HarmoNiLink-Release}" \
		-keyPwd "$$SIGN_KEYSTORE_PASS" \
		-appCertFile "$${SIGN_CERT_FILE:-./signing/Release_Cert.cer}" \
		-profileFile "$${SIGN_PROFILE_FILE:-./signing/NiLink_ProfileRelease.p7b}" \
		-inFile $(U_HAP) \
		-signAlg "$${SIGN_ALG:-SHA256withECDSA}" \
		-keystoreFile "$${SIGN_KEYSTORE_FILE:-./signing/HarmoNiLink.p12}" \
		-keystorePwd "$$SIGN_KEYSTORE_PASS" \
		-outFile $(U_HAP:.hap=-signed.hap) \
		-compatibleVersion "$${SIGN_COMPAT_VERSION:-23}" -signCode 1 || exit 1; \
	echo ">>> 3/4 Build APP (release) + repack"; \
	$(HVIGORW) assembleApp -p product=default -p buildMode=release || exit 1; \
	TMP=$$(mktemp -d); \
	unzip -o "$(CURDIR)/$(U_APP)" -d $$TMP >/dev/null; \
	cp $(U_HAP:.hap=-signed.hap) $$TMP/entry-default.hap; \
	cd $$TMP && zip -qr unsigned-repacked.app . && cd $(CURDIR); \
	echo ">>> 4/4 Sign APP"; \
	java -jar $(TOOL) sign-app -mode localSign \
		-keyAlias "$${SIGN_KEY_ALIAS:-HarmoNiLink-Release}" \
		-keyPwd "$$SIGN_KEYSTORE_PASS" \
		-appCertFile "$${SIGN_CERT_FILE:-./signing/Release_Cert.cer}" \
		-profileFile "$${SIGN_PROFILE_FILE:-./signing/NiLink_ProfileRelease.p7b}" \
		-inFile $$TMP/unsigned-repacked.app \
		-signAlg "$${SIGN_ALG:-SHA256withECDSA}" \
		-keystoreFile "$${SIGN_KEYSTORE_FILE:-./signing/HarmoNiLink.p12}" \
		-keystorePwd "$$SIGN_KEYSTORE_PASS" \
		-outFile $(APP) \
		-compatibleVersion "$${SIGN_COMPAT_VERSION:-23}" -signCode 1 || exit 1; \
	rm -rf $$TMP; \
	cp $(U_HAP:.hap=-signed.hap) $(HAP); \
	ls -lh $(HAP) $(APP)

clean:
	rm -rf build/ entry/build/ .hvigor/ entry/.cxx
	@echo "Cleaned."

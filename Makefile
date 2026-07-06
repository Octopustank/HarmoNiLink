# HarmoNiLink Makefile — GNU/Linux + DevEco CLI only
#
# Requires official HarmonyOS CLI environment:
#   export OHOS_CLI_HOME="/path/to/harmony-cli-tools"
#   export PATH="$OHOS_CLI_HOME/command-line-tools/bin:$PATH"
#   (plus SDK and Node paths — see Huawei docs for full setup)

OS := $(shell uname -s)
ifeq ($(OS),Linux)
  # OK
else
  $(error This Makefile requires GNU/Linux (detected: $(OS)))
endif

ENV_OK := $(shell command -v hvigorw >/dev/null 2>&1 && echo yes || echo no)
ifeq ($(ENV_OK),no)
  $(error hvigorw not found on PATH — check DevEco CLI installation)
endif

HVIGORW := hvigorw
TOOL    := $(OHOS_SDK_HOME)/default/openharmony/toolchains/lib/hap-sign-tool.jar
OUT     := build/outputs/default
HAP     := $(OUT)/HarmoNiLink-default-signed.hap
APP     := $(OUT)/HarmoNiLink-default-signed.app
U_HAP   := entry/build/default/outputs/default/entry-default-unsigned.hap
U_APP   := $(OUT)/HarmoNikon-default-unsigned.app

.PHONY: all build hap app sign clean

all: build

build: hap app

hap:
	$(HVIGORW) assembleHap --mode module -p module=entry@default -p product=default

app:
	$(HVIGORW) assembleApp -p product=default

sign:
	@if [ ! -f .env ]; then echo "ERROR: .env not found (copy .env.example)"; exit 1; fi
	@if [ ! -f "$(TOOL)" ]; then echo "ERROR: $(TOOL) not found — check OHOS_SDK_HOME"; exit 1; fi
	@eval $$(grep -v '^#' .env | sed 's/^/export /'); \
	if [ -z "$$SIGN_KEYSTORE_PASS" ]; then echo "ERROR: SIGN_KEYSTORE_PASS empty in .env"; exit 1; fi; \
	$(HVIGORW) assembleHap --mode module -p module=entry@default -p product=default; \
	java -jar $(TOOL) sign-app -mode localSign \
		-keyAlias "$${SIGN_KEY_ALIAS:-HarmoNiLink-Release}" \
		-keyPwd "$$SIGN_KEYSTORE_PASS" \
		-appCertFile "$${SIGN_CERT_FILE:-./signing/Release_Cert.cer}" \
		-profileFile "$${SIGN_PROFILE_FILE:-./signing/HarmoNiLinkRelease.p7b}" \
		-inFile $(U_HAP) \
		-signAlg "$${SIGN_ALG:-SHA256withECDSA}" \
		-keystoreFile "$${SIGN_KEYSTORE_FILE:-./signing/HarmoNiLink.p12}" \
		-keystorePwd "$$SIGN_KEYSTORE_PASS" \
		-outFile entry/build/default/outputs/default/entry-default-signed.hap \
		-compatibleVersion "$${SIGN_COMPAT_VERSION:-23}" -signCode 1; \
	$(HVIGORW) assembleApp -p product=default; \
	TMP=$$(mktemp -d); cd $$TMP; \
		unzip -o "$(CURDIR)/$(U_APP)" >/dev/null; \
		cp "$(CURDIR)/entry/build/default/outputs/default/entry-default-signed.hap" ./entry-default.hap; \
		zip -qr unsigned-repacked.app .; \
		cd $(CURDIR); \
		java -jar $(TOOL) sign-app -mode localSign \
			-keyAlias "$${SIGN_KEY_ALIAS:-HarmoNiLink-Release}" \
			-keyPwd "$$SIGN_KEYSTORE_PASS" \
			-appCertFile "$${SIGN_CERT_FILE:-./signing/Release_Cert.cer}" \
			-profileFile "$${SIGN_PROFILE_FILE:-./signing/HarmoNiLinkRelease.p7b}" \
			-inFile $$TMP/unsigned-repacked.app \
			-signAlg "$${SIGN_ALG:-SHA256withECDSA}" \
			-keystoreFile "$${SIGN_KEYSTORE_FILE:-./signing/HarmoNiLink.p12}" \
			-keystorePwd "$$SIGN_KEYSTORE_PASS" \
			-outFile $(APP) \
			-compatibleVersion "$${SIGN_COMPAT_VERSION:-23}" -signCode 1; \
		rm -rf $$TMP; \
	cp entry/build/default/outputs/default/entry-default-signed.hap $(HAP); \
	ls -lh $(HAP) $(APP)

clean:
	rm -rf build/ entry/build/ .hvigor/ entry/.cxx
	@echo "Cleaned."

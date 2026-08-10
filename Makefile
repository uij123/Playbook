.PHONY: all native cli bundle signing-setup doctor clean

all: native cli

native:
	cd native && swift build -c release

cli:
	cd cli && npm install --no-fund --no-audit && npm run build

# One-time per machine: create a stable code-signing identity so macOS
# permission grants to pb-record.app survive rebuilds (no re-granting).
signing-setup:
	./scripts/setup-signing.sh

# Package pb-record as a standalone signed .app so on-device voice narration
# works (see scripts/build-app.sh). Uses the stable identity if signing-setup
# has been run; otherwise ad-hoc (grants reset each rebuild).
bundle: native
	./scripts/build-app.sh

doctor: all
	./pb doctor

clean:
	rm -rf native/.build cli/dist cli/node_modules

.PHONY: all native cli bundle doctor clean

all: native cli

native:
	cd native && swift build -c release

cli:
	cd cli && npm install --no-fund --no-audit && npm run build

# Package pb-record as a standalone signed .app so on-device voice narration
# works (see scripts/build-app.sh for why a bundle identity is required).
bundle: native
	./scripts/build-app.sh

doctor: all
	./pb doctor

clean:
	rm -rf native/.build cli/dist cli/node_modules

.PHONY: all native cli doctor clean

all: native cli

native:
	cd native && swift build -c release

cli:
	cd cli && npm install --no-fund --no-audit && npm run build

doctor: all
	./pb doctor

clean:
	rm -rf native/.build cli/dist cli/node_modules

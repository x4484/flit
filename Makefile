.PHONY: build test run app app-universal site clean

build:
	swift build -c release

test:
	swift test

run:
	swift run Flit

app:
	./scripts/build-app.sh

app-universal:
	FLIT_BUILD_UNIVERSAL=1 ./scripts/build-app.sh

site:
	./scripts/build-site.py

clean:
	rm -rf .build dist

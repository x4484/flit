.PHONY: build test run app clean

build:
	swift build -c release

test:
	swift test

run:
	swift run Flit

app:
	./scripts/build-app.sh

clean:
	rm -rf .build dist

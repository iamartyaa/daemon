.PHONY: build test spike app dmg

build:
	swift build

test:
	swift test

# Embedder benchmark: make spike ARGS="imgA imgB audioA.wav audioB.wav"
spike:
	swift build --product EmbedSpike && .build/debug/EmbedSpike $(ARGS)

app:
	scripts/bundle.sh release

dmg:
	scripts/dmg.sh

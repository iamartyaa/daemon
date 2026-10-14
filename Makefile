.PHONY: build test spike app dmg install

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

# Build, install to ~/Applications (Spotlight and Launchpad find it), and open it.
LSREGISTER = /System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister
install:
	scripts/bundle.sh release
	-pkill -x Daemon
	rm -rf "$(HOME)/Applications/Daemon.app"
	mkdir -p "$(HOME)/Applications"
	cp -R build/Daemon.app "$(HOME)/Applications/"
	-$(LSREGISTER) -u build/Daemon.app
	$(LSREGISTER) -f "$(HOME)/Applications/Daemon.app"
	open "$(HOME)/Applications/Daemon.app"

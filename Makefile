.PHONY: build release run clean probe devices dmg dist

build:
	Scripts/bundle.sh debug

release:
	Scripts/bundle.sh release

# Runs from /Applications, not build/: iCloud tags the bundle in a synced ~/Documents, and macOS
# then won't list the app under Screen Recording. ditto leaves those attributes behind.
run: build
	-osascript -e 'tell application id "io.github.nickpagz.proof" to quit' 2>/dev/null
	@# Opening while the old copy is still shutting down fails with LaunchServices error -609.
	@for i in $$(seq 50); do pgrep -f 'Proof.app/Contents/MacOS/Proof' >/dev/null || break; sleep 0.2; done
	rm -rf /Applications/Proof.app
	ditto --noextattr --norsrc build/Proof.app /Applications/Proof.app
	open /Applications/Proof.app

clean:
	rm -rf .build build

# make probe FILE=path/to/recording.mp4
probe:
	build/Proof.app/Contents/MacOS/Proof --probe "$(FILE)"

devices:
	build/Proof.app/Contents/MacOS/Proof --devices

# Drag-to-Applications disk image from the current build (dev-signed; for local testing).
dmg: release
	Scripts/make-dmg.sh

# Developer ID build, notarized and stapled, plus the disk image. See Scripts/release.sh.
dist:
	Scripts/release.sh

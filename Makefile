.PHONY: app run debug install uninstall icon snapshots clean

app:
	@scripts/build-app.sh

debug:
	@CONFIG=debug scripts/build-app.sh

# Rebuild, quit any running copy, launch the fresh build.
run: app
	@pkill -x Pomodoro || true
	@open build/Pomodoro.app

# Copy into /Applications (needed for "Launch at login").
install: app
	@pkill -x Pomodoro || true
	@rm -rf /Applications/Pomodoro.app
	@cp -R build/Pomodoro.app /Applications/
	@open /Applications/Pomodoro.app
	@echo "✓ Installed to /Applications/Pomodoro.app"

uninstall:
	@pkill -x Pomodoro || true
	@rm -rf /Applications/Pomodoro.app
	@echo "✓ Removed /Applications/Pomodoro.app"

# Regenerate Resources/AppIcon.icns from scripts/make-icon.swift.
icon:
	@scripts/make-icon.sh

clean:
	@rm -rf build .build

# Render each window to .context/snapshots/*.png (no screen-recording permission needed).
snapshots: app
	@pkill -x Pomodoro || true
	@rm -rf .context/snapshots
	@rm -rf "$(CURDIR)/build/snapshot-data"
	@POMODORO_DATA_DIR="$(CURDIR)/build/snapshot-data" POMODORO_SNAPSHOT_DIR="$(CURDIR)/.context/snapshots" build/Pomodoro.app/Contents/MacOS/Pomodoro
	@ls .context/snapshots

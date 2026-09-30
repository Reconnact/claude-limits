.PHONY: test menubar install-menubar uninstall-menubar
test: menubar
	bash test/collect.test.sh
	bash test/import.test.sh
	bash test/fetch.test.sh
	bash test/tally.test.sh
	bash test/update.test.sh
	bash test/menubar.test.sh
	bash test/install.test.sh
	node --test test/limits.test.js

LABEL := net.alpha-lab.claude-limits-bar
PLIST := $(HOME)/Library/LaunchAgents/$(LABEL).plist
# in ~/Applications so Spotlight finds it; the executable is a link, the app finds index.html through it
APP := $(HOME)/Applications/claude-limits.app

menubar: menubar/claude-limits-bar
menubar/claude-limits-bar: menubar/ClaudeLimitsBar.swift
	swiftc -O $< -o $@

install-menubar: menubar uninstall-menubar
	mkdir -p $(APP)/Contents/MacOS
	ln -s $(CURDIR)/menubar/claude-limits-bar $(APP)/Contents/MacOS/claude-limits-bar
	@printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
	  '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
	  '<plist version="1.0"><dict>' \
	  '<key>CFBundleIdentifier</key><string>$(LABEL)</string>' \
	  '<key>CFBundleName</key><string>claude-limits</string>' \
	  '<key>CFBundleExecutable</key><string>claude-limits-bar</string>' \
	  '<key>CFBundlePackageType</key><string>APPL</string>' \
	  '<key>LSUIElement</key><true/>' \
	  '</dict></plist>' > $(APP)/Contents/Info.plist
	@printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
	  '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
	  '<plist version="1.0"><dict>' \
	  '<key>Label</key><string>$(LABEL)</string>' \
	  '<key>ProgramArguments</key><array><string>$(APP)/Contents/MacOS/claude-limits-bar</string></array>' \
	  '<key>RunAtLoad</key><true/>' \
	  '<key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>' \
	  '</dict></plist>' > $(PLIST)
	launchctl bootstrap gui/$$(id -u) $(PLIST)

uninstall-menubar:
	@launchctl bootout gui/$$(id -u)/$(LABEL) 2>/dev/null || true
	rm -f $(PLIST)
	rm -rf $(APP)

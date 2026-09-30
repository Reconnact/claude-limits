.PHONY: test menubar install-menubar uninstall-menubar
test: menubar
	bash test/collect.test.sh
	bash test/import.test.sh
	bash test/fetch.test.sh
	bash test/menubar.test.sh
	bash test/install.test.sh
	node --test test/limits.test.js

LABEL := net.alpha-lab.claude-limits-bar
PLIST := $(HOME)/Library/LaunchAgents/$(LABEL).plist

menubar: menubar/claude-limits-bar
menubar/claude-limits-bar: menubar/ClaudeLimitsBar.swift
	swiftc -O $< -o $@

install-menubar: menubar uninstall-menubar
	@printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
	  '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
	  '<plist version="1.0"><dict>' \
	  '<key>Label</key><string>$(LABEL)</string>' \
	  '<key>ProgramArguments</key><array><string>$(CURDIR)/menubar/claude-limits-bar</string></array>' \
	  '<key>RunAtLoad</key><true/>' \
	  '<key>KeepAlive</key><true/>' \
	  '</dict></plist>' > $(PLIST)
	launchctl bootstrap gui/$$(id -u) $(PLIST)

uninstall-menubar:
	@launchctl bootout gui/$$(id -u)/$(LABEL) 2>/dev/null || true
	rm -f $(PLIST)

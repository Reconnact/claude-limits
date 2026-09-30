.PHONY: test
test:
	bash test/collect.test.sh
	bash test/import.test.sh
	node --test test/limits.test.js

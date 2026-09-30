.PHONY: test
test:
	bash test/collect.test.sh
	bash test/import.test.sh
	bash test/fetch.test.sh
	node --test test/limits.test.js

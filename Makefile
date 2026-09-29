.PHONY: test
test:
	bash test/collect.test.sh
	node --test test/limits.test.js

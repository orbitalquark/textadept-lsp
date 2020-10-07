# Copyright 2018-2020 Mitchell. See LICENSE.

# Documentation.

ta = ../..
cwd = $(shell pwd)
docs: luadoc README.md
README.md: init.lua
	cd $(ta)/scripts && luadoc --doclet markdowndoc $(cwd)/$< > $(cwd)/$@
	sed -i -e '1,+4d' -e '6c# Language Server Protocol' -e '7d' -e 's/^##/#/;' $@
luadoc: init.lua
	cd $(ta)/modules && luadoc -d $(cwd) --doclet lua/tadoc $(cwd)/$< \
		--ta-home=$(shell readlink -f $(ta))
	sed -i 's/_HOME.\+\?_HOME/_HOME/;' tags

# External dkjson dependency.

deps: dkjson.lua

dkjson_tgz = dkjson-2.5.tar.gz
$(dkjson_tgz): ; wget http://dkolf.de/src/dkjson-lua.fsl/tarball/$@
dkjson.lua: | $(dkjson_tgz) ; tar xzf $| && mv dkjson-*/$@ $@ && rm -r dkjson-*

# Releases.

ifneq (, $(shell hg summary 2>/dev/null))
  archive = hg archive -X ".hg*" $(1)
else
  archive = git archive HEAD --prefix $(1)/ | tar -xf -
endif

release: lsp | $(dkjson_tgz)
	cp $| $<
	make -C $< deps
	zip -r $<.zip $< -x "*.gz" "$</.git*" && rm -r $<
lsp: ; $(call archive,$@)

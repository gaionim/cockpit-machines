# extract name from package.json
PACKAGE_NAME := $(shell awk '/"name":/ {gsub(/[",]/, "", $$2); print $$2}' package.json)
RPM_NAME := cockpit-$(PACKAGE_NAME)
VERSION := $(shell T=$$(git describe 2>/dev/null) || T=1; echo $$T | tr '-' '.')
ifeq ($(TEST_OS),)
TEST_OS = fedora-35
endif
export TEST_OS
TARFILE=cockpit-$(PACKAGE_NAME)-$(VERSION).tar.xz
NODE_CACHE=cockpit-$(PACKAGE_NAME)-node-$(VERSION).tar.xz
SPEC=$(RPM_NAME).spec
APPSTREAMFILE=org.cockpit-project.$(PACKAGE_NAME).metainfo.xml
VM_IMAGE=$(CURDIR)/test/images/$(TEST_OS)
# stamp file to check if/when npm install ran
NODE_MODULES_TEST=node_modules/.bin/webpack
# one example file in dist/ from webpack to check if that already ran
WEBPACK_TEST=dist/manifest.json
# one example file in src/lib to check if it was already checked out
LIB_TEST=src/lib/cockpit-po-plugin.js

WEBLATE_REPO=tmp/weblate-repo
WEBLATE_REPO_URL=https://github.com/cockpit-project/cockpit-machines-weblate.git
WEBLATE_REPO_BRANCH=main

PYTHONFILES=$(shell git grep -lI '^#!.*python') $(shell git ls-tree -r --name-only HEAD | grep '\.py')

all: $(WEBPACK_TEST)

#
# i18n
#

LINGUAS=$(basename $(notdir $(wildcard po/*.po)))

po/$(PACKAGE_NAME).js.pot:
	xgettext --default-domain=$(PACKAGE_NAME) --output=$@ --language=C --keyword= \
		--keyword=_:1,1t --keyword=_:1c,2,2t --keyword=C_:1c,2 \
		--keyword=N_ --keyword=NC_:1c,2 \
		--keyword=gettext:1,1t --keyword=gettext:1c,2,2t \
		--keyword=ngettext:1,2,3t --keyword=ngettext:1c,2,3,4t \
		--keyword=gettextCatalog.getString:1,3c --keyword=gettextCatalog.getPlural:2,3,4c \
		--from-code=UTF-8 $$(find src/ -name '*.js' -o -name '*.jsx')

po/$(PACKAGE_NAME).html.pot: $(NODE_MODULES_TEST)
	po/html2po -o $@ $$(find src -name '*.html')

po/$(PACKAGE_NAME).manifest.pot: $(NODE_MODULES_TEST)
	po/manifest2po src/manifest.json -o $@

po/$(PACKAGE_NAME).metainfo.pot: $(APPSTREAMFILE)
	xgettext --default-domain=$(PACKAGE_NAME) --output=$@ $<

po/$(PACKAGE_NAME).pot: po/$(PACKAGE_NAME).html.pot po/$(PACKAGE_NAME).js.pot po/$(PACKAGE_NAME).manifest.pot po/$(PACKAGE_NAME).metainfo.pot
	msgcat --sort-output --output-file=$@ $^

po/LINGUAS:
	echo $(LINGUAS) | tr ' ' '\n' > $@

# Update translations against current PO template
update-po: po/$(PACKAGE_NAME).pot
	for lang in $(LINGUAS); do \
		msgmerge --output-file=po/$$lang.po po/$$lang.po $<; \
	done

$(WEBLATE_REPO):
	git clone --depth=1 -b $(WEBLATE_REPO_BRANCH) $(WEBLATE_REPO_URL) $(WEBLATE_REPO)

upload-pot: po/$(PACKAGE_NAME).pot $(WEBLATE_REPO)
	cp ./po/$(PACKAGE_NAME).pot $(WEBLATE_REPO)
	git -C $(WEBLATE_REPO) commit -m "Update source file" -- $(PACKAGE_NAME).pot
	git -C $(WEBLATE_REPO) push

clean-po:
	rm ./po/*.po

download-po: $(WEBLATE_REPO)
	cp $(WEBLATE_REPO)/*.po ./po/

#
# Build/Install/dist
#

%.spec: packaging/%.spec.in
	sed -e 's/%{VERSION}/$(VERSION)/g' $< > $@

packaging/arch/PKGBUILD: packaging/arch/PKGBUILD.in
	sed 's/VERSION/$(VERSION)/; s/SOURCE/$(TARFILE)/' $< > $@

packaging/debian/changelog: packaging/debian/changelog.in
	sed 's/VERSION/$(VERSION)/' $< > $@

$(WEBPACK_TEST): $(LIB_TEST) $(shell find src/ -type f) package.json webpack.config.js
	test/download-dist $${DOWNLOAD_DIST_OPTIONS:-} || \
	    if [ -z "$$FORCE_DOWNLOAD_DIST" ]; then \
		($(MAKE) $(NODE_MODULES_TEST) && NODE_ENV=$(NODE_ENV) node_modules/.bin/webpack); \
	    else \
		exit 1; \
	    fi

watch:
	NODE_ENV=$(NODE_ENV) node_modules/.bin/webpack --watch

clean:
	rm -rf dist/
	rm -f $(SPEC) packaging/arch/PKGBUILD packaging/debian/changelog
	rm -f po/LINGUAS

install: $(WEBPACK_TEST) po/LINGUAS
	mkdir -p $(DESTDIR)/usr/share/cockpit/$(PACKAGE_NAME)
	cp -r dist/* $(DESTDIR)/usr/share/cockpit/$(PACKAGE_NAME)
	mkdir -p $(DESTDIR)/usr/share/metainfo/
	msgfmt --xml -d po \
		--template $(APPSTREAMFILE) \
		-o $(DESTDIR)/usr/share/metainfo/$(APPSTREAMFILE)

# this requires a built source tree and avoids having to install anything system-wide
devel-install: $(WEBPACK_TEST)
	mkdir -p ~/.local/share/cockpit
	ln -s `pwd`/dist ~/.local/share/cockpit/$(PACKAGE_NAME)

dist: $(TARFILE)
	@ls -1 $(TARFILE)

# when building a distribution tarball, call webpack with a 'production' environment
# we don't ship node_modules for license and compactness reasons; we ship a
# pre-built dist/ (so it's not necessary) and ship package-lock.json (so that
# node_modules/ can be reconstructed if necessary)
$(TARFILE): export NODE_ENV=production
$(TARFILE): $(WEBPACK_TEST) $(SPEC) packaging/arch/PKGBUILD packaging/debian/changelog
	tar --xz -cf $(TARFILE) --transform 's,^,cockpit-$(PACKAGE_NAME)/,' \
		--exclude '*.in' --exclude test/reference \
		$$(git ls-files) src/lib/ package-lock.json $(SPEC) packaging/arch/PKGBUILD packaging/debian/changelog dist/

$(NODE_CACHE): $(NODE_MODULES_TEST)
	tar --xz -cf $@ node_modules

node-cache: $(NODE_CACHE)

# convenience target for developers
rpm: $(TARFILE) $(SPEC)
	mkdir -p "`pwd`/output"
	mkdir -p "`pwd`/rpmbuild"
	rpmbuild -bb \
	  --define "_sourcedir `pwd`" \
	  --define "_specdir `pwd`" \
	  --define "_builddir `pwd`/rpmbuild" \
	  --define "_srcrpmdir `pwd`" \
	  --define "_rpmdir `pwd`/output" \
	  --define "_buildrootdir `pwd`/build" \
	  $(SPEC)
	find `pwd`/output -name '*.rpm' -printf '%f\n' -exec mv {} . \;
	rm -r "`pwd`/rpmbuild"
	rm -r "`pwd`/output" "`pwd`/build"

# rpms/debs can be built offline; arch can't yet
ifeq ($(filter arch,$(TEST_OS)),)
NETWORK=--no-network
endif

# build a VM with locally built distro pkgs installed
$(VM_IMAGE): $(TARFILE) packaging/debian/rules packaging/debian/control packaging/arch/PKGBUILD bots
	bots/image-customize --verbose $(NETWORK) --fresh --build $(TARFILE) --script $(CURDIR)/test/vm.install $(TEST_OS)

# convenience target for the above
vm: $(VM_IMAGE)
	echo $(VM_IMAGE)

# run static code checks for python code
codecheck:
	python3 -m pyflakes $(PYTHONFILES)
	python3 -m pycodestyle --max-line-length=195 $(PYTHONFILES) # TODO: Fix long lines

# run the browser integration tests; skip check for SELinux denials
check: $(NODE_MODULES_TEST) $(VM_IMAGE) test/common test/reference
	test/common/run-tests

# checkout Cockpit's bots for standard test VM images and API to launch them
# must be from main, as only that has current and existing images; but testvm.py API is stable
# support CI testing against a bots change
bots:
	git clone --quiet --reference-if-able $${XDG_CACHE_HOME:-$$HOME/.cache}/cockpit-project/bots https://github.com/cockpit-project/bots.git
	if [ -n "$$COCKPIT_BOTS_REF" ]; then git -C bots fetch --quiet --depth=1 origin "$$COCKPIT_BOTS_REF"; git -C bots checkout --quiet FETCH_HEAD; fi
	@echo "checked out bots/ ref $$(git -C bots rev-parse HEAD)"

# checkout Cockpit's test API; this has no API stability guarantee, so check out a stable tag
# when you start a new project, use the latest release, and update it from time to time
test/common:
	flock Makefile sh -ec '\
	    git fetch --depth=1 https://github.com/cockpit-project/cockpit.git d1a410cf9ccb33e983fbd38cad5a6fc95bc1c4b4; \
	    git checkout --force FETCH_HEAD -- test/common; \
	    git reset test/common'

test/reference: test/common
	test/common/pixel-tests pull

# checkout Cockpit's PF/React/build library; again this has no API stability guarantee, so check out a stable tag
$(LIB_TEST):
	flock Makefile sh -ec '\
	    git fetch --depth=1 https://github.com/cockpit-project/cockpit.git 262; \
	    git checkout --force FETCH_HEAD -- pkg/lib; \
	    git reset -- pkg/lib'
	mv pkg/lib src/ && rmdir -p pkg

$(NODE_MODULES_TEST): package.json
	# if it exists already, npm install won't update it; force that so that we always get up-to-date packages
	rm -f package-lock.json
	# unset NODE_ENV, skips devDependencies otherwise
	env -u NODE_ENV npm install
	env -u NODE_ENV npm prune

.PHONY: all clean install devel-install dist node-cache rpm check vm update-po


QUAY_USERNAME ?= 
QUAY_PASSWORD ?= 

ifdef OPERATOR_TESTING
APPR_NAMESPACE ?= $(QUAY_USERNAME)-testing
else
APPR_NAMESPACE ?= $(QUAY_USERNAME)
endif
APPR_REPOSITORY ?= db-operators
OPERATOR_IMAGE ?= quay.io/$(APPR_NAMESPACE)/$(OPERATOR_NAME)
OPERATOR_NAME ?= postgresql-operator
OPERATOR_VERSION ?= 0.0.5

.PHONY: clean
clean:
	@-rm -rvf ./vendor
	@-rm -rvf ./tmp

.PHONY: get-tag
get-tag:
	$(eval export TAG := $(shell date +%s))

.PHONY: ./vendor
./vendor: go.mod go.sum
	go mod vendor

.PHONY: build-operator-image
build-operator-image: ./vendor get-tag
	operator-sdk build $(OPERATOR_IMAGE):$(OPERATOR_VERSION)-$(TAG)

.PHONY: push-operator-image
push-operator-image: build-operator-image get-tag
	@echo $(QUAY_PASSWORD) | docker login quay.io -u $(QUAY_USERNAME) --password-stdin
	docker push $(OPERATOR_IMAGE):$(OPERATOR_VERSION)-$(TAG)

.PHONY: build-operator-image-stable
build-operator-image-stable: ./vendor
	operator-sdk build $(OPERATOR_IMAGE):$(OPERATOR_VERSION)

.PHONY: push-operator-image-stable
push-operator-image-stable: build-operator-image-stable
	@echo $(QUAY_PASSWORD) | docker login quay.io -u $(QUAY_USERNAME) --password-stdin
	docker push $(OPERATOR_IMAGE):$(OPERATOR_VERSION)

.PHONY: deploy-operator-package
deploy-operator-package: push-operator-image get-tag
	$(eval OPERATOR_MANIFESTS := tmp/manifests)
	$(eval CREATION_TIMESTAMP := $(shell date --date="@$(TAG)" '+%Y-%m-%d %H:%M:%S'))
	$(eval ICON_BASE64_DATA := $(shell cat ./icon/pgo.png | base64))
	operator-courier --verbose flatten manifests/ $(OPERATOR_MANIFESTS)
	cp -vf deploy/crds/*_crd.yaml $(OPERATOR_MANIFESTS)
	@sed -i -e 's,REPLACE_NAME,$(OPERATOR_NAME),g' $(OPERATOR_MANIFESTS)/postgresql-operator.v$(OPERATOR_VERSION).clusterserviceversion-v$(OPERATOR_VERSION).yaml
	@sed -i -e 's,REPLACE_VERSION,$(OPERATOR_VERSION),g' $(OPERATOR_MANIFESTS)/postgresql-operator.v$(OPERATOR_VERSION).clusterserviceversion-v$(OPERATOR_VERSION).yaml
	@sed -i -e 's,REPLACE_IMAGE,$(OPERATOR_IMAGE):$(OPERATOR_VERSION)-$(TAG),g' $(OPERATOR_MANIFESTS)/postgresql-operator.v$(OPERATOR_VERSION).clusterserviceversion-v$(OPERATOR_VERSION).yaml
	@sed -i -e 's,REPLACE_CREATED_AT,$(CREATION_TIMESTAMP),' $(OPERATOR_MANIFESTS)/postgresql-operator.v$(OPERATOR_VERSION).clusterserviceversion-v$(OPERATOR_VERSION).yaml
	@sed -i -e 's,REPLACE_ICON_BASE64_DATA,$(ICON_BASE64_DATA),' $(OPERATOR_MANIFESTS)/postgresql-operator.v$(OPERATOR_VERSION).clusterserviceversion-v$(OPERATOR_VERSION).yaml
	@sed -i -e 's,REPLACE_NAME,$(OPERATOR_NAME),g' $(OPERATOR_MANIFESTS)/database.package.yaml
	@sed -i -e 's,REPLACE_VERSION,$(OPERATOR_VERSION),g' $(OPERATOR_MANIFESTS)/database.package.yaml
	@sed -i -e 's,REPLACE_PACKAGE,$(APPR_REPOSITORY),' $(OPERATOR_MANIFESTS)/database.package.yaml
	operator-courier --verbose verify --ui_validate_io $(OPERATOR_MANIFESTS)
	$(eval QUAY_API_TOKEN := $(shell curl -sH "Content-Type: application/json" -XPOST https://quay.io/cnr/api/v1/users/login -d '{"user":{"username":"'${QUAY_USERNAME}'","password":"'${QUAY_PASSWORD}'"}}' | jq -r '.token'))
	@operator-courier push $(OPERATOR_MANIFESTS) $(APPR_NAMESPACE) $(APPR_REPOSITORY) $(OPERATOR_VERSION)-$(TAG) "$(QUAY_API_TOKEN)"

.PHONY: install-operator-source
install-operator-source:
	$(eval INSTALL_DIR := deploy/install)
	sed -e 's,REPLACE_NAMESPACE,$(APPR_NAMESPACE),g' ./$(INSTALL_DIR)/operatorsource.yaml | sed -e 's,REPLACE_REPOSITORY,$(APPR_REPOSITORY),g' | oc apply -f -

.PHONY: uninstall-operator
uninstall-operator:
	#$(eval INSTALL_DIR := deploy/install)
	@-oc delete sub postgresql -n openshift-operators
	@-oc delete catsrc installed-custom-openshift-operators -n openshift-operators
	@-oc delete csc installed-custom-openshift-operators -n openshift-marketplace
	@-oc delete opsrc db-operators -n openshift-marketplace
	@-oc delete crd databases.postgresql.baiju.dev
	@-oc delete deploy postgres-operator -n openshift-operators
	@-oc delete csv postgresql-operator.v$(OPERATOR_VERSION) -n openshift-operators

.PHONY: reinstall-operator
reinstall-operator: uninstall-operator deploy-operator-package install-operator-source

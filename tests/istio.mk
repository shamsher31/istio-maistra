# Test-specific targets, included from top Makefile
ifeq (${TEST_ENV},minikube)

# In minikube env we don't need to push the images to dockerhub or gcr, it is all local,
# but we need to use the minikube's docker env.
# Note that tests simply use go/out, so going up 3 dirs from the os/arch/debug path
export KUBECONFIG=${GO_TOP}/out/minikube.conf
export TEST_ENV=minikube
MINIKUBE_FLAGS=--use_local_cluster --cluster_wide
.PHONY: minikube

# Prepare minikube
minikube:
	minikube update-context
	@echo "Minikube started ${KUBECONFIG}"
	minikube docker-env > ${ISTIO_OUT}/minikube.dockerenv

e2e_docker: minikube docker

else ifeq (${TEST_ENV},minikube-none)

# In minikube env we don't need to push the images to dockerhub or gcr, it is all local,
# but we need to use the minikube's docker env.
# Note that tests simply use go/out, so going up 3 dirs from the os/arch/debug path
export KUBECONFIG=${GO_TOP}/out/minikube.conf
export TEST_ENV=minikube-none
MINIKUBE_FLAGS=--use_local_cluster --cluster_wide
.PHONY: minikube

# Prepare minikube
minikube:
	minikube update-context
	@echo "Minikube started ${KUBECONFIG}"

e2e_docker: minikube docker


else

# All other test environments require the docker images to be pushed to a repo.
# The HUB is defined in user-specific .istiorc, TAG can be set or defaults to git version
e2e_docker: push

endif

E2E_TIMEOUT ?= 60m


# If set outside, it appears it is not possible to modify the variable.
E2E_ARGS ?=

ISTIOCTL_BIN ?= ${ISTIO_OUT}/istioctl

DEFAULT_EXTRA_E2E_ARGS = ${MINIKUBE_FLAGS}
DEFAULT_EXTRA_E2E_ARGS += --istioctl=${ISTIOCTL_BIN}
DEFAULT_EXTRA_E2E_ARGS += --mixer_tag=${TAG_VARIANT}
DEFAULT_EXTRA_E2E_ARGS += --pilot_tag=${TAG_VARIANT}
DEFAULT_EXTRA_E2E_ARGS += --proxy_tag=${TAG_VARIANT}
DEFAULT_EXTRA_E2E_ARGS += --ca_tag=${TAG_VARIANT}
DEFAULT_EXTRA_E2E_ARGS += --galley_tag=${TAG_VARIANT}
DEFAULT_EXTRA_E2E_ARGS += --sidecar_injector_tag=${TAG_VARIANT}
DEFAULT_EXTRA_E2E_ARGS += --app_tag=${TAG}
DEFAULT_EXTRA_E2E_ARGS += --mixer_hub=${HUB}
DEFAULT_EXTRA_E2E_ARGS += --pilot_hub=${HUB}
DEFAULT_EXTRA_E2E_ARGS += --proxy_hub=${HUB}
DEFAULT_EXTRA_E2E_ARGS += --ca_hub=${HUB}
DEFAULT_EXTRA_E2E_ARGS += --galley_hub=${HUB}
DEFAULT_EXTRA_E2E_ARGS += --sidecar_injector_hub=${HUB}
DEFAULT_EXTRA_E2E_ARGS += --app_hub=${HUB}

EXTRA_E2E_ARGS ?= ${DEFAULT_EXTRA_E2E_ARGS}

e2e_simple: build generate_e2e_yaml e2e_simple_run
e2e_kiali: build generate_e2e_yaml e2e_kiali_run

e2e_simple_noauth: build generate_e2e_yaml e2e_simple_noauth_run

e2e_mixer: build generate_e2e_yaml e2e_mixer_run

e2e_galley: build generate_e2e_yaml e2e_galley_run

e2e_dashboard: build generate_e2e_yaml e2e_dashboard_run

e2e_bookinfo: build generate_e2e_yaml e2e_bookinfo_run

e2e_stackdriver: build generate_e2e_yaml e2e_stackdriver_run

e2e_all: build generate_e2e_yaml e2e_all_run

# *_run targets do not rebuild the artifacts and test with whatever is given

e2e_simple_run: out_dir
	go test -v -timeout ${E2E_TIMEOUT} ./tests/e2e/tests/simple -args --auth_enable=true \
	--egress=false --ingress=false \
	--valueFile test-values/values-e2e.yaml \
	--rbac_enable=false --cluster_wide ${E2E_ARGS} ${T} ${EXTRA_E2E_ARGS} ${CAPTURE_LOG}

e2e_kiali_run: out_dir
	go test -v -timeout ${E2E_TIMEOUT} ./tests/e2e/tests/kiali -args --auth_enable=false \
	--egress=false --ingress=false \
	--rbac_enable=false --cluster_wide ${E2E_ARGS} ${EXTRA_E2E_ARGS} ${CAPTURE_LOG}

e2e_simple_noauth_run: out_dir
	go test -v -timeout ${E2E_TIMEOUT} ./tests/e2e/tests/simple -args --auth_enable=false \
	--egress=false --ingress=false \
	--valueFile test-values/values-e2e.yaml \
	--rbac_enable=false --cluster_wide ${E2E_ARGS} ${T} ${EXTRA_E2E_ARGS} ${CAPTURE_LOG}

e2e_mixer_run: out_dir
	go test -v -timeout ${E2E_TIMEOUT} ./tests/e2e/tests/mixer \
	--auth_enable=false --egress=false --ingress=false --rbac_enable=false \
	--cluster_wide ${E2E_ARGS} ${T} ${EXTRA_E2E_ARGS} ${CAPTURE_LOG}

e2e_galley_run: out_dir
	go test -v -timeout ${E2E_TIMEOUT} ./tests/e2e/tests/galley -args ${E2E_ARGS} ${EXTRA_E2E_ARGS} -use_galley_config_validator -cluster_wide

e2e_dashboard_run: out_dir
	go test -v -timeout ${E2E_TIMEOUT} ./tests/e2e/tests/dashboard -args ${E2E_ARGS} ${EXTRA_E2E_ARGS} -use_galley_config_validator -cluster_wide

e2e_bookinfo_run: out_dir
	go test -v -timeout ${E2E_TIMEOUT} ./tests/e2e/tests/bookinfo -args ${E2E_ARGS} ${EXTRA_E2E_ARGS}

e2e_stackdriver_run: out_dir
	go test -v -timeout ${E2E_TIMEOUT} ./tests/e2e/tests/stackdriver -args ${E2E_ARGS} ${EXTRA_E2E_ARGS} --cluster_wide --gcp_proj=${GCP_PROJ} --sa_cred=/etc/service-account/service-account.json

e2e_all_run: out_dir
	$(MAKE) --keep-going e2e_simple_run e2e_bookinfo_run e2e_dashboard_run

JUNIT_E2E_XML ?= $(ISTIO_OUT)/junit.xml
TARGET ?= e2e_all
with_junit_report: | $(JUNIT_REPORT)
	mkdir -p $(dir $(JUNIT_E2E_XML))
	$(MAKE) $(TARGET) 2>&1 | tee >($(JUNIT_REPORT) > $(JUNIT_E2E_XML))

e2e_all_junit_report:
	$(MAKE) with_junit_report TARGET=e2e_all

e2e_all_run_junit_report:
	$(MAKE) with_junit_report TARGET=e2e_all_run

# The pilot tests cannot currently be part of e2e_all, since they requires some additional flags.
e2e_pilot: out_dir build generate_e2e_yaml
	go test -v -timeout ${E2E_TIMEOUT} ./tests/e2e/tests/pilot ${E2E_ARGS} ${EXTRA_E2E_ARGS}

e2e_pilotv2_v1alpha3: | build test/local/noauth/e2e_pilotv2

e2e_bookinfo_envoyv2_v1alpha3: | build test/local/auth/e2e_bookinfo_envoyv2

e2e_bookinfo_trustdomain: | build test/local/auth/e2e_bookinfo_trustdomain

e2e_pilotv2_auth_sds: | build test/local/auth/e2e_sds_pilotv2

e2e_multicluster_split_horizon: | build test/local/auth/e2e_split_horizon

# This is used to keep a record of the test results.
CAPTURE_LOG=| tee -a ${OUT_DIR}/tests/build-log.txt

## Targets for fast local development and staged CI.
# The test take a T argument. Example:
# make test/local/noauth/e2e_pilotv2 T=-test.run=TestPilot/ingress


.PHONY: out_dir
out_dir:
	@mkdir -p ${OUT_DIR}/{logs,tests}

test/local/auth/e2e_simple: out_dir generate_e2e_yaml
	go test -v -timeout ${E2E_TIMEOUT} ./tests/e2e/tests/simple -args --auth_enable=true \
	--egress=false --ingress=false \
	--rbac_enable=false --use_local_cluster --cluster_wide ${E2E_ARGS} ${T} ${EXTRA_E2E_ARGS} ${CAPTURE_LOG}

test/local/noauth/e2e_simple: out_dir generate_e2e_yaml
	go test -v -timeout ${E2E_TIMEOUT} ./tests/e2e/tests/simple -args --auth_enable=false \
	--egress=false --ingress=false \
	--rbac_enable=false --use_local_cluster --cluster_wide ${E2E_ARGS} ${T} ${EXTRA_E2E_ARGS} ${CAPTURE_LOG}

test/local/e2e_mixer: out_dir generate_e2e_yaml
	go test -v -timeout ${E2E_TIMEOUT} ./tests/e2e/tests/mixer \
	--auth_enable=false --egress=false --ingress=false --rbac_enable=false \
	--cluster_wide ${E2E_ARGS} ${T} ${EXTRA_E2E_ARGS} ${CAPTURE_LOG}

test/local/e2e_galley: out_dir build generate_e2e_yaml
	go test -v -timeout ${E2E_TIMEOUT} ./tests/e2e/tests/galley -args \
	-use_local_cluster -cluster_wide --use_galley_config_validator -test.v ${E2E_ARGS} ${EXTRA_E2E_ARGS} \
	${CAPTURE_LOG}

# v1alpha3+envoyv2 test without MTLS
test/local/noauth/e2e_pilotv2: out_dir generate_e2e_yaml_coredump
	go test -v -timeout ${E2E_TIMEOUT} ./tests/e2e/tests/pilot \
		--auth_enable=false --ingress=false --rbac_enable=true --cluster_wide \
		${E2E_ARGS} ${T} ${EXTRA_E2E_ARGS} ${CAPTURE_LOG}
	# Run the pilot controller tests
	go test -v -timeout ${E2E_TIMEOUT} ./tests/e2e/tests/controller ${CAPTURE_LOG}

# v1alpha3+envoyv2 test with MTLS
test/local/auth/e2e_pilotv2: out_dir generate_e2e_yaml_coredump
	go test -v -timeout ${E2E_TIMEOUT} ./tests/e2e/tests/pilot \
		--auth_enable=true --ingress=false --rbac_enable=true --cluster_wide \
		${E2E_ARGS} ${T} ${EXTRA_E2E_ARGS} ${CAPTURE_LOG}
	# Run the pilot controller tests
	go test -v -timeout ${E2E_TIMEOUT} ./tests/e2e/tests/controller ${CAPTURE_LOG}

# test with MTLS using key/cert distributed through SDS
test/local/auth/e2e_sds_pilotv2: out_dir generate_e2e_yaml_coredump
	go test -v -timeout ${E2E_TIMEOUT} ./tests/e2e/tests/pilot \
		--auth_enable=true --auth_sds_enable=true  --ingress=false --rbac_enable=true --cluster_wide \
		${E2E_ARGS} ${T} ${EXTRA_E2E_ARGS} ${CAPTURE_LOG}
	# Run the pilot controller tests
	go test -v -timeout ${E2E_TIMEOUT} ./tests/e2e/tests/controller ${CAPTURE_LOG}

e2e_cloudfoundry: init out_dir
	iptables -t nat -A OUTPUT -d 127.1.1.1/32 -p tcp -j REDIRECT --to-port 15001
	go test -v -timeout ${E2E_TIMEOUT} ./tests/e2e/tests/pilot/cloudfoundry ${T} \
		${CAPTURE_LOG}
	iptables -t nat -F

test/local/cloudfoundry/e2e_pilotv2: out_dir
	sudo apt update
	sudo apt install -y iptables
	sudo iptables -t nat -A OUTPUT -d 127.1.1.1/32 -p tcp -j REDIRECT --to-port 15001
	go test -v -timeout ${E2E_TIMEOUT} ./tests/e2e/tests/pilot/cloudfoundry ${T} \
		${CAPTURE_LOG}
	sudo iptables -t nat -F

test/local/auth/e2e_bookinfo_envoyv2: out_dir generate_e2e_yaml
	go test -v -timeout ${E2E_TIMEOUT} ./tests/e2e/tests/bookinfo \
		--auth_enable=true --egress=true --ingress=false --rbac_enable=false \
		--cluster_wide ${E2E_ARGS} ${T} ${EXTRA_E2E_ARGS} ${CAPTURE_LOG}

test/local/auth/e2e_bookinfo_trustdomain: out_dir generate_e2e_yaml
	go test -v -timeout ${E2E_TIMEOUT} ./tests/e2e/tests/bookinfo \
		--auth_enable=true --trust_domain_enable --egress=true --ingress=false --rbac_enable=false \
		--cluster_wide ${E2E_ARGS} ${T} ${EXTRA_E2E_ARGS} ${CAPTURE_LOG}

test/local/auth/e2e_split_horizon: out_dir generate_e2e_yaml
	go test -v -timeout ${E2E_TIMEOUT} ./tests/e2e/tests/multicluster \
		--auth_enable=true --split_horizon \
		--cluster_wide ${E2E_ARGS} ${T} ${EXTRA_E2E_ARGS} ${CAPTURE_LOG}

test/local/noauth/e2e_mixer_envoyv2: export EXTRA_HELM_SETTINGS=--set mixer.adapters.stdio.enabled=false
test/local/noauth/e2e_mixer_envoyv2: out_dir generate_e2e_yaml
	go test -v -timeout ${E2E_TIMEOUT} ./tests/e2e/tests/mixer \
	--auth_enable=false --egress=false --ingress=false --rbac_enable=false \
	--cluster_wide ${E2E_ARGS} ${T} ${EXTRA_E2E_ARGS} ${CAPTURE_LOG}

junit-report: out_dir ${ISTIO_BIN}/go-junit-report
	${ISTIO_BIN}/go-junit-report < $(OUT_DIR)/tests/build-log.txt > $(OUT_DIR)/tests/junit.xml

# Dumpsys will get as much info as possible from the test cluster
# Can be run after tests. It will also process the auto-saved log output
# This assume istio runs in istio-system namespace, and 'skip-cleanup' was used in tests.
dumpsys: out_dir
	tools/dump_kubernetes.sh --output-directory ${OUT_DIR}/logs --error-if-nasty-logs

# Run once for each cluster, to install helm on the cluster
helm/init: ${HELM}
	kubectl apply -n kube-system -f install/kubernetes/helm/helm-service-account.yaml
	helm init --stable-repo-url https://charts.helm.sh/stable --upgrade --service-account tiller

# Install istio for the first time
helm/install:
	${HELM} install \
	  install/kubernetes/helm/istio-init \
	  --name istio-system-init --namespace istio-system \
	  --set-string global.hub=${HUB} \
	  --set-string global.tag=${TAG_VARIANT} \
	  --set-string global.imagePullPolicy=Always \
	  ${HELM_ARGS}
	sleep 10
	${HELM} install \
	  install/kubernetes/helm/istio \
	  --name istio-system --namespace istio-system \
	  --set-string global.hub=${HUB} \
	  --set-string global.tag=${TAG_VARIANT} \
	  --set-string global.imagePullPolicy=Always \
	  ${HELM_ARGS}

# Upgrade istio. Options must be set:
#  "make helm/upgrade HELM_ARGS="--values myoverride.yaml"
helm/upgrade:
	${HELM} upgrade \
	  --set-string global.hub=${HUB} \
	  --set-string global.tag=${TAG_VARIANT} \
	  --set-string global.imagePullPolicy=Always \
	  ${HELM_ARGS} \
	  istio-system install/kubernetes/helm/istio

# Delete istio installed with helm
helm/delete:
	${HELM} delete --purge istio-system
	for i in install/kubernetes/helm/istio-init/files/crd-*; do kubectl delete -f $i; done

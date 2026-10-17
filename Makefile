.PHONY: help install upgrade-os upgrade-k3s reconfigure-k3s deploy deploy-system deploy-k3s deploy-users deploy-secrets deploy-argocd deploy-dashboards deploy-registries deploy-tailscale build-proxysql-operator destroy-cluster verify logs clean status syntax-check lint

INVENTORY := inventory.dist
VAULT_PASS := --ask-vault-pass
FIRST_SERVER := rpi-5-1

help:
	@echo "Home Pi Infrastructure - Makefile Commands"
	@echo ""
	@echo "Installation & Setup:"
	@echo "  make install              Install Ansible collections"
	@echo ""
	@echo "Deployment:"
	@echo "  make deploy               Deploy full infrastructure (site.yml)"
	@echo "  make deploy-system        Deploy only system setup"
	@echo "  make deploy-k3s           Deploy only k3s cluster"
	@echo "  make deploy-users         Deploy only user management"
	@echo "  make deploy-secrets       Seed cluster Secrets/ConfigMaps only"
	@echo "  make deploy-argocd        Bootstrap Argo CD only"
	@echo "  make deploy-dashboards    Import Grafana dashboards (not part of make deploy)"
	@echo "  make deploy-tailscale     Apply the Tailscale node config (restarts tailscaled, one node at a time)"
	@echo "  make upgrade-os           Full apt dist-upgrade on every node (not part of make deploy; may need reboots)"
	@echo "  make upgrade-k3s          Rolling k3s upgrade to k3s_version, one node at a time (etcd snapshot first)"
	@echo "  make reconfigure-k3s      Apply group_vars/server/main.yaml to the servers (rolling restart, then re-encrypt Secrets)"
	@echo "  make deploy-registries    Point each node at the Zot pull-through cache (restarts k3s, one node at a time)"
	@echo "  make build-proxysql-operator  Build the ProxySQL operator image and push it to the in-cluster Zot"
	@echo ""
	@echo "Destruction:"
	@echo "  make destroy-cluster      WIPE k3s + Longhorn data on every node (asks to confirm)"
	@echo ""
	@echo "Verification & Monitoring:"
	@echo "  make verify               Verify cluster health"
	@echo "  make logs                 Show k3s logs on first server"
	@echo "  make status               Show k3s cluster status"
	@echo ""
	@echo "Development:"
	@echo "  make syntax-check         Check playbook syntax"
	@echo "  make lint                 Run ansible-lint"
	@echo "  make clean                Remove temporary files"

install:
	@echo "Installing Ansible collections..."
	ansible-galaxy collection install -r requirements.yaml
	@echo "✓ Collections installed"

deploy:
	@echo "Deploying full infrastructure..."
	ansible-playbook site.yml -i $(INVENTORY) $(VAULT_PASS)

deploy-system:
	@echo "Deploying system setup only..."
	ansible-playbook site.yml -i $(INVENTORY) $(VAULT_PASS) --tags setup

deploy-k3s:
	@echo "Deploying k3s cluster only..."
	ansible-playbook site.yml -i $(INVENTORY) $(VAULT_PASS) --tags k3s

deploy-users:
	@echo "Deploying user management only..."
	ansible-playbook site.yml -i $(INVENTORY) $(VAULT_PASS) --tags user_management

deploy-secrets:
	@echo "Seeding cluster secrets only..."
	ansible-playbook site.yml -i $(INVENTORY) $(VAULT_PASS) --tags secrets

deploy-argocd:
	@echo "Bootstrapping Argo CD only..."
	ansible-playbook site.yml -i $(INVENTORY) $(VAULT_PASS) --tags helm,argocd

deploy-registries:
	@echo "Configuring registry mirrors (restarts k3s on each node, one at a time)..."
	ansible-playbook site.yml -i $(INVENTORY) $(VAULT_PASS) --tags registries

upgrade-os:
	@echo "Running a full apt dist-upgrade on every node (reboots are not done for you)..."
	ansible-playbook site.yml -i $(INVENTORY) $(VAULT_PASS) --tags setup -e setup_upgrade_packages=true

upgrade-k3s:
	@echo "Rolling k3s upgrade (servers, then agents, one node at a time)..."
	ansible-playbook upgrade-k3s.yml -i $(INVENTORY) $(VAULT_PASS)

reconfigure-k3s:
	@echo "Rolling k3s server reconfigure (restarts the servers one at a time)..."
	ansible-playbook upgrade-k3s.yml -i $(INVENTORY) $(VAULT_PASS) -e k3s_reconfigure=true

deploy-tailscale:
	@echo "Configuring tailscaled on each node (restarts it if its config changed, one node at a time)..."
	ansible-playbook site.yml -i $(INVENTORY) $(VAULT_PASS) --tags tailscale

deploy-dashboards:
	@echo "Importing Grafana dashboards (needs Grafana up and the control host on the tailnet)..."
	ansible-playbook dashboards.yml -i $(INVENTORY) $(VAULT_PASS)

build-proxysql-operator:
	@echo "Building the ProxySQL operator image and pushing it to Zot..."
	./scripts/build-proxysql-operator.sh

destroy-cluster:
	ansible-playbook destroy.yml -i $(INVENTORY) $(VAULT_PASS)

verify:
	@echo "Verifying cluster health..."
	ansible $(FIRST_SERVER) -i $(INVENTORY) $(VAULT_PASS) -m command -a "sudo kubectl get nodes && echo '---' && sudo kubectl get pods -A | grep -E 'coredns|metrics-server|local-path' && echo '---' && sudo kubectl get applications -n argocd"

status:
	@echo "Cluster Status:"
	ansible $(FIRST_SERVER) -i $(INVENTORY) $(VAULT_PASS) -m command -a "sudo kubectl get nodes && echo '---' && sudo kubectl get applications -n argocd"

logs:
	@echo "Tailing k3s logs from first server..."
	ansible $(FIRST_SERVER) -i $(INVENTORY) $(VAULT_PASS) -m command -a "sudo journalctl -u k3s -f"

syntax-check:
	@echo "Checking playbook syntax..."
	ansible-playbook site.yml -i $(INVENTORY) $(VAULT_PASS) --syntax-check
	@echo "✓ Syntax valid"

lint:
	@if command -v ansible-lint &> /dev/null; then \
		echo "Running ansible-lint..."; \
		ansible-lint site.yml; \
	else \
		echo "ansible-lint not installed. Install with: pip install ansible-lint"; \
	fi

clean:
	@echo "Cleaning temporary files..."
	find . -name "*.pyc" -delete
	find . -name "__pycache__" -type d -delete
	rm -rf .ansible_cache
	@echo "✓ Cleaned"

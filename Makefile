.PHONY: help install deploy deploy-system deploy-k3s deploy-users deploy-secrets deploy-argocd deploy-maintenance verify logs clean status drain uncordon syntax-check lint

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
	@echo "  make deploy-maintenance   Deploy only maintenance tools"
	@echo ""
	@echo "Verification & Monitoring:"
	@echo "  make verify               Verify cluster health"
	@echo "  make logs                 Show k3s logs on first server"
	@echo "  make status               Show k3s cluster status"
	@echo ""
	@echo "Maintenance:"
	@echo "  make drain NODE=rpi-4b-1  Drain node for maintenance"
	@echo "  make uncordon NODE=rpi-4b-1  Return node to service"
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

deploy-maintenance:
	@echo "Deploying maintenance tools only..."
	ansible-playbook site.yml -i $(INVENTORY) $(VAULT_PASS) --tags maintenance

verify:
	@echo "Verifying cluster health..."
	ansible $(FIRST_SERVER) -i $(INVENTORY) -m command -a "sudo kubectl get nodes && echo '---' && sudo kubectl get pods -A | grep -E 'coredns|metrics-server|local-path' && echo '---' && sudo kubectl get applications -n argocd"

status:
	@echo "Cluster Status:"
	ansible $(FIRST_SERVER) -i $(INVENTORY) -m command -a "sudo kubectl get nodes && echo '---' && sudo kubectl get applications -n argocd"

logs:
	@echo "Tailing k3s logs from first server..."
	ansible $(FIRST_SERVER) -i $(INVENTORY) -m command -a "sudo journalctl -u k3s -f"

drain:
	@if [ -z "$(NODE)" ]; then \
		echo "Error: NODE not specified. Usage: make drain NODE=rpi-4b-1"; \
		exit 1; \
	fi
	@echo "Draining node $(NODE)..."
	ansible $(FIRST_SERVER) -i $(INVENTORY) -m command -a "sudo kubectl drain $(NODE) --ignore-daemonsets --delete-emptydir-data --timeout=5m"

uncordon:
	@if [ -z "$(NODE)" ]; then \
		echo "Error: NODE not specified. Usage: make uncordon NODE=rpi-4b-1"; \
		exit 1; \
	fi
	@echo "Uncordoning node $(NODE)..."
	ansible $(FIRST_SERVER) -i $(INVENTORY) -m command -a "sudo kubectl uncordon $(NODE)"

syntax-check:
	@echo "Checking playbook syntax..."
	ansible-playbook site.yml -i $(INVENTORY) --syntax-check
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

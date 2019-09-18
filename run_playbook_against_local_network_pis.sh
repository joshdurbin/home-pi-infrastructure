#!/usr/bin/env bash

ansible-playbook complete_playbook.yml -i inventory.dist --timeout=60 --ask-vault-pass
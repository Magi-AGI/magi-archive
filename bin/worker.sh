#!/bin/bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
eval "$(rbenv init -)"
cd ~/magi-archive
set -a
source .env.production
set +a
export RAILS_ENV=production
exec bundle exec rake jobs:work

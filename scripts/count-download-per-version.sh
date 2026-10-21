#!/bin/sh
# SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
# SPDX-License-Identifier: GPL-3.0-or-later
# Download count of every release asset.
curl -s https://api.github.com/repos/gttyterm/gtty/releases | jq -r '.[][] | select(.name != null) | "\(.name): \(.download_count)"' 2>/dev/null || curl -s https://api.github.com/repos/gttyterm/gtty/releases | jq -r '.[].assets[] | "\(.name): \(.download_count)"'

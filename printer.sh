#!/bin/bash
# Adds or removes the "reMarkable Paper Pro" printer. RM-Clipper must be running to add it.
#   ./printer.sh add       add it and make it the default printer
#   ./printer.sh remove    remove it again
set -euo pipefail
NAME=reMarkable_Paper_Pro
case "${1:-}" in
  add)
    lpadmin -p $NAME -E -v ipp://localhost:8631/ipp/print -m everywhere -D "reMarkable Paper Pro" \
      -o printer-error-policy=retry-job -o printer-is-shared=false
    lpoptions -d $NAME >/dev/null   # default printer of this user (lpadmin -d did not stick)
    lpstat -p $NAME -d ;;
  remove)
    lpoptions -x $NAME 2>/dev/null || true
    lpadmin -x $NAME ;;
  *) echo "usage: ./printer.sh add|remove" >&2; exit 2 ;;
esac

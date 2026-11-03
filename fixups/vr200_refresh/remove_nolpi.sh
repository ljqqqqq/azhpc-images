#!/bin/bash
set -euo pipefail
[[ ${EUID} -eq 0 ]] || { echo 'Run as root.' >&2; exit 1; }

# Match the complete kernel argument, preserving surrounding quotes/whitespace.
parameter_pattern="(^|[[:space:]\"'])irqchip[.]gicv3_nolpi(=[^[:space:]\"']*)?([[:space:]\"']|$)"
shopt -s nullglob
for config in /etc/default/grub /etc/default/grub.d/*.cfg; do
    [[ -f "$config" ]] || continue
    if grep -Eq "$parameter_pattern" "$config"; then
        # Repeat to handle adjacent copies sharing the same token separator.
        sed -E -i --follow-symlinks ":remove; s/${parameter_pattern}/\\1\\3/g; t remove" "$config"
        echo "Removed irqchip.gicv3_nolpi from ${config}"
    fi
done

# Regenerate even if the source files were already clean: grub.cfg may be stale.
update-grub
[[ -s /boot/grub/grub.cfg ]] || { echo 'ERROR: Missing generated grub.cfg.' >&2; exit 1; }
if grep -Eq "^[[:space:]]*linux(efi)?[[:space:]].*${parameter_pattern}" /boot/grub/grub.cfg; then
    echo 'ERROR: irqchip.gicv3_nolpi remains in generated kernel boot entries.' >&2
    exit 1
fi
echo 'GRUB updated without irqchip.gicv3_nolpi; reboot to apply.'

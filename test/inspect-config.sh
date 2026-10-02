#!/bin/sh
# Renders Config.php with a deliberately hostile password, lints it, then reads the
# value back through PHP so the assertion covers a real round-trip rather than
# matching raw text (var_export correctly escapes backslashes, so the file text
# will never equal the input literally). Used by test/smoke.sh.
set -eu
/bin/sh /opt/churchcrm/render-config.sh true >/dev/null 2>&1

CFG=/var/www/html/Include/Config.php

if php -l "$CFG" >/dev/null 2>&1; then
    echo "LINT_OK"
else
    echo "LINT_FAIL"
    php -l "$CFG" 2>&1 || true
fi

# Evaluate only the password assignment in isolation; including the whole file
# would pull in LoadConfigs.php, which needs a database.
line="$(grep '^\$sPASSWORD' "$CFG")"
printf '%s\n' "<?php" "$line" 'echo $sPASSWORD;' > /tmp/probe.php
printf 'VALUE=%s\n' "$(php /tmp/probe.php)"
rm -f /tmp/probe.php
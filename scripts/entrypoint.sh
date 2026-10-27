#!/bin/bash

if [ ! -f /etc/app_configured ]; then
    # The ZNC password comes from the install form. There is no built-in
    # default, so refuse to set ZNC up without one (and do not report the
    # install as finished).
    if [ -z "${ZNCPASS:-}" ]; then
        echo "ZNCPASS is empty; refusing to set up ZNC without a password." >&2
        exit 1
    fi

    mkdir -p /znc-data/configs

    # If this is not an update....
    if [ ! -f /znc-data/configs/znc.conf ]; then
    #The config doesnt exist, so it must be a fresh install.

        mv /znc.conf /znc-data/configs/znc.conf

        # ZNC's sha256 method stores sha256(password + salt) in hex. Work it
        # out here: driving `znc --makepass` through expect echoed the extra
        # password sends into its output, which sometimes split the Salt line
        # and saved a salt of "=", so the password did not work.
        SALT="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20)"
        HASH="$(printf '%s%s' "${ZNCPASS}" "${SALT}" | sha256sum | awk '{print $1}')"
        if [ "${#SALT}" -ne 20 ] || ! printf '%s' "${HASH}" | grep -qE '^[0-9a-f]{64}$'; then
            echo "Could not hash the ZNC password." >&2
            exit 1
        fi

        sed -i 's|USER|'${USERNAME}'|g' /znc-data/configs/znc.conf
        sed -i 's|ZNCPORT|'${ZNCPORT}'|g' /znc-data/configs/znc.conf
        sed -i 's|ZNCHASH|'${HASH}'|g' /znc-data/configs/znc.conf
        sed -i 's|ZNCSALT|'${SALT}'|g' /znc-data/configs/znc.conf
    else
        # so it is an update/migration!
        echo "Updating the ZNC Config"
        sed -ie 's/Port =.*/Port = '${ZNCPORT}'/g' /znc-data/configs/znc.conf
        sed -i 's/SSL = false/SSL = true/g' /znc-data/configs/znc.conf
        sed -i 's@SSLCertFile = /znc-data/znc.pem@SSLCertFile = /etc/ssl/private/cert.pem@g' /znc-data/configs/znc.conf
        sed -i 's@SSLDHParamFile = /znc-data/znc.pem@SSLDHParamFile = /znc-data/dh.pem@g' /znc-data/configs/znc.conf
        sed -i 's@SSLKeyFile = /znc-data/znc.pem@SSLKeyFile = /etc/ssl/private/key.pem@g' /znc-data/configs/znc.conf
    fi

    if [ ! -f /znc-data/dh.pem ]; then
        openssl dhparam -out /znc-data/dh.pem 2048
    fi

    chown -R znc:znc /znc-data
    chmod 700 /znc-data

    # Tell Appbox we're done installing: mark the callback pending. It is sent
    # in the background below, so it can never keep ZNC from starting.
    touch /etc/appbox_callback_pending
    touch /etc/app_configured
fi

# Send a pending installed callback in the background. The helper retries
# network errors, 408, 429 and 5xx and stops on any other status (e.g. 401
# once the token was used or cleared) instead of retrying forever.
if [ -f /etc/appbox_callback_pending ]; then
    (
        set +e
        /usr/local/bin/appbox-installed-callback
        rm -f /etc/appbox_callback_pending
    ) </dev/null &
fi

/bin/su -s /bin/bash -c "znc --foreground --datadir /znc-data" znc
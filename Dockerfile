FROM alpine:3.24

# ZNCPASS has no default: Appbox always passes the ZNC Password from the
# install form, and entrypoint.sh refuses to set ZNC up without it.
ENV USERNAME=admin
ENV ZNCPORT=6667

RUN addgroup -S znc -g 1000
RUN adduser -D -S -h /znc-data -s /sbin/nologin -G znc znc -u 1000

RUN apk update
RUN apk add git gdb perl-dev python3-dev swig tcl-dev cyrus-sasl-dev openssl openssl-dev ca-certificates
RUN apk add curl bash expect libcap wget cmake argon2-dev
RUN apk add --update alpine-sdk

# The tarball's SHA-512 matches the one in Alpine 3.24's znc APKBUILD.
RUN wget https://znc.in/releases/archive/znc-1.10.3.tar.gz \
    && echo "68f3f6641b480c041010c5596e1234043e05c9137eda06233845017603095f5b  znc-1.10.3.tar.gz" | sha256sum -c -
RUN tar -xzvf znc-1.10.3.tar.gz
# Same optional features as the 1.8.2 build (OpenSSL and IPv6 only), plus
# Argon2id password hashes. Existing SHA-256 hashes still work and ZNC
# upgrades them when the user next logs in.
RUN cd znc-1.10.3 && ./configure --enable-openssl --enable-argon --enable-ipv6 \
        --disable-cyrus --disable-tcl --disable-perl --disable-python \
        --disable-charset --disable-i18n \
    && make && make install
RUN rm -fr /znc-1.10.3*

RUN mkdir -p /znc-data/configs
ADD /sources/znc.conf /znc.conf
ADD scripts/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Sends POST /v1/apps/installed/${INSTANCE_ID} for the entrypoint. It retries
# network errors, 408, 429 and 5xx and stops on any other status.
COPY appbox-installed-callback /usr/local/bin/appbox-installed-callback
RUN chmod 755 /usr/local/bin/appbox-installed-callback

RUN setcap cap_net_bind_service=+ep /usr/local/bin/znc

EXPOSE 80

CMD [ "/entrypoint.sh" ]
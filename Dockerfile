FROM alpine:3.18

# ZNCPASS has no default: Appbox always passes the ZNC Password from the
# install form, and entrypoint.sh refuses to set ZNC up without it.
ENV USERNAME=admin
ENV ZNCPORT=6667

RUN addgroup -S znc -g 1000
RUN adduser -D -S -h /znc-data -s /sbin/nologin -G znc znc -u 1000

RUN apk update
RUN apk add git gdb perl-dev python3-dev swig tcl-dev cyrus-sasl-dev openssl openssl-dev ca-certificates
RUN apk add curl bash expect libcap wget
RUN apk add --update alpine-sdk

# znc.in has moved 1.8.2 to its archive. The checksum is that of Debian's
# znc_1.8.2.orig.tar.gz.
RUN wget https://znc.in/releases/archive/znc-1.8.2.tar.gz \
    && echo "ff238aae3f2ae0e44e683c4aee17dc8e4fdd261ca9379d83b48a7d422488de0d  znc-1.8.2.tar.gz" | sha256sum -c -
RUN tar -xzvf znc-1.8.2.tar.gz
RUN cd znc-1.8.2 && ./configure --with-openssl && make && make install
RUN rm -fr /znc-1.8.2*

RUN mkdir -p /znc-data/configs
ADD /sources/znc.conf /znc.conf
ADD scripts/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Sends POST /v1/apps/installed/${INSTANCE_ID} for the entrypoint. It retries
# network errors, 408, 429 and 5xx and stops on any other status.
COPY appbox-installed-callback /usr/local/bin/appbox-installed-callback
RUN chmod 755 /usr/local/bin/appbox-installed-callback

RUN mkdir -p /appbox/scripts
ADD scripts/changepassword.sh /appbox/scripts/changepassword.sh
RUN chmod +x /appbox/scripts/changepassword.sh

RUN setcap cap_net_bind_service=+ep /usr/local/bin/znc

EXPOSE 80

CMD [ "/entrypoint.sh" ]
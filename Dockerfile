FROM alpine:3.18

ENV USERNAME=admin
ENV ZNCPASS=admin123
ENV ZNCPORT=6667

RUN addgroup -S znc -g 1000
RUN adduser -D -S -h /znc-data -s /sbin/nologin -G znc znc -u 1000

RUN apk update
RUN apk add git gdb perl-dev python3-dev swig tcl-dev cyrus-sasl-dev openssl openssl-dev ca-certificates
RUN apk add curl bash expect libcap wget
RUN apk add --update alpine-sdk

RUN wget https://znc.in/releases/znc-1.8.2.tar.gz
RUN tar -xzvf znc-1.8.2.tar.gz
RUN cd znc-1.8.2 && ./configure --with-openssl && make && make install
RUN rm -fr /znc-1.8.2*

RUN mkdir -p /znc-data/configs
ADD /sources/znc.conf /znc.conf
ADD scripts/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

RUN mkdir -p /appbox/scripts
ADD scripts/changepassword.sh /appbox/scripts/changepassword.sh
RUN chmod +x /appbox/scripts/changepassword.sh

RUN setcap cap_net_bind_service=+ep /usr/local/bin/znc

EXPOSE 80

CMD [ "/entrypoint.sh" ]